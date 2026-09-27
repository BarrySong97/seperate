// @purpose `--render-shots <dir>`: builds the real window from demo projects and renders it to PNGs for the website.
// @role    Entered from main.swift instead of AppDelegate (DEBUG builds only); owns its own Store and exits when done.
// @deps    AppKit, Store, MainWindowController, GhosttyRuntime, TerminalView, CommandPalette
// @gotcha  Renders views into bitmaps (terminals read from Ghostty's IOSurface), never a screen capture, so no
//          permission prompt. The window stays off every screen. Run via scripts/render-shots.sh.
//          docs/plans/2026-09-27-render-shots.md
#if DEBUG
import AppKit
import Carbon.HIToolbox
import CoreImage

@MainActor
enum ShotRenderer {
    static func run(out: URL) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, never takes focus
        Task { @MainActor in
            do { try await render(to: out); exit(0) } catch { print("render-shots: \(error)"); exit(1) }
        }
        app.run()
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private static var keep: [AnyObject] = []

    private static func render(to out: URL) async throws {
        guard let root = Core.shotsRoot else { throw Failure(description: "SEPERATE_SHOTS_ROOT is not set") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        GhosttyRuntime.shared.extraConfig = "font-size = 15"
        GhosttyRuntime.shared.start()

        let store = Store()
        store.renameWorkspace(store.activeID, to: "工作")
        let wc = MainWindowController(store: store)
        keep = [store, wc]
        guard let window = wc.window else { throw Failure(description: "no window") }
        // Retina output: the window takes its scale from the screen its frame is on (it is never shown).
        let sharpest = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        window.setFrame(NSRect(origin: sharpest?.frame.origin ?? .zero, size: window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1440, height: 900)).size), display: false)
        if window.backingScaleFactor < 2 { print("render-shots: no Retina screen, images will be 1x") }

        // Scene — first launch: import projects the agents have used (nothing added yet).
        window.contentView?.layoutSubtreeIfNeeded()
        try await pause(0.5)
        store.showImport()
        try await pause(2.5)
        let importFull = try capture(window, scale: 4)
        if let card = panelCard(in: window) { try save(spotlight(importFull, window, keep: [card], radius: 12), "import", out) }
        overlays(in: window).forEach { $0.removeFromSuperview() }

        for name in ["atlas-cli", "pixel-api", "lumen-notes"] { store.addProject(path: root + name) }   // newest on top

        store.refresh()
        let sessions = try await waitFor("the demo sessions", timeout: 20) { store.discovered.count >= 4 ? store.discovered : nil }
        func find(_ kind: AgentKind, _ folder: String) throws -> AgentSession {
            guard let s = sessions.filter({ $0.kind == kind && $0.cwd.hasSuffix("/" + folder) }).max(by: { $0.lastActivity < $1.lastActivity })
            else { throw Failure(description: "no \(kind.rawValue) session in \(folder)") }
            return s
        }
        let notesSearch = try find(.claude, "lumen-notes")
        let darkMode = try find(.codex, "暗色模式")
        let apiTests = try find(.claude, "pixel-api")
        let atlasJSON = try find(.codex, "atlas-cli")
        print("render-shots: sessions \(sessions.map { "\($0.kind.rawValue):\($0.title)" })")

        // Scene 1 — three agents side by side (homepage hero / OG image).
        store.open(notesSearch.id)
        store.open(darkMode.id, newPane: true)
        store.open(apiTests.id, newPane: true)
        wc.workspace.sync(structure: true)
        try await pause(0.5)
        wc.sidebar.debugExpandAll()
        try await settle(store, window)
        // Inbox states normally come from the agents' hooks; this run has none, so set them.
        store.shotsSetPhase(atlasJSON.id, .needsInput("Approval requested: cargo run -- --json to"), need: .permission)
        store.shotsSetPhase(notesSearch.id, .done("已加上 searchNotes(query)：按标题搜索，忽略大小写"))
        store.shotsSetPhase(apiTests.id, .working)
        try await pause(1)
        try save(capture(window), "hero", out)

        // Scene — the inbox above the bell. Its content is the real InboxView; the frame stands in for NSPopover's.
        let inbox = ShotPopover(content: InboxPopover.debugContent(store: store))
        let bell = wc.sidebar.debugBell
        let anchor = window.contentView!.convert(bell.bounds, from: bell)
        inbox.frame = NSRect(x: max(8, anchor.midX - 60), y: anchor.minY - inbox.frame.height - 8, width: inbox.frame.width, height: inbox.frame.height)
        window.contentView!.addSubview(inbox)
        try await pause(0.5)
        let inboxFull = try capture(window, scale: 4)
        let bellRect = window.contentView!.convert(bell.bounds.insetBy(dx: -6, dy: -6), from: bell)
        try save(spotlight(inboxFull, window, keep: [inbox.frame, bellRect], radius: 10), "inbox", out)
        inbox.removeFromSuperview()

        // Scene 2 — 2×2 with all four agents.
        store.open(atlasJSON.id, newPane: true)
        store.apply(.grid)
        store.toggleSidebar()
        wc.workspace.sync(structure: true)
        try await pause(0.6)
        try await settle(store, window)
        try save(capture(window), "panes", out)
        store.toggleSidebar()
        try await pause(0.6)

        // Scene 3 — the command palette, searched with pinyin initials.
        store.apply(.three)
        wc.workspace.sync(structure: true)
        try await settle(store, window)
        let side = window.contentView!.convert(wc.sidebar.bounds, from: wc.sidebar)
        let tree = NSRect(x: side.minX, y: side.minY, width: side.width, height: min(side.height, 320))
        try save(spotlight(capture(window, scale: 4), window, keep: [tree], radius: 12), "worktree", out)
        store.showPalette()
        try await pause(0.5)
        if let palette = descendants(of: window.contentView).compactMap({ $0 as? CommandPalette }).first {
            palette.debugType(ProcessInfo.processInfo.environment["SHOTS_PALETTE_QUERY"].flatMap { $0.isEmpty ? nil : $0 } ?? "a")
        }
        try await pause(2)
        let paletteFull = try capture(window, scale: 4)
        if let card = panelCard(in: window) { try save(spotlight(paletteFull, window, keep: [card], radius: 12), "palette", out) }
        print("render-shots: done → \(out.path)")
    }

    // MARK: Waiting

    private static func pause(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private static func waitFor<T>(_ what: String, timeout: Double, _ check: () -> T?) async throws -> T {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = check() { return v }
            try await pause(0.25)
        }
        throw Failure(description: "timed out waiting for \(what)")
    }

    /// Waits until every visible terminal has drawn and its text stopped changing. Answers an agent's
    /// "trust this folder?" prompt with its Yes option (moving to it first; Claude's default is "No, exit").
    private static var trustKeys: [ObjectIdentifier: Int] = [:]
    private static func settle(_ store: Store, _ window: NSWindow) async throws {
        var last: [ObjectIdentifier: String] = [:]
        var stableFor = 0.0
        let end = Date().addingTimeInterval(45)
        while Date() < end {
            try await pause(0.6)
            let shown = visibleTerminals(in: window)
            var changed = shown.isEmpty
            for t in shown {
                let id = ObjectIdentifier(t)
                let text = t.visibleText() ?? ""
                if answerTrust(t, text) { changed = true }
                if last[id] != text || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { changed = true }
                // An agent still starting up (Codex: "Resuming session…", model "loading") is not settled.
                if text.contains("Resuming session") || text.contains("loading") { changed = true }
                last[id] = text
            }
            stableFor = changed ? 0 : stableFor + 0.6
            if stableFor >= 3 { return }
        }
        print("render-shots: terminals still changing after 45 s, capturing anyway")
    }

    /// One key per call: Down until the selected line is the Yes option, then Return. True when a key was sent.
    private static func answerTrust(_ t: TerminalView, _ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { let l = $0.lowercased(); return l.contains("trust") && (l.contains("folder") || l.contains("directory")) }),
              lines.contains(where: { $0.contains("Yes") }) else { return false }
        let id = ObjectIdentifier(t)
        guard trustKeys[id, default: 0] < 6 else { return false }
        trustKeys[id, default: 0] += 1
        let marker = lines.first { l in ["❯", "›", "▶", ">"].contains { l.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }
        if marker?.contains("Yes") == true {
            print("render-shots: trusting the demo folder in \(t.sessionID)")
            t.pressKey(kVK_Return, text: "\r")
        } else {
            t.pressKey(kVK_DownArrow, text: nil)
        }
        return true
    }

    // MARK: Capture

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func visibleTerminals(in window: NSWindow) -> [TerminalView] {
        descendants(of: window.contentView).compactMap { $0 as? TerminalView }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
    }

    /// Floating panels over the workspace (command palette, import): drawn last, above the terminals.
    private static func overlays(in window: NSWindow) -> [NSView] {
        (window.contentView?.subviews ?? []).filter { $0 is CommandPalette || $0 is ImportPanel || $0 is ShotPopover }
    }

    /// The window drawn in three layers: AppKit views, each terminal's Ghostty frame in its place, then panels.
    /// Resolution views are drawn at: 2 for whole-window shots, 4 where a part is shown enlarged.
    private static var renderScale: CGFloat = 2

    private static func bitmap(for view: NSView, in rect: NSRect) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * renderScale), pixelsHigh: Int(rect.height * renderScale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        return rep
    }

    private static func capture(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        renderScale = scale
        guard let content = window.contentView, let rep = bitmap(for: content, in: content.bounds)
        else { throw Failure(description: "cannot render the window") }
        let panels = overlays(in: window)
        panels.forEach { $0.isHidden = true }
        content.cacheDisplay(in: content.bounds, to: rep)
        panels.forEach { $0.isHidden = false }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure(description: "no bitmap context") }
        let cg = ctx.cgContext
        func place(_ v: NSView) -> CGRect {
            var r = content.convert(v.bounds, from: v)
            if content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
            return r
        }
        for t in visibleTerminals(in: window) {
            guard let image = t.renderedImage() else { continue }
            let r = place(t)
            cg.saveGState(); cg.clip(to: r); cg.draw(image, in: r); cg.restoreGState()
        }
        for p in panels { drawPanel(p, in: cg, place: place) }
        ctx.flushGraphics()
        return rep
    }

    /// A floating panel. cacheDisplay draws what views draw themselves but not layer properties, so first
    /// the panel's own backgrounds, borders and shadows are painted, then its content goes on top. Before
    /// that: the show animation is jumped to its end, table rows are created (a never-shown window has only
    /// made the first), and the search field lets go of focus so it draws its text itself.
    private static func drawPanel(_ p: NSView, in cg: CGContext, place: (NSView) -> CGRect) {
        p.window?.makeFirstResponder(nil)
        p.window?.endEditing(for: nil)
        for v in [p] + descendants(of: p) {
            v.layer?.removeAllAnimations()
            if v.alphaValue < 1 { v.alphaValue = 1 }
            v.layer?.transform = CATransform3DIdentity
        }
        for table in descendants(of: p).compactMap({ $0 as? NSTableView }) {
            table.layoutSubtreeIfNeeded()
            let rows = table.rows(in: table.visibleRect)
            for r in rows.location..<(rows.location + rows.length) {
                _ = table.rowView(atRow: r, makeIfNecessary: true)
                _ = table.view(atColumn: 0, row: r, makeIfNecessary: true)
            }
        }
        p.layoutSubtreeIfNeeded()
        // Seperate's own views and the panel's card, not AppKit's internal layers; the dimming scrim is left out (the blur sets the panel apart).
        let own = p.subviews.filter { $0.frame.size != p.bounds.size } + descendants(of: p).filter { Bundle(for: type(of: $0)) == Bundle.main }
        for v in own where !v.isHiddenOrHasHiddenAncestor {
            guard let layer = v.layer, layer.opacity > 0 else { continue }
            let r = place(v)
            let path = CGPath(roundedRect: r, cornerWidth: layer.cornerRadius, cornerHeight: layer.cornerRadius, transform: nil)
            if let bg = layer.backgroundColor, bg.alpha > 0 {
                cg.saveGState()
                if let sh = v.shadow, let color = sh.shadowColor {
                    cg.setShadow(offset: sh.shadowOffset, blur: sh.shadowBlurRadius, color: color.cgColor)
                }
                cg.addPath(path); cg.setFillColor(bg); cg.fillPath()
                cg.restoreGState()
            }
            if layer.borderWidth > 0, let border = layer.borderColor {
                cg.saveGState()
                cg.addPath(path); cg.setStrokeColor(border); cg.setLineWidth(layer.borderWidth); cg.strokePath()
                cg.restoreGState()
            }
        }
        guard let rep = bitmap(for: p, in: p.bounds) else { return }
        p.cacheDisplay(in: p.bounds, to: rep)
        if let image = rep.cgImage { cg.draw(image, in: place(p)) }
        // A table's rows are not drawn as part of an ancestor's cacheDisplay; draw each table on its own,
        // clipped to what its scroll view shows.
        for table in descendants(of: p).compactMap({ $0 as? NSTableView }) where !table.isHiddenOrHasHiddenAncestor {
            guard let trep = bitmap(for: table, in: table.visibleRect) else { continue }
            table.cacheDisplay(in: table.visibleRect, to: trep)
            guard let image = trep.cgImage else { continue }
            var r = place(table)
            let visible = table.visibleRect
            r = CGRect(x: r.minX + visible.minX, y: r.maxY - visible.maxY, width: visible.width, height: visible.height)
            cg.saveGState()
            if let clip = table.enclosingScrollView?.contentView { cg.clip(to: place(clip)) }
            cg.draw(image, in: r)
            cg.restoreGState()
        }
        // Editable fields and image views are skipped by an ancestor's cacheDisplay too: draw them one by one.
        for v in descendants(of: p) where (v is NSImageView || (v as? NSTextField)?.isEditable == true)
            && !v.isHiddenOrHasHiddenAncestor && v.enclosingScrollView == nil {
            if let iv = v as? NSImageView, let image = iv.image {
                // Template symbols take their tint from contentTintColor.
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    if image.isTemplate { (iv.contentTintColor ?? .labelColor).set(); rect.fill(using: .sourceAtop) }
                    return true
                }
                let r = place(iv)
                let fit = NSRect(x: r.midX - image.size.width / 2, y: r.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                tinted.draw(in: fit)
                NSGraphicsContext.restoreGraphicsState()
            } else if let vrep = bitmap(for: v, in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: vrep)
                if let image = vrep.cgImage { cg.draw(image, in: place(v)) }
            }
        }
    }

    /// The card of the open floating panel (its largest child that is not the full-size scrim).
    private static func panelCard(in window: NSWindow) -> NSRect? {
        guard let panel = overlays(in: window).first else { return nil }
        let card = panel.subviews.filter { $0.frame.size != panel.bounds.size }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        return card.map { window.contentView!.convert($0.bounds, from: $0) }
    }

    /// The blurred window as the backdrop, and the part being shown (`keep`, window points, top-left origin)
    /// enlarged and centred over it with a shadow, so it can be read at website size. Output is 2x the window.
    private static func spotlight(_ full: NSBitmapImageRep, _ window: NSWindow, keep: [NSRect], radius: CGFloat) throws -> NSBitmapImageRep {
        guard let sharp = full.cgImage, let content = window.contentView else { throw Failure(description: "no image") }
        let src = CGFloat(full.pixelsWide) / content.bounds.width      // source pixels per point (4)
        let W = content.bounds.width, H = content.bounds.height, outScale: CGFloat = 2
        func px(_ r: NSRect, _ k: CGFloat) -> CGRect { CGRect(x: r.minX * k, y: (H - r.maxY) * k, width: r.width * k, height: r.height * k) }

        let base = CIImage(cgImage: sharp)
        let soft = base.clampedToExtent().applyingGaussianBlur(sigma: 6 * src).cropped(to: base.extent)
        let ci = CIContext()
        guard let blurred = ci.createCGImage(soft, from: base.extent),
              let ctx = CGContext(data: nil, width: Int(W * outScale), height: Int(H * outScale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "no context") }
        ctx.interpolationQuality = .high
        ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: W * outScale, height: H * outScale))

        // The piece: the union of what is kept, sharp where kept, the blurred window in between.
        let union = keep.dropFirst().reduce(keep[0]) { $0.union($1) }
        let pieceSrc = px(union, src).integral
        guard let pctx = CGContext(data: nil, width: Int(pieceSrc.width), height: Int(pieceSrc.height), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "no context") }
        let whole = CGRect(x: -pieceSrc.minX, y: -pieceSrc.minY, width: CGFloat(sharp.width), height: CGFloat(sharp.height))
        pctx.draw(blurred, in: whole)
        for r in keep {
            pctx.saveGState()
            let k = px(r, src).offsetBy(dx: -pieceSrc.minX, dy: -pieceSrc.minY)
            pctx.addPath(CGPath(roundedRect: k, cornerWidth: radius * src, cornerHeight: radius * src, transform: nil))
            pctx.clip()
            pctx.draw(sharp, in: whole)
            pctx.restoreGState()
        }
        guard let piece = pctx.makeImage() else { throw Failure(description: "no piece") }

        // As large as fits in ~80% of the frame, at most 2x (the source is drawn at 4x, so it stays sharp).
        let zoom = min(W * 0.8 / union.width, H * 0.8 / union.height, 2)
        let size = CGSize(width: union.width * zoom * outScale, height: union.height * zoom * outScale)
        let target = CGRect(x: (W * outScale - size.width) / 2, y: (H * outScale - size.height) / 2, width: size.width, height: size.height)
        let path = CGPath(roundedRect: target, cornerWidth: radius * zoom * outScale, cornerHeight: radius * zoom * outScale, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24 * outScale), blur: 60 * outScale, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(path); ctx.setFillColor(Theme.panel.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.draw(piece, in: target)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { throw Failure(description: "no image") }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func save(_ rep: NSBitmapImageRep, _ name: String, _ out: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "PNG encoding failed") }
        try png.write(to: out.appendingPathComponent(name + ".png"))
        print("render-shots: wrote \(name).png \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }
}
/// A popover-shaped card for content that normally lives in an NSPopover window.
@MainActor
private final class ShotPopover: NSView {
    init(content: NSView) {
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line2.cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 30
        shadow?.shadowOffset = NSSize(width: 0, height: -10)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.5)
        content.frame = bounds
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}
#endif
