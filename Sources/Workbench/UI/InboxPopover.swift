import AppKit

/// The bell's popover: sessions that need you (permission, question, plan), finished turns and
/// errors to look at, and what is still running. Clicking a row jumps there and counts as read.
@MainActor
final class InboxPopover: NSObject, NSPopoverDelegate {
    private let store: Store
    private let popover = NSPopover()
    private let content: InboxView
    private var token: UUID?

    init(store: Store) {
        self.store = store
        content = InboxView(store: store)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let vc = NSViewController()
        vc.view = content
        popover.contentViewController = vc
        content.onPick = { [weak self] id in
            self?.popover.performClose(nil)
            self?.store.openFromInbox(id)
        }
        content.onResize = { [weak self] size in self?.popover.contentSize = size }
    }

    var isShown: Bool { popover.isShown }

    func toggle(from anchor: NSView) {
        if popover.isShown { popover.performClose(nil); return }
        content.reload()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        token = store.observe { [weak self] _ in self?.content.reload() }
    }

    func popoverDidClose(_ notification: Notification) {
        if let token { store.unobserve(token) }
        token = nil
    }
}

@MainActor
private final class InboxView: NSView {
    var onPick: ((String) -> Void)?
    var onResize: ((NSSize) -> Void)?
    private let store: Store
    private var filter = 0            // 0 all, 1 needs, 2 review, 3 working
    private let title = NSTextField.label("收件箱", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
    private let summary = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private let readAll = NSButton(title: "全部标为已读", target: nil, action: nil)
    private let tabs = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let list = InboxFlipped()
    private let empty = NSTextField.label(font: NSFont.systemFont(ofSize: 12.5), color: Theme.faint)
    private let footer = NSTextField.label("点一行 = 跳到那个会话并标为已读　·　⌘I 打开 / 关闭", font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    static let width: CGFloat = 440

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        readAll.isBordered = false
        readAll.font = NSFont.systemFont(ofSize: 11.5)
        readAll.contentTintColor = Theme.muted
        readAll.target = self; readAll.action = #selector(markRead)
        tabs.segmentCount = 4
        tabs.segmentStyle = .rounded
        tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(filterChanged)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        empty.alignment = .center
        [title, summary, readAll, tabs, scroll, empty, footer].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func markRead() { store.markInboxRead() }
    @objc private func filterChanged() { filter = tabs.selectedSegment; reload() }

    func reload() {
        let all = store.inboxItems()
        let needs = all.filter { $0.group == .needs }, review = all.filter { $0.group == .review }, working = all.filter { $0.group == .working }
        summary.stringValue = needs.isEmpty ? (review.isEmpty ? "都处理完了" : "\(review.count) 个待查看")
            : "\(needs.count) 个需要你" + (review.isEmpty ? "" : " · \(review.count) 个待查看")
        for (i, (label, n)) in [("全部", needs.count + review.count), ("需要你", needs.count), ("待查看", review.count), ("进行中", working.count)].enumerated() {
            tabs.setLabel(n > 0 ? "\(label) \(n)" : label, forSegment: i)
            tabs.setWidth(0, forSegment: i)
        }
        readAll.isEnabled = !review.isEmpty
        let shown: [InboxItem]
        switch filter {
        case 1: shown = needs
        case 2: shown = review
        case 3: shown = working
        default: shown = all
        }
        list.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 4
        var lastGroup: InboxItem.Group?
        for item in shown {
            if filter == 0, item.group != lastGroup {
                let n = shown.filter { $0.group == item.group }.count
                let h = NSTextField.label(["需要你", "待你查看", "进行中"][item.group.rawValue] + " · \(n)",
                                          font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                          color: [Theme.wait, Theme.accent, Theme.run][item.group.rawValue])
                h.frame = NSRect(x: 16, y: y + 8, width: Self.width - 32, height: 14)
                list.addSubview(h)
                y += 26
                lastGroup = item.group
            }
            let row = InboxRow(item: item)
            row.onClick = { [weak self] in self?.onPick?(item.id) }
            row.frame = NSRect(x: 6, y: y, width: Self.width - 12, height: InboxRow.height(for: item, width: Self.width - 12))
            list.addSubview(row)
            y += row.frame.height + 2
        }
        let listH = min(max(y + 6, 90), 520)
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(y + 6, listH))
        empty.isHidden = !shown.isEmpty
        empty.stringValue = working.isEmpty || filter != 0 ? "这里没有需要处理的会话" : "都处理完了 · \(working.count) 个会话还在运行"
        let total = 44 + 34 + listH + 32
        frame.size = NSSize(width: Self.width, height: total)
        needsLayout = true
        onResize?(frame.size)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 16, y: 16, width: 60, height: 18)
        summary.frame = NSRect(x: 76, y: 17, width: 220, height: 16)
        readAll.sizeToFit()
        readAll.frame = NSRect(x: w - readAll.frame.width - 16, y: 14, width: readAll.frame.width + 4, height: 22)
        tabs.frame = NSRect(x: 12, y: 44, width: w - 24, height: 24)
        let listTop: CGFloat = 78
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: bounds.height - listTop - 32)
        empty.frame = NSRect(x: 0, y: listTop + 36, width: w, height: 18)
        footer.frame = NSRect(x: 16, y: bounds.height - 24, width: w - 32, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        NSRect(x: 0, y: 76, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 32, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class InboxFlipped: NSView { override var isFlipped: Bool { true } }

/// Agent icon · title · label pill · time, then where it is, then the agent's own words.
@MainActor
private final class InboxRow: NSView {
    var onClick: (() -> Void)?
    private let item: InboxItem
    private var hovering = false
    private let icon = NSImageView()
    private let title = NSTextField.label(font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), color: Theme.selFG)
    private let pill = NSTextField.label(font: NSFont.systemFont(ofSize: 10.5, weight: .semibold))
    private let time = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.faint)
    private let place = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: Theme.muted)
    private let message = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: NSColor(white: 0.8, alpha: 1))

    static func pillInfo(_ l: InboxItem.Label) -> (String, NSColor) {
        switch l {
        case .permission: ("需要授权", Theme.wait)
        case .question: ("等你回答", Theme.wait)
        case .plan: ("确认计划", Theme.wait)
        case .bell: ("终端响铃", Theme.wait)
        case .done: ("待查看", Theme.accent)
        case .failed: ("出错了", Theme.danger)
        case .working: ("进行中", Theme.run)
        }
    }

    static func height(for item: InboxItem, width: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: item.message, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let h = text.boundingRect(with: NSSize(width: width - 46, height: 60), options: [.usesLineFragmentOrigin]).height
        return 8 + 17 + 2 + 14 + 3 + min(ceil(h), 32) + 8
    }

    init(item: InboxItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.image = Icons.agent(item.agent, size: 13)
        title.stringValue = item.title
        let (label, color) = Self.pillInfo(item.label)
        pill.stringValue = " \(label) "
        pill.textColor = color
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4
        pill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        time.stringValue = item.group == .working ? "" : RelativeTime.short(item.since)
        time.alignment = .right
        place.stringValue = item.place
        message.stringValue = item.message
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        message.cell?.truncatesLastVisibleLine = true
        toolTip = item.message
        [icon, title, pill, time, place, message].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 10, y: 10, width: 14, height: 14)
        time.sizeToFit()
        time.frame = NSRect(x: w - 10 - time.frame.width, y: 9, width: time.frame.width, height: 15)
        pill.sizeToFit()
        let titleW = min(title.intrinsicContentSize.width, w - 34 - pill.frame.width - 8 - time.frame.width - 16)
        title.frame = NSRect(x: 34, y: 8, width: max(40, titleW), height: 17)
        pill.frame = NSRect(x: title.frame.maxX + 8, y: 9, width: pill.frame.width, height: 15)
        place.frame = NSRect(x: 34, y: 27, width: w - 44, height: 14)
        message.frame = NSRect(x: 34, y: 44, width: w - 44, height: bounds.height - 44 - 6)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; layer?.backgroundColor = Theme.selBG.cgColor }
    override func mouseExited(with event: NSEvent) { hovering = false; layer?.backgroundColor = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
