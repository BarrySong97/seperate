import AppKit
import UserNotifications

/// System notifications and the Dock badge. One notification per session: a newer one replaces
/// the older, and it is withdrawn once the session is looked at.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?          // the user clicked the notification of this session
    private var authorized: Bool?

    /// UNUserNotificationCenter only works inside an app bundle (not in tests or `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func start() { center?.delegate = self }

    func post(session id: String, title: String, subtitle: String, body: String, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = id
        content.userInfo = ["session": id]
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let send = { center.add(request) }
        if authorized == true { send(); return }
        // First use: macOS asks the user once.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
                if granted { send() }
            }
        }
    }

    func remove(session id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func setBadge(_ n: Int) { NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }

    // Shown even while the app is in front: we only post for sessions the user cannot see.
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.content.userInfo["session"] as? String
        Task { @MainActor [weak self] in
            if let id { self?.onOpen?(id) }
            done()
        }
    }
}
