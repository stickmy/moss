import AppKit
import Foundation
import UserNotifications

@MainActor
final class AgentNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, error in
            if let error {
                print("[Notifications] Permission error: \(error)")
            }
        }
    }

    func postAgentWaiting(sessionId: UUID, sessionTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Agent Waiting"
        content.body = sessionTitle.isEmpty ? "A terminal needs your attention" : sessionTitle
        content.sound = .default
        content.userInfo = ["sessionId": sessionId.uuidString]

        let request = UNNotificationRequest(
            identifier: "agent-waiting-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionIdString = response.notification.request.content.userInfo["sessionId"] as? String ?? ""

        await MainActor.run {
            guard let sessionId = UUID(uuidString: sessionIdString) else { return }
            NotificationCenter.default.post(
                name: .terminalFocusRequested,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if await MainActor.run(body: { NSApplication.shared.isActive }) {
            return []
        }
        return [.banner, .sound]
    }
}
