import XCTest
@testable import PaddockCore

/// `Engine.handle` against a real (unstarted unless a test says so) engine in a throwaway home.
final class EngineHandleTests: XCTestCase {
    private var home: TestHome!
    private var engine: Engine!
    private let v85 = PHPVersion("8.5")!
    private let v84 = PHPVersion("8.4")!

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TestHome()
        engine = Engine.development(paths: home.paths, settings: home.settings)
        try engine.installer.installBundled()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        home?.cleanUp()
    }

    private func status(_ response: Response, file: StaticString = #filePath, line: UInt = #line) throws -> EngineStatus {
        guard case .ok(let status) = response else {
            XCTFail("expected ok, got \(response)", file: file, line: line)
            throw XCTSkip("unexpected error response")
        }
        return status
    }

    private func st(_ request: Request, file: StaticString = #filePath, line: UInt = #line) async throws -> EngineStatus {
        try status(await engine.handle(request), file: file, line: line)
    }

    private func expectError(_ request: Request, _ code: String, file: StaticString = #filePath, line: UInt = #line) async {
        let response = await engine.handle(request)
        XCTAssertEqual(errorCode(response), code, "\(request) -> \(response)", file: file, line: line)
    }

    private func errorCode(_ response: Response) -> String? {
        if case .error(let code, _) = response { return code }
        return nil
    }

    // MARK: - State requests

    func testParkAndForgetStoreStandardizedPaths() async throws {
        let extra = try home.makeDirectory("more-sites")
        let messy = extra.path + "/../more-sites/"
        let parked = try await st(.park(path: messy))
        XCTAssertEqual(engine.store.load().parked.last, extra.standardizedFileURL.path)
        XCTAssertNotNil(parked.defaultPHP)

        _ = try await st(.park(path: extra.path))
        XCTAssertEqual(engine.store.load().parked.filter { $0 == extra.path }.count, 1, "park is idempotent")

        _ = try await st(.forget(path: messy))
        XCTAssertFalse(engine.store.load().parked.contains(extra.path))
        _ = try await st(.forget(path: "/never/parked"))
    }

    func testParkRejectsNonDirectoryAndRelativePaths() async throws {
        let file = home.root.appendingPathComponent("a-file")
        try Data().write(to: file)
        await expectError(.park(path: file.path), "not_a_directory")
        await expectError(.park(path: "/no/such/dir"), "not_a_directory")
        await expectError(.park(path: "relative/dir"), "not_a_directory")
        await expectError(.link(name: "x", path: file.path), "not_a_directory")
    }

    func testLinkNormalizesNameAndUnlinkIsIdempotent() async throws {
        let app = try home.makeDirectory("my-app-dir")
        let linked = try await st(.link(name: "My Shiny App!", path: app.path))
        XCTAssertEqual(engine.store.load().links["my-shiny-app"], app.path)
        XCTAssertEqual(linked.sites.first { $0.name == "my-shiny-app" }?.kind, .linked)

        _ = try await st(.unlink(name: "my-shiny-app"))
        XCTAssertNil(engine.store.load().links["my-shiny-app"])
        _ = try await st(.unlink(name: "my-shiny-app"))
    }

    func testLinkWithUnusableNameIsInternalError() async throws {
        let app = try home.makeDirectory("app")
        guard case .error(let code, let message) = await engine.handle(.link(name: "!!!", path: app.path)) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(code, "internal")
        XCTAssertTrue(message.contains("!!!"), message)
    }

    func testSecureUnsecureAndUnknownSite() async throws {
        let secured = try await st(.secure(site: "plain-php"))
        XCTAssertTrue(secured.sites.first { $0.name == "plain-php" }?.secured == true)
        XCTAssertEqual(engine.store.load().secured, ["plain-php"])

        let unsecured = try await st(.unsecure(site: "plain-php"))
        XCTAssertTrue(unsecured.sites.first { $0.name == "plain-php" }?.secured == false)
        _ = try await st(.unsecure(site: "plain-php")) // not set: still ok

        await expectError(.secure(site: "nope"), "unknown_site")
        await expectError(.unsecure(site: "nope"), "unknown_site")
    }

    func testLanMasterAndSiteChoicesAreStored() async throws {
        let on = try await st(.lan(enabled: true))
        XCTAssertEqual(on.lan?.enabled, true)
        XCTAssertEqual(on.lan?.port, LAN.defaultPort)
        XCTAssertTrue(engine.store.load().lanEnabled)

        let chosen = try await st(.lanSite(site: "plain-php", enabled: true))
        XCTAssertTrue(chosen.sites.first { $0.name == "plain-php" }?.lan == true)
        XCTAssertEqual(engine.store.load().lanSites, ["plain-php"])

        _ = try await st(.lanSite(site: "plain-php", enabled: false))
        XCTAssertTrue(engine.store.load().lanSites.isEmpty)
        _ = try await st(.lanSite(site: "plain-php", enabled: false)) // not set: still ok
        await expectError(.lanSite(site: "nope", enabled: true), "unknown_site")

        // Turning the master switch off keeps the per-site choices for when it is turned on again.
        _ = try await st(.lanSite(site: "plain-php", enabled: true))
        let off = try await st(.lan(enabled: false))
        XCTAssertEqual(off.lan?.enabled, false)
        XCTAssertEqual(engine.store.load().lanSites, ["plain-php"])
    }

    func testLanListenerStartsAndStopsWithTheMasterSwitch() async throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                       home.settings.dnsPort])
        let lanEngine = Engine.development(paths: home.paths, settings: home.settings,
                                           lanPortChooser: { _ in port })
        defer { lanEngine.shutdown() }
        _ = await lanEngine.handle(.lan(enabled: true))
        _ = await lanEngine.handle(.lanSite(site: "plain-php", enabled: true))
        guard case .ok(let started) = await lanEngine.handle(.start), started.running else {
            return XCTFail("start should be ok")
        }
        XCTAssertEqual(started.lan?.port, port)
        XCTAssertEqual(started.lan?.running, true)
        XCTAssertEqual(lanEngine.store.load().lanPort, port, "the chosen port is remembered")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: port), "the LAN listener answers on its port")

        guard case .ok(let off) = await lanEngine.handle(.lan(enabled: false)) else {
            return XCTFail("turning the LAN off should be ok")
        }
        XCTAssertEqual(off.lan?.enabled, false)
        XCTAssertEqual(off.lan?.running, false)
        XCTAssertEqual(off.processes["lan"], "stopped")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port), "the port is free again")
    }

    func testIsolateUnisolateAndUse() async throws {
        let isolated = try await st(.isolate(site: "plain-php", version: v85))
        XCTAssertTrue(isolated.sites.first { $0.name == "plain-php" }?.pinned == true)
        XCTAssertEqual(engine.store.load().phpPins["plain-php"], v85)

        await expectError(.isolate(site: "plain-php", version: v84), "php_not_installed")
        await expectError(.isolate(site: "nope", version: v85), "unknown_site")

        _ = try await st(.unisolate(site: "plain-php"))
        XCTAssertNil(engine.store.load().phpPins["plain-php"])
        _ = try await st(.unisolate(site: "plain-php"))
        await expectError(.unisolate(site: "nope"), "unknown_site")

        await expectError(.use(version: v84), "php_not_installed")
        let r1 = try await st(.use(version: v85))
        XCTAssertEqual(r1.defaultPHP, v85)
    }

    func testRemovePHPRefusesDefaultAndPinned() async throws {
        await expectError(.removePHP(version: v85), "php_in_use")
        // A pinned but non-default version is also in use.
        try engine.store.update { $0.defaultPHP = self.v84; $0.phpPins["plain-php"] = self.v85 }
        await expectError(.removePHP(version: v85), "php_in_use")
        // Removing something not installed is fine.
        _ = try await st(.removePHP(version: PHPVersion("8.2")!))
    }

    func testInstallPHPErrorsAndNoOps() async throws {
        await expectError(.installPHP(version: PHPVersion("9.9")!), "php_not_available")
        _ = try await st(.installPHP(version: v85)) // already installed
    }

    /// No Swoole-free build exists for 8.1-8.3: asking for one is the ordinary "not available" answer.
    func testInstallingAVersionWithoutAPaddockBuildIsNotAvailable() async throws {
        for minor in 1...3 {
            let v = PHPVersion(major: 8, minor: minor)
            let response = await engine.handle(.installPHP(version: v))
            guard case .error(let code, let message) = response else { return XCTFail("\(response)") }
            XCTAssertEqual(code, ErrorCode.phpNotAvailable)
            XCTAssertEqual(message, "PHP 8.\(minor) isn't available for Intel Macs yet.")
            XCTAssertFalse(engine.installer.isInstalled(v))
        }
    }

    // MARK: - Running state

    func testBlockedPortsStillAcceptStateChanges() async throws {
        let holder = try TestSupport.listen(port: home.settings.httpPort)
        defer { close(holder) }
        guard case .error(let code, let message) = await engine.handle(.start) else {
            return XCTFail("expected ports_blocked")
        }
        XCTAssertEqual(code, "ports_blocked")
        XCTAssertTrue(message.hasPrefix("Paddock can't start: port \(home.settings.httpPort) is in use by "), message)

        let extra = try home.makeDirectory("later")
        let parked = try await st(.park(path: extra.path))
        XCTAssertFalse(parked.running)
        XCTAssertEqual(parked.blockedBy.first?.port, home.settings.httpPort)
        XCTAssertEqual(parked.blockedBy.first?.pid, getpid())
    }

    func testStartStopRestartAndSerializedParks() async throws {
        let r2 = try await st(.start)
        XCTAssertTrue(r2.running)
        let r3 = try await st(.start)
        XCTAssertTrue(r3.running, "start while running is ok")

        // Concurrent parks must not lose each other's updates.
        var dirs: [URL] = []
        for i in 0..<8 { dirs.append(try home.makeDirectory("batch-\(i)")) }
        await withTaskGroup(of: Void.self) { group in
            for dir in dirs {
                group.addTask { _ = await self.engine.handle(.park(path: dir.path)) }
            }
        }
        let parked = Set(engine.store.load().parked)
        for dir in dirs { XCTAssertTrue(parked.contains(dir.path), "lost \(dir.path)") }
        XCTAssertTrue(engine.status().running)

        let r4 = try await st(.stop)

        XCTAssertFalse(r4.running)
        let r5 = try await st(.restart)
        XCTAssertTrue(r5.running)
        let r6 = try await st(.restart)
        XCTAssertTrue(r6.running)
    }

    // MARK: - Status never blocks behind slow work

    func testStatusIsPromptWhileInstallPHPRuns() async throws {
        let started = expectation(description: "install started")
        let release = DispatchSemaphore(value: 0)
        let slow = Engine.development(paths: home.paths, settings: home.settings, installAction: { _ in
            started.fulfill()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = release.wait(timeout: .now() + 20)
                    continuation.resume()
                }
            }
        })
        let install = Task { await slow.handle(.installPHP(version: v84)) }
        await fulfillment(of: [started], timeout: 10)

        for _ in 0..<5 {
            let began = Date()
            let response = await slow.handle(.status)
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "status waited for the install")
            if case .error = response { XCTFail("status errored") }
        }
        // Other mutations queue behind the install rather than interleaving with it.
        let parkDir = try home.makeDirectory("queued")
        let queuedPark = Task { await slow.handle(.park(path: parkDir.path)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(slow.store.load().parked.contains(parkDir.path), "park ran during the install")

        release.signal()
        _ = await install.value
        _ = await queuedPark.value
        XCTAssertTrue(slow.store.load().parked.contains(parkDir.path))
    }

    func testRequestsQueuedBehindShutdownCannotStartTheEngineAgain() async throws {
        let started = expectation(description: "install started")
        let release = DispatchSemaphore(value: 0)
        let slow = Engine.development(paths: home.paths, settings: home.settings, installAction: { _ in
            started.fulfill()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = release.wait(timeout: .now() + 20)
                    continuation.resume()
                }
            }
        })
        defer { slow.shutdown() }
        let install = Task { await slow.handle(.installPHP(version: v84)) }
        await fulfillment(of: [started], timeout: 10)

        // A shutdown queues behind the install; a start arrives after it.
        let shutdown = Task { await slow.handle(.shutdown) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Task { await slow.handle(.start) }
        try await Task.sleep(nanoseconds: 200_000_000)
        release.signal()
        _ = await install.value
        guard case .ok = await shutdown.value else { return XCTFail("shutdown should be ok") }
        let startResponse = await start.value
        XCTAssertEqual(startResponse, .error(code: ErrorCode.internal, message: "Paddock is shutting down."))
        XCTAssertFalse(slow.status().running)
        XCTAssertTrue(slow.status().processes.values.allSatisfy { $0 == "stopped" }, "\(slow.status().processes)")

        // Later changes are refused too; status still answers.
        let later = try home.makeDirectory("too-late")
        let parkResponse = await slow.handle(.park(path: later.path))
        XCTAssertEqual(parkResponse, .error(code: ErrorCode.internal, message: "Paddock is shutting down."))
        XCTAssertFalse(slow.store.load().parked.contains(later.path))
        guard case .ok = await slow.handle(.status) else { return XCTFail("status should still answer") }
    }

    func testShutDownAfterPendingWorkWaitsForTheRequestInProgressThenRefusesTheRest() async throws {
        let engine = try XCTUnwrap(self.engine)
        guard case .ok(let running) = await engine.handle(.start), running.running else {
            return XCTFail("start should be ok")
        }
        await engine.shutDownAfterPendingWork()
        XCTAssertFalse(engine.status().running)
        XCTAssertFalse(engine.status().dnsRunning)
        let again = await engine.handle(.start)
        XCTAssertEqual(again, .error(code: ErrorCode.internal, message: "Paddock is shutting down."))
        XCTAssertFalse(engine.status().running)
    }

    func testStatusIsPromptWhileStartRuns() async throws {
        let fresh = Engine.development(paths: home.paths, settings: home.settings)
        let done = DispatchGroup()
        done.enter()
        let starter = Thread {
            try? fresh.start()
            done.leave()
        }
        var finished: Bool { done.wait(timeout: .now()) == .success }
        starter.start()
        defer { fresh.shutdown() }

        var answeredDuringStart = 0
        let deadline = Date().addingTimeInterval(30)
        while !finished && Date() < deadline {
            let began = Date()
            let status = fresh.status()
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "status waited for start()")
            if !finished {
                answeredDuringStart += 1
                XCTAssertFalse(status.running)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(finished, "start() did not finish")
        XCTAssertGreaterThan(answeredDuringStart, 0, "start() finished before status was ever asked")
        XCTAssertTrue(fresh.status().running)
    }

    func testStatusIsPromptWhileReloadRuns() async throws {
        try engine.start()
        XCTAssertTrue(engine.status().running)
        let running = engine!
        let reloading = Thread { try? running.reload() }
        reloading.start()
        for _ in 0..<20 {
            let began = Date()
            _ = engine.status()
            XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "status waited for reload()")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testRunningIsFalseWhenCaddyHasCrashed() async throws {
        try engine.start()
        XCTAssertTrue(engine.status().running)
        // Kill only the Caddy process this engine started.
        let pid = try XCTUnwrap(engine.status().processes["caddy"].flatMap(TestSupport.pid(from:)))
        kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while engine.status().running && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(engine.status().running, "\(engine.status().processes)")
    }

    /// Kills only the Caddy this engine started until the supervisor gives up (stays crashed).
    private func driveCaddyToGivenUp(_ engine: Engine) async throws {
        try await driveToGivenUp(engine, process: "caddy")
    }

    /// Kills only the `process` child this engine started until the supervisor gives up (stays crashed).
    private func driveToGivenUp(_ engine: Engine, process: String) async throws {
        var crashedSince: Date?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let description = engine.status().processes[process] ?? ""
            if description.hasPrefix("crashed") {
                if let since = crashedSince, Date().timeIntervalSince(since) > 0.5 { return }
                crashedSince = crashedSince ?? Date()
            } else {
                crashedSince = nil
                if let pid = TestSupport.pid(from: description) { kill(pid, SIGKILL) }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("\(process) was never given up on")
    }

    func testStartRecoversAfterCaddyIsGivenUpOn() async throws {
        let fast = Engine.development(paths: home.paths, settings: home.settings, backoffScale: 0.01)
        defer { fast.shutdown() }
        _ = await fast.handle(.start)
        try await driveCaddyToGivenUp(fast)
        XCTAssertFalse(fast.status().running)

        guard case .ok(let status) = await fast.handle(.start) else { return XCTFail("start should recover") }
        XCTAssertTrue(status.running)
        XCTAssertTrue(status.processes["caddy"]?.hasPrefix("running") == true, "\(status.processes)")
    }

    func testStateChangesStillSucceedWhileCaddyIsGivenUpOn() async throws {
        let fast = Engine.development(paths: home.paths, settings: home.settings, backoffScale: 0.01)
        defer { fast.shutdown() }
        _ = await fast.handle(.start)
        try await driveCaddyToGivenUp(fast)

        let extra = try home.makeDirectory("while-down")
        guard case .ok(let status) = await fast.handle(.park(path: extra.path)) else {
            return XCTFail("park should be ok while Caddy is down")
        }
        XCTAssertFalse(status.running)
        XCTAssertTrue(fast.store.load().parked.contains(extra.path))
    }

    // MARK: - The development port helper given up on, or missing

    func testStartRecoversAfterThePortHelperIsGivenUpOn() async throws {
        let fast = Engine.development(paths: home.paths, settings: home.settings, backoffScale: 0.01)
        defer { fast.shutdown() }
        guard case .ok(let first) = await fast.handle(.start), first.running else { return XCTFail("start should be ok") }
        try await driveToGivenUp(fast, process: "ports")
        XCTAssertFalse(fast.status().running, "\(fast.status().processes)")

        guard case .ok(let status) = await fast.handle(.start) else { return XCTFail("start should recover") }
        XCTAssertTrue(status.running)
        XCTAssertTrue(status.processes["ports"]?.hasPrefix("running") == true, "\(status.processes)")
        XCTAssertEqual(PortCheck.holders(of: [home.settings.httpPort]).count, 1, "the helper holds the port again")
    }

    func testADevelopmentHomeWithoutPaddockPortsSaysSoAndStartsNothing() async throws {
        let bare = Engine(paths: home.paths, settings: home.settings, installAction: nil,
                          managesPortHelper: true, portHelper: nil, portHolders: TestSupport.portHoldersWithoutProbes)
        defer { bare.shutdown() }
        let response = await bare.handle(.start)
        XCTAssertEqual(response, .error(code: ErrorCode.internal, message: Messages.portHelperMissing))
        XCTAssertEqual(Messages.portHelperMissing, "Can't find paddock-ports next to paddockd.")
        XCTAssertFalse(bare.status().running)
        XCTAssertNil(bare.status().processes["caddy"], "nothing of the web stack was started")
        XCTAssertEqual(PortCheck.holders(of: [home.settings.httpPort, home.settings.httpsPort]), [])
    }

    // MARK: - Shutdown never waits for a PHP download

    /// Starts the web stack, then a PHP install that would take a minute, then shuts down.
    private func shutDownDuringSlowInstall(_ shutDown: @escaping (Engine) async -> Void) async throws {
        let started = expectation(description: "install started")
        let slow = Engine.development(paths: home.paths, settings: home.settings, installAction: { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        defer { slow.shutdown() }
        guard case .ok(let running) = await slow.handle(.start), running.running else {
            return XCTFail("start should be ok")
        }
        let pids = running.processes.values.compactMap(TestSupport.pid(from:))
        XCTAssertGreaterThanOrEqual(pids.count, 3, "\(running.processes)")
        let install = Task { await slow.handle(.installPHP(version: v84)) }
        await fulfillment(of: [started], timeout: 10)

        let began = Date()
        await shutDown(slow)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "shutdown waited for the download")
        let response = await install.value
        XCTAssertEqual(response, .error(code: ErrorCode.internal, message: Messages.phpInstallCancelled(v84)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.phpDir(v84).deletingLastPathComponent().path),
                       "nothing in the version directory")
        XCTAssertFalse(slow.status().running)
        for pid in pids {
            XCTAssertTrue(kill(pid, 0) != 0 && errno == ESRCH, "pid \(pid) of the web stack survived")
        }
    }

    func testShutDownAfterPendingWorkCancelsAnInstallInProgress() async throws {
        try await shutDownDuringSlowInstall { await $0.shutDownAfterPendingWork() }
    }

    func testAShutdownRequestCancelsAnInstallInProgress() async throws {
        try await shutDownDuringSlowInstall { engine in
            guard case .ok = await engine.handle(.shutdown) else { return XCTFail("shutdown should be ok") }
        }
    }
}
