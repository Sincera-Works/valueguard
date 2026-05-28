import Foundation
import UserNotifications

/// Fire a macOS user notification when a category activates.
@MainActor
final class NotifyAction {
    private var authRequested = false
    private var authGranted = false

    /// Idempotent. Triggers the system permission prompt on first invocation.
    func ensureAuthorization() async {
        guard !authRequested else { return }
        authRequested = true
        do {
            authGranted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            authGranted = false
        }
    }

    func notify(category: String, app: String?, score: Float) async {
        await ensureAuthorization()
        guard authGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = "ValueGuard — \(category)"
        if let app {
            content.body = "Detected in \(app) (score \(String(format: "%.2f", score)))"
        } else {
            content.body = "Detected (score \(String(format: "%.2f", score)))"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
