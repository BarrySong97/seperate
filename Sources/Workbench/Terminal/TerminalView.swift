import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// One libghostty surface: a real terminal (pty + GPU renderer) living in an NSView.
/// The view is created once per running session and re-parented when the layout changes.
@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    let sessionID: String
    private(set) var surface: ghostty_surface_t?

    var onTitle: ((String) -> Void)?
    var onPwd: ((String) -> Void)?
    var onAttention: (() -> Void)?          // bell from the program
    var onNotify: ((_ title: String, _ body: String) -> Void)?   // desktop notification (OSC 9 / 777) from the program
    var onCommandFinished: ((_ exitCode: Int) -> Void)?         // a shell command (e.g. the agent) ended; -1 = unknown
    var onUserInput: ((_ isReturn: Bool) -> Void)?              // the user typed into this terminal
    var contextMenu: (() -> NSMenu?)?                          // right-click menu (new session here, copy, paste…)
    var onFocus: (() -> Void)?
    var onClose: ((_ processAlive: Bool) -> Void)?   // shell exited, or close requested

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?

    static func from(_ ud: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Starts a login shell in `cwd`; `initialInput` (e.g. "codex resume <id>\n") is typed into it,
    /// so quitting the agent drops back to a shell in the same directory.
    init(sessionID: String, cwd: String, initialInput: String?, env extra: [String: String] = [:]) {
        self.sessionID = sessionID
        pending = (cwd, initialInput, extra.isEmpty ? ["WORKBENCH_SESSION": sessionID] : extra)
        super.init(frame: .zero)
    }

    /// The shell starts only once the view is on screen at its real size: a terminal started
    /// off-screen would report a placeholder width, and the agent's first screen (Claude's welcome
    /// box, the prompt) would be laid out that narrow and stay squeezed in the scrollback.
    private var pending: (cwd: String, input: String?, env: [String: String])?

    private func startIfReady() {
        guard surface == nil, let p = pending, let window, bounds.width >= 40, bounds.height >= 40,
              let app = GhosttyRuntime.shared.app else { return }
        pending = nil
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window.backingScaleFactor)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        let pairs = p.env.map { (strdup($0.key)!, strdup($0.value)!) }
        defer { pairs.forEach { free($0.0); free($0.1) } }
        var env = pairs.map { ghostty_env_var_s(key: $0.0, value: $0.1) }
        p.cwd.withCString { cwdPtr in
            cfg.working_directory = cwdPtr
            env.withUnsafeMutableBufferPointer { envBuf in
                cfg.env_vars = envBuf.baseAddress
                cfg.env_var_count = envBuf.count
                if let input = p.input {
                    input.withCString { ptr in
                        cfg.initial_input = ptr
                        surface = ghostty_surface_new(app, &cfg)
                    }
                } else {
                    surface = ghostty_surface_new(app, &cfg)
                }
            }
        }
        guard let surface else { NSLog("Seperate: ghostty_surface_new failed for %@", sessionID); return }
        // Tell it its real scale and size right away, before the shell reads the window size.
        viewDidChangeBackingProperties()
        ghostty_surface_set_occlusion(surface, true)
        if window.firstResponder === self { ghostty_surface_set_focus(surface, true) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Frees the surface. Must be called before the view is released.
    func destroy() {
        guard let s = surface else { return }
        surface = nil
        ghostty_surface_free(s)
    }

    func surfaceRequestedClose(processAlive: Bool) {
        // Defer: freeing from inside a Ghostty callback is not safe.
        DispatchQueue.main.async { [weak self] in self?.onClose?(processAlive) }
    }

    /// Asks Ghostty to close; it answers through `onClose` with whether a process is still running.
    func requestClose() {
        if let surface { ghostty_surface_request_close(surface) } else { onClose?(false) }
    }

    // MARK: Actions targeted at this surface

    func handle(action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let t = action.action.set_title.title { onTitle?(String(cString: t)) }
            return true
        case GHOSTTY_ACTION_PWD:
            if let p = action.action.pwd.pwd { onPwd?(String(cString: p)) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            onAttention?()
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            onNotify?(n.title.map { String(cString: $0) } ?? "", n.body.map { String(cString: $0) } ?? "")
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            onCommandFinished?(Int(action.action.command_finished.exit_code))
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            cursor = Self.cursor(for: action.action.mouse_shape)
            window?.invalidateCursorRects(for: self)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN { NSCursor.setHiddenUntilMouseMoves(true) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            if let p = u.url {
                let s = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)
                if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            }
            return true
        default:
            return false
        }
    }

    private var cursor: NSCursor = .iBeam
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: .operationNotAllowed
        default: .arrow
        }
    }

    // MARK: Geometry

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if surface == nil { startIfReady() } else { syncSize() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, let surface else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(frame)
        if frame.width > 0, frame.height > 0 {
            ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        }
        syncSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if surface == nil { startIfReady(); return }
        if window != nil { viewDidChangeBackingProperties() }
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
    }

    private func syncSize() {
        // Off-screen, convertToBacking has no display scale and would report half the pixels.
        guard let surface, window != nil, frame.width > 0, frame.height > 0 else { return }
        let px = convertToBacking(NSRect(origin: .zero, size: frame.size)).size
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true); onFocus?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        if !event.modifierFlags.contains(.command) {
            onUserInput?(event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter))
        }
        let translationMods = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        let translationFlags = Self.flags(translationMods)
        var translationEvent = event
        if translationFlags != event.modifierFlags.intersection(.deviceIndependentFlagsMask),
           let e = NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                                    modifierFlags: translationFlags, timestamp: event.timestamp,
                                    windowNumber: event.windowNumber, context: nil,
                                    characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
                                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                    isARepeat: event.isARepeat, keyCode: event.keyCode) {
            translationEvent = e
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let hadMarked = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: hadMarked)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list { sendKey(action, event: event, translationEvent: translationEvent, text: text, composing: false) }
        } else {
            sendKey(action, event: event, translationEvent: translationEvent,
                    text: Self.eventText(translationEvent), composing: markedText.length > 0 || hadMarked)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event, translationEvent: event, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard markedText.length == 0 else { return }
        let mask: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: mask = .shift
        case kVK_Control, kVK_RightControl: mask = .control
        case kVK_Option, kVK_RightOption: mask = .option
        case kVK_Command, kVK_RightCommand: mask = .command
        case kVK_CapsLock: mask = .capsLock
        default: return
        }
        let pressed = event.modifierFlags.contains(mask)
        sendKey(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event, translationEvent: event, text: nil, composing: false)
    }

    /// Lets terminal keybindings (and Ctrl combos) reach Ghostty before the menu bar sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        // App shortcuts that must win over terminal bindings (Ghostty maps ⌘K to clear screen).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           ["k", "p"].contains(event.charactersIgnoringModifiers?.lowercased()) { return false }
        let key = keyStruct(GHOSTTY_ACTION_PRESS, event: event, text: nil, composing: false)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = ghostty_surface_key_is_binding(surface, key, &flags)
        if isBinding || event.modifierFlags.contains(.control) {
            keyDown(with: event)
            return true
        }
        return false
    }

    override func doCommand(by selector: Selector) {}   // no system beep

    private func sendKey(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent, text: String?, composing: Bool) {
        guard let surface else { return }
        var k = keyStruct(action, event: event, text: nil, composing: composing)
        k.consumed_mods = Self.mods(translationEvent.modifierFlags.subtracting([.control, .command]))
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString { p in
                k.text = p
                _ = ghostty_surface_key(surface, k)
            }
        } else {
            _ = ghostty_surface_key(surface, k)
        }
    }

    private func keyStruct(_ action: ghostty_input_action_e, event: NSEvent, text: String?, composing: Bool) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.mods = Self.mods(event.modifierFlags)
        k.consumed_mods = GHOSTTY_MODS_NONE
        k.composing = composing
        k.text = nil
        if event.type == .keyDown || event.type == .keyUp,
           let u = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            k.unshifted_codepoint = u.value
        }
        return k
    }

    private static func eventText(_ event: NSEvent) -> String? {
        guard let chars = event.characters, let scalar = chars.unicodeScalars.first else { return nil }
        if chars.unicodeScalars.count == 1 {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }   // function keys
        }
        return chars
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ m: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if m.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if m.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if m.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        if m.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { f.insert(.capsLock) }
        return f
    }

    // MARK: NSTextInputClient (IME, dictation, voice input)
    // Mirrors Ghostty's own SurfaceView. Input methods that push text on their own (Doubao voice,
    // Dictation) first ask where the insertion point is; answering NSNotFound makes them drop the text.

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !s.isEmpty else { return }
        if keyTextAccumulator != nil { keyTextAccumulator?.append(s) }
        else { sendCommittedText(s) }
    }

    /// Committed text outside a key press goes in as typed input (a key event carrying text),
    /// not as a paste, so TUIs like Claude Code / Codex treat it like typing.
    private func sendCommittedText(_ text: String) {
        guard let surface else { return }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var k = ghostty_input_key_s()
            k.action = action
            k.mods = GHOSTTY_MODS_NONE
            k.consumed_mods = GHOSTTY_MODS_NONE
            if action == GHOSTTY_ACTION_PRESS {
                text.withCString { p in k.text = p; _ = ghostty_surface_key(surface, k) }
            } else {
                _ = ghostty_surface_key(surface, k)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) }
        else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }
        if keyTextAccumulator == nil { syncPreedit(clearIfNeeded: true) }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit(clearIfNeeded: true)
    }

    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Terminal selection as text + its offset; nil when nothing is selected.
    private func readSelection() -> (text: String, range: NSRange)? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        return (String(cString: t.text), NSRange(location: Int(t.offset_start), length: Int(t.offset_len)))
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    /// Always a real insertion point (never NSNotFound): the selection if any, else an empty range at 0.
    func selectedRange() -> NSRange { readSelection()?.range ?? NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let sel = readSelection() else { return nil }
        return NSAttributedString(string: sel.text)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {   // a caret, not a box: the Dictation / voice indicator anchors to it (Ghostty #8493)
            x += w * Double(range.location)
            w = 0
        }
        let r = NSRect(x: x, y: frame.height - y, width: w, height: max(h, 1))
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: Accessibility
    // Voice tools check that the focused element is editable text before inserting.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityHelp() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { "" }
    override func accessibilitySelectedText() -> String? { readSelection()?.text ?? "" }
    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    override func accessibilityNumberOfCharacters() -> Int { 0 }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    /// Tools that insert through Accessibility replace the "selected text" at the caret.
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        sendCommittedText(text)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    /// Right-click opens Seperate's menu; ⇧ + right-click still goes to the program running in the terminal.
    override func rightMouseDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift), let menu = contextMenu?() {
            window?.makeFirstResponder(self)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if !mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) || contextMenu == nil { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    }

    var hasSelection: Bool { surface.map(ghostty_surface_has_selection) ?? false }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE) }

    @discardableResult
    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) -> Bool {
        guard let surface else { return false }
        mousePos(event)
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { mousePos(event) }
    override func mouseDragged(with event: NSEvent) { mousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { mousePos(event) }
    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { dx *= 2; dy *= 2; mods |= 1 }
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= Int32(momentum.rawValue) << 1
        ghostty_surface_mouse_scroll(surface, dx, dy, ghostty_input_scroll_mods_t(mods))
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { binding("select_all") }

    private func binding(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
}
