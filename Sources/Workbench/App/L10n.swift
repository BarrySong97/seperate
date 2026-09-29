// @purpose UI language: `tr("中文", "English")` picks one side; the 跟随系统 / 中文 / English setting.
// @role    Called by every view, menu, dialog and notification; the Language menu in AppDelegate sets it.
// @deps    Foundation (UserDefaults, Locale).
// @gotcha  Fixed at launch (views and menus are built once); a change takes a restart. The setting is the
//          app's own `AppleLanguages`, so Sparkle and AppKit's built-in strings follow it too. ADR-0006
import Foundation

/// The two sides of a UI string, chosen once per launch: Chinese when the preferred language is Chinese,
/// English otherwise. Every user-visible string goes through this (DrawFontTests-style guard: L10nTests).
@inline(__always) func tr(_ zh: String, _ en: String) -> String { L10n.isChinese ? zh : en }

/// English count with a regular plural: `plural(3, "tab")` → "3 tabs", `plural(1, "tab")` → "1 tab".
func plural(_ count: Int, _ noun: String, _ plural: String? = nil) -> String {
    "\(count) " + (count == 1 ? noun : plural ?? noun + "s")
}

enum AppLanguage: String, CaseIterable, Sendable {
    case system, zh, en

    /// Language names stay in their own language, so either reader can find theirs.
    var title: String {
        switch self {
        case .system: tr("跟随系统", "System Default")
        case .zh: "中文"   // l10n: a language named in itself
        case .en: "English"
        }
    }
}

enum L10n {
    /// Tests pin this; the app never changes it after launch.
    nonisolated(unsafe) static var isChinese: Bool = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")

    private static let key = "AppleLanguages"

    /// What the Language menu shows as chosen: only a value in the app's own domain counts, the global
    /// list (System Settings › Language) is "System Default".
    static var choice: AppLanguage {
        let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?[key] as? [String] }
        guard let first = own?.first else { return .system }
        return first.hasPrefix("zh") ? .zh : .en
    }

    /// Takes effect on the next launch.
    static func set(_ lang: AppLanguage) {
        switch lang {
        case .system: UserDefaults.standard.removeObject(forKey: key)
        case .zh: UserDefaults.standard.set(["zh-Hans"], forKey: key)
        case .en: UserDefaults.standard.set(["en"], forKey: key)
        }
    }

    /// The language a choice would give, to tell whether picking it changes anything.
    static func resolves(_ lang: AppLanguage) -> Bool {
        switch lang {
        case .zh: return true
        case .en: return false
        case .system:
            // The system list without the app's override: the global domain.
            let global = UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: key)?.first
            return (global ?? Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }
}
