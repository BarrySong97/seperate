import AppKit

/// Tab strip + origin line on top of each pane. Updated in place; tab views are reused by session id.
@MainActor
final class PaneHeaderView: NSView, NSDraggingSource {
    static let height: CGFloat = 34 + 26

    private let store: Store
    private let paneID: String
    private let strip = NSView()
    private var tabs: [String: TabView] = [:]
    private var order: [String] = []
    private let splitRight = IconButton(symbol: "rectangle.split.2x1", tooltip: "向右分屏 ⌘D", side: 24)
    private let splitDown = IconButton(symbol: "rectangle.split.1x2", tooltip: "向下分屏 ⌘⇧D", side: 24)
    private let close = IconButton(symbol: "xmark", tooltip: "关闭这一栏", side: 24)
    private let originChip = ChipView()
    private let origin = NSTextField.label(font: Theme.smallFont, color: Theme.muted)
    private let originStatus = DotView(frame: .zero)
    private let originState = NSTextField.label(font: Theme.smallFont, color: Theme.faint)
    private let sid = NSTextField.label(font: Theme.monoFont, color: Theme.faint)
    // Worktree actions at the end of the origin line: Finder, default editor ▾, copy path, ···.
    private let finderButton = IconButton(symbol: "folder", tooltip: "在 Finder 中显示", side: 26)
    private let editorButton = IconButton(symbol: "chevron.left.forwardslash.chevron.right", tooltip: "用编辑器打开", side: 26)
    private let editorMore = IconButton(symbol: "chevron.down", size: 7, tooltip: "用其他应用打开", side: 16)
    private let editorGroup = NSView()
    private let copyButton = IconButton(symbol: "doc.on.doc", size: 11, tooltip: "复制路径", side: 26)
    private let moreButton = IconButton(symbol: "ellipsis", size: 12, tooltip: "Worktree 操作", side: 26)
    private var originWorktree: Worktree?
    private var focused = false
    private var downAt: NSPoint?

    init(store: Store, paneID: String) {
        self.store = store
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        strip.wantsLayer = true
        strip.layer?.masksToBounds = true
        originChip.side = 14
        [strip, splitRight, splitDown, close, originChip, origin, originStatus, originState, sid].forEach(addSubview)
        editorGroup.wantsLayer = true
        editorGroup.layer?.cornerRadius = 6
        editorGroup.layer?.backgroundColor = Theme.selBG.cgColor
        [finderButton, editorGroup, editorButton, editorMore, copyButton, moreButton].forEach(addSubview)
        finderButton.image = ExternalApp.finderIcon
        finderButton.onClick = { [weak self] in
            guard let p = self?.originWorktree?.path else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
        editorButton.onClick = { [weak self] in
            guard let self, let p = self.originWorktree?.path else { return }
            if let e = self.store.preferredEditor { e.open(p) } else { self.popApps() }
        }
        editorMore.onClick = { [weak self] in self?.popApps() }
        copyButton.onClick = { [weak self] in
            guard let self, let p = self.originWorktree?.path else { return }
            self.store.copyPath(p)
            self.copyButton.toolTip = "已复制：" + p.abbreviatingHome
        }
        moreButton.onClick = { [weak self] in
            guard let self, let wt = self.originWorktree else { return }
            Menus.worktree(self.store, wt).popUp(positioning: nil, at: NSPoint(x: 0, y: self.moreButton.bounds.height + 2), in: self.moreButton)
        }
        splitRight.onClick = { [weak self] in self.map { $0.store.splitFocused($0.paneID, edge: .right) } }
        splitDown.onClick = { [weak self] in self.map { $0.store.splitFocused($0.paneID, edge: .bottom) } }
        close.onClick = { [weak self] in self.map { $0.store.closePane($0.paneID) } }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func update(_ pane: Pane, focused: Bool) {
        self.focused = focused
        // Reuse tab views by session id; drop the ones no longer in the pane.
        for id in Set(tabs.keys).subtracting(pane.tabs) { tabs[id]?.removeFromSuperview(); tabs[id] = nil }
        for id in pane.tabs where tabs[id] == nil {
            let t = TabView(sessionID: id)
            t.onSelect = { [weak self] in self.map { $0.store.activate(id, in: $0.paneID) } }
            t.onClose = { [weak self] in self?.store.closeTab(id) }
            strip.addSubview(t)
            tabs[id] = t
        }
        order = pane.tabs
        for id in pane.tabs { refreshTab(id, active: pane.active == id) }
        updateOrigin(pane.active)
        needsLayout = true
        needsDisplay = true
    }

    func refreshTab(_ id: String, active: Bool? = nil) {
        guard let t = tabs[id], let s = store.session(id) else { return }
        let isActive = active ?? (store.layout.panes.first { $0.id == paneID }?.active == id)
        t.configure(title: store.title(of: s), kind: s.kind, status: store.status(of: id), active: isActive, focused: focused)
        t.toolTip = store.worktree(for: s).map { "\(store.projectName(of: $0)) / \($0.alias)" } ?? s.cwd.abbreviatingHome
        if isActive { updateOrigin(id) }
    }

    private func popApps() {
        guard let p = originWorktree?.path else { return }
        Menus.appsMenu(store, path: p).popUp(positioning: nil, at: NSPoint(x: 0, y: editorMore.bounds.height + 2), in: editorMore)
    }

    private func updateActions(_ wt: Worktree?) {
        originWorktree = wt
        for v in [finderButton, editorGroup, editorButton, editorMore, copyButton, moreButton] as [NSView] { v.isHidden = wt == nil }
        guard wt != nil else { return }
        let e = store.preferredEditor
        editorButton.image = e?.icon() ?? Icons.symbol("chevron.left.forwardslash.chevron.right", size: 11)
        editorButton.toolTip = e.map { "用 \($0.name) 打开 ⌥⌘O" } ?? "选择打开方式"
        copyButton.toolTip = "复制路径"
    }

    private func updateOrigin(_ active: String?) {
        updateActions(active.flatMap { store.session($0) }.flatMap { store.worktree(for: $0) })
        guard let active, let s = store.session(active) else {
            originChip.isHidden = true; origin.stringValue = "空栏"; originStatus.status = .history
            originState.stringValue = ""; sid.stringValue = ""; needsLayout = true; return
        }
        if let wt = store.worktree(for: s) {
            originChip.isHidden = false
            originChip.name = store.projectName(of: wt)
            originChip.iconPath = store.project(wt.projectID)?.iconPath
            origin.stringValue = "\(store.projectName(of: wt))  /  \(wt.alias)   \(s.kind.displayName)"
        } else {
            originChip.isHidden = true
            origin.stringValue = "\(s.cwd.abbreviatingHome)   \(s.kind.displayName)"
        }
        let st = store.status(of: active)
        originStatus.status = st
        originState.stringValue = [.waiting: "需要你", .working: "工作中", .done: "完成", .failed: "出错", .running: "运行中"][st] ?? ""
        sid.stringValue = s.agentSessionID.map { String($0.prefix(8)) } ?? ""
        sid.toolTip = s.agentSessionID.map { "会话 ID：\($0)" }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Row 1: tab strip.
        let actionsW: CGFloat = 24 * 3 + 4
        close.frame = NSRect(x: w - 4 - 24, y: 5, width: 24, height: 24)
        splitDown.frame = NSRect(x: close.frame.minX - 24, y: 5, width: 24, height: 24)
        splitRight.frame = NSRect(x: splitDown.frame.minX - 24, y: 5, width: 24, height: 24)
        let stripX: CGFloat = 6
        var x: CGFloat = 0
        let maxTabW: CGFloat = 200
        let availW = w - stripX - actionsW - 8
        let tabW = min(maxTabW, max(90, order.isEmpty ? maxTabW : availW / CGFloat(order.count)))
        for id in order {
            tabs[id]?.frame = NSRect(x: x, y: 0, width: tabW, height: 34)
            x += tabW
        }
        strip.frame = NSRect(x: stripX, y: 0, width: max(0, min(x, availW)), height: 34)
        // Row 2: origin line.
        let y2: CGFloat = 35
        originChip.frame = NSRect(x: 12, y: y2 + 5, width: 14, height: 14)
        let ox: CGFloat = originChip.isHidden ? 12 : 32
        // Actions at the very end, right to left: ··· · copy · [editor ▾] · Finder.
        var right = w - 6
        if !moreButton.isHidden {
            let by = y2 + (25 - 24) / 2
            moreButton.frame = NSRect(x: right - 26, y: by, width: 26, height: 24); right = moreButton.frame.minX - 2
            copyButton.frame = NSRect(x: right - 26, y: by, width: 26, height: 24); right = copyButton.frame.minX - 4
            editorMore.frame = NSRect(x: right - 16, y: by, width: 16, height: 24)
            editorButton.frame = NSRect(x: editorMore.frame.minX - 26, y: by, width: 26, height: 24)
            editorGroup.frame = NSRect(x: editorButton.frame.minX, y: by, width: 42, height: 24)
            right = editorGroup.frame.minX - 2
            finderButton.frame = NSRect(x: right - 26, y: by, width: 26, height: 24); right = finderButton.frame.minX - 8
        }
        sid.sizeToFit()
        sid.frame = NSRect(x: right - sid.frame.width - 4, y: y2 + 5, width: sid.frame.width, height: 15)
        originState.sizeToFit()
        originState.frame = NSRect(x: sid.frame.minX - originState.frame.width - 10, y: y2 + 5, width: originState.frame.width, height: 15)
        originStatus.frame = NSRect(x: originState.frame.minX - 11, y: y2 + 10, width: 6, height: 6)
        origin.frame = NSRect(x: ox, y: y2 + 5, width: max(0, originStatus.frame.minX - ox - 10), height: 15)
    }

    // MARK: Dragging the whole pane by the empty part of its tab strip

    override func mouseDown(with event: NSEvent) {
        store.focus(pane: paneID)
        downAt = convert(event.locationInWindow, from: nil).y < 34 ? event.locationInWindow : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4,
              let pane = superview else { return }
        downAt = nil
        let pb = NSPasteboardItem()
        pb.setString(PaneView.panePrefix + paneID, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pb)
        // Drag a scaled-down picture of the pane, anchored under the cursor.
        let snap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds).map { rep -> NSImage in
            pane.cacheDisplay(in: pane.bounds, to: rep)
            let img = NSImage(size: pane.bounds.size); img.addRepresentation(rep); return img
        }
        let scale = min(1, 320 / max(pane.bounds.width, 1))
        let size = NSSize(width: pane.bounds.width * scale, height: pane.bounds.height * scale)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - 17, width: size.width, height: size.height), contents: snap)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ground.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 34).fill()
        Theme.pane.setFill(); NSRect(x: 0, y: 34, width: bounds.width, height: 26).fill()
        Theme.line.setFill()
        NSRect(x: 0, y: 34, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// One tab: icon, title, status dot, close. Drag it to another pane or its edge.
@MainActor
final class TabView: NSView, NSDraggingSource {
    let sessionID: String
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private let dot = DotView(frame: .zero)
    private let close = IconButton(symbol: "xmark", size: 8, tooltip: "关闭 Tab", side: 16)
    private var active = false, focused = false
    private var downAt: NSPoint?

    init(sessionID: String) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        [icon, title, dot, close].forEach(addSubview)
        close.onClick = { [weak self] in self?.onClose?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(title t: String, kind: AgentKind, status: SessionStatus, active: Bool, focused: Bool) {
        self.active = active; self.focused = focused; self.waiting = status == .waiting
        title.stringValue = t
        title.textColor = active ? Theme.text : Theme.muted
        icon.image = Icons.agent(kind, size: 11)
        dot.status = status
        close.alphaValue = active ? 1 : 0.6
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var row: [(NSView, CGFloat?)] = [(icon, 11), (title, nil)]
        if !dot.isHidden { row.append((dot, 8)) }
        row.append((close, 16))
        layoutRow(row, leading: 10, trailing: 4, gap: 6)
    }

    private var waiting = false

    override func draw(_ dirtyRect: NSRect) {
        if active { Theme.pane.setFill(); bounds.fill() }
        // A tab that needs you is tinted amber even when it is not the one showing.
        if waiting {
            Theme.wait.withAlphaComponent(0.13).setFill(); bounds.fill()
            Theme.wait.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        }
        if active && focused { Theme.accent.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill() }
        Theme.line.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; onSelect?() }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let pb = NSPasteboardItem()
        pb.setString(sessionID, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { downAt = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size); img.addRepresentation(rep); return img
    }
}
