import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The framework contracts every recipe inherits: orphans after a daemon crash, bounded initialise steps,
/// series and updates, the data's version, listening on this Mac only at run time, a minimal environment,
/// config files, and saved state that is never trusted blindly. Fake service, free high ports only.
final class ServiceLifecycleTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var engine: Engine?
    private var daemon: Process?
    private var children: [Process] = []
    private var groups: Set<Int32> = []

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        engine?.shutdown()
        engine = nil
        if let daemon, daemon.isRunning {
            kill(daemon.processIdentifier, SIGTERM)
            if !waitFor(15, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        // Only groups this test's daemons created.
        for group in groups where ((try? TestSupport.pgrep(group: group)) ?? []).isEmpty == false { kill(-group, SIGKILL) }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private func makeManager(_ recipes: [ServiceRecipe] = [FakeService.recipe()], readyTimeout: TimeInterval? = nil,
                             session: URLSession = .shared,
                             portCheck: ServicePortCheck = .withoutProbes,
                             log: @escaping @Sendable (String) -> Void = { _ in }) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     downloader: ArtifactDownloader(session: session), portCheck: portCheck,
                                     portBase: home.portBase, readyTimeout: readyTimeout, log: log)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String = "fake") -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func serviceError(_ body: () async throws -> Void) async -> ServiceError? {
        do { try await body(); return nil } catch { return error as? ServiceError }
    }

    private func pid(_ manager: ServiceManager, _ id: String = "fake") -> Int32? {
        manager.processes[ServiceManager.processName(id)].flatMap(TestSupport.pid(from:))
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    // MARK: - Orphans

    /// A daemon killed outright leaves its service running; the next daemon recognises it as its own
    /// (pid, start time, program under the recipe's binaries), stops it and starts a fresh one on the same port.
    func testANewDaemonReclaimsTheServiceAKilledDaemonLeftBehind() throws {
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [FakeService.recipe()])).write(to: catalog)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon(catalog: catalog)
        guard case .ok(let added) = try client.send(.serviceAdd(kind: "fake", version: nil), timeout: 60) else {
            return XCTFail("add")
        }
        _ = try client.send(.stop, timeout: 60) // Only the service should outlive the daemon.
        let orphan = try XCTUnwrap(added.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        groups.insert(orphan)
        let record = home.paths.serviceRun("fake").appendingPathComponent("pid")
        XCTAssertEqual(ServiceProcessRecord.read(from: record)?.pid, orphan)

        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        self.daemon = nil
        XCTAssertTrue(isAlive(orphan), "the service survives its daemon")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: home.fakePort))

        try launchDaemon(catalog: catalog)
        var fresh: Int32?
        XCTAssertTrue(waitFor(30) {
            guard case .ok(let status)? = try? client.send(.status, timeout: 5),
                  status.services.first?.state == .running,
                  let pid = status.processes["service-fake"].flatMap(TestSupport.pid(from:)) else { return false }
            fresh = pid
            return true
        }, "the service is running again")
        let newPid = try XCTUnwrap(fresh)
        groups.insert(newPid)
        XCTAssertNotEqual(newPid, orphan)
        XCTAssertTrue(waitFor(5) { !self.isAlive(orphan) }, "the orphan was stopped")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: home.fakePort), "same port")
        XCTAssertEqual(ServiceProcessRecord.read(from: record)?.pid, newPid)
    }

    /// A record that names a live process which isn't the service (the program is elsewhere) is stale: it is
    /// removed and that process is never signalled.
    func testARecordNamingAnUnrelatedProcessIsNeverSignalled() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let record = home.paths.serviceRun("fake").appendingPathComponent("pid")
        XCTAssertNil(ServiceProcessRecord.read(from: record), "a clean stop removes the record")

        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["60"]
        try sleep.run()
        children.append(sleep)
        let live = try XCTUnwrap(ServiceProcessRecord.live(pid: sleep.processIdentifier))
        // Exactly the sleep, and one that claims the service's own program.
        for claimed in [live.executable, FakeService.installed(paths: home.paths)] {
            try ServiceProcessRecord(pid: live.pid, pgid: live.pgid, startSeconds: live.startSeconds,
                                     startMicroseconds: live.startMicroseconds, executable: claimed).write(to: record)
            try manager.start("fake")
            XCTAssertTrue(sleep.isRunning, "never signalled (\(claimed))")
            XCTAssertEqual(status(manager)?.state, .running)
            XCTAssertNotEqual(ServiceProcessRecord.read(from: record)?.pid, sleep.processIdentifier)
            manager.stop("fake")
        }
    }

    // MARK: - Initialise steps

    func testAStepIgnoringSIGTERMEndsAtItsDeadlineAndTheEngineStaysResponsive() async throws {
        let engine = makeEngine([FakeService.recipe(initialiseArguments: ["--ignore-term", "--sleep", "60"],
                                                    initialiseTimeoutSeconds: 2)])
        let started = Date()
        let add = Task { await engine.handle(.serviceAdd(kind: "fake", version: nil)) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let probe = Date()
        _ = engine.status()
        XCTAssertLessThan(Date().timeIntervalSince(probe), 0.5, "status answers during the step")
        guard case .error(let code, let message) = await add.value else { return XCTFail("expected a timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(code, ErrorCode.serviceFailed)
        XCTAssertTrue(message.contains("longer than 2 seconds"), message)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
    }

    func testAStepLeavingAGrandchildOnStdoutDoesNotHang() async throws {
        let manager = makeManager([FakeService.recipe(initialiseArguments: ["--grandchild"], initialiseTimeoutSeconds: 5)])
        let started = Date()
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(status(manager)?.state, .running)
        XCTAssertTrue(manager.logTail("fake").contains("fake-service: initialising"))
    }

    func testShutdownDuringALongStepReturnsPromptly() async throws {
        let engine = makeEngine([FakeService.recipe(initialiseArguments: ["--ignore-term", "--sleep", "60"])])
        let add = Task { await engine.handle(.serviceAdd(kind: "fake", version: nil)) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let started = Date()
        await engine.shutDownAfterPendingWork()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        guard case .error(let code, _) = await add.value else { return XCTFail("expected cancelled") }
        XCTAssertEqual(code, ErrorCode.serviceCancelled)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
    }

    // MARK: - Series and updates

    private func remoteAsset(_ name: String) -> RecipeAsset {
        RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/\(name)")!,
                                       sha256: FakeService.asset.artifact.sha256),
                    archive: "binary", installAs: FakeService.installedName)
    }

    func testIDsAndAddingBySeriesOrVersion() async throws {
        let manager = makeManager([FakeService.recipe(version: "1.2.0", series: "1.2", seriesInID: true),
                                   FakeService.recipe(version: "1.2.1", series: "1.2", seriesInID: true),
                                   FakeService.recipe(version: "2.0.0", series: "2", seriesInID: true)])
        let byVersion = try await manager.add(kind: "fake", version: "1.2.0")
        XCTAssertEqual(byVersion.id, "fake-1-2")
        XCTAssertEqual(byVersion.name, "Fake 1.2")
        XCTAssertEqual(byVersion.series, "1.2")
        XCTAssertEqual(byVersion.version, "1.2.0")
        let bySeries = try await manager.add(kind: "fake", version: "1.2")
        XCTAssertEqual(bySeries.id, "fake-1-2-2")
        XCTAssertEqual(bySeries.version, "1.2.1", "a series means its newest patch")
        let newest = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(newest.id, "fake-2")
        XCTAssertEqual(newest.version, "2.0.0")
    }

    /// A newer patch whose files are on this Mac is taken at the next start; the version changes once it is
    /// ready, and the old binaries go when nothing else uses them.
    func testANewerLocalPatchIsTakenAtTheNextStart() async throws {
        let first = makeManager([FakeService.recipe(version: "1.0")])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let second = makeManager([FakeService.recipe(version: "1.0"), FakeService.recipe(version: "1.1")])
        XCTAssertEqual(status(second)?.updateAvailable, "1.1")
        try second.start("fake")
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.version, "1.1")
        XCTAssertNil(status(second)?.updateAvailable)
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first,
                       FakeService.installed(paths: home.paths, version: "1.1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "fake", version: "1.0").path),
                       "the old binaries are removed once the new ones run")
        XCTAssertTrue(try String(contentsOf: home.paths.serviceHome("fake").appendingPathComponent("data-version"),
                                 encoding: .utf8).contains("1.1"))
    }

    /// A newer patch that would need a download is never fetched unprompted: the old binaries keep running and
    /// the status offers the update; `update` downloads it and switches.
    func testARemotePatchWaitsForAnExplicitUpdate() async throws {
        let first = makeManager([FakeService.recipe(version: "1.0")])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBinaryURLProtocol.self]
        FakeBinaryURLProtocol.requests.value = 0
        let second = makeManager([FakeService.recipe(version: "1.0"),
                                  FakeService.recipe(version: "1.1", assets: [remoteAsset("fake-1.1")])],
                                 session: URLSession(configuration: configuration))
        try second.start("fake")
        XCTAssertEqual(FakeBinaryURLProtocol.requests.value, 0, "no unprompted download")
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.version, "1.0")
        XCTAssertEqual(status(second)?.updateAvailable, "1.1")
        XCTAssertEqual(status(second)?.state, .running)

        let updated = try await second.update("fake")
        XCTAssertEqual(updated.version, "1.1")
        XCTAssertEqual(FakeBinaryURLProtocol.requests.value, 1)
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertNil(status(second)?.updateAvailable)
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first,
                       FakeService.installed(paths: home.paths, version: "1.1"))
        let again = try await second.update("fake")
        XCTAssertEqual(again.version, "1.1", "up to date: nothing happens")
    }

    func testAFailedUpdateGoesBackToTheOldVersion() async throws {
        let first = makeManager([FakeService.recipe(version: "1.0")])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let broken = FakeService.recipe(version: "1.1", extraArguments: ["--no-listen"],
                                        assets: [remoteAsset("fake-1.1")], readyTimeoutSeconds: 2)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBinaryURLProtocol.self]
        let second = makeManager([FakeService.recipe(version: "1.0"), broken], session: URLSession(configuration: configuration))
        try second.start("fake")
        let error = await serviceError { _ = try await second.update("fake") }
        guard case .updateFailed(let name, let version, let previous, _)? = error else {
            return XCTFail("\(String(describing: error))")
        }
        XCTAssertEqual([name, version, previous], ["Fake", "1.1", "1.0"])
        XCTAssertEqual(status(second)?.state, .running, "back on the old binaries")
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.version, "1.0")
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first,
                       FakeService.installed(paths: home.paths, version: "1.0"))
    }

    /// The catalog dropping a series doesn't strand its instances while their binaries are there.
    func testAnInstanceOutlivesItsSeriesLeavingTheCatalog() async throws {
        let first = makeManager([FakeService.recipe(version: "1.0")])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let other = FakeService.recipe(kind: "other", displayName: "Other")
        let second = makeManager([other])
        XCTAssertEqual(status(second)?.state, .stopped)
        try second.start("fake")
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertEqual(status(second)?.displayName, "Fake")
        XCTAssertEqual(status(second)?.env.first, "FAKE_HOST=127.0.0.1")
        second.stopAll()

        try FileManager.default.removeItem(at: home.paths.serviceBin(kind: "fake", version: "1.0"))
        let third = makeManager([other])
        guard case .unavailable? = status(third)?.state else { return XCTFail("\(String(describing: status(third)))") }
        XCTAssertThrowsError(try third.start("fake"))
    }

    func testDataFromAnotherSeriesIsNeverStarted() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        try Data(#"{"kind": "fake", "series": "2", "version": "2.0"}"#.utf8)
            .write(to: home.paths.serviceHome("fake").appendingPathComponent("data-version"))
        XCTAssertThrowsError(try manager.start("fake")) { error in
            XCTAssertTrue(Messages.serviceError(error as! ServiceError).contains("2.0"), "\(error)")
        }
        guard case .unavailable? = status(manager)?.state else { return XCTFail() }
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    /// An instance saved before series existed gets its series from the catalog.
    func testAnInstanceSavedWithoutASeriesStillRuns() async throws {
        let manager = makeManager([FakeService.recipe(version: "1.0", series: "1")])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stopAll()
        var text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        text = text.replacingOccurrences(of: #""series" : "1","#, with: "")
        XCTAssertFalse(text.contains("\"series\""))
        try Data(text.utf8).write(to: home.paths.stateFile)
        let again = makeManager([FakeService.recipe(version: "1.0", series: "1")])
        XCTAssertEqual(status(again)?.series, "1")
        try again.start("fake")
        XCTAssertEqual(status(again)?.state, .running)
    }

    // MARK: - Running

    func testAServiceListeningBeyondThisMacIsStopped() async throws {
        let manager = makeManager([FakeService.recipe(extraArguments: ["--any-address"])])
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        guard case .notLoopback(let name, let address)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(name, "Fake")
        XCTAssertTrue(address.hasPrefix("*:"), address)
        XCTAssertEqual(Messages.serviceError(error!),
                       "Fake tried to listen on \(address), which is not this Mac only. Paddock stopped it.")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort), "stopped")
        XCTAssertNotEqual(status(manager)?.state, .running)
    }

    func testServicesGetAMinimalEnvironmentAndTheirConfigFiles() async throws {
        setenv("PADDOCK_LEAK_CHECK", "leaked", 1)
        defer { unsetenv("PADDOCK_LEAK_CHECK") }
        let recipe = FakeService.recipe(configFiles: [RecipeFile(path: "{config}/fake.conf", contents: "port = {port.main}\n")])
        let manager = makeManager([recipe])
        _ = try await manager.add(kind: "fake", version: nil)
        let env = Set(FakeService.environment(paths: home.paths, id: "fake"))
        XCTAssertEqual(env, ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(home.paths.serviceData("fake").path)",
                             "TMPDIR=\(home.paths.serviceRun("fake").path)", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"])
        let conf = home.paths.serviceConfig("fake").appendingPathComponent("fake.conf")
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "port = \(home.fakePort)\n")
        try Data("edited".utf8).write(to: conf)
        try manager.restart("fake")
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "port = \(home.fakePort)\n", "rewritten on start")
    }

    /// A port that was free when chosen but is taken by the time the download is done is chosen again;
    /// nothing was saved before that point.
    func testPortsAreCheckedAgainAfterTheDownload() async throws {
        let calls = LockedCounter()
        let preferred = home.fakePort
        let check = ServicePortCheck(isFree: { port in
            if port == preferred { return calls.next() == 0 } // free at first, taken afterwards
            return !PortCheck.accepts(port: port)
        }, holders: TestSupport.portHoldersWithoutProbes)
        let manager = makeManager(portCheck: check)
        let instance = try await manager.add(kind: "fake", version: nil)
        XCTAssertNotEqual(instance.ports["main"], preferred)
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.ports["main"], instance.ports["main"])
    }

    /// Saved ids are checked again before any path is built from them: a hand-edited `..` is ignored.
    func testAnInvalidSavedIDIsNeverActedOn() async throws {
        let canary = home.root.deletingLastPathComponent().appendingPathComponent("pdk-canary-\(UUID().uuidString)")
        try Data("alive".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }
        let inHome = home.paths.home.appendingPathComponent("keep")
        try Data("alive".utf8).write(to: inHome)
        let hostile = ServiceInstance(id: "..", kind: "fake", series: "1", version: "1.0", name: "Evil",
                                      ports: ["main": home.fakePort], autostart: true, createdAt: Date())
        try StateStore(paths: home.paths).update { $0.services = [hostile] }
        let lines = LockedBox<[String]>([])
        let manager = makeManager(log: { line in lines.value.append(line) })
        XCTAssertEqual(manager.statuses(), [])
        XCTAssertThrowsError(try manager.remove("..", deleteData: true))
        XCTAssertThrowsError(try manager.remove("Evil", deleteData: true))
        manager.startAutostart()
        XCTAssertEqual(lines.value.filter { $0.contains("\"..\"") }.count, 1, "\(lines.value)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.stateFile.path))
    }

    // MARK: - Engine and daemon

    private func makeEngine(_ recipes: [ServiceRecipe]) -> Engine {
        var settings = Settings()
        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53595)
        let engine = Engine(paths: home.paths, settings: settings, installAction: nil, managesPortHelper: true,
                            portHelper: TestSupport.portHelper, portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: recipes), portBase: home.portBase,
                                                       portCheck: .withoutProbes),
                            log: { _ in })
        self.engine = engine
        return engine
    }

    private func launchDaemon(catalog: URL) throws {
        try TestSupport.requireVendored()
        let process = Process()
        process.executableURL = Bundle(for: ServiceHome.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("paddockd")
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        let http = TestSupport.freeTCPPort()
        env["PADDOCK_HTTP_PORT"] = "\(http)"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort(excluding: [http]))"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53594))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServiceCatalog.overrideVariable] = catalog.path
        env[ServicePorts.portBaseVariable] = "\(home.portBase)"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        guard waitFor(40, { PaddockClient(paths: self.home.paths).daemonIsRunning }) else {
            XCTFail("daemon did not answer")
            throw XCTSkip("daemon did not answer")
        }
        // Remember the web side's groups too, so a killed daemon's leftovers are swept in tearDown.
        if case .ok(let status)? = try? PaddockClient(paths: home.paths).send(.status, timeout: 5) {
            for description in status.processes.values { if let pid = TestSupport.pid(from: description) { groups.insert(pid) } }
        }
    }
}

/// Serves the built fake service's bytes for any URL, counting requests.
final class FakeBinaryURLProtocol: URLProtocol {
    static let requests = LockedBox(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.value += 1
        let data = (try? Data(contentsOf: FakeService.binary)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
