import AppKit

/// "Bone" palette: cmux's warm olive-gray ground, selection by lightness instead of a hue accent.
enum Theme {
    static let ground   = NSColor(hex: 0x22231E)   // sidebar, gaps between panes
    static let pane     = NSColor(hex: 0x272822)   // pane + terminal background
    static let panel    = NSColor(hex: 0x2B2C26)
    static let line     = NSColor(hex: 0x34352F)
    static let line2    = NSColor(hex: 0x42433C)
    static let text     = NSColor(hex: 0xE8E8E2)
    static let muted    = NSColor(hex: 0x9C9D95)
    static let faint    = NSColor(hex: 0x6D6E67)
    static let selBG    = NSColor(hex: 0x3D3E36)
    static let selFG    = NSColor(hex: 0xF5F4EC)
    static let hover    = NSColor(white: 1, alpha: 0.05)
    static let accent   = NSColor(hex: 0xD6D3C3)   // bone: active tab rule, focus
    static let focus    = NSColor(hex: 0x76776D)   // focused pane border
    static let run      = NSColor(hex: 0x9CCF6C)
    static let wait     = NSColor(hex: 0xE6B450)
    static let claude   = NSColor(hex: 0xE8916C)
    static let shell    = NSColor(hex: 0x78C6DE)

    static let uiFont = NSFont.systemFont(ofSize: 12.5)
    static let danger = NSColor(hex: 0xF08A80)
    static let smallFont = NSFont.systemFont(ofSize: 11.5)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    /// Terminal colors layered over the user's own Ghostty config.
    static let ghosttyConfig = """
    background = #272822
    foreground = #e8e8e2
    cursor-color = #d6d3c3
    selection-background = #3d3e36
    selection-foreground = #f5f4ec
    window-padding-x = 10
    window-padding-y = 8
    window-padding-balance = true
    confirm-close-surface = false
    """
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
