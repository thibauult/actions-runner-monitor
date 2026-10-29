import AppKit
import Foundation
import UserNotifications

/// System notifications for job starts. Clicking one opens the job on GitHub.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private static let urlKey = "url"

    /// Asks for permission the first time; the system remembers the answer.
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func jobStarted(_ job: JobRun, on runner: Runner) {
        let content = UNMutableNotificationContent()
        content.title = "Job started"
        content.subtitle = runner.name
        content.body = job.name
        content.sound = .default
        if let url = job.url ?? runner.settingsURL {
            content.userInfo[urlKey] = url.absoluteString
        }
        let request = UNNotificationRequest(identifier: "\(runner.id)-\(job.startedAt.timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let string = response.notification.request.content.userInfo[Self.urlKey] as? String, let url = URL(string: string) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
