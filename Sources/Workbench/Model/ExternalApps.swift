import AppKit

/// Editors and terminals a worktree can be opened in. Only installed ones are offered, each with the
/// icon macOS has for it; the user's default editor is remembered in the app's settings.
enum ExternalApp: String, CaseIterable {
    case zed, cursor, vscode, windsurf, xcode, ghostty, iterm, terminal

    var name: String {
        switch self {
        case .zed: "Zed"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .xcode: "Xcode"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm"
        case .terminal: "终端"
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .windsurf: ["com.exafunction.windsurf"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .iterm: ["com.googlecode.iterm2"]
        case .terminal: ["com.apple.Terminal"]
        }
    }

    var isTerminal: Bool { [.ghostty, .iterm, .terminal].contains(self) }

    var url: URL? { bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first }

    @MainActor private static var iconCache: [ExternalApp: NSImage] = [:]

    /// The app's own icon, as macOS shows it.
    @MainActor func icon(size: CGFloat = 16) -> NSImage? {
        guard let url else { return nil }
        let base = Self.iconCache[self] ?? NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[self] = base
        let img = base.copy() as! NSImage
        img.size = NSSize(width: size, height: size)
        return img
    }

    static var installed: [ExternalApp] { allCases.filter { $0.url != nil } }
    static var editors: [ExternalApp] { installed.filter { !$0.isTerminal } }

    func open(_ path: String) {
        guard let app = url else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor static var finderIcon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app").copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}
