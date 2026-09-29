// @purpose The installer's single window and its steps: welcome, quit running app, installing, done, newer installed, failed.
// @role    InstallerController, created by main.swift; runs Installation on a background queue and ejects the DMG on finish.
// @deps    AppKit, Installation; NSRunningApplication (by bundle ID) and hdiutil for eject.
// @gotcha  Quits the running Seperate via terminate() and waits up to 30s; colors are hard-coded to the Bone theme; UI strings are Chinese; see docs/modules/installer/README.md
import AppKit

/// The installer's single window: welcome → (quit running app) → installing → done.
/// Colors follow the app's "Bone" theme so the first thing a new user sees already looks like Seperate.
@MainActor
final class InstallerController: NSObject {
    enum Step {
        case welcome
        case quitFirst(String?)
        case installing
        case done
        case newerInstalled
        case failed(String)
    }

    enum C {
        static let ground = color(0x272822)
        static let panel = color(0x2B2C26)
        static let line = color(0x3A3B35)
        static let text = color(0xE8E8E2)
        static let muted = color(0x9C9D95)
        static let faint = color(0x6D6E67)
        static let wait = color(0xE6B450)
        static let danger = color(0xF08A80)
        static func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    let window: NSWindow
    private let install: Installation
    private var step: Step = .welcome
    private let progress = NSProgressIndicator()
    private let ejectBox = NSButton(checkboxWithTitle: tr("完成后推出安装盘", "Eject the installer disk when done"), target: nil, action: nil)
    private var progressTimer: Timer?

    /// The mounted DMG this installer runs from, if any.
    private var volume: URL? {
        let parts = Bundle.main.bundleURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(parts[2])")
    }

    init(install: Installation) {
        self.install = install
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = C.ground
        window.title = tr("安装 Seperate", "Install Seperate")
        ejectBox.state = .on
        if let installed = install.installedInfo, installed.build > install.payloadInfo.build { step = .newerInstalled }
        render()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Rendering

    func show(_ s: Step) { step = s; render() }

    private func render() {
        let payload = install.payloadInfo
        let icns = install.payload.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let icon = NSImageView(image: NSImage(contentsOf: icns) ?? NSWorkspace.shared.icon(forFile: install.payload.path))
        icon.image?.size = NSSize(width: 84, height: 84)
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        var rows: [NSView] = [icon]
        var buttons: [NSButton] = []

        switch step {
        case .welcome:
            let installed = install.installedInfo
            rows.append(label("Seperate \(payload.version)", size: 17, weight: .semibold))
            rows.append(label(tr("在一个窗口里并排运行 Claude Code、Codex 和终端。", "Run Claude Code, Codex and terminals side by side in one window."), color: C.muted))
            rows.append(destinationPill())
            if let installed {
                rows.append(label(installed.build == payload.build ? tr("这个版本已安装，可以重新安装", "This version is already installed; you can reinstall it") : tr("将替换已安装的 \(installed.version)", "Replaces the installed \(installed.version)"), size: 11.5, color: C.wait))
            }
            buttons = [button(tr("取消", "Cancel"), #selector(quit)), button(installed == nil ? tr("安装", "Install") : tr("更新", "Update"), #selector(start), primary: true)]
        case .quitFirst(let note):
            rows.append(label(tr("Seperate 正在运行", "Seperate is running"), size: 17, weight: .semibold))
            rows.append(label(note ?? tr("需要先退出 Seperate 才能安装。正在运行的终端会像平常退出时一样提示你确认。", "Seperate needs to quit before installing. Running terminals will ask you to confirm, as when you quit normally."), color: C.muted))
            buttons = [button(tr("取消", "Cancel"), #selector(quit)), button(tr("退出并安装", "Quit and Install"), #selector(quitRunningAndInstall), primary: true)]
        case .installing:
            rows.append(label(tr("正在安装…", "Installing…"), size: 17, weight: .semibold))
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0; progress.maxValue = 1
            progress.widthAnchor.constraint(equalToConstant: 300).isActive = true
            rows.append(progress)
            rows.append(label(tr("正在复制 Seperate.app 到“\(folderName)”", "Copying Seperate.app to “\(folderName)”"), size: 11.5, color: C.faint))
            let cancel = button(tr("取消", "Cancel"), #selector(quit)); cancel.isEnabled = false
            buttons = [cancel]
        case .done:
            rows.append(label(tr("已安装", "Installed"), size: 17, weight: .semibold))
            rows.append(label(tr("Seperate 已在“\(folderName)”里。以后的新版本会在应用内更新。", "Seperate is in “\(folderName)”. Future versions update inside the app."), color: C.muted))
            if volume != nil { rows.append(ejectBox) }
            buttons = [button(tr("完成", "Done"), #selector(finish)), button(tr("打开 Seperate", "Open Seperate"), #selector(openAndFinish), primary: true)]
        case .newerInstalled:
            let v = install.installedInfo?.version ?? "?"
            rows.append(label(tr("已安装更新的版本", "A newer version is installed"), size: 17, weight: .semibold))
            rows.append(label(tr("“\(folderName)”里已经是 Seperate \(v)，比这个安装包（\(payload.version)）更新。", "“\(folderName)” already has Seperate \(v), newer than this installer (\(payload.version))."), color: C.muted))
            buttons = [button(tr("关闭", "Close"), #selector(quit)), button(tr("打开 Seperate", "Open Seperate"), #selector(openAndFinish), primary: true)]
        case .failed(let message):
            rows.append(label(tr("安装没有完成", "Installation didn’t finish"), size: 17, weight: .semibold))
            rows.append(label(message, color: C.danger))
            rows.append(label(tr("原来的版本没有改动。", "The existing version was not changed."), size: 11.5, color: C.faint))
            buttons = [button(tr("关闭", "Close"), #selector(quit)), button(tr("重试", "Try Again"), #selector(start), primary: true)]
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: icon)

        let bar = NSStackView(views: buttons)
        bar.orientation = .horizontal
        bar.spacing = 8

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = C.ground.cgColor
        [stack, bar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        window.defaultButtonCell = buttons.last?.cell as? NSButtonCell
    }

    private var folderName: String { install.destinationDir.path == "/Applications" ? tr("应用程序", "Applications") : install.destinationDir.path }

    private func label(_ s: String, size: CGFloat = 12.5, weight: NSFont.Weight = .regular, color: NSColor = C.text) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func destinationPill() -> NSView {
        let row = NSStackView(views: [label(tr("安装到", "Install to"), size: 11.5, color: C.muted), label(folderName, size: 11.5, weight: .medium)])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = C.panel.cgColor
        row.layer?.borderColor = C.line.cgColor
        row.layer?.borderWidth = 1
        row.layer?.cornerRadius = 6
        return row
    }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if primary { b.keyEquivalent = "\r"; b.bezelColor = .controlAccentColor }
        return b
    }

    // MARK: Actions

    private var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Installation.bundleID)
    }

    @objc private func start() {
        if !running.isEmpty { return show(.quitFirst(nil)) }
        show(.installing)
        var stage: URL?
        let total = Double(max(Installation.directorySize(install.payload), 1))
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stage else { return }
                self.progress.doubleValue = min(Double(Installation.directorySize(stage)) / total, 0.98)
            }
        }
        let install = self.install
        DispatchQueue.global(qos: .userInitiated).async {
            let error: Error?
            do { try install.run(staging: { url in DispatchQueue.main.async { stage = url } }); error = nil } catch let e { error = e }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.progressTimer?.invalidate()
                    if let error { self.show(.failed(Self.describe(error))) } else { self.progress.doubleValue = 1; self.show(.done) }
                }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteNoPermissionError {
            return tr("没有权限写入目标文件夹。请用管理员账户运行，或把 Seperate 拖到“应用程序”。", "No permission to write to the destination folder. Run as an administrator, or drag Seperate to Applications.")
        }
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteOutOfSpaceError { return tr("磁盘空间不足。", "Not enough disk space.") }
        return e.localizedDescription
    }

    /// Asks the running app to quit through its normal path (so it can confirm with open terminals), then installs.
    @objc private func quitRunningAndInstall() {
        running.forEach { $0.terminate() }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                waited += 0.3
                if self.running.isEmpty { t.invalidate(); self.start() }
                else if waited > 30 { t.invalidate(); self.show(.quitFirst(tr("Seperate 还没有退出。保存正在进行的工作，退出后再试。", "Seperate hasn’t quit yet. Save your work, quit it, then try again."))) }
            }
        }
    }

    @objc private func openAndFinish() {
        NSWorkspace.shared.openApplication(at: install.destination, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish() } }
        }
    }

    @objc private func finish() {
        if let volume, ejectBox.state == .on, case .done = step {
            // The DMG can't be ejected while this installer runs from it; detach just after we exit.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/hdiutil detach -quiet \"$0\"", volume.path]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Design check

    /// Renders every step to PNGs without showing a window (`--snapshot DIR`).
    func snapshot(to dir: URL) throws {
        let steps: [(String, Step)] = [("1-welcome", .welcome), ("2-quit", .quitFirst(nil)), ("3-installing", .installing),
                                       ("4-done", .done), ("5-newer", .newerInstalled), ("6-failed", .failed(tr("磁盘空间不足。", "Not enough disk space.")))]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, s) in steps {
            show(s)
            if case .installing = s { progress.doubleValue = 0.62 }
            guard let view = window.contentView else { continue }
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 400)
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
