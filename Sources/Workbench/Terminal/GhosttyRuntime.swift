import AppKit
import GhosttyKit

/// Owns the single libghostty app instance and routes its C callbacks to terminal views.
/// Every ghostty_* call happens on the main thread; only `wakeup` arrives off-main.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    /// Surface-targeted actions the terminal view does not handle itself (splits, tabs…).
    var onSurfaceAction: ((TerminalView, ghostty_action_s) -> Bool)?

    private init() {}

    func start() {
        guard app == nil else { return }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           FileManager.default.fileExists(atPath: res.path) {
            setenv("GHOSTTY_RESOURCES_DIR", res.path, 1)
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("Workbench: ghostty_init failed"); return
        }
        guard let cfg = makeConfig() else { return }
        defer { ghostty_config_free(cfg) }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
        }
        rt.action_cb = { _, target, action in
            MainActor.assumeIsolated { GhosttyRuntime.shared.handle(target: target, action: action) }
        }
        rt.read_clipboard_cb = { ud, location, state, mimes, count, list in
            MainActor.assumeIsolated { GhosttyRuntime.readClipboard(ud, location, state, mimes, count, list) }
        }
        rt.confirm_read_clipboard_cb = { ud, confirm, state, request in
            MainActor.assumeIsolated { GhosttyRuntime.confirmReadClipboard(ud, confirm, state, request) }
        }
        rt.write_clipboard_cb = { _, location, content, count, confirm in
            MainActor.assumeIsolated { GhosttyRuntime.writeClipboard(location, content, count, confirm) }
        }
        rt.close_surface_cb = { ud, processAlive in
            MainActor.assumeIsolated { TerminalView.from(ud)?.surfaceRequestedClose(processAlive: processAlive) }
        }

        app = ghostty_app_new(&rt, cfg)
        if app == nil { NSLog("Workbench: ghostty_app_new failed"); return }
        ghostty_app_set_focus(app, NSApp.isActive)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, true) } }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_set_focus(a, false) } }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let a = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(a) } }
        }
    }

    func tick() { if let app { ghostty_app_tick(app) } }

    /// User's own Ghostty config first (fonts, keybinds), then our theme on top so the chrome matches.
    private func makeConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        let theme = Theme.ghosttyConfig
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-ghostty.conf")
        if (try? theme.write(to: url, atomically: true, encoding: .utf8)) != nil {
            ghostty_config_load_file(cfg, url.path)
        }
        ghostty_config_finalize(cfg)
        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let m = d.message { NSLog("Workbench: ghostty config: %@", String(cString: m)) }
        }
        return cfg
    }

    // MARK: Actions

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = TerminalView.from(ghostty_surface_userdata(surface))
        else { return false }
        if view.handle(action: action) { return true }
        return onSurfaceAction?(view, action) ?? false
    }

    // MARK: Clipboard (text; files and images arrive as paths)

    private static let textMimes = ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"]

    private static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
                                      _ state: UnsafeMutableRawPointer?,
                                      _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int,
                                      _ list: Bool) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = TerminalView.from(ud)?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        var wanted: [String] = []
        for i in 0..<count { if let p = mimes?[i] { wanted.append(String(cString: p)) } }
        let text = pasteText(NSPasteboard.general)
        let served = wanted.filter { textMimes.contains($0) }
        if (text == nil || served.isEmpty) && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, state: state, mimes: text == nil ? [] : served, text: text ?? "",
                 available: list && text != nil ? ["text/plain"] : [], confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// What ⌘V puts in the terminal. Files copied in Finder become their (escaped) paths, like Ghostty's
    /// own app; an image with no text (a copied screenshot) is saved as a PNG and pasted as its path,
    /// which Claude Code and Codex attach as an image.
    static func pasteText(_ pb: NSPasteboard) -> String? {
        let files = (pb.pasteboardItems ?? []).compactMap { item -> String? in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL else { return nil }
            return shellEscape(url.path)
        }
        if !files.isEmpty { return files.joined(separator: " ") }
        if let s = pb.string(forType: .string) { return s }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Seperate/pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("paste-\(f.string(from: Date())).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return shellEscape(url.path)
    }

    /// Backslash-escapes characters a shell would split or interpret.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\\'\"`$&|;<>()[]{}*?!#~=%^")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// Pastes that Ghostty flags as unsafe (e.g. contain newlines) are allowed — agents' prompts are
    /// multi-line all the time. Programs reading the clipboard via OSC 52/Kitty are denied.
    private static func confirmReadClipboard(_ ud: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                             _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
        guard let surface = TerminalView.from(ud)?.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c = confirm?.pointee else {
            ghostty_surface_deny_clipboard_request(surface, state); return
        }
        var complete = ghostty_clipboard_complete_s(contents: c.contents, contents_len: c.contents_len,
                                                    available: c.available, available_len: c.available_len,
                                                    confirmed: true, remember: false)
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }

    private static func complete(_ surface: ghostty_surface_t, state: UnsafeMutableRawPointer?,
                                 mimes: [String], text: String, available: [String], confirmed: Bool) {
        let data = Array(text.utf8CString)   // includes NUL; len excludes it
        let mimePtrs = mimes.map { strdup($0)! }
        let availPtrs = available.map { strdup($0)! }
        defer { (mimePtrs + availPtrs).forEach { free($0) } }
        data.withUnsafeBufferPointer { buf in
            let contents = mimePtrs.map {
                ghostty_clipboard_content_s(mime: $0, data: buf.baseAddress, len: data.count - 1)
            }
            let avail: [UnsafePointer<CChar>?] = availPtrs.map { UnsafePointer($0) }
            contents.withUnsafeBufferPointer { cb in
                avail.withUnsafeBufferPointer { ab in
                    var c = ghostty_clipboard_complete_s(contents: cb.baseAddress, contents_len: cb.count,
                                                         available: ab.baseAddress, available_len: ab.count,
                                                         confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &c, state)
                }
            }
        }
    }

    private static func writeClipboard(_ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?,
                                       _ count: Int, _ confirm: Bool) {
        // Writes that need confirmation come from programs (OSC 52); skip them rather than prompt.
        guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content else { return }
        for i in 0..<count {
            let c = content[i]
            guard let mime = c.mime, textMimes.contains(String(cString: mime)), let d = c.data else { continue }
            let s = String(decoding: UnsafeRawBufferPointer(start: d, count: c.len), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            return
        }
    }
}
