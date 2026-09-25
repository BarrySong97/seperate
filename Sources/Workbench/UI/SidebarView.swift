import AppKit

/// Projects → worktrees → sessions of the active workspace as an NSOutlineView, with the Arc-style
/// workspace switcher at the bottom. Expansion state is AppKit's own (autosave keyed per workspace),
/// the way CodeEdit's project navigator does it — the app never tracks it itself.
@MainActor
final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let width: CGFloat = 244
    static let footerHeight: CGFloat = 34
    static let switcherHeight: CGFloat = 42
    static let motion = Motion(duration: 0.28)
    /// Sessions listed per worktree (pinned, needs you, then newest, any age) before the "show all" row;
    /// running ones are always listed.
    static let sessionLimit = 5

    /// Arc-like timing: quick start, soft landing.
    struct Motion { let duration: TimeInterval; let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }

    var topInset: CGFloat = 38 { didSet { needsLayout = true } }   // traffic lights when docked

    private let store: Store
    private let outline = SidebarOutline()
    private let scroll = HoverScrollView()
    private let slider = NSView()           // clips the outline during workspace slides
    private let footer = NSView()
    private let addButton = NSButton()
    private let addMore = IconButton(symbol: "chevron.down", size: 8, tooltip: "更多添加方式", side: 20)
    // The inbox bell, at the right end of the "添加项目" row.
    private let bell = IconButton(symbol: "bell", size: 12, tooltip: "收件箱 ⌘I", side: 26)
    private let bellBadge = BellBadge()
    private lazy var inbox = InboxPopover(store: store)
    private let switcher = WorkspaceSwitcher()
    private let tintLayer = CAGradientLayer()
    private var items: [String: Item] = [:]
    private var token: UUID?
    private var clock: Timer?
    private var loadedWorkspace: String?
    private(set) var expanded = Set<String>()     // kept from expand/collapse notifications (hidden children included)
    private var swipeAccum: CGFloat = 0
    private var swipeLocked = false

    /// Outline items need stable object identity across reloads; keyed by "p:<root>", "w:<path>", "s:<id>".
    final class Item: NSObject {
        enum Kind { case project(Project), worktree(Worktree), session(AgentSession), more(Worktree, Int) }
        var kind: Kind
        let key: String
        init(key: String, kind: Kind) { self.key = key; self.kind = kind }
    }

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ground.cgColor
        tintLayer.colors = [Theme.ground.cgColor, Theme.ground.cgColor]
        tintLayer.locations = [0, 0.55]
        layer?.addSublayer(tintLayer)

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 0
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = .zero
        outline.style = .plain
        outline.autosaveExpandedItems = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.registerForDraggedTypes([.projectID, .worktreePath])
        scroll.documentView = outline
        scroll.drawsBackground = false
        slider.wantsLayer = true
        slider.layer?.masksToBounds = true
        slider.addSubview(scroll)
        addSubview(slider)

        for (b, title, sym, sel) in [(addButton, "添加项目", "plus", #selector(addProject))] {
            b.isBordered = false
            b.font = Theme.smallFont
            b.contentTintColor = Theme.faint
            b.image = Icons.symbol(sym, size: 10)
            b.imagePosition = .imageLeading
            b.title = title
            b.target = self
            b.action = sel
            footer.addSubview(b)
        }
        // "添加项目" picks a folder; ▾ also offers the projects your agents have worked in.
        addMore.onClick = { [weak self] in
            guard let self else { return }
            let m = NSMenu()
            m.addItem(ActionItem("选择文件夹…") { [weak self] in self?.store.pickProject() })
            m.addItem(ActionItem("从 Agent 使用过的项目导入…") { [weak self] in self?.store.showImport() })
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: self.addMore.bounds.height + 2), in: self.addMore)
        }
        footer.addSubview(addMore)
        bell.onClick = { [weak self] in self?.toggleInbox() }
        footer.addSubview(bell)
        footer.addSubview(bellBadge)
        store.inboxHandler = { [weak self] in self?.toggleInbox() }
        addSubview(footer)
        switcher.onSelect = { [weak self] id in self?.store.switchWorkspace(to: id) }
        switcher.onAdd = { [weak self] in self?.store.promptNewWorkspace() }
        switcher.onMenu = { [weak self] w in self.map { Menus.workspace($0.store, w) } }
        switcher.onReorder = { [weak self] id, index in self?.store.reorderWorkspace(id, to: index) }
        addSubview(switcher)

        token = store.observe { [weak self] change in
            self?.updateBell()
            switch change {
            case .projects: self?.reload()
            case .session(let id): self?.refreshSession(id)
            case .layout: self?.refreshAllSessions()
            case .workspace: self?.workspaceChanged()
            case .reveal(let id): self?.reveal(id)
            case .sidebar: break
            }
        }
        loadWorkspace(animated: false)
        updateBell()
        // Relative times ("5分钟") age even when nothing else changes.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllSessions() }
        }
    }

    deinit { clock?.invalidate() }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // A bare CALayer animates frame changes implicitly (~0.25 s), so the tint would trail a resize.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()
        let listH = h - topInset - Self.footerHeight - Self.switcherHeight
        slider.frame = NSRect(x: 0, y: topInset, width: w, height: max(0, listH))
        if scroll.frame.origin.x == 0 || scroll.frame.width != w { scroll.frame = slider.bounds }
        footer.frame = NSRect(x: 0, y: h - Self.switcherHeight - Self.footerHeight, width: w, height: Self.footerHeight)
        addButton.sizeToFit()
        addButton.frame = NSRect(x: 10, y: 7, width: addButton.frame.width + 6, height: 20)
        addMore.frame = NSRect(x: addButton.frame.maxX, y: 7, width: 20, height: 20)
        // Same column as the workspace switcher's "+" below it (centred on w - 20).
        bell.frame = NSRect(x: w - 20 - 13, y: 4, width: 26, height: 26)
        bellBadge.frame = NSRect(x: bell.frame.maxX - 13, y: bell.frame.minY - 1, width: 18, height: 14)
        switcher.frame = NSRect(x: 0, y: h - Self.switcherHeight, width: w, height: Self.switcherHeight)
    }

    // The strip above the list (behind the traffic lights) acts as title bar.
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < topInset { window?.handleTitlebarMouseDown(event) }
        else { super.mouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        NSRect(x: 0, y: footer.frame.minY, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: switcher.frame.minY, width: bounds.width, height: 1).fill()
    }

    // MARK: Data

    private func item(_ key: String, _ kind: Item.Kind) -> Item {
        if let i = items[key] { i.kind = kind; return i }
        let i = Item(key: key, kind: kind); items[key] = i; return i
    }

    private func item(forKey key: String) -> Item? {
        if let i = items[key] { return i }
        if key.hasPrefix("p:"), let p = store.project(String(key.dropFirst(2))) { return item(key, .project(p)) }
        if key.hasPrefix("w:"), let w = store.worktree(path: String(key.dropFirst(2))) { return item(key, .worktree(w)) }
        if key.hasPrefix("s:"), let s = store.session(String(key.dropFirst(2))) { return item(key, .session(s)) }
        return nil
    }

    private func children(of item: Item?) -> [Item] {
        guard let item else { return store.visibleProjects.map { self.item("p:" + $0.id, .project($0)) } }
        switch item.kind {
        case .project(let p):
            // Worktrees with nothing to show stay out of the list; start one from the project's "+".
            let shown = store.worktrees(of: p).filter { $0.isMain || !store.sessions(in: $0).isEmpty }
            if shown.count <= 1 { return shown.first.map(sessionItems) ?? [] }
            return shown.map { self.item("w:" + $0.path, .worktree($0)) }
        case .worktree(let w): return sessionItems(w)
        case .session, .more: return []
        }
    }

    /// The first few sessions (plus any running ones), then a "show all" row when there are more.
    private func sessionItems(_ w: Worktree) -> [Item] {
        let list = store.sessions(in: w)
        var visible = Array(list.prefix(Self.sessionLimit))
        visible += list.dropFirst(Self.sessionLimit).filter { store.status(of: $0.id) != .history }
        var out = visible.map { self.item("s:" + $0.id, .session($0)) }
        let total = store.allSessions(in: w).count
        if total > visible.count { out.append(item("m:" + w.path, .more(w, total))) }
        return out
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item as? Item).count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item as? Item)[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch (item as! Item).kind { case .project, .worktree: true; case .session, .more: false }
    }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    // AppKit persists expansion per autosaveName using these keys (the CodeEdit approach).
    func outlineView(_ o: NSOutlineView, persistentObjectForItem item: Any?) -> Any? { (item as? Item)?.key }
    func outlineView(_ o: NSOutlineView, itemForPersistentObject object: Any) -> Any? { (object as? String).flatMap(item(forKey:)) }

    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as! Item).kind {
        case .project: 30
        case .worktree: 26
        case .session: 28
        case .more: 26
        }
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (o.makeView(withIdentifier: .init("row"), owner: nil) as? HoverRowView) ?? { let r = HoverRowView(); r.identifier = .init("row"); return r }()
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let it = item as! Item
        switch it.kind {
        case .project(let p):
            let v = (o.makeView(withIdentifier: .init("project"), owner: nil) as? ProjectCell) ?? { let c = ProjectCell(); c.identifier = .init("project"); return c }()
            // Collapsed: show only the most pressing state inside (needs you > done > working).
            let inside = o.isItemExpanded(it) ? [] : store.worktrees(of: p).flatMap(store.sessions(in:)).map { store.status(of: $0.id) }
            let live = inside.filter { $0.urgency >= SessionStatus.working.urgency }.max { $0.urgency < $1.urgency }.map { [$0] } ?? []
            v.configure(p, live: live, open: o.isItemExpanded(it))
            v.plus.onClick = { [weak self, weak v] in guard let self, let v else { return }; Menus.project(self.store, p).popUp(positioning: nil, at: NSPoint(x: 0, y: v.plus.bounds.height + 2), in: v.plus) }
            return v
        case .worktree(let w):
            let v = (o.makeView(withIdentifier: .init("worktree"), owner: nil) as? WorktreeCell) ?? { let c = WorktreeCell(); c.identifier = .init("worktree"); return c }()
            v.configure(w, collapsed: !o.isItemExpanded(it))
            v.plus.onClick = { [weak self, weak v] in guard let self, let v else { return }; Menus.worktree(self.store, w).popUp(positioning: nil, at: NSPoint(x: 0, y: v.plus.bounds.height + 2), in: v.plus) }
            return v
        case .more(_, let total):
            let v = (o.makeView(withIdentifier: .init("more"), owner: nil) as? MoreCell) ?? { let c = MoreCell(); c.identifier = .init("more"); return c }()
            v.configure(total: total)
            return v
        case .session(let s):
            let v = (o.makeView(withIdentifier: .init("session"), owner: nil) as? SessionCell) ?? { let c = SessionCell(); c.identifier = .init("session"); return c }()
            let pane = store.layout.pane(containing: s.id)
            let elsewhere = pane == nil && store.workspaceContaining(s.id) != nil
            let selected = pane != nil && pane?.id == store.layout.focusedPaneID && pane?.active == s.id
            v.configure(title: store.title(of: s), kind: s.kind, status: store.status(of: s.id), time: RelativeTime.short(s.lastActivity),
                        pinned: store.isPinned(s.id), selected: selected, open: pane != nil || elsewhere)
            v.toolTip = "\(s.kind.displayName) · \(RelativeTime.full(s.lastActivity))"
                + (elsewhere ? "\n打开在「\(store.workspaceContaining(s.id)!.name)」里，点击会移到这里" : "\n⌘/⇧+点击：向右分屏打开")
            return v
        }
    }

    // MARK: Interaction

    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let it = outline.item(atRow: row) as? Item else { return }
        switch it.kind {
        case .project, .worktree:
            toggle(it, row: row)
        case .more(let w, _):
            store.showPalette(.worktree(w.path))
        case .session(let s):
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            store.open(s.id, newPane: mods.contains(.command) || mods.contains(.shift))
        }
    }

    // MARK: Expand / collapse animation
    // AppKit's animated expand slides the new rows down from above the parent row, and since rows
    // are transparent they visibly pass over it. Instead, like an accordion: the rows below the
    // parent slide to open (or close) the gap, and the children fade in (or out) inside it.

    private var toggling = false

    #if DEBUG
    /// Dev aid: toggle the first row whose title contains `name`; lists rows as text.
    func debugToggle(_ name: String) {
        for r in 0..<outline.numberOfRows {
            guard let it = outline.item(atRow: r) as? Item else { continue }
            if case .project(let p) = it.kind, p.name.contains(name) { toggle(it, row: r); return }
            if case .worktree(let w) = it.kind, w.alias.contains(name) { toggle(it, row: r); return }
        }
    }
    func debugRows() -> String {
        (0..<outline.numberOfRows).map { r -> String in
            guard let it = outline.item(atRow: r) as? Item else { return "?" }
            switch it.kind {
            case .project(let p): return "P \(p.name) open=\(outline.isItemExpanded(it))"
            case .worktree(let w): return "  W \(w.alias) open=\(outline.isItemExpanded(it))"
            case .session(let x): return "    S \(x.title)"
            case .more: return "    more"
            }
        }.joined(separator: "\n")
    }
    #endif

    func toggle(_ it: Item, row: Int) {
        guard !toggling else { return }
        let collapsing = outline.isItemExpanded(it)
        // Only an explicit collapse forgets a row; AppKit also notifies for children hidden by a parent's collapse.
        if collapsing { expanded.remove(it.key) }
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DisclosureCell)?.setOpen(!collapsing, animated: true)
        if collapsing { animateCollapse(it, row: row) } else { animateExpand(it, row: row) }
    }

    /// Rows from `first` down to the bottom of the visible area, allowing for a `shift` that will move them.
    private func rowViews(from first: Int, shift: CGFloat) -> [NSView] {
        let bottom = outline.visibleRect.maxY + abs(shift)
        var out: [NSView] = []
        var r = first
        while r < outline.numberOfRows, outline.rect(ofRow: r).minY < bottom {
            if let v = outline.rowView(atRow: r, makeIfNecessary: true) { out.append(v) }
            r += 1
        }
        return out
    }

    private func animateExpand(_ it: Item, row: Int) {
        let before = outline.numberOfRows
        outline.expandItem(it)   // children remembered as open come back inside the did-expand notification
        let added = outline.numberOfRows - before
        guard added > 0 else { return }
        outline.layoutSubtreeIfNeeded()
        let first = row + 1, last = row + added
        let gap = outline.rect(ofRow: last).maxY - outline.rect(ofRow: first).minY
        let children = (first...last).filter { outline.rect(ofRow: $0).minY < outline.visibleRect.maxY }
            .compactMap { outline.rowView(atRow: $0, makeIfNecessary: true) }
        let below = rowViews(from: last + 1, shift: 0).filter { outline.rect(ofRow: outline.row(for: $0)).minY - gap < outline.visibleRect.maxY }
        let d = Self.motion.duration
        toggling = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.toggling = false }
        for v in below { v.layer?.add(slide(from: -gap, to: 0, duration: d), forKey: "accordion") }
        for v in children { v.layer?.add(fade(from: 0, to: 1, delay: d * 0.3, duration: d * 0.7), forKey: "accordion") }
        CATransaction.commit()
    }

    private func animateCollapse(_ it: Item, row: Int) {
        let level = outline.level(forRow: row)
        var last = row
        while last + 1 < outline.numberOfRows, outline.level(forRow: last + 1) > level { last += 1 }
        guard last > row else { outline.collapseItem(it); return }
        let first = row + 1
        let gap = outline.rect(ofRow: last).maxY - outline.rect(ofRow: first).minY
        let children = (first...last).filter { outline.rect(ofRow: $0).intersects(outline.visibleRect) }
            .compactMap { outline.rowView(atRow: $0, makeIfNecessary: false) }
        let below = rowViews(from: last + 1, shift: gap)
        let d = Self.motion.duration
        toggling = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // Swap the animated picture for the real collapsed layout in one frame.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.outline.collapseItem(it)
            (children + below).forEach { $0.layer?.removeAnimation(forKey: "accordion") }
            CATransaction.commit()
            self.toggling = false
        }
        for v in below { v.layer?.add(slide(from: 0, to: -gap, duration: d, hold: true), forKey: "accordion") }
        for v in children { v.layer?.add(fade(from: 1, to: 0, delay: 0, duration: d * 0.55, hold: true), forKey: "accordion") }
        CATransaction.commit()
    }

    /// Vertical move in the outline's (flipped) coordinates: negative is up.
    private func slide(from: CGFloat, to: CGFloat, duration: CFTimeInterval, hold: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = from; a.toValue = to
        a.duration = duration
        a.timingFunction = Self.motion.curve
        if hold { a.fillMode = .forwards; a.isRemovedOnCompletion = false }
        return a
    }

    private func fade(from: Float, to: Float, delay: CFTimeInterval, duration: CFTimeInterval, hold: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = to
        a.beginTime = CACurrentMediaTime() + delay
        a.duration = duration
        a.timingFunction = Self.motion.curve
        a.fillMode = hold ? .both : .backwards
        a.isRemovedOnCompletion = !hold
        return a
    }

    // Collapsed project rows aggregate their live dots; worktree rows show a "collapsed" hint.
    // Reloading inside the notification cancels the expansion change itself, so refresh the row afterwards.
    func outlineViewItemDidExpand(_ n: Notification) {
        if let it = n.userInfo?["NSObject"] as? Item {
            expanded.insert(it.key)
            // A reload forgets how hidden children were; bring them back the way they were left.
            for child in children(of: it) where expanded.contains(child.key) && !outline.isItemExpanded(child) { outline.expandItem(child) }
        }
        refreshRowLater(n)
    }
    func outlineViewItemDidCollapse(_ n: Notification) { refreshRowLater(n) }
    private func refreshRowLater(_ n: Notification) {
        guard let it = n.userInfo?["NSObject"] as? Item else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.outline.row(forItem: it) >= 0 else { return }
            self.outline.reloadItem(it)
        }
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let it = outline.item(atRow: row) as? Item else { return nil }
        switch it.kind {
        case .project(let p): return Menus.project(store, p)
        case .worktree(let w): return Menus.worktree(store, w)
        case .session(let s): return Menus.session(store, s)
        case .more: return nil
        }
    }

    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let pb = NSPasteboardItem()
        switch (item as! Item).kind {
        case .session(let s): pb.setString(s.id, forType: .string)       // into a pane
        case .project(let p): pb.setString(p.id, forType: .projectID)    // reorder in the list
        case .worktree(let w): pb.setString(w.path, forType: .worktreePath)  // reorder inside its project
        default: return nil
        }
        return pb
    }

    // Projects are reordered by dragging them between other projects (top level only);
    // worktrees by dragging them between the other worktrees of their project.
    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let path = info.draggingPasteboard.string(forType: .worktreePath) {
            guard let wt = store.worktree(path: path), let project = items["p:" + wt.projectID] else { return [] }
            if let it = item as? Item, it === project, index >= 0 { return .move }
            // On or inside a row of the same project: aim at the gap above or below that worktree.
            var target = item as? Item
            while let t = target, (o.parent(forItem: t) as? Item) !== project { target = o.parent(forItem: t) as? Item }
            guard let t = target, let i = children(of: project).firstIndex(where: { $0 === t }) else { return [] }
            let row = o.row(forItem: t)
            let below = row >= 0 && o.convert(info.draggingLocation, from: nil).y > o.rect(ofRow: row).midY
            o.setDropItem(project, dropChildIndex: i + (below ? 1 : 0))
            return .move
        }
        guard info.draggingPasteboard.string(forType: .projectID) != nil else { return [] }
        if item == nil, index >= 0 { return .move }
        // Dropped on or inside a project: aim at the gap above or below that project instead.
        var target = item as? Item
        while let t = target, o.parent(forItem: t) != nil { target = o.parent(forItem: t) as? Item }
        guard let t = target, let top = children(of: nil).firstIndex(where: { $0 === t }) else { return [] }
        let row = o.row(forItem: t)
        let below = row >= 0 && o.convert(info.draggingLocation, from: nil).y > o.rect(ofRow: row).midY
        o.setDropItem(nil, dropChildIndex: top + (below ? 1 : 0))
        return .move
    }

    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let path = info.draggingPasteboard.string(forType: .worktreePath) {
            guard let project = item as? Item, index >= 0 else { return false }
            let shown = children(of: project)
            var before: String? = nil
            if index < shown.count, case .worktree(let w) = shown[index].kind { before = w.path }
            store.reorderWorktree(path, before: before)
            return true
        }
        guard item == nil, index >= 0, let id = info.draggingPasteboard.string(forType: .projectID) else { return false }
        store.reorderProject(id, to: index)
        return true
    }

    @objc private func addProject() { store.pickProject() }

    // MARK: Inbox bell

    private func toggleInbox() {
        if window?.isVisible == true, !isHidden, bell.window != nil { inbox.toggle(from: bell) }
    }

    /// Amber count = sessions that need you; a small bone dot = only finished / failed ones to look at.
    private func updateBell() {
        let items = store.inboxItems()
        let needs = items.filter { $0.group == .needs }.count
        let review = items.filter { $0.group == .review }.count
        bellBadge.state = needs > 0 ? .count(needs) : (review > 0 ? .dot : .none)
        bell.contentTintColor = needs + review > 0 ? Theme.text : Theme.muted
        bell.toolTip = needs > 0 ? "\(needs) 个会话需要你 · ⌘I" : (review > 0 ? "\(review) 个待查看 · ⌘I" : "收件箱 ⌘I")
    }

    /// Two-finger horizontal swipe over the list switches workspaces (Arc's gesture).
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
        if event.phase == .began { swipeAccum = 0; swipeLocked = false }
        guard !swipeLocked else { return }
        swipeAccum += event.scrollingDeltaX
        if abs(swipeAccum) > 60 {
            swipeLocked = true
            store.switchWorkspace(offset: swipeAccum < 0 ? 1 : -1)   // natural scrolling: swipe left = next
        }
    }

    // MARK: Updates

    /// Test hook mirroring a click on an open row.
    func noteExplicitCollapse(_ it: Item) { expanded.remove(it.key) }

    /// Items AppKit opened on its own (autosave restore, expandChildren) send no notification; pick them up here.
    private func noteVisibleExpansion() {
        for row in 0..<outline.numberOfRows {
            if let it = outline.item(atRow: row) as? Item, outline.isItemExpanded(it) { expanded.insert(it.key) }
        }
    }

    /// Re-expands parents first; children only exist once their parent is open.
    private func expand(keys: Set<String>) {
        for p in children(of: nil) where keys.contains(p.key) {
            outline.expandItem(p)
            for w in children(of: p) where keys.contains(w.key) { outline.expandItem(w) }
        }
    }

    /// Data changed within the current workspace: reload, keeping whatever is expanded.
    private func reload() {
        let keys = expanded
        outline.reloadData()
        expand(keys: keys)
        noteVisibleExpansion()
        switcher.update(store)
        needsLayout = true
    }

    /// Switching workspace: a new autosave name so AppKit restores that workspace's expansion state.
    private func loadWorkspace(animated: Bool) {
        let w = store.active
        let name = "sidebar-" + w.id
        let firstTime = UserDefaults.standard.object(forKey: "NSOutlineView Items " + name) == nil
        expanded = []
        outline.autosaveName = name
        outline.reloadData()
        if firstTime { outline.expandItem(nil, expandChildren: true) }
        noteVisibleExpansion()
        loadedWorkspace = w.id
        switcher.update(store)
        applyTint(w, animated: animated)
        needsLayout = true
    }

    private func applyTint(_ w: Workspace, animated: Bool) {
        let top = NSColor(hex: w.tint).blended(withFraction: 0.9, of: Theme.ground) ?? Theme.ground
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Self.motion.duration : 0)
        tintLayer.colors = [top.cgColor, Theme.ground.cgColor]
        CATransaction.commit()
    }

    private func workspaceChanged() {
        guard store.active.id != loadedWorkspace else { switcher.update(store); applyTint(store.active, animated: true); return }
        let from = store.workspaces.firstIndex { $0.id == loadedWorkspace } ?? 0
        let dir: CGFloat = store.activeIndex > from ? 1 : -1
        // Slide: a snapshot of the old list leaves while the new one enters from the other side.
        let snap = NSImageView(frame: scroll.frame)
        if let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            let img = NSImage(size: scroll.bounds.size); img.addRepresentation(rep); snap.image = img
        }
        slider.addSubview(snap)
        loadWorkspace(animated: true)
        let w = slider.bounds.width
        scroll.frame.origin.x = dir * w
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.motion.duration
            ctx.timingFunction = Self.motion.curve
            snap.animator().frame.origin.x = -dir * w
            scroll.animator().frame.origin.x = 0
        }, completionHandler: { snap.removeFromSuperview() })
    }

    private func reveal(_ id: String) {
        guard let s = store.session(id), let wt = store.worktree(for: s) else { return }
        if let p = items["p:" + wt.projectID] { outline.expandItem(p) }
        if let w = items["w:" + wt.path] { outline.expandItem(w) }
        if let it = items["s:" + id] { let row = outline.row(forItem: it); if row >= 0 { outline.scrollRowToVisible(row) } }
    }

    private func refreshSession(_ id: String) {
        if let it = items["s:" + id], outline.row(forItem: it) >= 0 { outline.reloadItem(it) }
        if let s = store.session(id), let wt = store.worktree(for: s), let p = items["p:" + wt.projectID],
           outline.row(forItem: p) >= 0, !outline.isItemExpanded(p) { outline.reloadItem(p) }
        switcher.update(store)   // attention badges on other workspaces
    }

    private func refreshAllSessions() {
        for row in 0..<outline.numberOfRows {
            if let it = outline.item(atRow: row) as? Item, case .session = it.kind { outline.reloadItem(it) }
        }
    }
}

/// Outline that asks a closure for the context menu of the clicked row, and hides the disclosure
/// triangles. (Answering `false` to `shouldShowOutlineCellForItem` instead would make AppKit refuse
/// to collapse rows at all.)
@MainActor
final class SidebarOutline: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// Arc's space row: one button per workspace, the active one's name, and "+".
/// The bell's badge: an amber count, or a small dot.
@MainActor
final class BellBadge: NSView {
    enum State: Equatable { case none, dot, count(Int) }
    var state: State = .none { didSet { if state != oldValue { needsDisplay = true; isHidden = state == .none } } }
    override init(frame: NSRect) { super.init(frame: frame); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .none: break
        case .dot:
            Theme.ground.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 3, width: 9, height: 9)).fill()
            Theme.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: 3.5, y: 4.5, width: 6, height: 6)).fill()
        case .count(let n):
            let text = NSAttributedString(string: n > 9 ? "9+" : "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Theme.ground])
            let w = max(14, text.size().width + 7)
            let r = NSRect(x: 0, y: 0, width: w, height: 13)
            Theme.ground.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 7.5, yRadius: 7.5).fill()
            Theme.wait.setFill(); NSBezierPath(roundedRect: r, xRadius: 6.5, yRadius: 6.5).fill()
            text.draw(at: NSPoint(x: r.midX - text.size().width / 2, y: r.midY - text.size().height / 2))
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let projectID = NSPasteboard.PasteboardType("dev.seperate.project")
    static let worktreePath = NSPasteboard.PasteboardType("dev.seperate.worktree")
}

@MainActor
final class WorkspaceSwitcher: NSView {
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var onMenu: ((Workspace) -> NSMenu?)?
    var onReorder: ((_ id: String, _ index: Int) -> Void)?   // index = insertion point in the current order
    private var buttons: [WorkspaceButton] = []
    private var grab: CGFloat = 0
    private let name = NSTextField.label(font: Theme.smallFont, color: Theme.muted)
    private let add = IconButton(symbol: "plus", tooltip: "新建 Workspace", side: 26)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(name)
        addSubview(add)
        add.onClick = { [weak self] in self?.onAdd?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func update(_ store: Store) {
        while buttons.count > store.workspaces.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < store.workspaces.count {
            let b = WorkspaceButton()
            b.onClick = { [weak self, weak b] in if let id = b?.workspaceID { self?.onSelect?(id) } }
            b.menuProvider = { [weak self, weak b] in b?.workspace.flatMap { self?.onMenu?($0) } }
            b.onDrag = { [weak self, weak b] event in if let self, let b { self.drag(b, event) } }
            b.onDrop = { [weak self, weak b] in if let self, let b { self.drop(b) } }
            addSubview(b); buttons.append(b)
        }
        for (b, w) in zip(buttons, store.workspaces) {
            b.configure(w, active: w.id == store.activeID, badge: w.id != store.activeID && store.needsAttention(w),
                        shortcut: (store.workspaces.firstIndex { $0.id == w.id } ?? 0) + 1)
        }
        name.stringValue = store.active.name
        needsLayout = true
    }

    // Dragging a square: it follows the pointer, and the others slide aside to open the gap where it will land.
    private static let side: CGFloat = 22, spacing: CGFloat = 4, inset: CGFloat = 10
    private var dragged: WorkspaceButton?
    private var slot = 0

    private func slotX(_ i: Int) -> CGFloat { Self.inset + CGFloat(i) * (Self.side + Self.spacing) }

    private func drag(_ b: WorkspaceButton, _ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if dragged !== b {
            dragged = b
            grab = x - b.frame.minX
            slot = buttons.firstIndex { $0 === b } ?? 0
            addSubview(b)   // above its siblings
        }
        b.frame.origin.x = min(max(slotX(0), x - grab), slotX(buttons.count - 1))
        let target = min(max(0, Int(((b.frame.minX - Self.inset) / (Self.side + Self.spacing)).rounded())), buttons.count - 1)
        guard target != slot else { return }
        slot = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = SidebarView.motion.curve
            for (i, other) in buttons.filter({ $0 !== b }).enumerated() {
                other.animator().frame.origin.x = slotX(i >= slot ? i + 1 : i)
            }
        }
    }

    private func drop(_ b: WorkspaceButton) {
        guard dragged === b, let from = buttons.firstIndex(where: { $0 === b }), let id = b.workspaceID else { dragged = nil; return }
        let to = slot
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = SidebarView.motion.curve
            b.animator().frame.origin.x = slotX(to)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.dragged = nil
            self.grab = 0
            if to != from { self.onReorder?(id, to > from ? to + 1 : to) }   // the store's insertion point
            self.needsLayout = true
        })
    }

    override func layout() {
        super.layout()
        // Square buttons, the name and "+" all share one vertical center.
        let side = Self.side, midY = bounds.height / 2
        var x = Self.inset
        // Mid-drag the squares are placed by the drag; leave them where they are.
        for b in buttons where dragged == nil { b.frame = NSRect(x: x, y: midY - side / 2, width: side, height: side); x += side + Self.spacing }
        x = slotX(buttons.count)
        add.frame = NSRect(x: bounds.width - 32, y: midY - 12, width: 24, height: 24)
        let nameH = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: x + 4, y: midY - nameH / 2, width: max(0, add.frame.minX - x - 8), height: nameH)
    }
}

@MainActor
final class WorkspaceButton: NSView {
    override var isFlipped: Bool { true }   // badge sits top-right
    var onClick: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onDrop: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var workspace: Workspace?
    private var downAt: NSPoint?, dragging = false
    var workspaceID: String? { workspace?.id }
    private var active = false, badge = false, hovering = false

    func configure(_ w: Workspace, active: Bool, badge: Bool, shortcut: Int) {
        workspace = w; self.active = active; self.badge = badge
        toolTip = "\(w.name) · ⌃\(shortcut)"
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    // A click selects; a drag of more than a few points reorders.
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt else { return }
        if !dragging, abs(event.locationInWindow.x - d.x) > 4 { dragging = true }
        if dragging { onDrag?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { onDrop?() } else if downAt != nil { onClick?() }
        downAt = nil; dragging = false
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let w = workspace else { return }
        let tint = NSColor(hex: w.tint)
        if active { tint.withAlphaComponent(0.22).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        else if hovering { Theme.hover.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                    .foregroundColor: active ? tint.blended(withFraction: 0.35, of: .white) ?? tint : Theme.muted]
        let s = NSAttributedString(string: w.icon, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
        if badge {
            Theme.wait.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 7, y: 1, width: 6, height: 6)).fill()
        }
    }
}

/// Row that tells its cell when the mouse is over it (for hover-only "+" buttons and highlights).
@MainActor
final class HoverRowView: NSTableRowView {
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { (view(atColumn: 0) as? HoverCell)?.hovered = true }
    override func mouseExited(with event: NSEvent) { (view(atColumn: 0) as? HoverCell)?.hovered = false }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
class HoverCell: NSTableCellView {
    var hovered = false { didSet { hoverChanged() } }
    func hoverChanged() {}
}

/// Rows that expand: a chevron that turns when they open or close.
@MainActor
protocol DisclosureCell: AnyObject {
    var chevron: ChevronView { get }
}

extension DisclosureCell {
    func setOpen(_ open: Bool, animated: Bool) { chevron.setOpen(open, animated: animated) }
}

@MainActor
final class ChevronView: NSView {
    private let shape = CAShapeLayer()
    private(set) var isOpen = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -1.8, y: -3.5)); p.addLine(to: CGPoint(x: 1.8, y: 0)); p.addLine(to: CGPoint(x: -1.8, y: 3.5))
        shape.path = p
        shape.fillColor = nil
        shape.strokeColor = Theme.faint.cgColor
        shape.lineWidth = 1.4
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen || !animated else { return }
        isOpen = open
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(SidebarView.motion.curve)
        // Layer y-axis points up here, so -90° turns ">" into "v".
        shape.setAffineTransform(open ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity)
        CATransaction.commit()
    }

    func setColor(_ c: NSColor) { shape.strokeColor = c.cgColor }
}

@MainActor
final class ProjectCell: HoverCell, DisclosureCell {
    let chevron = ChevronView()
    let chip = ChipView()
    let name = NSTextField.label(font: NSFont.systemFont(ofSize: 12.5, weight: .semibold))
    let plus = IconButton(symbol: "plus", tooltip: "新建", side: 24)
    private var dots: [DotView] = []

    init() {
        super.init(frame: .zero)
        [chevron, chip, name, plus].forEach(addSubview)
        plus.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: Project, live: [SessionStatus], open: Bool) {
        chevron.setOpen(open, animated: false)
        chip.name = p.name
        chip.iconPath = p.iconPath
        name.stringValue = p.name
        toolTip = p.rootPath.abbreviatingHome
        dots.forEach { $0.removeFromSuperview() }
        dots = live.map { st in let d = DotView(frame: .zero); d.status = st; addSubview(d); return d }
        needsLayout = true
    }

    override func hoverChanged() { plus.alphaValue = hovered ? 1 : 0 }

    override func layout() {
        super.layout()
        var row: [(NSView, CGFloat?)] = [(chevron, 10), (chip, 18), (name, nil)]
        dots.forEach { row.append(($0, 8)) }
        row.append((plus, 24))
        layoutRow(row, leading: 14, trailing: 6, gap: 6)
    }
}

@MainActor
final class WorktreeCell: HoverCell, DisclosureCell {
    let chevron = ChevronView()
    let name = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    let plus = IconButton(symbol: "plus", size: 10, tooltip: "在这个 Worktree 新建 Session", side: 22)

    init() {
        super.init(frame: .zero)
        [chevron, name, plus].forEach(addSubview)
        plus.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ w: Worktree, collapsed: Bool) {
        name.stringValue = w.alias
        chevron.setOpen(!collapsed, animated: false)
        toolTip = w.path.abbreviatingHome
        needsLayout = true
    }

    override func hoverChanged() { plus.alphaValue = hovered ? 1 : 0; name.textColor = hovered ? Theme.muted : Theme.faint }

    override func layout() {
        super.layout()
        layoutRow([(chevron, 10), (name, nil), (plus, 22)], leading: 36, trailing: 6, gap: 4)
    }
}

/// "显示全部 N 个…" under a long session list; opens the searchable picker.
@MainActor
final class MoreCell: HoverCell {
    private let icon = NSImageView()
    private let label = NSTextField.label(font: NSFont.systemFont(ofSize: 11.5), color: Theme.faint)

    init() {
        super.init(frame: .zero)
        icon.image = Icons.symbol("magnifyingglass", size: 10)
        icon.contentTintColor = Theme.faint
        [icon, label].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(total: Int) { label.stringValue = "显示全部 \(total) 个…"; toolTip = "搜索这个 Worktree 下的所有 Session" }

    override func hoverChanged() {
        label.textColor = hovered ? Theme.text : Theme.faint
        icon.contentTintColor = label.textColor
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { Theme.hover.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill() }
    }
    override func layout() {
        super.layout()
        layoutRow([(icon, 12), (label, nil)], leading: 48, trailing: 14, gap: 8)
    }
}

@MainActor
final class SessionCell: HoverCell {
    private let icon = NSImageView()
    private let title = NSTextField.label()
    private let time = NSTextField.label(font: NSFont.systemFont(ofSize: 10.5), color: Theme.faint)
    private let pin = NSImageView()
    private let dot = DotView(frame: .zero)
    private var selected = false

    init() {
        super.init(frame: .zero)
        time.alignment = .right
        pin.image = Icons.symbol("pin.fill", size: 8)
        [icon, title, pin, time, dot].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, kind: AgentKind, status: SessionStatus, time when: String, pinned: Bool = false, selected: Bool, open: Bool) {
        pin.isHidden = !pinned
        pin.contentTintColor = selected ? Theme.selFG : Theme.faint
        self.selected = selected
        self.status = status
        title.stringValue = t
        let loud = status == .waiting || status == .done || status == .failed
        title.font = NSFont.systemFont(ofSize: Theme.uiFont.pointSize, weight: loud ? .semibold : .regular)
        switch status {
        case .waiting:
            time.stringValue = "等待确认"
            time.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            time.textColor = Theme.wait
        case .failed:
            time.stringValue = "出错了"
            time.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            time.textColor = Theme.danger
        case .done:
            time.stringValue = "完成 · " + when
            time.font = NSFont.systemFont(ofSize: 10.5)
            time.textColor = selected ? Theme.selFG : Theme.accent
        default:
            time.stringValue = when
            time.font = NSFont.systemFont(ofSize: 10.5)
            time.textColor = selected ? Theme.selFG.withAlphaComponent(0.6) : Theme.faint
        }
        title.textColor = selected ? Theme.selFG : (status == .history && !open ? Theme.muted : Theme.text)
        icon.image = Icons.agent(kind, size: 12, color: selected ? Theme.selFG : nil)
        dot.status = status
        needsDisplay = true
        needsLayout = true
    }

    override func hoverChanged() { needsDisplay = true }
    private var status: SessionStatus = .history

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 0)
        if selected { Theme.selBG.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
        else if hovered { Theme.hover.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
        else if status == .waiting { Theme.wait.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
    }

    override func layout() {
        super.layout()
        time.sizeToFit()
        var row: [(NSView, CGFloat?)] = [(icon, 12), (title, nil)]
        if !pin.isHidden { row.append((pin, 9)) }
        row.append((time, time.frame.width))
        if !dot.isHidden { row.append((dot, 8)) }
        layoutRow(row, leading: 48, trailing: 14, gap: 8)
    }
}
