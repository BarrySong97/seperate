import AppKit

/// Workspace name, layout summary and preset buttons above the workspace.
@MainActor
final class TopBarView: NSView {
    static let height: CGFloat = 38

    private let store: Store
    private let sidebarButton = IconButton(symbol: "sidebar.left", size: 13, tooltip: "切换侧栏 ⌘B", side: 26)
    private let title = NSTextField.label(font: NSFont.systemFont(ofSize: 13, weight: .semibold))
    private let summary = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private var presets: [NSButton] = []
    private let updatePill = NSButton()
    private var token: UUID?
    private var updateObserver: NSObjectProtocol?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        [sidebarButton, title, summary].forEach(addSubview)
        sidebarButton.onClick = { store.toggleSidebar() }
        for p in LayoutPreset.allCases {
            let b = NSButton()
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.toolTip = p == .grid ? "2×2" : "\(p.paneCount) 栏"
            b.target = self
            b.action = #selector(applyPreset(_:))
            b.tag = LayoutPreset.allCases.firstIndex(of: p)!
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            addSubview(b)
            presets.append(b)
        }

        updatePill.isBordered = false
        updatePill.wantsLayer = true
        updatePill.layer?.cornerRadius = 11
        updatePill.layer?.borderWidth = 1
        updatePill.layer?.backgroundColor = Theme.wait.withAlphaComponent(0.14).cgColor
        updatePill.layer?.borderColor = Theme.wait.withAlphaComponent(0.35).cgColor
        updatePill.toolTip = "查看并安装更新"
        updatePill.target = self
        updatePill.action = #selector(showUpdate(_:))
        updatePill.isHidden = true
        addSubview(updatePill)
        updateObserver = NotificationCenter.default.addObserver(forName: Updater.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUpdatePill() }
        }

        token = store.observe { [weak self] change in
            switch change {
            case .layout, .projects, .session, .workspace: self?.refresh()
            case .sidebar, .reveal: break
            }
        }
        refresh()
        refreshUpdatePill()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func refresh() {
        title.stringValue = store.active.name
        let panes = store.layout.panes
        let tabs = panes.flatMap(\.tabs)
        let projects = Set(tabs.compactMap { store.session($0).flatMap(store.worktree(for:))?.projectID })
        let states = tabs.map { store.status(of: $0) }
        let count = { (st: SessionStatus) in states.filter { $0 == st }.count }
        let text = NSMutableAttributedString(string: "\(panes.count) 栏 · \(tabs.count) 个 Tab · 来自 \(projects.count) 个项目",
                                             attributes: [.foregroundColor: Theme.muted, .font: NSFont.systemFont(ofSize: 12)])
        for (st, label, color) in [(SessionStatus.waiting, "个需要你", Theme.wait), (.working, "个在运行", Theme.muted), (.done, "个完成未读", Theme.muted)] {
            let n = count(st)
            guard n > 0 else { continue }
            text.append(NSAttributedString(string: "  ·  ", attributes: [.foregroundColor: Theme.faint, .font: NSFont.systemFont(ofSize: 12)]))
            text.append(NSAttributedString(string: "\(n) \(label)", attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: 12, weight: st == .waiting ? .semibold : .regular)]))
        }
        summary.attributedStringValue = text
        for (i, b) in presets.enumerated() {
            let on = store.layout.preset == LayoutPreset.allCases[i]
            b.image = Icons.preset(LayoutPreset.allCases[i], color: on ? Theme.selFG : Theme.faint)
            b.layer?.backgroundColor = (on ? Theme.selBG : .clear).cgColor
        }
        needsLayout = true
    }

    @objc private func applyPreset(_ sender: NSButton) { store.apply(LayoutPreset.allCases[sender.tag]) }
    @objc private func showUpdate(_ sender: NSButton) { Updater.shared.checkForUpdates() }

    private func refreshUpdatePill() {
        guard let version = Updater.shared.pendingVersion else { updatePill.isHidden = true; needsLayout = true; return }
        updatePill.attributedTitle = NSAttributedString(string: "●  新版本 \(version)", attributes: [
            .foregroundColor: Theme.wait, .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)])
        updatePill.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        sidebarButton.frame = NSRect(x: 12, y: (h - 26) / 2, width: 26, height: 26)
        title.sizeToFit()
        title.frame = NSRect(x: 46, y: (h - 16) / 2, width: min(title.frame.width, 200), height: 16)
        var x = bounds.width - 10
        for b in presets.reversed() { x -= 28; b.frame = NSRect(x: x, y: (h - 24) / 2, width: 28, height: 24) }
        if !updatePill.isHidden {
            let w = ceil(updatePill.attributedTitle.size().width) + 22
            x -= 10 + w
            updatePill.frame = NSRect(x: x, y: (h - 22) / 2, width: w, height: 22)
        }
        let sx = title.frame.maxX + 10
        summary.frame = NSRect(x: sx, y: (h - 16) / 2, width: max(0, x - 10 - sx), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) { Theme.ground.setFill(); bounds.fill() }

    // The top bar sits where the title bar would be: drag moves the window, double-click zooms it.
    override func mouseDown(with event: NSEvent) { window?.handleTitlebarMouseDown(event) }
}
