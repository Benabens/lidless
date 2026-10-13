import Foundation
import UserNotifications

/// Tells the user, after the fact, that Lidless cut closed-lid mode short. With the lid closed
/// nobody is looking at the menu, so the reason has to be waiting for them when they open it.
@MainActor
enum UserNotifier {
    /// Notification Center needs a bundle; a bare executable (`swift run`) has none.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asked when the user arms closed-lid mode: the moment the notifications start to matter.
    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
