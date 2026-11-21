import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The service framework, end to end, with the fake service (no download): adding, starting, stopping,
/// removing, ports, failures and the daemon's lifecycle. Every port is a free high one.
final class ServiceFrameworkTests: XCTestCase {
    private var home: ServiceHome!
    private var manager: ServiceManager?
    private var engine: Engine?
    private var listeners: [Int32] = []
    private var daemon: Process?

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        manager?.stopAll()
        manager = nil
        engine?.shutdown()
        engine = nil
        if let daemon, daemon.isRunning {
            kill(daemon.processIdentifier, SIGTERM)
            if !waitFor(15, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        for fd in listeners { close(fd) }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private func makeManager(_ recipes: [ServiceRecipe] = [FakeService.recipe()], home: ServiceHome? = nil,
                             readyTimeout: TimeInterval = Readiness.deadline,
                             downloader: ArtifactDownloader = ArtifactDownloader()) -> ServiceManager {
        let home = home ?? self.home!
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     downloader: downloader, portCheck: .withoutProbes, portBase: home.portBase,
                                     readyTimeout: readyTimeout)
        self.manager = manager
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String) -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func listen(_ port: Int) throws {
        listeners.append(try listenReusingAddress(port: port))
    }

    private func serviceError(_ body: () async throws -> Void) async -> ServiceError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? ServiceError
        }
    }

    // MARK: - Add, stop, start

    func testAddInitialisesStartsAndWaitsUntilReady() async throws {
        let manager = makeManager()
        let instance = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(instance.id, "fake")
        XCTAssertEqual(instance.name, "Fake")
        XCTAssertEqual(instance.ports, ["main": home.portBase + 100], "the preferred port, moved by the test base")
        XCTAssertTrue(instance.autostart)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [instance])

        let status = try XCTUnwrap(self.status(manager, "fake"))
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.mainPort, home.portBase + 100)
        XCTAssertTrue(PortCheck.acceptsIPv4(port: home.portBase + 100), "ready means it accepts connections")
        let socket = home.paths.serviceRun("fake").appendingPathComponent("fake.sock").path
        XCTAssertEqual(status.env, ["FAKE_HOST=127.0.0.1", "FAKE_PORT=\(home.portBase + 100)", "FAKE_SOCKET=\(socket)"])
        XCTAssertEqual(try manager.env("FAKE"), status.env)
        XCTAssertEqual(status.openURL, "http://127.0.0.1:\(home.portBase + 100)")
        XCTAssertEqual(status.dataPath, home.paths.serviceData("fake").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceData("fake")
            .appendingPathComponent("initialised").path), "initialise ran in {data}")
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake"),
                       [FakeService.binary.path, "serve", home.paths.serviceData("fake").path,
                        "--port", "\(home.portBase + 100)", "--socket", socket, "--name", "Fake"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceConfig("fake").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceLog("fake").path))
    }

    func testStopAndStartKeepTheDataAndDoNotInitialiseAgain() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        let port = home.portBase + 100
        let marker = home.paths.serviceData("fake").appendingPathComponent("initialised")
        try FileManager.default.removeItem(at: marker)

        manager.stop("fake")
        XCTAssertEqual(status(manager, "fake")?.state, .stopped)
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceData("fake")
            .appendingPathComponent("stopped").path), "stopped cleanly by its stop signal")

        try manager.start("Fake")
        XCTAssertEqual(status(manager, "fake")?.state, .running)
        XCTAssertTrue(PortCheck.acceptsIPv4(port: port))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "initialise runs only when data is new")

        try manager.restart("fake")
        XCTAssertEqual(status(manager, "fake")?.state, .running)
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.ports, ["main": port], "the port stays")
    }

    // MARK: - Remove

    func testRemoveKeepsTheDataAndReAddingReusesIt() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        let data = home.paths.serviceData("fake")
        try Data("precious".utf8).write(to: data.appendingPathComponent("rows"))
        try FileManager.default.removeItem(at: data.appendingPathComponent("initialised"))

        let path = try manager.remove("fake", deleteData: false)
        XCTAssertEqual(path, data)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertEqual(manager.statuses(), [])
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.portBase + 100), "removing stops it")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("rows"), encoding: .utf8), "precious")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceConfig("fake").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceRun("fake").path))

        let again = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(again.id, "fake")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("initialised").path),
                       "never initialised over existing data")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("rows"), encoding: .utf8), "precious")
        XCTAssertEqual(status(manager, "fake")?.notice, "Found existing data for Fake; using it.")
        XCTAssertEqual(status(manager, "fake")?.state, .running)
    }

    func testRemoveWithDeleteDataDeletesIt() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        let path = try manager.remove("FAKE", deleteData: true)
        XCTAssertEqual(path, home.paths.serviceData("fake"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
    }

    func testUnknownNamesAndKinds() async throws {
        let manager = makeManager()
        let unknownKind = await serviceError { _ = try await manager.add(kind: "nope", version: nil) }
        XCTAssertEqual(unknownKind, .unknownKind("nope", available: ["fake"]))
        let unknownVersion = await serviceError { _ = try await manager.add(kind: "fake", version: "9") }
        XCTAssertEqual(unknownVersion, .unknownVersion(kind: "fake", version: "9", available: ["1.0"]))
        XCTAssertThrowsError(try manager.start("nope")) { XCTAssertEqual($0 as? ServiceError, .unknownService("nope")) }
        XCTAssertThrowsError(try manager.remove("nope", deleteData: true)) {
            XCTAssertEqual($0 as? ServiceError, .unknownService("nope"))
        }
    }

    // MARK: - Ports

    func testASecondAddGetsTheNextPortAndItsOwnFolder() async throws {
        let manager = makeManager()
        let first = try await manager.add(kind: "fake", version: nil)
        let second = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(second.id, "fake-2")
        XCTAssertEqual(second.name, "Fake (2)")
        let port = try XCTUnwrap(second.ports["main"])
        XCTAssertGreaterThan(port, try XCTUnwrap(first.ports["main"]))
        XCTAssertLessThanOrEqual(port, home.portBase + 100 + ServicePorts.searchLimit)
        XCTAssertEqual(manager.statuses().map(\.state), [.running, .running])
        XCTAssertNotEqual(home.paths.serviceData("fake"), home.paths.serviceData("fake-2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceData("fake-2")
            .appendingPathComponent("initialised").path))
        XCTAssertTrue(try manager.env("Fake (2)").contains("FAKE_PORT=\(port)"))
    }

    func testTwoAddsAtOnceAreSerialized() async throws {
        let manager = makeManager()
        async let a = manager.add(kind: "fake", version: nil)
        async let b = manager.add(kind: "fake", version: nil)
        let added = try await [a, b]
        XCTAssertEqual(Set(added.map(\.id)), ["fake", "fake-2"])
        XCTAssertEqual(Set(added.compactMap { $0.ports["main"] }).count, 2)
        XCTAssertEqual(Set(StateStore(paths: home.paths).load().services.map(\.id)), ["fake", "fake-2"])
    }

    func testPreferredPortTakenUsesTheNextFreeOneEverywhere() async throws {
        try listen(home.portBase + 100)
        let manager = makeManager()
        let instance = try await manager.add(kind: "fake", version: nil)
        let port = try XCTUnwrap(instance.ports["main"])
        XCTAssertNotEqual(port, home.portBase + 100)
        XCTAssertGreaterThan(port, home.portBase + 100)
        XCTAssertTrue(try manager.env("fake").contains("FAKE_PORT=\(port)"))
        XCTAssertEqual(status(manager, "fake")?.state, .running)
    }

    func testSavedPortTakenAtALaterStartIsPortInUseAndOthersKeepRunning() async throws {
        let manager = makeManager()
        let first = try await manager.add(kind: "fake", version: nil)
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let port = try XCTUnwrap(first.ports["main"])
        try listen(port)

        XCTAssertThrowsError(try manager.start("fake")) { error in
            guard case .portInUse(let name, let busy, let holder)? = error as? ServiceError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, "Fake")
            XCTAssertEqual(busy, port)
            XCTAssertFalse(holder.isEmpty)
        }
        guard case .portInUse(let holder)? = status(manager, "fake")?.state else {
            return XCTFail("\(String(describing: status(manager, "fake")))")
        }
        XCTAssertEqual(Messages.printable(holder, limit: 200), holder, "the holder's name is sanitised")
        XCTAssertEqual(status(manager, "fake-2")?.state, .running, "the other instance keeps running")
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.ports["main"], port, "the port never moves")

        for fd in listeners { close(fd) }
        listeners = []
        try manager.start("fake")
        XCTAssertEqual(status(manager, "fake")?.state, .running)
    }

    // MARK: - Failures

    func testAFailingInitialiseLeavesNoInstanceAndNoFolder() async throws {
        let manager = makeManager([FakeService.recipe(initialiseFailure: "the init step broke")])
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        guard case .initialiseFailed(let name, let output)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(name, "Fake")
        XCTAssertTrue(output.contains("the init step broke"), output)
        XCTAssertTrue(Messages.serviceError(try XCTUnwrap(error)).contains("the init step broke"))
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceRun("fake").path))
        XCTAssertEqual(manager.statuses(), [])
    }

    func testAChecksumMismatchInstallsNothing() async throws {
        let archive = home.root.appendingPathComponent("fake.tar.gz")
        try Data("not what the catalog says".utf8).write(to: archive)
        let asset = RecipeAsset(artifact: Artifact(url: archive, sha256: String(repeating: "0", count: 64)),
                                archive: "tar.gz")
        let manager = makeManager([FakeService.recipe(assets: [asset])])
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        XCTAssertEqual(error, .installFailed(name: "Fake", reason: .checksumMismatch(file: "fake.tar.gz")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "fake", version: "1.0").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.paths.home.path)
            .filter { $0.hasPrefix(".service-install-") }
        XCTAssertEqual(leftovers, [], "no staging folder left behind")
    }

    func testAServiceThatNeverBecomesReadyIsStoppedAndCrashedWithItsLog() async throws {
        let manager = makeManager([FakeService.recipe(extraArguments: ["--no-listen"])], readyTimeout: 1.5)
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        guard case .notReady(let name, let log)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(name, "Fake")
        XCTAssertTrue(log.contains("fake-service: starting"), log)
        XCTAssertEqual(status(manager, "fake")?.state, .crashed)
        XCTAssertEqual(StateStore(paths: home.paths).load().services.map(\.id), ["fake"],
                       "saved before it started: it can be started again or removed")
        XCTAssertTrue(waitFor(5) {
            FileManager.default.fileExists(atPath: self.home.paths.serviceData("fake").appendingPathComponent("stopped").path)
        }, "the process was stopped")
    }

    // MARK: - Sockets

    func testALongHomeRunsTCPOnlyAndTheEnvSaysSo() async throws {
        let long = try ServiceHome(longFolder: true)
        defer { long.cleanUp() }
        let manager = makeManager(home: long)
        XCTAssertGreaterThan(long.paths.serviceRun("fake").appendingPathComponent("fake.sock").path.utf8.count, 103)
        _ = try await manager.add(kind: "fake", version: nil)
        let env = try manager.env("fake")
        XCTAssertEqual(env, ["FAKE_HOST=127.0.0.1", "FAKE_PORT=\(long.portBase + 100)",
                             "# Unix socket disabled: Paddock's folder path is too long"])
        let arguments = FakeService.arguments(paths: long.paths, id: "fake")
        let socketIndex = try XCTUnwrap(arguments.firstIndex(of: "--socket"))
        XCTAssertEqual(arguments[socketIndex + 1], "", "{socket} renders as nothing")
        XCTAssertEqual(status(manager, "fake")?.state, .running)
        manager.stopAll()
    }

    // MARK: - Through the engine

    private func makeEngine(_ recipes: [ServiceRecipe] = [FakeService.recipe()],
                            session: URLSession = .shared) -> Engine {
        var settings = Settings()
        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53598)
        let engine = Engine(paths: home.paths, settings: settings, installAction: nil, managesPortHelper: true,
                            portHelper: TestSupport.portHelper, portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: recipes), portBase: home.portBase,
                                                       session: session, portCheck: .withoutProbes),
                            log: { _ in })
        self.engine = engine
        return engine
    }

    func testStatusAnswersAtOnceWhileAServiceIsStarting() async throws {
        let engine = makeEngine([FakeService.recipe(extraArguments: ["--delay", "2500"])])
        let add = Task { await engine.handle(.serviceAdd(kind: "fake", version: nil)) }
        XCTAssertTrue(waitFor(10) { engine.status().services.first?.state == .starting })
        let started = Date()
        let status = engine.status()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(status.services.map(\.state), [.starting])
        guard case .catalog(let entries) = await engine.handle(.serviceCatalog) else { return XCTFail("catalog") }
        XCTAssertEqual(entries.map(\.kind), ["fake"], "the catalog answers while an add is in progress")
        guard case .ok(let done) = await add.value else { return XCTFail("add failed") }
        XCTAssertEqual(done.services.map(\.state), [.running])
    }

    func testEngineRequestsAndErrorCodes() async throws {
        let engine = makeEngine()
        guard case .error(let code, let message) = await engine.handle(.serviceAdd(kind: "nope", version: nil)) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(code, ErrorCode.unknownServiceKind)
        XCTAssertTrue(message.contains("fake"), "lists the available kinds: \(message)")
        guard case .ok(let added) = await engine.handle(.serviceAdd(kind: "fake", version: nil)) else {
            return XCTFail("add")
        }
        XCTAssertEqual(added.services.map(\.id), ["fake"])
        XCTAssertNotNil(added.processes["service-fake"], "service processes are listed with the others")
        guard case .ok(let stopped) = await engine.handle(.serviceStop(name: "fake")) else { return XCTFail("stop") }
        XCTAssertEqual(stopped.services.first?.state, .stopped)
        guard case .ok(let started) = await engine.handle(.serviceStart(name: "Fake")) else { return XCTFail("start") }
        XCTAssertEqual(started.services.first?.state, .running)
        guard case .ok = await engine.handle(.serviceRestart(name: "fake")) else { return XCTFail("restart") }
        guard case .error(let unknown, _) = await engine.handle(.serviceStop(name: "nope")) else { return XCTFail() }
        XCTAssertEqual(unknown, ErrorCode.unknownService)

        _ = await engine.handle(.serviceStop(name: "fake"))
        try listen(home.portBase + 100)
        guard case .error(let busy, let busyMessage) = await engine.handle(.serviceStart(name: "fake")) else {
            return XCTFail("expected port in use")
        }
        XCTAssertEqual(busy, ErrorCode.servicePortInUse)
        XCTAssertTrue(busyMessage.contains("\(home.portBase + 100)"), busyMessage)

        guard case .removed(let path, let status) = await engine.handle(.serviceRemove(name: "fake", deleteData: false))
        else { return XCTFail("remove") }
        XCTAssertEqual(path, home.paths.serviceData("fake").path)
        XCTAssertEqual(status.services, [])
    }

    /// The web side stopping leaves services running; the daemon shutting down stops them and their
    /// whole process group.
    func testWebStopLeavesServicesRunningAndShutdownStopsThem() async throws {
        let engine = makeEngine()
        guard case .ok(let added) = await engine.handle(.serviceAdd(kind: "fake", version: nil)) else {
            return XCTFail("add")
        }
        let pid = try XCTUnwrap(added.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        engine.stop()
        XCTAssertEqual(engine.status().services.first?.state, .running)
        XCTAssertFalse(try TestSupport.pgrep(group: pid).isEmpty)

        await engine.shutDownAfterPendingWork()
        XCTAssertEqual(try TestSupport.pgrep(group: pid), [], "nothing of the service is left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceData("fake")
            .appendingPathComponent("stopped").path), "stopped with its stop signal")
    }

    /// An add downloading when the daemon shuts down is cancelled: shutdown never waits for a download,
    /// and nothing of the add is kept.
    func testShutdownCancelsAnAddThatIsDownloading() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let asset = RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/fake.tar.gz")!,
                                                   sha256: String(repeating: "0", count: 64)), archive: "tar.gz")
        let engine = makeEngine([FakeService.recipe(assets: [asset])], session: session)
        let add = Task { await engine.handle(.serviceAdd(kind: "fake", version: nil)) }
        XCTAssertTrue(waitFor(10) { StallingURLProtocol.started.value })
        let started = Date()
        await engine.shutDownAfterPendingWork()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        guard case .error(_, let message) = await add.value else { return XCTFail("expected cancelled") }
        XCTAssertTrue(message.contains("cancelled"), message)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "fake", version: "1.0").path))
    }

    // MARK: - The daemon

    func testTheDaemonRestoresAutostartServicesAndStopsThemOnExit() throws {
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [FakeService.recipe()])).write(to: catalog)
        let client = PaddockClient(paths: home.paths)

        try launchDaemon(catalog: catalog)
        guard case .ok(let added) = try client.send(.serviceAdd(kind: "fake", version: nil), timeout: 60) else {
            return XCTFail("add")
        }
        let port = home.portBase + 100
        XCTAssertEqual(added.services.first?.ports, ["main": port])
        let firstGroup = try XCTUnwrap(added.processes["service-fake"].flatMap(TestSupport.pid(from:)))

        try stopDaemon()
        XCTAssertEqual(try TestSupport.pgrep(group: firstGroup), [], "the service stopped with the daemon")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))

        try launchDaemon(catalog: catalog)
        XCTAssertTrue(waitFor(30) {
            guard case .ok(let status)? = try? client.send(.status, timeout: 5) else { return false }
            return status.services.first?.state == .running
        }, "the autostart service came back")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: port))
        guard case .ok(let status) = try client.send(.status, timeout: 5) else { return XCTFail("status") }
        let secondGroup = try XCTUnwrap(status.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        try stopDaemon()
        XCTAssertEqual(try TestSupport.pgrep(group: secondGroup), [])
    }

    private func launchDaemon(catalog: URL) throws {
        let binary = Bundle(for: ServiceHome.self).bundleURL.deletingLastPathComponent().appendingPathComponent("paddockd")
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        env["PADDOCK_HTTP_PORT"] = "\(TestSupport.freeTCPPort())"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort())"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53597))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServiceCatalog.overrideVariable] = catalog.path
        env[ServicePorts.portBaseVariable] = "\(home.portBase)"
        process.environment = env
        let log = home.root.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        guard waitFor(40, { PaddockClient(paths: self.home.paths).daemonIsRunning }) else {
            XCTFail("daemon did not answer: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
            throw XCTSkip("daemon did not answer")
        }
    }

    private func stopDaemon() throws {
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGTERM)
        XCTAssertTrue(waitFor(30) { !daemon.isRunning }, "daemon exited")
        XCTAssertEqual(daemon.terminationStatus, 0)
        self.daemon = nil
    }
}

/// Starts every request and never answers: a download that only ends when cancelled.
final class StallingURLProtocol: URLProtocol {
    static let started = LockedBox(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.value = true }
    override func stopLoading() {}
}

extension ServicePortCheck {
    /// Connection checks as in the daemon, but a hidden holder is never probed over HTTP or launchd.
    static let withoutProbes = ServicePortCheck(isFree: { !PortCheck.accepts(port: $0) },
                                                holders: TestSupport.portHoldersWithoutProbes)
}
