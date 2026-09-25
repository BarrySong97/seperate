import AppKit

/// "Import from agents": the projects Codex / Claude have worked in, found and searched by the Rust
/// core, shown in-window like ⌘K. Pick several, choose the workspace, import.
/// Codex desktop scratch chats are folded into one row; projects already in Seperate are listed greyed.
@MainActor
final class ImportPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row {
        case header(String)
        case project(Core.AgentProject, addedIn: String?)   // workspace name when already in Seperate
        case scratch(count: Int, open: Bool)
    }

    private let store: Store
    private var rows: [Row] = []
    private var checked: Set<String> = []
    private var scratchOpen = false
    private var searchWork: DispatchWorkItem?

    private let scrim = NSView()
    private let card = ImportFlippedView()
    private let titleLabel = NSTextField.label("从 Agent 使用过的项目导入", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
    private let hint = NSTextField.label("按最近使用排序 · 子目录和 Worktree 已归到各自的仓库", font: Theme.smallFont, color: Theme.faint)
    private let glass = NSImageView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField.label("没有找到 Agent 用过的项目", font: NSFont.systemFont(ofSize: 12.5), color: Theme.faint)
    private let target = NSPopUpButton()
    private let targetLabel = NSTextField.label("导入到", font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let confirm = NSButton(title: "导入", target: nil, action: nil)
    private var keyMonitor: Any?
    var contentRect: NSRect = .zero { didSet { needsLayout = true } }

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(scrim)

        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.panel.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.line2.cgColor
        card.shadow = NSShadow()
        card.shadow?.shadowBlurRadius = 40
        card.shadow?.shadowOffset = NSSize(width: 0, height: -16)
        card.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.55)
        addSubview(card)

        glass.image = Icons.symbol("magnifyingglass", size: 12)
        glass.contentTintColor = Theme.muted
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 14)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: "搜索项目名、路径…（支持拼音）",
                                                               attributes: [.foregroundColor: Theme.faint, .font: NSFont.systemFont(ofSize: 14)])
        field.delegate = self
        field.cell?.isScrollable = true

        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        empty.alignment = .center

        for w in store.workspaces {
            target.addItem(withTitle: w.name)
            target.lastItem?.representedObject = w.id
        }
        target.selectItem(at: store.activeIndex)
        target.controlSize = .small
        cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(dismiss)
        cancel.keyEquivalent = "\u{1b}"
        confirm.bezelStyle = .rounded
        confirm.target = self; confirm.action = #selector(importChecked)
        confirm.keyEquivalent = "\r"
        [titleLabel, hint, glass, field, scroll, empty, targetLabel, target, cancel, confirm].forEach(card.addSubview)
        reload(query: "")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Data (from the Rust core)

    private var generation = 0

    /// The core walks every session on the first call (~0.4 s), so it runs off the main thread.
    private func reload(query: String) {
        generation += 1
        let gen = generation
        if rows.isEmpty { empty.stringValue = "正在查找 Agent 用过的项目…"; empty.isHidden = false }
        Task.detached(priority: .userInitiated) {
            let found = Core.agentProjects(query: query)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.show(found, query: query)
            }
        }
    }

    private func show(_ found: [Core.AgentProject], query: String) {
        let addedIn = Dictionary(store.workspaces.flatMap { w in w.projectRoots.map { ($0, w.name) } }, uniquingKeysWith: { a, _ in a })
        let fresh = found.filter { !$0.scratch && addedIn[$0.root] == nil }
        let scratch = found.filter { $0.scratch && addedIn[$0.root] == nil }
        let added = found.filter { addedIn[$0.root] != nil }
        var out: [Row] = fresh.map { .project($0, addedIn: nil) }
        if !scratch.isEmpty {
            let open = scratchOpen || (!query.isEmpty && fresh.isEmpty)
            out.append(.scratch(count: scratch.count, open: open))
            if open { out += scratch.map { .project($0, addedIn: nil) } }
        }
        if !added.isEmpty {
            out.append(.header("已在 Seperate"))
            out += added.map { .project($0, addedIn: addedIn[$0.root]) }
        }
        rows = out
        table.reloadData()
        empty.isHidden = !rows.isEmpty
        empty.stringValue = query.isEmpty ? "没有找到 Agent 用过的项目" : "没有匹配的项目"
        updateConfirm()
    }

    private func updateConfirm() {
        confirm.title = checked.isEmpty ? "导入" : "导入 \(checked.count) 个项目"
        confirm.isEnabled = !checked.isEmpty
        needsLayout = true
    }

    func controlTextDidChange(_ obj: Notification) {
        // The core caches its scan, so each search is a cheap filter; still, coalesce fast typing.
        searchWork?.cancel()
        let q = field.stringValue
        let w = DispatchWorkItem { [weak self] in self?.reload(query: q) }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        case #selector(NSResponder.insertNewline(_:)): importChecked(); return true
        default: return false
        }
    }

    // MARK: Actions

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        switch rows[r] {
        case .project(let p, nil):
            if checked.remove(p.root) == nil { checked.insert(p.root) }
            table.reloadData(forRowIndexes: [r], columnIndexes: [0])
            updateConfirm()
        case .scratch:
            scratchOpen.toggle()
            reload(query: field.stringValue)
        default: break
        }
    }

    @objc private func importChecked() {
        guard !checked.isEmpty, let wsID = target.selectedItem?.representedObject as? String else { return }
        // Keep the list's order: each added project goes on top, so add the last one first.
        let order = rows.compactMap { if case .project(let p, nil) = $0, checked.contains(p.root) { return p.root } else { return nil } }
        for root in order.reversed() { store.addProject(path: root, to: wsID) }
        dismiss()
    }

    @objc private func dismiss() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    func present(in host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = SidebarView.motion.curve
            animator().alphaValue = 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrim.frame = bounds
        let area = contentRect == .zero ? bounds : contentRect
        let w = min(680, area.width - 40), h = min(560, bounds.height - 100)
        card.frame = NSRect(x: area.midX - w / 2, y: max(40, area.minY + 36), width: w, height: h)
        let cw = card.bounds.width, ch = card.bounds.height
        titleLabel.frame = NSRect(x: 18, y: 16, width: cw - 36, height: 18)
        hint.frame = NSRect(x: 18, y: 36, width: cw - 36, height: 15)
        glass.frame = NSRect(x: 18, y: 66, width: 14, height: 14)
        field.frame = NSRect(x: 40, y: 62, width: cw - 58, height: 22)
        scroll.frame = NSRect(x: 6, y: 94, width: cw - 12, height: ch - 94 - 52)
        empty.frame = NSRect(x: 0, y: 140, width: cw, height: 18)
        confirm.sizeToFit(); cancel.sizeToFit()
        let by = ch - 40
        confirm.frame = NSRect(x: cw - 16 - max(confirm.frame.width, 80), y: by, width: max(confirm.frame.width, 80), height: 28)
        cancel.frame = NSRect(x: confirm.frame.minX - 8 - max(cancel.frame.width, 70), y: by, width: max(cancel.frame.width, 70), height: 28)
        targetLabel.sizeToFit()
        targetLabel.frame.origin = NSPoint(x: 18, y: by + 6)
        target.sizeToFit()
        target.frame = NSRect(x: targetLabel.frame.maxX + 6, y: by + 2, width: max(target.frame.width, 110), height: 24)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] { case .header: 28; case .scratch: 32; case .project: 44 }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ImportRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t):
            let v = NSTextField.label(t, font: NSFont.systemFont(ofSize: 11, weight: .medium), color: Theme.faint)
            let box = ImportFlippedView(); box.addSubview(v)
            v.frame = NSRect(x: 12, y: 10, width: 400, height: 14)
            return box
        case .scratch(let n, let open):
            let c = (tableView.makeView(withIdentifier: .init("s"), owner: nil) as? ImportScratchCell) ?? {
                let c = ImportScratchCell(); c.identifier = .init("s"); return c
            }()
            c.configure(count: n, open: open)
            return c
        case .project(let p, let addedIn):
            let c = (tableView.makeView(withIdentifier: .init("p"), owner: nil) as? ImportProjectCell) ?? {
                let c = ImportProjectCell(); c.identifier = .init("p"); return c
            }()
            c.configure(p, checked: checked.contains(p.root), addedIn: addedIn)
            return c
        }
    }
}

@MainActor
private final class ImportFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class ImportRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// One project: checkbox, name over path, when it was last used and by which agents.
@MainActor
private final class ImportProjectCell: NSTableCellView {
    private let box = NSImageView()
    private let name = NSTextField.label(font: NSFont.systemFont(ofSize: 13, weight: .medium))
    private let path = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    private let when = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.muted)
    private let agents = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    private var hovering = false, enabled = true

    init() {
        super.init(frame: .zero)
        [box, name, path, when, agents].forEach(addSubview)
        when.alignment = .right; agents.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(_ p: Core.AgentProject, checked: Bool, addedIn: String?) {
        enabled = addedIn == nil
        box.image = Icons.symbol(addedIn != nil ? "checkmark.circle.fill" : (checked ? "checkmark.square.fill" : "square"), size: 14)
        box.contentTintColor = addedIn != nil ? Theme.faint : (checked ? Theme.accent : Theme.muted)
        name.stringValue = p.name
        name.textColor = enabled ? Theme.text : Theme.faint
        path.stringValue = p.root.abbreviatingHome + (p.git ? "" : "  ·  普通文件夹")
        let date = Date(timeIntervalSince1970: TimeInterval(p.lastUsed))
        when.stringValue = addedIn.map { "已在「\($0)」" } ?? RelativeTime.short(date)
        agents.stringValue = [p.codex > 0 ? "Codex \(p.codex)" : nil, p.claude > 0 ? "Claude \(p.claude)" : nil].compactMap { $0 }.joined(separator: " · ")
        toolTip = p.root
        needsLayout = true; needsDisplay = true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, enabled else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 7, yRadius: 7).fill()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        box.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let right: CGFloat = 170
        name.frame = NSRect(x: 40, y: 6, width: w - 40 - right - 12, height: 17)
        path.frame = NSRect(x: 40, y: 24, width: w - 40 - right - 12, height: 14)
        when.frame = NSRect(x: w - right - 14, y: 6, width: right, height: 15)
        agents.frame = NSRect(x: w - right - 14, y: 24, width: right, height: 14)
    }
}

/// "Codex 临时对话 (N)": the Codex desktop app's per-chat folders, folded away by default.
@MainActor
private final class ImportScratchCell: NSTableCellView {
    private let chevron = NSImageView()
    private let label = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: Theme.muted)

    init() {
        super.init(frame: .zero)
        [chevron, label].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(count: Int, open: Bool) {
        chevron.image = Icons.symbol(open ? "chevron.down" : "chevron.right", size: 9)
        chevron.contentTintColor = Theme.faint
        label.stringValue = "Codex 桌面版的临时对话目录（\(count) 个）"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 16, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: 40, y: (bounds.height - 15) / 2, width: bounds.width - 52, height: 15)
    }
}
