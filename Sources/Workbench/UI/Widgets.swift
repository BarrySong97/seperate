import AppKit

// Small AppKit building blocks shared by the sidebar, pane headers and top bar.

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func tint(for kind: AgentKind) -> NSColor {
        switch kind {
        case .codex: Theme.text
        case .claude: Theme.claude
        case .shell: Theme.shell
        }
    }

    /// Codex's own logo, when the build could bundle it (see scripts/build-app.sh).
    private static let codexLogo: NSImage? = Bundle.main.url(forResource: "codex-icon", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    /// Codex logo (or ">_"), Claude asterisk, shell window.
    static func agent(_ kind: AgentKind, size: CGFloat = 12, color: NSColor? = nil) -> NSImage {
        if kind == .codex, let logo = codexLogo {
            let key = "codex-logo-\(size)"
            if let img = cache[key] { return img }
            let side = size + 1
            let w = logo.size.width
            let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                // The artwork carries ~9% transparent margin; crop it so it lines up with the other icons.
                logo.draw(in: r, from: NSRect(x: w * 0.09, y: w * 0.09, width: w * 0.82, height: w * 0.82),
                          operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high])
                return true
            }
            cache[key] = img
            return img
        }
        let c = color ?? tint(for: kind)
        let key = "\(kind.rawValue)-\(size)-\(c.description)"
        if let img = cache[key] { return img }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let s = r.width / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            let path = NSBezierPath()
            path.lineWidth = size * 0.13; path.lineCapStyle = .round; path.lineJoinStyle = .round
            switch kind {
            case .codex:
                path.move(to: p(3.5, 4.5)); path.line(to: p(7, 8)); path.line(to: p(3.5, 11.5))
                path.move(to: p(8.5, 11.5)); path.line(to: p(13, 11.5))
            case .claude:
                path.move(to: p(8, 2)); path.line(to: p(8, 14))
                path.move(to: p(2.8, 5)); path.line(to: p(13.2, 11))
                path.move(to: p(2.8, 11)); path.line(to: p(13.2, 5))
            case .shell:
                path.appendRoundedRect(NSRect(x: 2 * s, y: 3 * s, width: 12 * s, height: 10 * s), xRadius: 2 * s, yRadius: 2 * s)
                path.move(to: p(5, 7)); path.line(to: p(7, 8.5)); path.line(to: p(5, 10))
            }
            c.setStroke(); path.stroke()
            return true
        }
        cache[key] = img
        return img
    }

    static func symbol(_ name: String, size: CGFloat = 11, weight: NSFont.Weight = .medium) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    }

    /// Layout preset glyph (1–4 columns or 2×2).
    static func preset(_ p: LayoutPreset, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 28, height: 24), flipped: true) { _ in
            color.setFill()
            let w = 17.0, h = 12.0, x0 = (28 - w) / 2, y0 = (24 - h) / 2
            func r(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double) {
                NSBezierPath(roundedRect: NSRect(x: x0 + x, y: y0 + y, width: rw, height: rh), xRadius: 1.2, yRadius: 1.2).fill()
            }
            if p == .grid { r(0, 0, 8, 5.5); r(9, 0, 8, 5.5); r(0, 6.5, 8, 5.5); r(9, 6.5, 8, 5.5) }
            else { let n = Double(p.paneCount), cw = (w - (n - 1)) / n; for i in 0..<p.paneCount { r(Double(i) * (cw + 1), 0, cw, h) } }
            return true
        }
    }
}

/// Borderless icon button that lights up on hover.
@MainActor
final class IconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private let side: CGFloat

    init(symbol: String, size: CGFloat = 11, tooltip: String, side: CGFloat = 22) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        isBordered = false
        image = Icons.symbol(symbol, size: size)
        imagePosition = .imageOnly
        contentTintColor = Theme.muted
        toolTip = tooltip
        target = self
        action = #selector(fire)
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }

    /// Always the full square, so rows that size views by their intrinsic height give the hover background room.
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = Theme.text }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = Theme.muted }

    override func draw(_ dirtyRect: NSRect) {
        if hovering { Theme.hover.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        super.draw(dirtyRect)
    }
}

/// Green (running) / yellow (waiting) dot; nothing for history.
@MainActor
final class DotView: NSView {
    /// working = a turning ring, waiting = a pulsing amber dot, done = a bone dot; nothing for idle / history.
    var status: SessionStatus = .history { didSet { if status != oldValue { restyle() } } }
    private let spinner = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.fillColor = nil
        spinner.strokeColor = Theme.run.cgColor
        spinner.lineWidth = 1.6
        spinner.lineCap = .round
        spinner.strokeEnd = 0.7
        layer?.addSublayer(spinner)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let r = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side).insetBy(dx: 0.8, dy: 0.8)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spinner.frame = bounds
        spinner.path = CGPath(ellipseIn: r, transform: nil)
        CATransaction.commit()
    }

    private func restyle() {
        isHidden = status == .history || status == .running
        spinner.isHidden = status != .working
        spinner.removeAllAnimations()
        layer?.removeAnimation(forKey: "pulse")
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if status == .working, motion {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi   // clockwise in a y-up layer
            a.duration = 0.9; a.repeatCount = .infinity
            spinner.add(a, forKey: "spin")
        }
        if status == .waiting, motion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.4
            a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            layer?.add(a, forKey: "pulse")
        }
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 7
        let r = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        switch status {
        case .waiting: Theme.wait.setFill(); NSBezierPath(ovalIn: r).fill()
        case .done: Theme.accent.setFill(); NSBezierPath(ovalIn: r).fill()
        case .failed: Theme.danger.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5).fill()   // a square, not only a colour
        default: break
        }
    }
}

/// Letter chip identifying a project; hue derived from the name so it is stable.
@MainActor
final class ChipView: NSView {
    var name = "" { didSet { needsDisplay = true } }
    var iconPath: String? { didSet { if iconPath != oldValue { needsDisplay = true } } }
    var side: CGFloat = 18
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private static var imageCache: [String: NSImage] = [:]
    private static func image(at path: String) -> NSImage? {
        if let i = imageCache[path] { return i }
        guard let i = NSImage(contentsOfFile: path), i.isValid else { return nil }
        imageCache[path] = i
        return i
    }

    override func draw(_ dirtyRect: NSRect) {
        // A project's own favicon / app icon wins over the letter.
        if let path = iconPath, let img = Self.image(at: path) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: side * 0.24, yRadius: side * 0.24).addClip()
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let hue = CGFloat(abs(name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }) % 360) / 360
        NSColor(hue: hue, saturation: 0.25, brightness: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.28, yRadius: side * 0.28).fill()
        let letter = String(name.prefix(1)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: side * 0.55, weight: .semibold),
            .foregroundColor: NSColor(hue: hue, saturation: 0.22, brightness: 0.82, alpha: 1)]
        let sz = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: (side - sz.width) / 2, y: (side - sz.height) / 2), withAttributes: attrs)
    }
}

/// NSMenuItem that runs a closure; keeps menus free of selector plumbing.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

extension NSWindow {
    /// What double-clicking a title bar does, following System Settings › Desktop & Dock.
    func titlebarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": miniaturize(nil)
        case "None": break
        default: zoom(nil)   // "Maximize" / "Fill" / unset
        }
    }

    /// Drag-to-move and double-click for views drawn over the (transparent) title bar.
    func handleTitlebarMouseDown(_ event: NSEvent) {
        if event.clickCount == 2 { titlebarDoubleClick() } else { performDrag(with: event) }
    }
}

/// A thin overlay scroller that never takes layout width and only shows while `revealed`
/// (the owning HoverScrollView reveals it while the mouse is over it), whatever the system
/// "Show scroll bars" setting is.
final class ThinScroller: NSScroller {
    var revealed = false { didSet { if revealed != oldValue { needsDisplay = true } } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }
    // AppKit fades overlay scrollers out after scrolling; visibility is ours to decide instead.
    override var alphaValue: CGFloat { get { 1 } set {} }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }   // no track, no background
    override func drawKnob() {
        guard revealed, knobProportion < 1 else { return }
        let k = rect(for: .knob)
        let r = NSRect(x: bounds.maxX - 3 - 4, y: k.minY + 2, width: 4, height: max(0, k.height - 4))
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }
}

final class HoverScrollView: NSScrollView {
    private let thin = ThinScroller()
    private var tracking: NSTrackingArea?
    private var styleObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        verticalScroller = thin
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        // Switching the system setting to "Always" would otherwise turn it back into a legacy scroller.
        styleObserver = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollerStyle = .overlay }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { thin.revealed = true }
    override func mouseExited(with event: NSEvent) { thin.revealed = false }
}

/// Compact "when" for session rows: 刚刚 / 5分钟 / 3小时 / 昨天 / 4天 / 9月12日 / 2025年9月12日.
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60))分钟" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600))小时" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "昨天" }
        if days < 7 { return "\(days)天" }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let sameYear = c.year == calendar.component(.year, from: now)
        return sameYear ? "\(c.month!)月\(c.day!)日" : "\(c.year!)年\(c.month!)月\(c.day!)日"
    }

    /// Full timestamp for tooltips.
    static func full(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: date)
    }
}

extension NSTextField {
    static func label(_ text: String = "", font: NSFont = Theme.uiFont, color: NSColor = Theme.text) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        return f
    }
}

extension NSView {
    /// Lays out children on one horizontal line, vertically centered. `flex` items share leftover width.
    func layoutRow(_ items: [(NSView, CGFloat?)], leading: CGFloat, trailing: CGFloat, gap: CGFloat) {
        let fixed = items.compactMap(\.1).reduce(0, +)
        let flexCount = items.filter { $0.1 == nil }.count
        let avail = max(0, bounds.width - leading - trailing - gap * CGFloat(items.count - 1) - fixed)
        var x = leading
        for (v, w) in items {
            let width = w ?? (flexCount > 0 ? avail / CGFloat(flexCount) : 0)
            let h = v.intrinsicContentSize.height > 0 && v.intrinsicContentSize.height < bounds.height ? v.intrinsicContentSize.height : bounds.height
            v.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: width, height: h)
            x += width + gap
        }
    }
}
