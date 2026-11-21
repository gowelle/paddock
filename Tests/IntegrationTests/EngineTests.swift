import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Starts real Caddy and PHP-FPM from Vendor/ on high ports with a throwaway PADDOCK_HOME.
final class EngineTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var parked: URL!
    private var settings = Settings()
    private var engine: Engine?

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        try makeHome(rootName: "pdk-\(TestSupport.token())")
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Tests

    func testServesParkedPlainSite() throws {
        try startEngine()
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testServesLaravelFrontController() throws {
        try startEngine()
        let r = try get("laravel-like.test", "/users/7")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body, "laravel:/users/7")
    }

    func testServesStaticFile() throws {
        try startEngine()
        let r = try get("laravel-like.test", "/robots.txt")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body.trimmingCharacters(in: .whitespacesAndNewlines), "static-ok")
    }

    func testUnknownSiteIs404() throws {
        try startEngine()
        let r = try get("nope.test", "/")
        XCTAssertEqual(r.status, 404)
        XCTAssertTrue(r.body.contains("<title>Paddock - Not Found</title>"), r.body)
        XCTAssertFalse(r.body.contains("Valet"), r.body)
    }

    func testNewFolderIsServedWithoutReload() throws {
        try startEngine()
        let fresh = parked.appendingPathComponent("fresh-site", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("<?php echo 'fresh:ok';".utf8).write(to: fresh.appendingPathComponent("index.php"))
        let r = try get("fresh-site.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body, "fresh:ok")
    }

    func testBlockedPortsReportedWhileDNSKeepsAnswering() throws {
        let holder = try TestSupport.listen(port: settings.httpPort)
        defer { close(holder) }
        let engine = Engine(paths: paths, settings: settings)
        self.engine = engine
        try engine.start()
        let status = engine.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.blockedBy.first?.port, settings.httpPort)
        XCTAssertEqual(status.blockedBy.first?.pid, getpid())
        XCTAssertEqual(status.portsNotPermitted, [])
        XCTAssertTrue(status.processes.values.allSatisfy { $0 == "stopped" }, "\(status.processes)")
        // The web server is blocked, but .test names still resolve.
        XCTAssertTrue(status.dnsRunning)
        XCTAssertEqual(try TestSupport.dig("blocked.test", port: settings.dnsPort), "127.0.0.1")

        engine.stop()
        XCTAssertTrue(engine.status().dnsRunning, "stopping the web stack leaves DNS answering")
        XCTAssertEqual(try TestSupport.dig("still.test", port: settings.dnsPort), "127.0.0.1")
        engine.shutdown()
        XCTAssertFalse(engine.status().dnsRunning)
        XCTAssertTrue(try TestSupport.canBindUDP(port: settings.dnsPort), "DNS responder still bound after shutdown")
    }

    func testAnUnavailableFirstParkedPathDoesNotStopTheOthersBeingServed() throws {
        // A file where a directory should be: the parked path can neither exist nor be created.
        let blocker = root.appendingPathComponent("not-a-volume")
        try Data().write(to: blocker)
        let missing = blocker.appendingPathComponent("Sites").path
        try StateStore(paths: paths).update { $0.parked = [missing, self.parked.path] }
        try startEngine()
        let status = try XCTUnwrap(engine).status()
        XCTAssertEqual(status.sites.map(\.name), ["laravel-like", "plain-php"])
        XCTAssertTrue(status.sites.allSatisfy { $0.path.hasPrefix(parked.path) }, "\(status.sites)")
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
        // Later changes keep working too.
        try XCTUnwrap(engine).reload()
    }

    func testSubdomainIsServedByItsSite() throws {
        try startEngine()
        let r = try get("api.plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testServesFolderWithSpaceInName() throws {
        try copyFixture("plain-php", as: "My App")
        try startEngine()
        let r = try get("my-app.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testWorksWithSpaceInHomePath() throws {
        try FileManager.default.removeItem(at: root)
        try makeHome(rootName: "pdk \(TestSupport.token())")
        XCTAssertTrue(paths.home.path.contains(" "))
        try startEngine()
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testStatusWhileRunning() throws {
        try startEngine()
        let status = try XCTUnwrap(engine).status()
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.blockedBy, [])
        XCTAssertEqual(status.defaultPHP, PHPVersion("8.5"))
        XCTAssertEqual(status.installedPHP, [PHPVersion("8.5")!])
        XCTAssertEqual(status.sites.map(\.name), ["laravel-like", "plain-php"])
        XCTAssertTrue(status.processes["caddy"]?.hasPrefix("running") == true, "\(status.processes)")
        XCTAssertTrue(status.processes["php-fpm-8.5"]?.hasPrefix("running") == true, "\(status.processes)")
        XCTAssertFalse(status.resolverInstalled)
        XCTAssertNoThrow(try JSONEncoder().encode(status))
    }

    func testReloadPicksUpNewFolderWithSpaceInName() throws {
        try startEngine()
        try copyFixture("plain-php", as: "Late Comer")
        try XCTUnwrap(engine).reload()
        let r = try get("late-comer.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:"), r.body)
    }

    func testStopLeavesNoProcessesAndFreesPorts() throws {
        try startEngine()
        let engine = try XCTUnwrap(self.engine)
        XCTAssertEqual(try get("plain-php.test", "/").status, 200) // spawns an FPM worker
        let groups = engine.status().processes.values.compactMap(TestSupport.pid(from:))
        XCTAssertEqual(groups.count, 2)

        engine.stop()

        for group in groups {
            XCTAssertEqual(try TestSupport.pgrep(group: group), [], "process group \(group) still has members")
        }
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(PortCheck.holders(of: [settings.httpPort, settings.httpsPort]), [])
        XCTAssertTrue(engine.status().dnsRunning, "DNS runs as long as the daemon does")
        engine.shutdown()
        XCTAssertTrue(try TestSupport.canBindUDP(port: settings.dnsPort), "DNS responder still bound")
    }

    func testCaddyWritesNothingToTheUsersCaddyDirectory() throws {
        let before = Self.userCaddySnapshot()
        // A secured site makes Caddy create its local CA and a certificate.
        try StateStore(paths: paths).update { $0.secured = ["plain-php"] }
        try startEngine()
        XCTAssertEqual(try get("laravel-like.test", "/").status, 200)
        try XCTUnwrap(engine).reload()
        engine?.stop()
        XCTAssertEqual(Self.userCaddySnapshot(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.caddyData.appendingPathComponent("pki").path),
                      "Caddy's local CA should live in the Paddock home")
    }

    // MARK: - HTTPS

    private func fakeTrust(accepts: Bool = true) -> (CertificateTrust, RecordingCommandRunner) {
        let runner = RecordingCommandRunner.fakeKeychain(accepts: accepts)
        return (CertificateTrust(paths: paths, runner: runner), runner)
    }

        func testSecuredSiteServesHttpsFromCaddyLocalAuthority() async throws {
        let (trust, runner) = fakeTrust()
        try startEngine(trust: trust)
        let response = await engine!.handle(.secure(site: "plain-php"))
        guard case .ok = response else { return XCTFail("\(response)") }

        let https = try curlHTTPS("plain-php.test", "/")
        XCTAssertEqual(https.status, 200, https.verbose)
        XCTAssertTrue(https.body.hasPrefix("plain:8.5"), https.body)
        XCTAssertTrue(https.verbose.contains("Caddy Local Authority"), https.verbose)
        let sub = try curlHTTPS("api.plain-php.test", "/")
        XCTAssertEqual(sub.status, 200, sub.verbose)
        XCTAssertTrue(sub.body.hasPrefix("plain:8.5"), sub.body)
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "add-trusted-cert" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trust.rootCertificate.path))
    }

    func testHttpRedirectsToHttpsAndUnsecureServesHttpAgain() async throws {
        let (trust, _) = fakeTrust()
        try startEngine(trust: trust)
        _ = await engine!.handle(.secure(site: "plain-php"))

        let redirect = try curlHTTP("plain-php.test", "/some/path?q=1")
        XCTAssertTrue((300..<400).contains(redirect.status), "\(redirect.status)")
        XCTAssertEqual(redirect.location, "https://plain-php.test:\(settings.httpsPort)/some/path?q=1")

        let response = await engine!.handle(.unsecure(site: "plain-php"))
        guard case .ok = response else { return XCTFail("\(response)") }
        let plain = try curlHTTP("plain-php.test", "/")
        XCTAssertEqual(plain.status, 200, plain.body)
    }

    func testDeclinedTrustLeavesSiteSecuredAndAnswersNeedsTrust() async throws {
        let (trust, runner) = fakeTrust(accepts: false)
        let logged = LockedBox<[String]>([])
        let engine = Engine(paths: paths, settings: settings, installAction: nil, trust: trust,
                            log: { line in logged.value.append(line) })
        self.engine = engine
        try engine.start()
        let response = await engine.handle(.secure(site: "plain-php"))
        guard case .error(let code, _) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(code, ErrorCode.needsTrust)
        // The failed `security` command is in the daemon log, status and output.
        XCTAssertTrue(logged.value.contains { $0.contains("status 1") && $0.contains("User canceled the authorization") },
                      "\(logged.value)")
        XCTAssertTrue(engine.store.load().secured.contains("plain-php"))
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/").status, 200)

        // `trust` retries, and still reports needs_trust while the user keeps declining.
        let retry = await engine.handle(.trust)
        guard case .error(let retryCode, _) = retry else { return XCTFail("\(retry)") }
        XCTAssertEqual(retryCode, ErrorCode.needsTrust)
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "add-trusted-cert" }.count, 2)
    }

    func testTrustRequestSucceedsWhenTrustedAndSkipsAddWhenAlreadyTrusted() async throws {
        let (trust, runner) = fakeTrust()
        try startEngine(trust: trust)
        _ = await engine!.handle(.secure(site: "plain-php"))
        let again = await engine!.handle(.trust)
        guard case .ok = again else { return XCTFail("\(again)") }
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "add-trusted-cert" }.count, 1)
    }

    func testTrustRequestWithoutTrustObjectIsAnErrorNotOk() async throws {
        try startEngine()
        let response = await engine!.handle(.trust)
        XCTAssertEqual(response, .error(code: ErrorCode.trustDisabled,
                                        message: "Certificate trust is turned off for this Paddock home."))
        let secured = await engine!.handle(.secure(site: "plain-php"))
        guard case .ok(let status) = secured else { return XCTFail("\(secured)") }
        XCTAssertFalse(status.trustEnabled)
    }

    func testNoRootCertificateMeansNeedsTrustWithoutCallingTrust() async throws {
        let (trust, runner) = fakeTrust()
        // Engine never started: Caddy is down, so root.crt cannot exist.
        let engine = Engine(paths: paths, settings: settings, trust: trust)
        self.engine = engine
        let response = await engine.handle(.secure(site: "plain-php"))
        XCTAssertEqual(response, .error(code: ErrorCode.needsTrust, message:
            "Paddock's web server hasn't created its certificate yet. Try again in a moment with: paddock trust"))
        XCTAssertTrue(runner.calls.isEmpty, "\(runner.calls)")
    }

    func testSecureWithoutTrustObjectBehavesAsBefore() async throws {
        try startEngine()
        let response = await engine!.handle(.secure(site: "plain-php"))
        guard case .ok = response else { return XCTFail("\(response)") }
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/").status, 200)
    }

    // MARK: - Helpers

    private var home: TestHome!

    private func makeHome(rootName: String) throws {
        home = try TestHome(rootName: rootName)
        root = home.root
        paths = home.paths
        parked = home.parked
        settings = home.settings
    }

    private func copyFixture(_ name: String, as folder: String? = nil) throws {
        try home.copyFixture(name, as: folder)
    }

    private func startEngine(trust: CertificateTrust? = nil) throws {
        let engine = Engine(paths: paths, settings: settings, trust: trust)
        self.engine = engine
        try engine.start()
        XCTAssertTrue(engine.status().running, "blocked by \(engine.status().blockedBy)")
    }

    private struct Response { let status: Int; let body: String }

    /// Plain HTTP/1.1 request to 127.0.0.1 with the given Host header, via the system curl.
    private func get(_ host: String, _ path: String) throws -> Response {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "10", "-H", "Host: \(host)",
                          "-w", "\n%{http_code}", "http://127.0.0.1:\(settings.httpPort)\(path)"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        var text = String(decoding: data, as: UTF8.self)
        let newline = try XCTUnwrap(text.lastIndex(of: "\n"), "curl output: \(text)")
        let status = Int(text[text.index(after: newline)...]) ?? -1
        text = String(text[..<newline])
        return Response(status: status, body: text)
    }

    private struct CurlResult { let status: Int; let body: String; let location: String?; let verbose: String }

    private func curl(_ arguments: [String]) throws -> CurlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-s", "-v", "--max-time", "10", "-D", "-",
                             "-w", "\n%{http_code}"] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let newline = try XCTUnwrap(text.lastIndex(of: "\n"), "curl output: \(text)")
        let status = Int(text[text.index(after: newline)...]) ?? -1
        let all = String(text[..<newline])
        let parts = all.components(separatedBy: "\r\n\r\n")
        let headers = parts.dropLast().last ?? ""
        let location = headers.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("location:") }
            .map { String($0.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces) }
        return CurlResult(status: status, body: parts.last ?? "", location: location,
                          verbose: String(decoding: errData, as: UTF8.self))
    }

    /// HTTPS to Caddy on the test's HTTPS port, without DNS: `-k` skips verification, `--resolve` pins the address.
    /// Caddy loads a newly secured site's certificate in the background, so a failed handshake (status 0)
    /// is retried for up to 10 seconds.
    private func curlHTTPS(_ host: String, _ path: String) throws -> CurlResult {
        let port = settings.httpsPort
        let deadline = Date().addingTimeInterval(10)
        while true {
            let result = try curl(["-k", "--resolve", "\(host):\(port):127.0.0.1", "https://\(host):\(port)\(path)"])
            if result.status != 0 || Date() >= deadline { return result }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func curlHTTP(_ host: String, _ path: String) throws -> CurlResult {
        let port = settings.httpPort
        return try curl(["--resolve", "\(host):\(port):127.0.0.1", "http://\(host):\(port)\(path)"])
    }

    /// Every path and modification date under ~/Library/Application Support/Caddy (empty if absent).
    private static func userCaddySnapshot() -> [String: Date] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Caddy")
        var out: [String: Date] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = e?.nextObject() as? URL {
            out[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return out
    }
}
