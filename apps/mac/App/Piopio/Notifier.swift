import AppKit
import PiopioKit
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

    func answer(ref: ContainerRef, title: String, body: String, failed: Bool, sound: Bool = false) {
        let threadId = ref.id
        guard Self.enabled else { return }
        Task {
            if authorized == nil {
                authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = failed ? "\(title): failed" : title
            content.body = body
            content.sound = failed || sound ? .default : nil
            content.threadIdentifier = threadId
            content.userInfo = ["threadId": threadId, "kind": ref.kind.rawValue]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let threadId = info["threadId"] as? String
        let build = info["kind"] as? String == "build"
        await MainActor.run {
            WindowOpener.shared.showMain()
            if let threadId { NotificationCenter.default.post(name: build ? .selectBuildSession : .selectThread, object: threadId) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner] // only posted when you're not looking at that thread
    }
}
