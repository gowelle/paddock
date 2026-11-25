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

/// Diagnoses the path from a request to a site. Pure: every outside fact comes from a probe.
public struct Doctor: Sendable {
    public typealias Probe = @Sendable (URL) async throws -> DoctorProbe
    public typealias LogFindingProbe = @Sendable (Site) -> DoctorLogFinding

    let build: Int
    let resolveHost: @Sendable (String) -> [String]
    let readableFolder: @Sendable (String) -> Bool
    let probeURL: Probe
    let newestLogError: LogFindingProbe
    let siteURL: @Sendable (Site) -> URL

    public init(build: Int,
                resolve: @escaping @Sendable (String) -> [String],
                readable: @escaping @Sendable (String) -> Bool,
                probe: @escaping Probe,
                logFinding: @escaping LogFindingProbe,
                url: @escaping @Sendable (Site) -> URL) {
        self.build = build
        self.resolveHost = resolve
        self.readableFolder = readable
        self.probeURL = probe
        self.newestLogError = logFinding
        self.siteURL = url
    }

    /// Every check, in order. `named` limits the site rows (the caller has already resolved it).
    ///
    /// A non-nil `named` must be a site the caller resolved from `status`; an unknown name produces
    /// an empty site list. The CLI and MCP resolve names and own the failure sentence, so no row is
    /// added here for a name that isn't in `status`.
    public func report(for status: EngineStatus, site named: String? = nil) async -> DoctorReport {
        if let stopped = stoppedReport(status) { return stopped }

        let sites = status.sites.filter { named == nil || $0.name == named }
        var global: [DoctorCheck] = []
        var globalFailures: [String: String] = [:]

        func add(_ check: DoctorCheck) {
            global.append(check)
            if check.outcome == .failed { globalFailures[check.id] = check.title }
        }

        // `causes` is checked first-match-wins: list the most specific cause first.
        func skipped(_ id: String, _ title: String, because causes: [String]) -> DoctorCheck? {
            guard let cause = causes.first(where: { globalFailures[$0] != nil }) else { return nil }
            return .skipped(id, title, "Skipped: \(globalFailures[cause]!) failed.")
        }

        add(.passed("daemon", "The daemon answers (build \(status.version))",
                    "The daemon answers (build \(status.version))."))

        if status.blockedBy.isEmpty {
            add(.passed("ports", "Ports 80 and 443 are free",
                        "Nothing was listening on 80 or 443 before Paddock."))
        } else {
            add(.failed("ports", "Ports 80 and 443 are free", Messages.cantStart(status.blockedBy),
                        fix: status.blockedBy.compactMap(\.stopCommand).first ?? "paddock start"))
        }

        if status.portHelperInstalled {
            add(.passed("port-helper", "The port helper manages 80 and 443",
                        "The port helper manages 80 and 443."))
        } else {
            add(.failed("port-helper", "The port helper manages 80 and 443",
                        "The port helper isn't installed.", fix: "paddock start"))
        }

        if status.resolverInstalled {
            add(.passed("resolver", "The .test resolver entry is installed",
                        "The .test resolver entry is installed."))
        } else {
            add(.failed("resolver", "The .test resolver entry is installed",
                        "The .test resolver entry isn't installed.", fix: "paddock start"))
        }

        let dnsSite = named == nil ? status.sites.first : sites.first
        if let dnsSite {
            let title = "DNS answers \(dnsSite.host)"
            let addresses = resolveHost(dnsSite.host)
            if addresses.contains("127.0.0.1") {
                add(.passed("dns", title, "\(dnsSite.host) resolves to 127.0.0.1."))
            } else {
                let found = addresses.isEmpty
                    ? "\(dnsSite.host) does not resolve."
                    : "\(dnsSite.host) resolves to \(addresses.joined(separator: ", "))."
                add(.failed("dns", title, found, fix: "paddock restart"))
            }
        } else {
            add(.skipped("dns", "DNS answers a site's host", "No sites to resolve."))
        }

        let caddyTitle = "Caddy is running"
        if let skip = skipped("caddy", caddyTitle, because: ["ports"]) {
            add(skip)
        } else if status.processes["caddy"]?.hasPrefix("running") == true {
            add(.passed("caddy", caddyTitle, "Caddy is running."))
        } else {
            add(.failed("caddy", caddyTitle, "Caddy isn't running.", fix: "paddock start"))
        }

        var siteReports: [DoctorReport.SiteReport] = []
        for site in sites {
            siteReports.append(await siteReport(for: site, in: status, globalFailures: globalFailures))
        }
        return DoctorReport(global: global, sites: siteReports)
    }

    /// A daemon that can't be diagnosed further: unreachable, stopped, or another build. One row only.
    private func stoppedReport(_ status: EngineStatus) -> DoctorReport? {
        let title = "The daemon answers (build \(status.version))"
        if status.version != build {
            return DoctorReport(global: [.failed("daemon", title,
                "The daemon is build \(status.version); this is build \(build).", fix: "paddock restart")],
                sites: [])
        }
        if !status.running && status.blockedBy.isEmpty {
            return DoctorReport(global: [.failed("daemon", title, "Paddock is stopped.",
                                                fix: "paddock start")], sites: [])
        }
        return nil
    }

    private func siteReport(for site: Site, in status: EngineStatus,
                            globalFailures: [String: String]) async -> DoctorReport.SiteReport {
        var checks: [DoctorCheck] = []
        var failures: [String: String] = [:]

        func add(_ check: DoctorCheck) {
            checks.append(check)
            if check.outcome == .failed { failures[check.id] = check.title }
        }

        // `causes` is checked first-match-wins: list the most specific cause first.
        func skipped(_ id: String, _ title: String, because causes: [String]) -> DoctorCheck? {
            var all = globalFailures
            for (key, value) in failures { all[key] = value }
            guard let cause = causes.first(where: { all[$0] != nil }) else { return nil }
            return .skipped(id, title, "Skipped: \(all[cause]!) failed.")
        }

        let phpTitle = "PHP \(site.php) is installed"
        if status.installedPHP.contains(site.php) {
            add(.passed("php", phpTitle, "PHP \(site.php) is installed."))
        } else {
            add(.failed("php", phpTitle, "PHP \(site.php) isn't installed.",
                        fix: "paddock use \(site.php)"))
        }

        let fpmTitle = "PHP-FPM \(site.php) is running"
        if let skip = skipped("php-fpm", fpmTitle, because: ["ports", "php"]) {
            add(skip)
        } else if status.processes["php-fpm-\(site.php)"]?.hasPrefix("running") == true {
            add(.passed("php-fpm", fpmTitle, "PHP-FPM \(site.php) is running."))
        } else {
            add(.failed("php-fpm", fpmTitle, "PHP-FPM \(site.php) isn't running.",
                        fix: "paddock restart"))
        }

        let folderTitle = "The site folder is readable"
        if readableFolder(site.path) {
            add(.passed("folder", folderTitle, "\(site.path) can be read."))
        } else {
            add(.failed("folder", folderTitle, "\(site.path) can't be read.", fix: nil))
        }

        let trustTitle = "macOS trusts Paddock's certificate"
        if !site.secured {
            add(.skipped("trust", trustTitle, "\(site.name) isn't secured; nothing to trust."))
        } else if !status.trustEnabled {
            add(.failed("trust", trustTitle, "Paddock can't install certificate trust in this build.",
                        fix: nil))
        } else if status.needsTrust {
            add(.failed("trust", trustTitle, "macOS doesn't trust Paddock's certificate.",
                        fix: "paddock trust"))
        } else {
            add(.passed("trust", trustTitle, "macOS trusts Paddock's certificate."))
        }

        let httpTitle = "\(site.url) answers"
        if let skip = skipped("http", httpTitle,
                              because: ["ports", "port-helper", "dns", "caddy", "php", "php-fpm"]) {
            add(skip)
        } else {
            add(await httpCheck(site, title: httpTitle))
        }

        add(logCheck(for: site))
        return DoctorReport.SiteReport(site: site.name, host: site.host, php: site.php, url: site.url,
                                       checks: checks)
    }

    private func httpCheck(_ site: Site, title: String) async -> DoctorCheck {
        let scheme = site.secured ? "HTTPS" : "HTTP"
        do {
            let probe = try await probeURL(siteURL(site))
            let found = "\(scheme) \(probe.statusCode) in \(probe.milliseconds) ms."
            if (500..<600).contains(probe.statusCode) {
                return .failed("http", title,
                               found + " Some request reached the site and failed; see the log row.",
                               fix: nil)
            }
            return .passed("http", title, found)
        } catch let error as URLError {
            let detail: String
            let fix: String?
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired,
                 .secureConnectionFailed:
                detail = "TLS failed: \(error.localizedDescription)"
                fix = "paddock trust"
            case .cannotFindHost:
                detail = "\(site.host) did not resolve for the request."
                fix = "paddock restart"
            case .cannotConnectToHost:
                detail = "Nothing answered on port \(Self.port(of: siteURL(site)))."
                fix = "paddock start"
            case .timedOut:
                detail = "No answer within 5 seconds."
                fix = "paddock restart"
            default:
                detail = error.localizedDescription
                fix = nil
            }
            return .failed("http", title, detail, fix: fix)
        } catch {
            return .failed("http", title, error.localizedDescription, fix: nil)
        }
    }

    private func logCheck(for site: Site) -> DoctorCheck {
        let title = "Newest error in the site's log"
        switch newestLogError(site) {
        case .none:
            return .skipped("log", title, "No logs in storage/logs.")
        case .noErrors(let file):
            return .info("log", title, "No errors in \(file).")
        case .error(let file, let line):
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return .info("log", title, "Newest error in \(file): \(String(trimmed.prefix(160)))")
        case .unreadable(let file):
            return .skipped("log", title, "\(file) couldn't be read.")
        }
    }

    private static func port(of url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme == "https" ? 443 : 80
    }
}
