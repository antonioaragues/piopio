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

    /// The engine, to answer approvals from a notification's buttons.
    weak var engine: EngineController?

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        let approve = UNNotificationAction(identifier: "approve", title: "Approve")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "approval", actions: [approve, deny], intentIdentifiers: [])])
    }

    /// An agent asks before doing something (06-agents §9 AS1, docs/design 6c): Approve or Deny right here.
    func approval(agent: ContainerRef, agentName: String, approvalId: String, title: String) {
        Task {
            if authorized == nil {
                authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(agentName) asks"
            content.body = title
            content.sound = .default
            content.categoryIdentifier = "approval"
            content.userInfo = ["agentId": agent.id, "approvalId": approvalId]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: approvalId, content: content, trigger: nil))
        }
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
        if let agentId = info["agentId"] as? String, let approvalId = info["approvalId"] as? String {
            let action = response.actionIdentifier
            await MainActor.run {
                if action == "approve" || action == "deny" {
                    Task { try? await Notifier.shared.engine?.decide(ContainerRef(kind: .agent, id: agentId), approvalId: approvalId, approve: action == "approve") }
                } else {
                    WindowOpener.shared.showMain()
                    NotificationCenter.default.post(name: .openInbox, object: approvalId)
                }
            }
            return
        }
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
