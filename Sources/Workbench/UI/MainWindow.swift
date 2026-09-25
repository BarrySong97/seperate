import AppKit

/// Sidebar | (top bar over workspace). Plain frame layout; the sidebar slides out (⌘B) and, while
/// hidden, peeks back in as a floating panel when the mouse touches the left edge — Arc's behaviour.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: Store
    private let root: RootView
    private var token: UUID?

    init(store: Store) {
        self.store = store
        root = RootView(sidebar: SidebarView(store: store), topBar: TopBarView(store: store), workspace: WorkspaceView(store: store))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Theme.ground
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 720, height: 420)
        w.setFrameAutosaveName("WorkbenchMain")
        super.init(window: w)
        w.delegate = self
        w.contentView = root
        root.setSidebarHidden(store.sidebarHidden, animated: false)
        if w.frame.origin == .zero { w.center() }
        token = store.observe { [weak self] change in
            if case .sidebar = change, let self { self.root.setSidebarHidden(self.store.sidebarHidden, animated: true) }
        }
        store.paletteHandler = { [weak self] scope in self?.root.showPalette(store: store, scope: scope) }
        store.importHandler = { [weak self] in self?.root.showImport(store: store) }
    }

    required init?(coder: NSCoder) { fatalError() }

    var workspace: WorkspaceView { root.workspace }
    var sidebar: SidebarView { root.sidebar }
}

@MainActor
final class RootView: NSView {
    let sidebar: SidebarView
    let topBar: TopBarView
    let workspace: WorkspaceView
    private let edge = EdgeSensor()          // 10 px strip that summons the peek
    private let peek = PeekPanel()           // floating container for the sidebar while hidden
    private let resizer = SidebarResizer()   // drag the sidebar's right edge
    private var sidebarIsHidden = false
    private var peeking = false
    private var peekTimer: Timer?

    init(sidebar: SidebarView, topBar: TopBarView, workspace: WorkspaceView) {
        self.sidebar = sidebar; self.topBar = topBar; self.workspace = workspace
        super.init(frame: .zero)
        [workspace, topBar, sidebar, resizer, edge, peek].forEach(addSubview)
        resizer.onDrag = { [weak self] x in self?.setSidebarWidth(x) }
        resizer.onEnd = { [weak self] in self.map { UserDefaults.standard.set(Double($0.sidebarWidth), forKey: Self.widthKey) } }
        edge.isHidden = true
        peek.isHidden = true
        edge.onEnter = { [weak self] in self?.showPeek() }
        peek.onExit = { [weak self] in self?.scheduleHidePeek() }
        peek.onEnter = { [weak self] in self?.peekTimer?.invalidate() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static let widthKey = "sidebarWidth"
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...480
    private var sidebarWidth: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: RootView.widthKey))
        return saved > 0 ? min(max(saved, RootView.sidebarWidthRange.lowerBound), RootView.sidebarWidthRange.upperBound) : SidebarView.width
    }()

    private func setSidebarWidth(_ w: CGFloat) {
        let r = Self.sidebarWidthRange
        sidebarWidth = min(max(w.rounded(), r.lowerBound), min(r.upperBound, bounds.width - 360))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        if !peeking { sidebar.frame = NSRect(x: sidebarIsHidden ? -sidebarWidth : 0, y: 0, width: sidebarWidth, height: h) }
        place(hidden: sidebarIsHidden)
        edge.frame = NSRect(x: 0, y: 0, width: 10, height: h)
        resizer.frame = NSRect(x: sidebarWidth - 3, y: TopBarView.height, width: 6, height: h - TopBarView.height)
        resizer.isHidden = sidebarIsHidden
        peek.frame = NSRect(x: 8, y: 44, width: sidebarWidth, height: h - 52)
        if peeking { sidebar.frame = peek.bounds }
    }

    /// Frames of the top bar and workspace for a given sidebar state.
    private func place(hidden: Bool) {
        let sw = hidden ? 0 : sidebarWidth
        let left = hidden ? 78.0 : sw   // keep clear of the traffic lights
        topBar.frame = NSRect(x: left, y: 0, width: bounds.width - left, height: TopBarView.height)
        let x = hidden ? 6 : sw
        workspace.frame = NSRect(x: x, y: TopBarView.height, width: bounds.width - x - 6, height: bounds.height - TopBarView.height - 6)
    }

    func setSidebarHidden(_ h: Bool, animated: Bool) {
        guard h != sidebarIsHidden else { return }
        sidebarIsHidden = h
        resizer.isHidden = h
        if peeking { endPeek(animated: false) }
        edge.isHidden = !h
        needsDisplay = true
        guard animated else { needsLayout = true; return }
        sidebar.isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = SidebarView.motion.duration
            ctx.timingFunction = SidebarView.motion.curve
            sidebar.animator().frame.origin.x = h ? -sidebarWidth : 0
            sidebar.animator().alphaValue = h ? 0 : 1
            // Animating the frames directly makes the terminals resize smoothly with the sidebar.
            let sw = h ? 0.0 : sidebarWidth, left = h ? 78.0 : sw, x = h ? 6.0 : sw
            topBar.animator().frame = NSRect(x: left, y: 0, width: bounds.width - left, height: TopBarView.height)
            workspace.animator().frame = NSRect(x: x, y: TopBarView.height, width: bounds.width - x - 6, height: bounds.height - TopBarView.height - 6)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.sidebar.isHidden = self.sidebarIsHidden && !self.peeking
            self.sidebar.alphaValue = 1
        })
    }

    // MARK: Command palette

    private weak var palette: CommandPalette?

    func showPalette(store: Store, scope: PaletteScope) {
        palette?.close()
        let p = CommandPalette(store: store, scope: scope)
        p.contentRect = NSRect(x: workspace.frame.minX, y: 0, width: workspace.frame.width, height: bounds.height)
        let terminalHadFocus = window?.firstResponder is TerminalView
        p.onClose = { [weak self] in
            // Give the keyboard back to the terminal the user was in.
            if terminalHadFocus, let self { DispatchQueue.main.async { self.workspace.focusActiveTerminal() } }
        }
        p.present(in: self)
        palette = p
    }

    func showImport(store: Store) {
        palette?.close()
        let p = ImportPanel(store: store)
        p.contentRect = NSRect(x: workspace.frame.minX, y: 0, width: workspace.frame.width, height: bounds.height)
        p.present(in: self)
    }

    // MARK: Peek

    private func showPeek() {
        guard sidebarIsHidden, !peeking else { return }
        peeking = true
        peekTimer?.invalidate()
        sidebar.removeFromSuperview()
        sidebar.topInset = 10
        sidebar.isHidden = false
        sidebar.alphaValue = 1
        peek.addSubview(sidebar)
        sidebar.frame = peek.bounds
        sidebar.autoresizingMask = [.width, .height]
        peek.isHidden = false
        peek.alphaValue = 0
        peek.frame.origin.x = 8 - 24
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = SidebarView.motion.duration
            ctx.timingFunction = SidebarView.motion.curve
            peek.animator().alphaValue = 1
            peek.animator().frame.origin.x = 8
        }
    }

    private func scheduleHidePeek() {
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPeek(animated: true) }
        }
    }

    private func endPeek(animated: Bool) {
        guard peeking else { return }
        let finish = { [self] in
            peeking = false
            peek.isHidden = true
            sidebar.removeFromSuperview()
            sidebar.autoresizingMask = []
            sidebar.topInset = 38
            addSubview(sidebar, positioned: .below, relativeTo: edge)
            sidebar.isHidden = sidebarIsHidden
            sidebar.alphaValue = 1
            needsLayout = true
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = SidebarView.motion.curve
            peek.animator().alphaValue = 0
            peek.animator().frame.origin.x = 8 - 16
        }, completionHandler: finish)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ground.setFill(); dirtyRect.fill()
        guard !sidebarIsHidden else { return }
        Theme.line.setFill()
        NSRect(x: sidebarWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Thin invisible handle on the sidebar's right edge; dragging it resizes the sidebar (and so the workspace).
@MainActor
final class SidebarResizer: NSView {
    var onDrag: ((CGFloat) -> Void)?      // new sidebar width, in the superview's coordinates
    var onEnd: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// Invisible strip along the window's left edge.
@MainActor
final class EdgeSensor: NSView {
    var onEnter: (() -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks
}

/// Rounded, shadowed container the sidebar moves into while peeking over the content.
@MainActor
final class PeekPanel: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.ground.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line2.cgColor
        layer?.masksToBounds = true
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 30
        shadow?.shadowOffset = NSSize(width: 0, height: -12)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.6)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
