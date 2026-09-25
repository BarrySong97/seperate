import AppKit

/// ⌘K / ⌘P palette, shown inside the window over a dimmed backdrop (enso-style overlay rather than a
/// separate window). One search field over grouped results; the list is an NSTableView, so long
/// session lists stay cheap. ↑↓ select, ⏎ open, ⌘⏎ open in a split, ⌘1–9 pick a row, esc close.
@MainActor
final class CommandPalette: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row { case header(String), result(PaletteResult) }

    private let store: Store
    private let scope: PaletteScope
    private let entries: [PaletteEntry]
    private var rows: [Row] = []
    private var resultRows: [Int] = []            // indices into `rows` that are selectable
    private var selected = 0                      // index into resultRows

    private let scrim = NSView()
    private let card = FlippedView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let scopeLabel = NSTextField.label(font: Theme.smallFont, color: Theme.faint)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    private let empty = NSTextField.label("没有匹配的结果", font: NSFont.systemFont(ofSize: 12.5), color: Theme.faint)
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    /// Workspace area to center the card over (the sidebar stays uncovered visually).
    var contentRect: NSRect = .zero { didSet { needsLayout = true } }

    init(store: Store, scope: PaletteScope) {
        self.store = store
        self.scope = scope
        self.entries = CommandPalette.entries(store, scope)
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

        glass.image = Icons.symbol("magnifyingglass", size: 14)
        glass.contentTintColor = Theme.muted
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 16)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: scope == .all ? "搜索所有项目的会话、Workspace、命令…（支持拼音）" : "搜索会话名称…（支持拼音）",
                                                               attributes: [.foregroundColor: Theme.faint, .font: NSFont.systemFont(ofSize: 16)])
        field.delegate = self
        field.cell?.isScrollable = true
        if case .worktree(let path) = scope, let wt = store.worktree(path: path) {
            scopeLabel.stringValue = "\(store.projectName(of: wt)) / \(wt.alias)"
        }

        let col = NSTableColumn(identifier: .init("r"))
        table.addTableColumn(col)
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
        footer.stringValue = "↑↓ 选择   ⏎ 打开   ⌘⏎ 向右分屏打开   ⌘1–9 快速选择   esc 关闭"
        empty.alignment = .center
        [glass, field, scopeLabel, scroll, footer, empty].forEach(card.addSubview)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Entries

    private static func entries(_ store: Store, _ scope: PaletteScope) -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        // ⌘K covers every project the user added, whichever workspace it lives in.
        let wts: [Worktree]
        switch scope {
        case .worktree(let path): wts = store.worktree(path: path).map { [$0] } ?? []
        case .all: wts = store.projects.flatMap(store.worktrees(of:))
        }
        let activeRoots = Set(store.active.projectRoots)
        for wt in wts {
            let local = activeRoots.contains(wt.projectID)
            let elsewhere = local ? nil : store.workspaces.first { $0.projectRoots.contains(wt.projectID) }?.name
            let project = store.projectName(of: wt)
            let multi = (store.project(wt.projectID).map(store.worktrees(of:))?.count ?? 1) > 1
            let context = multi ? "\(project) / \(wt.alias)" : project
            for s in store.allSessions(in: wt) {
                let title = store.title(of: s)
                let status = store.status(of: s.id)
                var hint: String? = nil
                if let m = store.phaseMessage(of: s.id), status == .waiting || status == .done { hint = String(m.prefix(36)) }
                else if store.layout.pane(containing: s.id) != nil { hint = "已打开" }
                else if let w = store.workspaceContaining(s.id) { hint = "在「\(w.name)」" }
                else if let name = elsewhere { hint = "在「\(name)」" }
                out.append(PaletteEntry(kind: .session(s.id), section: .sessions, title: title, context: scope == .all ? context : "",
                                        keys: [project, wt.alias, s.kind.displayName, s.kind.rawValue],
                                        running: status != .history, local: local, recency: s.lastActivity, agent: s.kind, status: status,
                                        openHint: hint, pinyin: Core.pinyinKeys(title)))
            }
        }
        guard scope == .all else { return out }
        for w in store.workspaces where w.id != store.activeID {
            out.append(PaletteEntry(kind: .workspace(w.id), section: .workspaces, title: "切换到「\(w.name)」",
                                    keys: [w.name, "workspace"], symbol: "square.stack", pinyin: Core.pinyinKeys(w.name)))
        }
        for wt in wts where activeRoots.contains(wt.projectID) {   // "new …" only for this workspace's projects
            let project = store.projectName(of: wt)
            let multi = (store.project(wt.projectID).map(store.worktrees(of:))?.count ?? 1) > 1
            for k in AgentKind.allCases {
                let title = "新建 \(k.displayName)"
                out.append(PaletteEntry(kind: .create(k, wt), section: .create, title: title,
                                        context: multi ? "\(project) / \(wt.alias)" : project,
                                        keys: [project, wt.alias, k.rawValue], agent: k, pinyin: Core.pinyinKeys(title)))
            }
        }
        func command(_ title: String, _ symbol: String, _ keys: [String] = [], _ action: @escaping () -> Void) {
            out.append(PaletteEntry(kind: .command(title, action), section: .commands, title: title, keys: keys,
                                    symbol: symbol, pinyin: Core.pinyinKeys(title)))
        }
        command("新建项目…", "plus.rectangle.on.folder", ["new create project git init"]) { store.promptNewProject() }
        command("添加项目…", "folder.badge.plus", ["add project"]) { store.pickProject() }
        command("从 Agent 使用过的项目导入…", "square.and.arrow.down", ["import agent project codex claude"]) { store.showImport() }
        command("新建 Workspace…", "plus.square.on.square", ["new workspace"]) { store.promptNewWorkspace() }
        command(store.sidebarHidden ? "显示侧栏" : "隐藏侧栏", "sidebar.left", ["sidebar"]) { store.toggleSidebar() }
        for p in LayoutPreset.allCases {
            command(p == .grid ? "布局：2×2" : "布局：\(p.paneCount) 栏", "rectangle.split.3x1", ["layout", p.rawValue]) { store.apply(p) }
        }
        return out
    }

    // MARK: Filtering

    func controlTextDidChange(_ obj: Notification) { refresh() }

    #if DEBUG
    func debugType(_ q: String) { field.stringValue = q; refresh() }
    #endif

    private func refresh() {
        rows = []
        resultRows = []
        let groups = PaletteSearch.rank(entries, query: field.stringValue)
        let showHeaders = scope == .all
        for (section, results) in groups {
            if showHeaders { rows.append(.header(section.title)) }
            for r in results { resultRows.append(rows.count); rows.append(.result(r)) }
        }
        selected = 0
        table.reloadData()
        empty.isHidden = !resultRows.isEmpty
        if let first = resultRows.first { table.scrollRowToVisible(max(0, first - 1)) }
    }

    private func select(_ i: Int) {
        guard !resultRows.isEmpty else { return }
        let old = selected
        selected = max(0, min(resultRows.count - 1, i))
        for idx in [old, selected] where idx < resultRows.count {
            table.reloadData(forRowIndexes: [resultRows[idx]], columnIndexes: [0])
        }
        table.scrollRowToVisible(resultRows[selected])
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(selected + 1); return true
        case #selector(NSResponder.moveUp(_:)): select(selected - 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            run(selected, split: NSApp.currentEvent?.modifierFlags.contains(.command) == true); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    // MARK: Running a result

    @objc private func clicked() {
        let row = table.clickedRow
        guard let i = resultRows.firstIndex(of: row) else { return }
        run(i, split: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func run(_ i: Int, split: Bool) {
        guard i >= 0, i < resultRows.count, case .result(let r) = rows[resultRows[i]] else { return }
        close()
        switch r.entry.kind {
        case .session(let sid):
            if store.layout.pane(containing: sid) != nil { store.focusSession(sid); return }  // already here: jump to it
            if store.workspaceContaining(sid) != nil { store.reveal(sid); return }             // open in another workspace: go there
            // A project that only lives in another workspace: switch there first, then open.
            if !r.entry.local, let pid = store.session(sid).flatMap(store.worktree(for:))?.projectID,
               let w = store.workspaces.first(where: { $0.projectRoots.contains(pid) }) {
                store.switchWorkspace(to: w.id)
            }
            if split { store.open(sid, newPane: true) }
            else { store.addTab(sid, to: store.layout.focusedPaneID); store.clearAttention(sid) }
        case .create(let k, let wt): store.newSession(k, in: wt, newPane: split)
        case .workspace(let id): store.switchWorkspace(to: id)
        case .command(_, let action): action()
        }
    }

    // MARK: Presenting

    func present(in host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.window?.isKeyWindow == true else { return e }
            // ⌘1–9 picks a row; everything else goes to the search field as usual.
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) {
                self.run(n - 1, split: false); return nil
            }
            return e
        }
        scrim.alphaValue = 0
        card.alphaValue = 0
        card.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = SidebarView.motion.curve
            scrim.animator().alphaValue = 1
            card.animator().alphaValue = 1
        }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.97; a.toValue = 1; a.duration = 0.16; a.timingFunction = SidebarView.motion.curve
        card.layer?.add(a, forKey: "pop")
        card.layer?.transform = CATransform3DIdentity
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        onClose?()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close() }   // click outside closes
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrim.frame = bounds
        let area = contentRect == .zero ? bounds : contentRect
        let w = min(640, area.width - 40), h = min(480, bounds.height - 120)
        card.frame = NSRect(x: area.midX - w / 2, y: max(50, area.minY + 40), width: w, height: h)
        let cw = card.bounds.width
        glass.frame = NSRect(x: 16, y: 17, width: 16, height: 16)
        scopeLabel.sizeToFit()
        let sw = min(scopeLabel.frame.width, cw * 0.4)
        scopeLabel.frame = NSRect(x: cw - sw - 16, y: 18, width: sw, height: 15)
        field.frame = NSRect(x: 42, y: 13, width: cw - 42 - (sw > 0 ? sw + 28 : 16), height: 24)
        scroll.frame = NSRect(x: 6, y: 51, width: cw - 12, height: card.bounds.height - 51 - 30)
        footer.frame = NSRect(x: 16, y: card.bounds.height - 22, width: cw - 32, height: 14)
        empty.frame = NSRect(x: 0, y: 51 + 40, width: cw, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {}

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .header = rows[row] { return 26 }; return 34 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlainRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t):
            let v = (tableView.makeView(withIdentifier: .init("h"), owner: nil) as? PaletteHeaderCell) ?? {
                let c = PaletteHeaderCell(); c.identifier = .init("h"); return c
            }()
            v.label.stringValue = t
            return v
        case .result(let r):
            let v = (tableView.makeView(withIdentifier: .init("r"), owner: nil) as? PaletteResultCell) ?? {
                let c = PaletteResultCell(); c.identifier = .init("r"); return c
            }()
            let pos = resultRows.firstIndex(of: row) ?? 0
            v.configure(r, selected: pos == selected, shortcut: pos < 9 ? pos + 1 : nil)
            return v
        }
    }
}

@MainActor
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class PlainRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isGroupRowStyle: Bool { get { false } set {} }
}

@MainActor
private final class PaletteHeaderCell: NSTableCellView {
    let label = NSTextField.label(font: NSFont.systemFont(ofSize: 11, weight: .medium), color: Theme.faint)
    init() { super.init(frame: .zero); addSubview(label) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); label.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 14) }
}

@MainActor
private final class PaletteResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField.label(font: NSFont.systemFont(ofSize: 13))
    private let context = NSTextField.label(font: Theme.smallFont, color: Theme.faint)
    private let hint = NSTextField.label(font: Theme.smallFont, color: Theme.faint)
    private let time = NSTextField.label(font: Theme.smallFont, color: Theme.faint)
    private let dot = DotView(frame: .zero)
    private let key = NSTextField.label(font: Theme.monoFont, color: Theme.faint)
    private var selected = false

    init() {
        super.init(frame: .zero)
        time.alignment = .right
        [icon, title, context, time, dot, hint, key].forEach(addSubview)
        key.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: PaletteResult, selected: Bool, shortcut: Int?) {
        self.selected = selected
        let e = r.entry
        if let a = e.agent { icon.image = Icons.agent(a, size: 13); icon.contentTintColor = nil }
        else { icon.image = Icons.symbol(e.symbol ?? "command", size: 12); icon.contentTintColor = Theme.muted }
        // Matched characters in the title are brightened, the rest stays in the normal text color.
        let base = selected ? Theme.selFG : Theme.text
        let t = NSMutableAttributedString(string: e.title, attributes: [.foregroundColor: base.withAlphaComponent(r.highlights.isEmpty ? 1 : 0.72),
                                                                        .font: NSFont.systemFont(ofSize: 13)])
        let ns = e.title as NSString, chars = Array(e.title)
        for range in r.highlights where range.upperBound <= chars.count {
            let start = String(chars[..<range.lowerBound]).utf16.count
            let len = String(chars[range]).utf16.count
            guard start + len <= ns.length else { continue }
            t.addAttributes([.foregroundColor: Theme.selFG, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)],
                            range: NSRange(location: start, length: len))
        }
        title.attributedStringValue = t
        context.stringValue = e.context
        if case .session = e.kind { time.stringValue = RelativeTime.short(e.recency); toolTip = RelativeTime.full(e.recency) }
        else { time.stringValue = ""; toolTip = nil }
        dot.status = e.status
        hint.stringValue = e.openHint ?? ""
        key.stringValue = shortcut.map { "⌘\($0)" } ?? ""
        needsDisplay = true
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Theme.selBG.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func layout() {
        super.layout()
        context.sizeToFit(); hint.sizeToFit(); time.sizeToFit()
        var row: [(NSView, CGFloat?)] = [(icon, 14), (title, nil)]
        if !context.stringValue.isEmpty { row.append((context, min(context.frame.width, bounds.width * 0.3))) }
        if !time.stringValue.isEmpty { row.append((time, time.frame.width)) }
        if !dot.isHidden { row.append((dot, 8)) }
        if !hint.stringValue.isEmpty { row.append((hint, hint.frame.width)) }
        row.append((key, 26))
        layoutRow(row, leading: 14, trailing: 12, gap: 10)
    }
}
