import AppKit

/// Renders `store.layout` as nested split containers of panes. Pane views are kept by id and
/// updated in place; only a change in nesting rebuilds the containers. Terminal views belong to the
/// store and are re-parented, never recreated.
@MainActor
final class WorkspaceView: NSView {
    private let store: Store
    private var paneViews: [String: PaneView] = [:]
    private var splitViews: [String: SplitContainerView] = [:]
    private var built = false
    private var token: UUID?
    private var lastFocusKey = ""

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ground.cgColor
        token = store.observe { [weak self] change in
            switch change {
            case .layout(let structure): self?.sync(structure: structure)
            case .session(let id): self?.refreshSession(id)
            case .projects: self?.refreshAll()
            case .workspace: self?.switchWorkspace()
            case .sidebar, .reveal: break
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync(structure: Bool) {
        let layout = store.layout
        if structure || !built {
            built = true
            let hadTerminalFocus = window?.firstResponder is TerminalView
            subviews.forEach { $0.removeFromSuperview() }
            let wanted = Set(layout.panes.map(\.id))
            for id in Set(paneViews.keys).subtracting(wanted) { paneViews[id] = nil }
            splitViews = [:]
            let root = build(layout.root)
            root.frame = bounds
            root.autoresizingMask = [.width, .height]
            addSubview(root)
            if hadTerminalFocus || window?.firstResponder === window { focusActiveTerminal() }
        } else {
            apply(layout.root)
        }
        for (id, v) in paneViews { v.isFocused = id == layout.focusedPaneID }
        let key = "\(layout.focusedPaneID)|\(layout.focusedPane?.active ?? "")"
        if key != lastFocusKey {
            lastFocusKey = key
            let fr = window?.firstResponder
            if fr == nil || fr is TerminalView || fr === window { focusActiveTerminal() }
        }
    }

    /// The whole right side belongs to the workspace: fade out, rebuild for the new layout, fade in.
    private func switchWorkspace() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.sync(structure: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = SidebarView.motion.duration
                ctx.timingFunction = SidebarView.motion.curve
                self.animator().alphaValue = 1
            }
        })
    }

    func focusActiveTerminal() {
        guard let p = store.layout.focusedPane, let sid = p.active, let t = store.terminals[sid] else { return }
        window?.makeFirstResponder(t)
    }

    private func build(_ node: LayoutNode) -> NSView {
        switch node {
        case .pane(let p):
            let v = paneViews[p.id] ?? PaneView(store: store, paneID: p.id)
            paneViews[p.id] = v
            v.update(p)
            return v
        case .split(let id, let axis, let sizes, let children):
            let v = SplitContainerView(store: store, splitID: id, axis: axis, sizes: sizes, children: children.map(build))
            splitViews[id] = v
            return v
        }
    }

    /// Structure unchanged: push tabs/active/sizes into the existing views.
    private func apply(_ node: LayoutNode) {
        switch node {
        case .pane(let p): paneViews[p.id]?.update(p)
        case .split(let id, _, let sizes, let children):
            splitViews[id]?.sizes = sizes
            children.forEach(apply)
        }
    }

    private func refreshSession(_ id: String) {
        guard let p = store.layout.pane(containing: id) else { return }
        paneViews[p.id]?.header.refreshTab(id)
    }

    private func refreshAll() {
        for p in store.layout.panes { paneViews[p.id]?.update(p) }
    }
}

// MARK: - Split container

@MainActor
final class SplitContainerView: NSView {
    static let gap: CGFloat = 6
    private let store: Store
    private let splitID: String
    private let axis: LayoutNode.Axis
    var sizes: [Double] { didSet { if sizes != oldValue { needsLayout = true } } }
    private let children: [NSView]
    private var dividers: [DividerView] = []

    init(store: Store, splitID: String, axis: LayoutNode.Axis, sizes: [Double], children: [NSView]) {
        self.store = store; self.splitID = splitID; self.axis = axis; self.sizes = sizes; self.children = children
        super.init(frame: .zero)
        children.forEach(addSubview)
        for i in 0..<(children.count - 1) {
            let d = DividerView(axis: axis)
            d.onDrag = { [weak self] delta in self?.drag(divider: i, delta: delta) }
            d.onEnd = { [weak self] in self?.commit() }
            d.onDoubleClick = { [weak self] in self?.equalize(i) }
            dividers.append(d)
            addSubview(d)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let total = sizes.reduce(0, +)
        let length = (axis == .horizontal ? bounds.width : bounds.height) - Self.gap * CGFloat(children.count - 1)
        var offset: CGFloat = 0
        for (i, child) in children.enumerated() {
            let len = (length * CGFloat(sizes[i] / total)).rounded()
            let isLast = i == children.count - 1
            let l = isLast ? (axis == .horizontal ? bounds.width : bounds.height) - offset : len
            child.frame = axis == .horizontal
                ? NSRect(x: offset, y: 0, width: l, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: l)
            offset += l
            if !isLast {
                dividers[i].frame = axis == .horizontal
                    ? NSRect(x: offset, y: 0, width: Self.gap, height: bounds.height)
                    : NSRect(x: 0, y: offset, width: bounds.width, height: Self.gap)
                offset += Self.gap
            }
        }
    }

    private func drag(divider i: Int, delta: CGFloat) {
        let total = sizes.reduce(0, +)
        let length = (axis == .horizontal ? bounds.width : bounds.height) - Self.gap * CGFloat(children.count - 1)
        guard length > 0 else { return }
        let d = Double(delta / length) * total
        let pair = sizes[i] + sizes[i + 1], minSize = total * 0.08
        let a = min(max(sizes[i] + d, minSize), pair - minSize)
        sizes[i] = a; sizes[i + 1] = pair - a
    }

    private func equalize(_ i: Int) {
        let m = (sizes[i] + sizes[i + 1]) / 2
        sizes[i] = m; sizes[i + 1] = m
        commit()
    }

    private func commit() { store.setSizes(splitID: splitID, sizes) }
}

@MainActor
final class DividerView: NSView {
    let axis: LayoutNode.Axis
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var last: NSPoint?
    private var hovering = false { didSet { needsDisplay = true } }

    init(axis: LayoutNode.Axis) { self.axis = axis; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if last == nil { hovering = false } }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || last != nil else { return }
        Theme.accent.withAlphaComponent(0.6).setFill()
        let r = axis == .horizontal ? NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
                                    : NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        r.fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        last = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let p = event.locationInWindow
        onDrag?(axis == .horizontal ? p.x - l.x : l.y - p.y)   // window coords are bottom-up
        last = p
    }
    override func mouseUp(with event: NSEvent) {
        guard last != nil else { return }
        last = nil
        hovering = false
        onEnd?()
    }
}

// MARK: - Pane

/// One pane: header (tabs + origin line) over the active tab's terminal. Accepts drops of
/// sessions/tabs: edges split, center adds a tab.
@MainActor
final class PaneView: NSView {
    /// Pasteboard marker for dragging a whole pane (tabs carry the bare session id).
    static let panePrefix = "pane:"
    private let store: Store
    let paneID: String
    let header: PaneHeaderView
    private let body = NSView()
    private var empty: EmptyPaneView?
    private var activeSession: String?
    private var dropOverlay: DropOverlay?

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            layer?.borderColor = (isFocused ? Theme.focus : Theme.line).cgColor
            if let p = store.layout.panes.first(where: { $0.id == paneID }) { header.update(p, focused: isFocused) }
        }
    }

    init(store: Store, paneID: String) {
        self.store = store
        self.paneID = paneID
        header = PaneHeaderView(store: store, paneID: paneID)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.pane.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor
        layer?.masksToBounds = true
        addSubview(header)
        addSubview(body)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func update(_ pane: Pane) {
        header.update(pane, focused: store.layout.focusedPaneID == paneID)
        guard pane.active != activeSession || body.subviews.isEmpty else { return }
        activeSession = pane.active
        body.subviews.forEach { $0.removeFromSuperview() }
        if let sid = pane.active, let t = store.terminal(for: sid) {
            empty = nil
            t.frame = body.bounds
            t.autoresizingMask = [.width, .height]
            body.addSubview(t)
        } else {
            let e = EmptyPaneView(store: store, paneID: paneID)
            e.frame = body.bounds
            e.autoresizingMask = [.width, .height]
            body.addSubview(e)
            empty = e
        }
    }

    override func layout() {
        super.layout()
        let h = PaneHeaderView.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        body.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        body.subviews.forEach { $0.frame = body.bounds }
        dropOverlay?.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        store.focus(pane: paneID)
        super.mouseDown(with: event)
    }

    // MARK: Drop target

    private enum Zone { case center, edge(DropEdge) }

    private func zone(at p: NSPoint) -> Zone {
        if p.y < PaneHeaderView.height { return .center }             // dropping on the tab strip adds a tab
        let x = p.x / bounds.width, y = p.y / bounds.height
        let d = min(x, 1 - x, y, 1 - y)
        if d > 0.24 { return .center }
        if d == x { return .edge(.left) }
        if d == 1 - x { return .edge(.right) }
        return d == y ? .edge(.top) : .edge(.bottom)
    }

    private func sessionID(from info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .string).flatMap { store.session($0) != nil ? $0 : nil }
    }

    private func draggedPane(from info: NSDraggingInfo) -> String? {
        guard let s = info.draggingPasteboard.string(forType: .string), s.hasPrefix(Self.panePrefix) else { return nil }
        let id = String(s.dropFirst(Self.panePrefix.count))
        return id == paneID ? nil : id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let isPane = draggedPane(from: sender) != nil
        guard isPane || sessionID(from: sender) != nil else { hideOverlay(); return [] }
        showOverlay(zone(at: convert(sender.draggingLocation, from: nil)), centerLabel: isPane ? "交换位置" : "加为 Tab")
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideOverlay() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideOverlay() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideOverlay()
        if let moving = draggedPane(from: sender) {
            switch zone(at: convert(sender.draggingLocation, from: nil)) {
            case .center: store.movePane(moving, to: paneID, edge: nil)
            case .edge(let e): store.movePane(moving, to: paneID, edge: e)
            }
            return true
        }
        guard let sid = sessionID(from: sender) else { return false }
        switch zone(at: convert(sender.draggingLocation, from: nil)) {
        case .center: store.move(sid, to: paneID, edge: nil)
        case .edge(let e): store.move(sid, to: paneID, edge: e)
        }
        return true
    }

    private func showOverlay(_ z: Zone, centerLabel: String) {
        if dropOverlay == nil {
            let o = DropOverlay(frame: bounds)
            addSubview(o)
            dropOverlay = o
        }
        let b = bounds.insetBy(dx: 6, dy: 6)
        switch z {
        case .center: dropOverlay?.set(rect: b, label: centerLabel)
        case .edge(let e):
            let r: NSRect
            switch e {
            case .left: r = NSRect(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
            case .right: r = NSRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
            case .top: r = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
            case .bottom: r = NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
            }
            dropOverlay?.set(rect: r, label: ["放到左侧", "放到右侧", "放到上方", "放到下方"][[DropEdge.left, .right, .top, .bottom].firstIndex(of: e)!])
        }
    }

    private func hideOverlay() { dropOverlay?.removeFromSuperview(); dropOverlay = nil }
}

@MainActor
final class DropOverlay: NSView {
    private var target: NSRect = .zero
    private var label = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(rect: NSRect, label: String) {
        guard rect != target || label != self.label else { return }
        target = rect; self.label = label; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: target, xRadius: 8, yRadius: 8)
        Theme.accent.withAlphaComponent(0.12).setFill(); path.fill()
        Theme.accent.setStroke(); path.lineWidth = 2; path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.accent]
        let s = NSAttributedString(string: label, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2))
    }
}

/// Shown in a pane with no tabs: recent sessions that are not open anywhere.
@MainActor
final class EmptyPaneView: NSView {
    private let store: Store
    private let paneID: String
    private let heading = NSTextField.label("放一个 Session 进来", font: NSFont.systemFont(ofSize: 13, weight: .semibold))
    private let hint = NSTextField.label("从左侧拖进来，或者选一个：", font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private let list = NSView()
    private var rows: [PickRow] = []

    init(store: Store, paneID: String) {
        self.store = store
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.pane.cgColor
        list.wantsLayer = true
        list.layer?.cornerRadius = 9
        list.layer?.borderWidth = 1
        list.layer?.borderColor = Theme.line.cgColor
        [heading, hint, list].forEach(addSubview)
        let open = Set(store.layout.openSessionIDs)
        let recent = store.sessionsByWorktree.values.flatMap { $0 }.filter { !open.contains($0.id) }
            .sorted { $0.lastActivity > $1.lastActivity }.prefix(6)
        for s in recent {
            let r = PickRow(kind: s.kind, title: store.title(of: s), detail: (store.worktree(for: s).map { store.projectName(of: $0) + " · " } ?? "") + RelativeTime.short(s.lastActivity))
            r.onPick = { [weak self] in guard let self else { return }; self.store.addTab(s.id, to: self.paneID) }
            list.addSubview(r)
            rows.append(r)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w: CGFloat = min(360, bounds.width - 32), rowH: CGFloat = 30
        let total = 20 + 20 + 10 + CGFloat(rows.count) * rowH + 8
        let x = (bounds.width - w) / 2, y0 = max(20, (bounds.height - total) / 2)
        heading.frame = NSRect(x: x, y: y0, width: w, height: 18)
        hint.frame = NSRect(x: x, y: y0 + 22, width: w, height: 16)
        list.frame = NSRect(x: x, y: y0 + 48, width: w, height: CGFloat(rows.count) * rowH + 8)
        for (i, r) in rows.enumerated() { r.frame = NSRect(x: 4, y: 4 + CGFloat(i) * rowH, width: w - 8, height: rowH) }
    }
}

/// One choosable session in the empty pane: highlights on hover, picks on click.
@MainActor
final class PickRow: NSView {
    var onPick: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField.label(font: NSFont.systemFont(ofSize: 12))
    private let detail = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    private var hovering = false { didSet { needsDisplay = true } }

    init(kind: AgentKind, title t: String, detail d: String) {
        super.init(frame: .zero)
        icon.image = Icons.agent(kind, size: 11)
        title.stringValue = t
        detail.stringValue = d
        detail.alignment = .right
        [icon, title, detail].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        detail.sizeToFit()
        layoutRow([(icon, 11), (title, nil), (detail, min(detail.frame.width, bounds.width * 0.4))], leading: 10, trailing: 10, gap: 8)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.selBG.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
