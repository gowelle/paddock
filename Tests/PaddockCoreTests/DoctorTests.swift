import XCTest
@testable import PaddockCore

final class DoctorTests: XCTestCase {
    private let php = PHPVersion(major: 8, minor: 5)

    private func site(_ name: String = "shop", secured: Bool = true, php: PHPVersion? = nil) -> Site {
        Site(name: name, path: "/tmp/paddock-doctor-\(name)", kind: .parked, secured: secured,
             php: php ?? self.php, pinned: false)
    }

    private func status(running: Bool = true, blocked: [PortHolder] = [], sites: [Site]? = nil,
                        installed: [PHPVersion]? = nil,
                        processes: [String: String] = ["caddy": "running (pid 1)",
                                                       "php-fpm-8.5": "running (pid 2)"],
                        resolver: Bool = true, trust: Bool = true, dns: Bool = true, helper: Bool = true,
                        needsTrust: Bool = false, version: Int = PaddockBuild.number) -> EngineStatus {
        EngineStatus(running: running, blockedBy: blocked, sites: sites ?? [site()],
                     installedPHP: installed ?? [php], defaultPHP: php, processes: processes,
                     resolverInstalled: resolver, trustEnabled: trust, dnsRunning: dns,
                     portHelperInstalled: helper, needsTrust: needsTrust, version: version)
    }

    private func doctor(resolve: [String] = ["127.0.0.1"], readable: Bool = true,
                        probe: @escaping Doctor.Probe = { _ in DoctorProbe(statusCode: 200, milliseconds: 12) },
                        log: @escaping Doctor.LogFindingProbe = { _ in .none }) -> Doctor {
        Doctor(build: PaddockBuild.number, resolve: { _ in resolve }, readable: { _ in readable },
               probe: probe, logFinding: log, url: { URL(string: $0.url)! })
    }

    private func check(_ checks: [DoctorCheck], _ id: String) -> DoctorCheck? {
        checks.first { $0.id == id }
    }

    func testAHealthySitePassesEveryCheck() async {
        let report = await doctor().report(for: status())
        XCTAssertEqual(report.global.map(\.outcome), Array(repeating: .passed, count: 6),
                       report.global.map { "\($0.id): \($0.detail)" }.joined(separator: "\n"))
        let checks = report.sites.first?.checks ?? []
        XCTAssertEqual(report.sites.first?.site, "shop")
        XCTAssertEqual(checks.filter { $0.outcome == .failed }.count, 0)
        XCTAssertEqual(check(checks, "http")?.detail, "HTTPS 200 in 12 ms.")
        XCTAssertEqual(check(checks, "trust")?.outcome, .passed)
        XCTAssertTrue(report.isHealthy)
    }

    func testAStoppedDaemonIsOneFailedCheck() async {
        let report = await doctor().report(for: status(running: false))
        XCTAssertEqual(report.global.map(\.id), ["daemon"])
        XCTAssertEqual(report.global.first?.outcome, .failed)
        XCTAssertEqual(report.global.first?.detail, "Paddock is stopped.")
        XCTAssertEqual(report.global.first?.fix, "paddock start")
        XCTAssertTrue(report.sites.isEmpty)
        XCTAssertFalse(report.isHealthy)
    }

    func testAnotherBuildIsOneFailedCheck() async {
        let report = await doctor().report(for: status(version: PaddockBuild.number - 1))
        XCTAssertEqual(report.global.map(\.id), ["daemon"])
        XCTAssertEqual(report.global.first?.detail,
                       "The daemon is build \(PaddockBuild.number - 1); this is build \(PaddockBuild.number).")
        XCTAssertEqual(report.global.first?.fix, "paddock restart")
    }

    func testBlockedPortsAreOneCauseAndSkipCaddyFPMAndHTTP() async {
        let holder = PortHolder(port: 80, pid: 42, command: "nginx", ownedByCurrentUser: true,
                                stopCommand: "brew services stop nginx")
        let report = await doctor().report(for: status(running: false, blocked: [holder]))
        let ports = check(report.global, "ports")
        XCTAssertEqual(ports?.outcome, .failed)
        XCTAssertEqual(ports?.fix, "brew services stop nginx")
        XCTAssertEqual(check(report.global, "caddy")?.outcome, .skipped)
        let checks = report.sites.first?.checks ?? []
        XCTAssertEqual(check(checks, "php-fpm")?.outcome, .skipped)
        XCTAssertEqual(check(checks, "http")?.outcome, .skipped)
        XCTAssertEqual(check(checks, "http")?.detail, "Skipped: Ports 80 and 443 are free failed.")
        XCTAssertEqual(report.failures.count, 1)
    }

    func testMissingPHPIsTheCauseForFPMAndHTTP() async {
        let report = await doctor().report(for: status(installed: []))
        let checks = report.sites.first?.checks ?? []
        XCTAssertEqual(check(checks, "php")?.outcome, .failed)
        XCTAssertEqual(check(checks, "php")?.fix, "paddock use 8.5")
        XCTAssertEqual(check(checks, "php-fpm")?.detail, "Skipped: PHP 8.5 is installed failed.")
        XCTAssertEqual(check(checks, "http")?.outcome, .skipped)
        XCTAssertEqual(report.failures.count, 1)
    }

    func testStoppedFPMFailsAndHTTPIsSkipped() async {
        let report = await doctor().report(for: status(processes: ["caddy": "running (pid 1)"]))
        let checks = report.sites.first?.checks ?? []
        XCTAssertEqual(check(checks, "php-fpm")?.detail, "PHP-FPM 8.5 isn't running.")
        XCTAssertEqual(check(checks, "php-fpm")?.fix, "paddock restart")
        XCTAssertEqual(check(checks, "http")?.outcome, .skipped)
        XCTAssertEqual(report.failures.count, 1)
    }

    func testAnUnreadableFolderStillGetsAnHTTPAnswer() async {
        let report = await doctor(readable: false).report(for: status())
        let checks = report.sites.first?.checks ?? []
        XCTAssertEqual(check(checks, "folder")?.detail, "/tmp/paddock-doctor-shop can't be read.")
        XCTAssertNil(check(checks, "folder")?.fix)
        XCTAssertEqual(check(checks, "http")?.outcome, .passed)
    }

    func testDNSFailureNamesTheAddressesFound() async {
        let failing = await doctor(resolve: []).report(for: status())
        XCTAssertEqual(check(failing.global, "dns")?.detail, "shop.test does not resolve.")
        XCTAssertEqual(check(failing.global, "dns")?.fix, "paddock restart")

        let elsewhere = await doctor(resolve: ["10.0.0.2", "fe80::1"]).report(for: status())
        XCTAssertEqual(check(elsewhere.global, "dns")?.detail, "shop.test resolves to 10.0.0.2, fe80::1.")
    }

    func testNoSitesSkipsDNS() async {
        let report = await doctor().report(for: status(sites: []))
        XCTAssertEqual(check(report.global, "dns")?.outcome, .skipped)
        XCTAssertEqual(check(report.global, "dns")?.detail, "No sites to resolve.")
        XCTAssertTrue(report.sites.isEmpty)
    }

    func testAnUnsecuredSiteSkipsTrustWithoutAFix() async {
        let report = await doctor().report(for: status(sites: [site(secured: false)]))
        let trust = check(report.sites.first?.checks ?? [], "trust")
        XCTAssertEqual(trust?.outcome, .skipped)
        XCTAssertEqual(trust?.detail, "shop isn't secured; nothing to trust.")
        XCTAssertNil(trust?.fix)
        XCTAssertTrue(report.isHealthy)
    }

    func testNeedsTrustFailsWithTheTrustFix() async {
        let report = await doctor().report(for: status(needsTrust: true))
        let trust = check(report.sites.first?.checks ?? [], "trust")
        XCTAssertEqual(trust?.outcome, .failed)
        XCTAssertEqual(trust?.detail, "macOS doesn't trust Paddock's certificate.")
        XCTAssertEqual(trust?.fix, "paddock trust")
    }

    func testAFiveHundredIsAFailureWithoutAFix() async {
        let failing = doctor(probe: { _ in DoctorProbe(statusCode: 500, milliseconds: 30) })
        let report = await failing.report(for: status())
        let http = check(report.sites.first?.checks ?? [], "http")
        XCTAssertEqual(http?.outcome, .failed)
        XCTAssertEqual(http?.detail,
                       "HTTPS 500 in 30 ms. Some request reached the site and failed; see the log row.")
        XCTAssertNil(http?.fix)
    }

    func testTransportErrorsMapToSentencesAndFixes() async {
        let cases: [(URLError.Code, String, String?)] = [
            (.serverCertificateUntrusted, "TLS failed:", "paddock trust"),
            (.cannotFindHost, "shop.test did not resolve for the request.", "paddock restart"),
            (.cannotConnectToHost, "Nothing answered on port 443.", "paddock start"),
            (.timedOut, "No answer within 5 seconds.", "paddock restart"),
        ]
        for (code, detail, fix) in cases {
            let failing = doctor(probe: { _ in throw URLError(code) })
            let report = await failing.report(for: status())
            let http = check(report.sites.first?.checks ?? [], "http")
            XCTAssertEqual(http?.outcome, .failed, "\(code)")
            XCTAssertTrue(http?.detail.hasPrefix(detail) == true, "\(code): \(http?.detail ?? "")")
            XCTAssertEqual(http?.fix, fix, "\(code)")
        }
    }

    func testLogFindingsBecomeInfoOrSkippedRows() async {
        let long = String(repeating: "x", count: 200)
        let cases: [(DoctorLogFinding, DoctorCheck.Outcome, String)] = [
            (.none, .skipped, "No logs in storage/logs."),
            (.noErrors(file: "laravel.log"), .info, "No errors in laravel.log."),
            (.error(file: "laravel.log", line: long), .info,
             "Newest error in laravel.log: " + String(repeating: "x", count: 160)),
            (.unreadable(file: "laravel.log"), .skipped, "laravel.log couldn't be read."),
        ]
        for (finding, outcome, detail) in cases {
            let report = await doctor(log: { _ in finding }).report(for: status())
            let log = check(report.sites.first?.checks ?? [], "log")
            XCTAssertEqual(log?.outcome, outcome)
            XCTAssertEqual(log?.detail, detail)
            XCTAssertNil(log?.fix)
        }
    }

    func testANamedSiteReportHasOnlyThatSite() async {
        let report = await doctor().report(for: status(sites: [site("shop"), site("blog")]), site: "blog")
        XCTAssertEqual(report.sites.map(\.site), ["blog"])
        XCTAssertEqual(check(report.global, "dns")?.title, "DNS answers blog.test")
    }
}
