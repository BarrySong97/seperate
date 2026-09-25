import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed is the appcast.xml attached to the latest GitHub Release.
/// Background checks never pop a window over a terminal: a found update shows as a pill in the top bar
/// (Sparkle's "gentle reminders"), and clicking it opens Sparkle's standard update dialog.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    static let changed = Notification.Name("dev.seperate.updater.changed")

    /// Version of an update found by a background check that the user has not looked at yet.
    private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController!
    private var started = false

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    private var updater: SPUUpdater { controller.updater }

    /// Only a bundled Seperate.app carries a feed URL; `swift run` has nothing to update.
    private var isBundled: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// Release builds start checking right away. Debug builds start only when "检查更新…" is used.
    /// Sparkle's own schedule only fires once the interval since the last check has passed, so a
    /// release build also checks quietly on every launch (a found update shows as the top-bar pill).
    func start() {
        #if !DEBUG
        startIfNeeded()
        if started, updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        #endif
    }

    private func startIfNeeded() {
        guard isBundled, !started else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isBundled else { return }
        startIfNeeded()
        setPending(nil)
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool { isBundled && (!started || updater.canCheckForUpdates) }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    private func setPending(_ version: String?) {
        guard pendingVersion != version else { return }
        pendingVersion = version
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks never take focus; we show the top-bar pill instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { setPending(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setPending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setPending(nil) }
    }
}
