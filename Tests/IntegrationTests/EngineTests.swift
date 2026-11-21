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
        let engine = Engine.development(paths: paths, settings: settings)
        self.engine = engine
        try engine.start()
        let status = engine.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.blockedBy.first?.port, settings.httpPort)
        XCTAssertEqual(status.blockedBy.first?.pid, getpid())
        XCTAssertTrue(status.processes.values.allSatisfy { $0 == "stopped" }, "\(status.processes)")
        XCTAssertNil(status.processes["caddy"], "nothing of the web stack starts while the ports are held")
        XCTAssertNil(status.processes["ports"])
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
        XCTAssertEqual(groups.count, 3, "Caddy, PHP-FPM and the port helper")

        engine.stop()

        for group in groups {
            XCTAssertEqual(try TestSupport.pgrep(group: group), [], "process group \(group) still has members")
        }
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(PortCheck.holders(of: [settings.httpPort, settings.httpsPort]), [])
        XCTAssertFalse(Self.acceptsUnix(paths.httpSocket.path), "Caddy's HTTP socket still answers")
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

    // MARK: - Port helper and Unix sockets

    func testServesThroughPortHelperOverUnixSockets() throws {
        try startEngine()
        let status = try XCTUnwrap(engine).status()
        XCTAssertTrue(status.portHelperInstalled, "a development home runs its own helper")
        let helperPid = try XCTUnwrap(status.processes["ports"].flatMap(TestSupport.pid(from:)), "\(status.processes)")
        let caddyPid = try XCTUnwrap(status.processes["caddy"].flatMap(TestSupport.pid(from:)))

        // The helper, not Caddy, holds both TCP ports.
        let holders = PortCheck.holders(of: [settings.httpPort, settings.httpsPort])
        XCTAssertEqual(holders.map(\.port), [settings.httpPort, settings.httpsPort])
        XCTAssertTrue(holders.allSatisfy { $0.pid == helperPid }, "\(holders)")
        XCTAssertFalse(holders.contains { $0.pid == caddyPid })

        // Caddy itself answers on the owner-only Unix sockets.
        let mode = try FileManager.default.attributesOfItem(atPath: paths.run.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let direct = try curlUnix(paths.httpSocket, "http://plain-php.test/")
        XCTAssertEqual(direct.status, 200, direct.verbose)
        XCTAssertTrue(direct.body.hasPrefix("plain:8.5"), direct.body)

        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testCaddyHasNoTCPListeners() throws {
        let (trust, _) = fakeTrust()
        try StateStore(paths: paths).update { $0.secured = ["plain-php"] }
        try startEngine(trust: trust)
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/").status, 200)
        let caddyPid = try XCTUnwrap(engine?.status().processes["caddy"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try TestSupport.tcpListeners(pid: caddyPid), "")
    }

    func testHelperSurvivesCaddyRestart() throws {
        let engine = Engine.development(paths: paths, settings: settings, backoffScale: 0.01)
        self.engine = engine
        try engine.start()
        let before = engine.status().processes
        let helperPid = try XCTUnwrap(before["ports"].flatMap(TestSupport.pid(from:)))
        let caddyPid = try XCTUnwrap(before["caddy"].flatMap(TestSupport.pid(from:)))

        // Kill only the Caddy this engine started; the supervisor brings it back.
        kill(caddyPid, SIGKILL)
        let deadline = Date().addingTimeInterval(15)
        var served: Response?
        while Date() < deadline {
            let now = engine.status().processes["caddy"].flatMap(TestSupport.pid(from:))
            if let now, now != caddyPid, let r = try? get("plain-php.test", "/"), r.status == 200 {
                served = r
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(served?.body.hasPrefix("plain:8.5") == true, "\(String(describing: served))")
        XCTAssertEqual(engine.status().processes["ports"], "running (pid \(helperPid))", "the helper was restarted")
        XCTAssertTrue(engine.status().running)
    }

    func testWebServerDownClosesConnection() throws {
        // Long restart delays, so Caddy stays down for a while after it dies.
        let engine = Engine.development(paths: paths, settings: settings, backoffScale: 10)
        self.engine = engine
        try engine.start()
        let caddyPid = try XCTUnwrap(engine.status().processes["caddy"].flatMap(TestSupport.pid(from:)))
        let helperPid = try XCTUnwrap(engine.status().processes["ports"].flatMap(TestSupport.pid(from:)))
        kill(caddyPid, SIGKILL)
        let gone = Date().addingTimeInterval(5)
        while engine.status().processes["caddy"]?.hasPrefix("running") == true && Date() < gone {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(engine.status().running, "Caddy is down")

        let began = Date()
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 0, "no HTTP answer while the web server is down: \(r.body)")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "the connection was closed, not left hanging")
        XCTAssertEqual(engine.status().processes["ports"], "running (pid \(helperPid))")
    }

    /// A socket bound to the HTTPS port without listening passes the connection check, but the helper
    /// can't bind there: start fails naming the helper, and nothing of the web stack is left running.
    func testHelperThatCannotBindLeavesNothingRunning() throws {
        let squatter = try XCTUnwrap(TestSupport.bindSocket(type: SOCK_STREAM, port: settings.httpsPort))
        defer { close(squatter) }
        let engine = Engine.development(paths: paths, settings: settings)
        self.engine = engine
        XCTAssertThrowsError(try engine.start()) { error in
            guard case EngineError.notReady(let process, let log) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(process, "ports")
            XCTAssertTrue(log.hasSuffix("paddock-ports.log"), log)
        }
        let status = engine.status()
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.processes.values.allSatisfy { $0 == "stopped" }, "\(status.processes)")
        XCTAssertEqual(PortCheck.holders(of: [settings.httpPort]), [])
    }

    /// On the real system launchd owns ports 80/443 (the installed helper): the engine starts Caddy on
    /// its Unix sockets only, runs no helper and checks no ports.
    func testSystemModeServesOnUnixSocketsWithoutHelperOrTCPPort() throws {
        // A listener on the HTTP port does not matter here: the engine doesn't look.
        let holder = try TestSupport.listen(port: settings.httpPort)
        defer { close(holder) }
        let engine = Engine(paths: paths, settings: settings, installAction: nil, managesPortHelper: false)
        self.engine = engine
        try engine.start()
        let status = engine.status()
        XCTAssertTrue(status.running, "blocked by \(status.blockedBy)")
        XCTAssertEqual(status.blockedBy, [])
        XCTAssertFalse(status.portHelperInstalled, "the real check arrives with the installer")
        XCTAssertNil(status.processes["ports"], "\(status.processes)")

        let r = try curlUnix(paths.httpSocket, "http://plain-php.test/")
        XCTAssertEqual(r.status, 200, r.verbose)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
        let caddyPid = try XCTUnwrap(status.processes["caddy"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try TestSupport.tcpListeners(pid: caddyPid), "")
        XCTAssertEqual(PortCheck.holders(of: [settings.httpsPort]), [], "nothing listens on the HTTPS port")
    }

    func testPortHelperInstalledComesFromTheInjectedCheckOnTheRealSystem() throws {
        let engine = Engine(paths: paths, settings: settings, installAction: nil, managesPortHelper: false,
                            portHelperInstalled: { true })
        self.engine = engine
        XCTAssertTrue(engine.status().portHelperInstalled)
    }

    func testTooLongHomeFailsStartNamingTheSocket() async throws {
        // /tmp/<name>/run/http.sock is exactly 104 bytes: one too many.
        let name = String(repeating: "p", count: 104 - "/tmp//run/http.sock".utf8.count)
        let longHome = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: longHome) }
        let long = Paths(home: longHome)
        XCTAssertEqual(long.httpSocket.path.utf8.count, 104)
        let engine = Engine.development(paths: long, settings: settings)
        self.engine = engine
        let response = await engine.handle(.start)
        XCTAssertEqual(response, .error(code: ErrorCode.internal,
                                        message: Messages.socketPathTooLong(long.httpSocket.path)))
        XCTAssertTrue(engine.status().processes.isEmpty, "\(engine.status().processes)")
    }

    // MARK: - HTTPS

    private func fakeTrust(accepts: Bool = true) -> (CertificateTrust, RecordingCommandRunner) {
        let runner = RecordingCommandRunner.fakeKeychain(accepts: accepts)
        return (CertificateTrust(paths: paths, runner: runner), runner)
    }

        func testSecuredSiteServesHttpsFromPaddockLocalAuthority() async throws {
        let (trust, runner) = fakeTrust()
        try startEngine(trust: trust)
        let response = await engine!.handle(.secure(site: "plain-php"))
        guard case .ok = response else { return XCTFail("\(response)") }

        let https = try curlHTTPS("plain-php.test", "/")
        XCTAssertEqual(https.status, 200, https.verbose)
        XCTAssertTrue(https.body.hasPrefix("plain:8.5"), https.body)
        XCTAssertTrue(https.verbose.contains("Paddock Local Authority - Intermediate"), https.verbose)
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
        let engine = Engine.development(paths: paths, settings: settings, trust: trust,
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
        let engine = Engine.development(paths: paths, settings: settings, trust: trust)
        self.engine = engine
        let response = await engine.handle(.secure(site: "plain-php"))
        XCTAssertEqual(response, .error(code: ErrorCode.needsTrust, message:
            "Paddock's web server hasn't created its certificate yet. Try again in a moment with: paddock trust"))
        XCTAssertTrue(runner.calls.isEmpty, "\(runner.calls)")
    }

    /// Paddock's CA has its own names, so browsers can't mistake another Caddy-based tool's root for it.
    func testSecuredSiteChainsToPaddocksOwnNamedRoot() async throws {
        let (trust, _) = fakeTrust()
        try startEngine(trust: trust)
        _ = await engine!.handle(.secure(site: "plain-php"))
        let local = paths.caddyData.appendingPathComponent("pki/authorities/local")
        XCTAssertEqual(try subjectAndIssuer(local.appendingPathComponent("root.crt")),
                       "subject=CN=Paddock Local Authority - Root\nissuer=CN=Paddock Local Authority - Root")
        XCTAssertEqual(try subjectAndIssuer(local.appendingPathComponent("intermediate.crt")),
                       "subject=CN=Paddock Local Authority - Intermediate\nissuer=CN=Paddock Local Authority - Root")
        // Verified against Paddock's root alone (no -k): the served chain leads to it. (This also waits for
        // Caddy to have issued the site's certificate, which it does in the background.)
        let verified = try curlHTTPS("plain-php.test", "/", trustingOnly: trust.rootCertificate)
        XCTAssertEqual(verified.status, 200, verified.verbose)
        XCTAssertTrue(verified.body.hasPrefix("plain:8.5"), verified.body)
        let leaf = paths.caddyData.appendingPathComponent("certificates/local/plain-php.test/plain-php.test.crt")
        XCTAssertTrue(try subjectAndIssuer(leaf).hasSuffix("issuer=CN=Paddock Local Authority - Intermediate"))
        XCTAssertEqual(engine!.status().needsTrust, false, "the fake keychain trusts it")
    }

    /// A home whose CA Caddy created under its default names, and an engine for it now.
    private func homeWithDefaultNamedAuthority() throws -> (oldName: String, root: URL) {
        try StateStore(paths: paths).update { $0.secured = ["plain-php"] }
        let old = Engine.development(paths: paths, settings: settings)
        old.namesCertificateAuthority = false
        self.engine = old
        try old.start()
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/").status, 200)
        let root = CertificateTrust(paths: paths, runner: RecordingCommandRunner()).rootCertificate
        let oldName = try XCTUnwrap(CertificateTrust.commonName(ofCertificateAt: root))
        XCTAssertTrue(oldName.hasPrefix("Caddy Local Authority"), oldName)
        old.shutdown()
        return (oldName, root)
    }

    /// A fake keychain keyed by certificate file: `verify-cert` answers from `trusted`, `add-trusted-cert`
    /// adds, `remove-trusted-cert` removes (or fails for `refuseRemoval`). Untrust calls are recorded with
    /// the name the file had at that moment.
    private func keychain(trusted: LockedBox<Set<String>>, refuseRemoval: Bool = false, refuseAdding: Bool = false,
                          removed: LockedBox<[String?]>) -> RecordingCommandRunner {
        RecordingCommandRunner { _, arguments in
            switch arguments.first {
            case "verify-cert": return trusted.value.contains(arguments[2]) ? (0, "") : notTrusted
            case "add-trusted-cert":
                if refuseAdding { return (1, "User canceled the authorization") }
                trusted.value.insert(arguments.last!)
                return (0, "")
            case "remove-trusted-cert":
                removed.value.append(CertificateTrust.commonName(ofCertificateAt: URL(fileURLWithPath: arguments[1])))
                if refuseRemoval { return (1, "User canceled the authorization") }
                trusted.value.remove(arguments[1])
                return (0, "")
            default: return (1, "unexpected")
            }
        }
    }

    /// The next start sets the old root aside (no `security` call, so nothing can wait on a dialog),
    /// deletes the old CA and its certificates, and says so once. The `trust` request then trusts the new
    /// root and removes the old one's trust and file.
    func testStartSetsAsideADefaultNamedAuthorityAndTrustCleansItUp() async throws {
        let (oldName, root) = try homeWithDefaultNamedAuthority()
        let replaced = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        // The old root (by path, as it will be kept) is trusted.
        let trusted = LockedBox<Set<String>>([root.path, replaced.path])
        let removed = LockedBox<[String?]>([])
        let runner = keychain(trusted: trusted, removed: removed)
        let logged = LockedBox<[String]>([])
        let engine = Engine.development(paths: paths, settings: settings,
                                        trust: CertificateTrust(paths: paths, runner: runner),
                                        log: { logged.value.append($0) })
        self.engine = engine
        try engine.start()
        XCTAssertFalse(runner.calls.contains { $0.arguments.first != "verify-cert" },
                       "start changed no trust: \(runner.calls.map(\.arguments))")
        XCTAssertEqual(CertificateTrust.commonName(ofCertificateAt: replaced), oldName, "the old root is kept")
        XCTAssertEqual(logged.value.filter { $0.contains("renamed") },
                       ["the certificate authority was renamed to Paddock Local Authority; the old certificate "
                        + "was kept at \(replaced.path) until you approve the change with paddock trust"])

        let verified = try curlHTTPS("plain-php.test", "/", trustingOnly: root)
        XCTAssertEqual(verified.status, 200, verified.verbose)
        XCTAssertEqual(CertificateTrust.commonName(ofCertificateAt: root), "Paddock Local Authority - Root")
        // The fake trusts root.crt by path; the new file is a different certificate, so make it untrusted.
        trusted.value.remove(root.path)

        let deadline = Date().addingTimeInterval(10)
        while !(engine.status().needsTrust && engine.status().hasReplacedRootsToClean) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(engine.status().needsTrust)
        XCTAssertTrue(engine.status().hasReplacedRootsToClean)

        let response = await engine.handle(.trust)
        guard case .ok(let status) = response else { return XCTFail("\(response)") }
        XCTAssertTrue(trusted.value.contains(root.path), "the new root is trusted")
        XCTAssertEqual(removed.value, [oldName], "exactly one untrust, for the replaced root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path), "no longer trusted, so deleted")
        XCTAssertFalse(status.needsTrust)
        XCTAssertFalse(status.hasReplacedRootsToClean)

        // Nothing to set aside on the next start.
        engine.stop()
        try engine.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path))
        XCTAssertEqual(CertificateTrust.commonName(ofCertificateAt: root), "Paddock Local Authority - Root")
    }

    /// The owner declined the new root: no second dialog for the old one in the same request.
    func testADeclinedCurrentRootIsNotFollowedByAPromptForTheReplacedRoot() async throws {
        let (_, _) = try homeWithDefaultNamedAuthority()
        let replaced = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        let trusted = LockedBox<Set<String>>([replaced.path])
        let removed = LockedBox<[String?]>([])
        let runner = keychain(trusted: trusted, refuseAdding: true, removed: removed)
        let engine = Engine.development(paths: paths, settings: settings,
                                        trust: CertificateTrust(paths: paths, runner: runner))
        self.engine = engine
        try engine.start()
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/").status, 200)
        let response = await engine.handle(.trust)
        guard case .error(let code, _) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(code, ErrorCode.needsTrust)
        XCTAssertEqual(removed.value, [], "no remove-trusted-cert after a declined add")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.path))
    }

    func testARefusedUntrustOfTheReplacedRootKeepsItAndTrustStillSucceeds() async throws {
        let (oldName, root) = try homeWithDefaultNamedAuthority()
        let replaced = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        let trusted = LockedBox<Set<String>>([replaced.path])
        let removed = LockedBox<[String?]>([])
        let engine = Engine.development(paths: paths, settings: settings, trust: CertificateTrust(
            paths: paths, runner: keychain(trusted: trusted, refuseRemoval: true, removed: removed)))
        self.engine = engine
        try engine.start()
        XCTAssertEqual(try curlHTTPS("plain-php.test", "/", trustingOnly: root).status, 200)

        let response = await engine.handle(.trust)
        guard case .ok(let status) = response else { return XCTFail("\(response)") }
        XCTAssertTrue(trusted.value.contains(root.path), "the current root is trusted")
        XCTAssertFalse(status.needsTrust)
        XCTAssertEqual(removed.value, [oldName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.path), "kept for the next attempt")
        XCTAssertTrue(status.hasReplacedRootsToClean)
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
        let engine = Engine.development(paths: paths, settings: settings, trust: trust)
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

    /// HTTPS verified against `root` only (curl's `--cacert`), retried like `curlHTTPS`.
    private func curlHTTPS(_ host: String, _ path: String, trustingOnly root: URL) throws -> CurlResult {
        let port = settings.httpsPort
        let deadline = Date().addingTimeInterval(10)
        while true {
            let result = try curl(["--cacert", root.path, "--resolve", "\(host):\(port):127.0.0.1",
                                   "https://\(host):\(port)\(path)"])
            if result.status != 0 || Date() >= deadline { return result }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// `openssl x509 -noout -subject -issuer` for a PEM certificate, as `subject=CN=…` lines (LibreSSL's
    /// `subject= /CN=…` normalized).
    private func subjectAndIssuer(_ certificate: URL) throws -> String {
        let result = try SystemCommandRunner().run("/usr/bin/openssl",
                                                   ["x509", "-noout", "-subject", "-issuer", "-in", certificate.path])
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.replacingOccurrences(of: "= /", with: "=")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A request straight to one of Caddy's Unix sockets, bypassing the port helper.
    private func curlUnix(_ socket: URL, _ url: String) throws -> CurlResult {
        try curl(["--unix-socket", socket.path, url])
    }

    /// Whether a Unix stream socket at `path` accepts a connection.
    private static func acceptsUnix(_ path: String) -> Bool {
        guard let fd = Wire.connect(to: path) else { return false }
        close(fd)
        return true
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
