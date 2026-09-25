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
    private let ejectBox = NSButton(checkboxWithTitle: "完成后推出安装盘", target: nil, action: nil)
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
        window.title = "安装 Seperate"
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
            rows.append(label("在一个窗口里并排运行 Claude Code、Codex 和终端。", color: C.muted))
            rows.append(destinationPill())
            if let installed {
                rows.append(label(installed.build == payload.build ? "这个版本已安装，可以重新安装" : "将替换已安装的 \(installed.version)", size: 11.5, color: C.wait))
            }
            buttons = [button("取消", #selector(quit)), button(installed == nil ? "安装" : "更新", #selector(start), primary: true)]
        case .quitFirst(let note):
            rows.append(label("Seperate 正在运行", size: 17, weight: .semibold))
            rows.append(label(note ?? "需要先退出 Seperate 才能安装。正在运行的终端会像平常退出时一样提示你确认。", color: C.muted))
            buttons = [button("取消", #selector(quit)), button("退出并安装", #selector(quitRunningAndInstall), primary: true)]
        case .installing:
            rows.append(label("正在安装…", size: 17, weight: .semibold))
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0; progress.maxValue = 1
            progress.widthAnchor.constraint(equalToConstant: 300).isActive = true
            rows.append(progress)
            rows.append(label("正在复制 Seperate.app 到“\(folderName)”", size: 11.5, color: C.faint))
            let cancel = button("取消", #selector(quit)); cancel.isEnabled = false
            buttons = [cancel]
        case .done:
            rows.append(label("已安装", size: 17, weight: .semibold))
            rows.append(label("Seperate 已在“\(folderName)”里。以后的新版本会在应用内更新。", color: C.muted))
            if volume != nil { rows.append(ejectBox) }
            buttons = [button("完成", #selector(finish)), button("打开 Seperate", #selector(openAndFinish), primary: true)]
        case .newerInstalled:
            let v = install.installedInfo?.version ?? "?"
            rows.append(label("已安装更新的版本", size: 17, weight: .semibold))
            rows.append(label("“\(folderName)”里已经是 Seperate \(v)，比这个安装包（\(payload.version)）更新。", color: C.muted))
            buttons = [button("关闭", #selector(quit)), button("打开 Seperate", #selector(openAndFinish), primary: true)]
        case .failed(let message):
            rows.append(label("安装没有完成", size: 17, weight: .semibold))
            rows.append(label(message, color: C.danger))
            rows.append(label("原来的版本没有改动。", size: 11.5, color: C.faint))
            buttons = [button("关闭", #selector(quit)), button("重试", #selector(start), primary: true)]
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

    private var folderName: String { install.destinationDir.path == "/Applications" ? "应用程序" : install.destinationDir.path }

    private func label(_ s: String, size: CGFloat = 12.5, weight: NSFont.Weight = .regular, color: NSColor = C.text) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func destinationPill() -> NSView {
        let row = NSStackView(views: [label("安装到", size: 11.5, color: C.muted), label(folderName, size: 11.5, weight: .medium)])
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
            return "没有权限写入目标文件夹。请用管理员账户运行，或把 Seperate 拖到“应用程序”。"
        }
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteOutOfSpaceError { return "磁盘空间不足。" }
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
                else if waited > 30 { t.invalidate(); self.show(.quitFirst("Seperate 还没有退出。保存正在进行的工作，退出后再试。")) }
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
                                       ("4-done", .done), ("5-newer", .newerInstalled), ("6-failed", .failed("磁盘空间不足。"))]
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
