import Foundation

/// A crash Paddock has stopped restarting: a site task or a service. The app announces it once (a rate-limited
/// notification with Restart and Open Log) and badges the menu bar while it lasts.
public struct CrashAlert: Identifiable, Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case task(site: String, task: String)
        case service(id: String)
    }

    public let item: Item
    /// What it is: `shop: queue`, `PostgreSQL 18`.
    public let title: String
    /// Why it stopped, in the daemon's words where it has some.
    public let reason: String
    /// Its log, when Paddock knows where it is.
    public let logPath: String?
    /// `task:<site>:<task>` or `service:<id>`: names it in notifications and the rate limit.
    public var id: String {
        switch item {
        case .task(let site, let task): return "task:\(site):\(task)"
        case .service(let id): return "service:\(id)"
        }
    }
}

/// What the app does with a crash the model noticed: show its notification, take it down again.
@MainActor
public protocol CrashAlertSink: AnyObject {
    func announce(_ alert: CrashAlert)
    func withdraw(_ id: String)
}

/// How often one crash is announced at most: a flapping task restarts and crashes again, and the user has seen
/// the same notice already. Each item has its own clock.
public struct CrashAlertPolicy: Equatable, Sendable {
    /// Seconds before the same item may be announced again.
    public static let cooldown: TimeInterval = 600

    private var announced: [String: Date] = [:]

    public init() {}

    public func shouldAnnounce(_ id: String, at now: Date) -> Bool {
        guard let last = announced[id] else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }

    public mutating func record(_ id: String, at now: Date) {
        announced[id] = now
    }
}

extension AppModel {
    /// Why a service stopped: the daemon's status doesn't say, but the supervisor's limit does.
    static var serviceGaveUpReason: String {
        "Paddock stopped restarting it after \(Supervisor.maxFailures) failures in a minute."
    }

    /// Takes the terminal crashes from a fresh status. The first status only seeds the map (a crash from before
    /// the app started is not news); afterwards, recovered items have their notices taken down and new ones are
    /// announced within the rate limit.
    func updateCrashAlerts(from status: EngineStatus) {
        var current: [String: CrashAlert] = [:]
        for site in status.sites {
            for task in site.tasks?.tasks ?? [] where task.gaveUp == true {
                var reason = Self.serviceGaveUpReason
                if case .crashed(let said) = task.state { reason = said }
                let alert = CrashAlert(item: .task(site: site.name, task: task.name),
                                       title: "\(site.name): \(task.name)", reason: reason, logPath: task.logPath)
                current[alert.id] = alert
            }
        }
        for service in status.services where service.gaveUp == true {
            let alert = CrashAlert(item: .service(id: service.id), title: service.name,
                                   reason: Self.serviceGaveUpReason,
                                   logPath: logPaths?.serviceLog(service.id).path)
            current[alert.id] = alert
        }

        let previous = crashAlerts
        crashAlerts = current
        guard crashAlertsSeeded else {
            crashAlertsSeeded = true
            return
        }
        for id in previous.keys where current[id] == nil { alertSink?.withdraw(id) }
        let timestamp = now()
        for (id, alert) in current where previous[id] == nil {
            guard crashAlertPolicy.shouldAnnounce(id, at: timestamp) else { continue }
            crashAlertPolicy.record(id, at: timestamp)
            alertSink?.announce(alert)
        }
    }

    /// The daemon went away: nothing is known to be crashed any more.
    func clearCrashAlerts() {
        guard crashAlertsSeeded else {
            crashAlerts = [:]
            return
        }
        for id in crashAlerts.keys { alertSink?.withdraw(id) }
        crashAlerts = [:]
    }

    /// `Restart` on a crash notice: starts it again; the next status says whether it recovered.
    public func restart(_ alert: CrashAlert) async {
        switch alert.item {
        case .task(let site, let task): await restartTask(site: site, task: task)
        case .service(let id): await startService(id)
        }
    }

    /// `Open Log` on a crash notice: shows its log and takes the notification down. The badge stays while the
    /// crash does.
    public func openCrashLog(_ alert: CrashAlert) {
        if let path = alert.logPath { show(log: URL(fileURLWithPath: path)) }
        alertSink?.withdraw(alert.id)
    }
}
