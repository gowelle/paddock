import AppKit
import PaddockCore
import UserNotifications

/// Shows a notification when Paddock has stopped restarting something, with buttons to restart it or read its
/// log, and takes the notification down when it recovers (or its log is opened).
@MainActor
final class CrashNotifier: NSObject, CrashAlertSink, UNUserNotificationCenterDelegate {
    static let category = "paddock.crash"
    static let restartAction = "paddock.crash.restart"
    static let openLogAction = "paddock.crash.open-log"

    /// Restart on a notice: the app restarts the task or service.
    var restart: (@MainActor (CrashAlert) -> Void)?
    /// Open Log on a notice: the app shows its log in the Logs window.
    var openLog: (@MainActor (CrashAlert) -> Void)?

    /// Until one is shown, so an action names the crash it belongs to.
    private var alerts: [String: CrashAlert] = [:]
    /// Only when running as the bundle: a plain executable (`swift run`) has no notification centre.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    private lazy var center = UNUserNotificationCenter.current()

    /// Asks for permission once and teaches the centre Paddock's buttons. Safe to call every launch.
    func start() {
        guard isAvailable else { return }
        center.delegate = self
        let restart = UNNotificationAction(identifier: Self.restartAction, title: "Restart")
        let openLog = UNNotificationAction(identifier: Self.openLogAction, title: "Open Log", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [restart, openLog], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func announce(_ alert: CrashAlert) {
        guard isAvailable else { return }
        alerts[alert.id] = alert
        let content = UNMutableNotificationContent()
        content.title = "\(alert.title) crashed"
        content.body = alert.reason
        content.categoryIdentifier = Self.category
        content.userInfo = ["id": alert.id]
        center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    func withdraw(_ id: String) {
        alerts[id] = nil
        guard isAvailable else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// A banner even while Paddock is the front app: a crash matters whether or not its window is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            guard let alert = alerts[id] else { return }
            switch action {
            case Self.restartAction:
                restart?(alert)
            case Self.openLogAction:
                openLog?(alert)
            default:
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
