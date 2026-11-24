import Foundation

/// One row of a doctor report: what was looked at, what was found, and the command that fixes it.
public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case passed, failed, skipped, info
    }

    public let id: String
    /// What was looked at, without a final period: `PHP 8.5 is installed`.
    public let title: String
    public let outcome: Outcome
    /// One sentence: what was found.
    public let detail: String
    /// A command for the owner to run; nil when nothing helps or the check passed.
    public let fix: String?

    public init(id: String, title: String, outcome: Outcome, detail: String, fix: String? = nil) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.detail = detail
        self.fix = fix
    }

    static func passed(_ id: String, _ title: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(id: id, title: title, outcome: .passed, detail: detail)
    }

    static func failed(_ id: String, _ title: String, _ detail: String, fix: String?) -> DoctorCheck {
        DoctorCheck(id: id, title: title, outcome: .failed, detail: detail, fix: fix)
    }

    static func skipped(_ id: String, _ title: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(id: id, title: title, outcome: .skipped, detail: detail)
    }

    static func info(_ id: String, _ title: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(id: id, title: title, outcome: .info, detail: detail)
    }
}

/// What one run of the doctor found, Paddock-wide and per site.
public struct DoctorReport: Codable, Equatable, Sendable {
    public struct SiteReport: Codable, Equatable, Sendable {
        public let site: String
        public let host: String
        public let php: PHPVersion
        public let url: String
        public let checks: [DoctorCheck]

        public init(site: String, host: String, php: PHPVersion, url: String, checks: [DoctorCheck]) {
            self.site = site
            self.host = host
            self.php = php
            self.url = url
            self.checks = checks
        }
    }

    public let global: [DoctorCheck]
    public let sites: [SiteReport]

    public init(global: [DoctorCheck], sites: [SiteReport]) {
        self.global = global
        self.sites = sites
    }

    public var failures: [DoctorCheck] {
        global.filter { $0.outcome == .failed }
            + sites.flatMap { $0.checks.filter { $0.outcome == .failed } }
    }

    public var isHealthy: Bool { failures.isEmpty }

    /// The report for a daemon whose status could not be fetched: one failed check, no site names.
    public static func unreachable(_ detail: String) -> DoctorReport {
        DoctorReport(global: [.failed("daemon", "The daemon answers", detail, fix: "paddock start")], sites: [])
    }
}

/// One HTTP answer, as the probe saw it.
public struct DoctorProbe: Equatable, Sendable {
    public let statusCode: Int
    public let milliseconds: Int

    public init(statusCode: Int, milliseconds: Int) {
        self.statusCode = statusCode
        self.milliseconds = milliseconds
    }
}

/// What a site's own log says, for the row that never fails.
public enum DoctorLogFinding: Equatable, Sendable {
    /// There is no `storage/logs/*.log`.
    case none
    case noErrors(file: String)
    case error(file: String, line: String)
    case unreadable(file: String)
}
