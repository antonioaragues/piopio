import AppKit
import UserNotifications

/// Notifies when an answer finishes or fails while you're elsewhere; clicking opens the thread.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized: Bool?

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "notifyAnswers") as? Bool ?? true
    }

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
    }

    func answer(threadId: String, title: String, body: String, failed: Bool) {
        guard Self.enabled else { return }
        Task {
            if authorized == nil {
                authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = failed ? "\(title): failed" : title
            content.body = body
            content.sound = failed ? .default : nil
            content.threadIdentifier = threadId
            content.userInfo = ["threadId": threadId]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        await MainActor.run {
            WindowOpener.shared.showMain()
            if let threadId { NotificationCenter.default.post(name: .selectThread, object: threadId) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner] // only posted when you're not looking at that thread
    }
}
