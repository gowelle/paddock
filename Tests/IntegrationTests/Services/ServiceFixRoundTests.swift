import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The first review's fixes, with the fake service on free high ports: stale lock files, readiness that
/// means "accepting connections", actions that never hold up a stop or a shutdown, and services stopped
/// side by side.
final class ServiceFixRoundTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var engine: Engine?
    private var children: [Process] = []

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        engine?.shutdown()
        engine = nil
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private static let locks = ["{data}/fake.pid", "{run}/lock-{port.main}"]

    private func makeManager(_ recipes: [ServiceRecipe], readyTimeout: TimeInterval? = nil) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     portCheck: .withoutProbes, portBase: home.portBase, readyTimeout: readyTimeout)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String = "fake") -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func start(_ program: URL, _ arguments: [String]) throws -> Process {
        let p = Process()
        p.executableURL = program
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        children.append(p)
        return p
    }

    private var pidLock: URL { home.paths.serviceData("fake").appendingPathComponent("fake.pid") }
    private func runLock(_ port: Int) -> URL { home.paths.serviceRun("fake").appendingPathComponent("lock-\(port)") }

    /// A fake that, like PostgreSQL, refuses to start while its lock file names a live process.
    private var lockingFake: ServiceRecipe {
        FakeService.recipe(extraArguments: ["--lock", "{data}/fake.pid"], lockFiles: Self.locks)
    }

    // MARK: - A1: stale lock files

    /// After an unclean shutdown the pid in a lock file may belong to some other process now: the file is
    /// removed (that process is never signalled) and the service starts.
    func testAStaleLockNamingAnUnrelatedProcessIsRemoved() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let other = try start(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        try Data("\(other.processIdentifier)\n/old/data\n".utf8).write(to: pidLock)
        try Data("\(other.processIdentifier)\n".utf8).write(to: runLock(home.fakePort))

        try manager.start("fake")
        XCTAssertEqual(status(manager)?.state, .running)
        XCTAssertTrue(other.isRunning, "never signalled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLock(home.fakePort).path))
        let pid = try XCTUnwrap(manager.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try String(contentsOf: pidLock, encoding: .utf8).components(separatedBy: "\n").first, "\(pid)",
                       "the stale lock was replaced by the new process's own")
    }

    /// A lock naming a live process of this service's own binaries is left alone and the start refused:
    /// something else runs on that data, and Paddock never starts a second copy over it.
    func testALockNamingALiveCopyOfTheServiceRefusesTheStart() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let elsewhere = home.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = try start(URL(fileURLWithPath: FakeService.installed(paths: home.paths)),
                             ["serve", elsewhere.path, "--no-listen"])
        XCTAssertTrue(waitFor(5) { FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("args").path) })
        let text = "\(copy.processIdentifier)\n\(elsewhere.path)\n"
        try Data(text.utf8).write(to: pidLock)

        XCTAssertThrowsError(try manager.start("fake")) { error in
            guard case .unavailable(let name, let reason)? = error as? ServiceError else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "Fake")
            XCTAssertTrue(reason.contains("already running") && reason.contains("\(copy.processIdentifier)"), reason)
        }
        XCTAssertTrue(copy.isRunning, "never signalled")
        XCTAssertEqual(try String(contentsOf: pidLock, encoding: .utf8), text, "left alone")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    /// A lock file that is a symlink is neither followed nor removed: the start is refused.
    func testASymlinkedLockFileIsNotFollowed() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let other = try start(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        let target = home.root.appendingPathComponent("elsewhere.pid")
        try Data("\(other.processIdentifier)\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: pidLock, withDestinationURL: target)

        XCTAssertThrowsError(try manager.start("fake")) { error in
            guard case .unavailable(_, let reason)? = error as? ServiceError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("fake.pid"), reason)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pidLock.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "\(other.processIdentifier)\n")
        XCTAssertTrue(other.isRunning)
    }

    // MARK: - A2: readiness by command

    /// The fake accepts connections at once, but its readiness command says yes only two seconds later: until
    /// then it is starting.
    func testAServiceIsStartingUntilItsReadinessCommandSaysReady() async throws {
        let ready = Readiness.command(RecipeCommand(executable: "{bin}/\(FakeService.installedName)",
                                                    arguments: ["ready", "{data}", "2000"]))
        let manager = makeManager([FakeService.recipe(ready: ready)])
        let began = Date()
        let add = Task { try await manager.add(kind: "fake", version: nil) }
        XCTAssertTrue(waitFor(10) { PortCheck.acceptsIPv4(port: self.home.fakePort) }, "listening")
        XCTAssertEqual(status(manager)?.state, .starting, "listening is not ready")
        _ = try await add.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 2)
        XCTAssertEqual(status(manager)?.state, .running)

        // Stop and start wait the same way.
        manager.stop("fake")
        let again = Date()
        try manager.start("fake")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(again), 2)
    }

    func testAReadinessCommandThatNeverSucceedsIsNotReady() async throws {
        let ready = Readiness.command(RecipeCommand(executable: "{bin}/\(FakeService.installedName)",
                                                    arguments: ["ready", "{data}", "600000"]))
        let manager = makeManager([FakeService.recipe(ready: ready)], readyTimeout: 2)
        do {
            _ = try await manager.add(kind: "fake", version: nil)
            XCTFail("added")
        } catch let error as ServiceError {
            guard case .notReady = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(status(manager)?.state, .crashed)
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    // MARK: - A5: actions never hold up a stop or a shutdown

    private var slowAction: RecipeAction {
        RecipeAction(command: RecipeCommand(executable: "{bin}/\(FakeService.installedName)",
                                            arguments: ["init", "{data}/slow", "--sleep", "8"]),
                     parameters: [RecipeParameter(name: "database", pattern: "^[a-z]+$")])
    }

    func testStoppingTheServiceCancelsItsActionAtOnce() async throws {
        let manager = makeManager([FakeService.recipe(actions: [RecipeAction.createDatabase: slowAction])])
        _ = try await manager.add(kind: "fake", version: nil)
        let action = Task.detached { () -> ServiceError? in
            do { _ = try manager.createDatabase("fake", database: "slow"); return nil } catch { return error as? ServiceError }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let stopping = Date()
        manager.stop("fake")
        XCTAssertLessThan(Date().timeIntervalSince(stopping), 5, "the stop did not wait for the action")
        let outcome = await action.value
        XCTAssertEqual(outcome, .actionCancelled(name: "Fake", action: RecipeAction.createDatabase))
        XCTAssertEqual(status(manager)?.state, .stopped)
    }

    func testShutdownDuringALongActionReturnsPromptly() async throws {
        var settings = Settings()
        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53591)
        let recipe = FakeService.recipe(actions: [RecipeAction.createDatabase: slowAction])
        let engine = Engine(paths: home.paths, settings: settings, installAction: nil, managesPortHelper: true,
                            portHelper: TestSupport.portHelper, portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [recipe]), portBase: home.portBase,
                                                       portCheck: .withoutProbes),
                            log: { _ in })
        self.engine = engine
        guard case .ok = await engine.handle(.serviceAdd(kind: "fake", version: nil)) else { return XCTFail("add") }
        let create = Task { await engine.handle(.serviceCreateDatabase(name: "fake", database: "slow")) }
        try await Task.sleep(nanoseconds: 700_000_000)
        let began = Date()
        await engine.shutDownAfterPendingWork()
        XCTAssertLessThan(Date().timeIntervalSince(began), 6, "shutdown did not wait for the action")
        guard case .error(let code, let message) = await create.value else { return XCTFail("not cancelled") }
        XCTAssertEqual(code, ErrorCode.serviceCancelled)
        XCTAssertEqual(message, "Creating the database in Fake was cancelled.")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    // MARK: - A6: services stop side by side

    /// Two services that ignore their stop signal, each with two seconds' grace: stopping both takes about
    /// two seconds, not four.
    func testServicesAreStoppedSideBySide() async throws {
        let first = FakeService.recipe(extraArguments: ["--ignore-term"], stopGraceSeconds: 2)
        let second = FakeService.recipe(kind: "other", displayName: "Other",
                                        ports: [RecipePort(name: "main", preferred: FakeService.preferredPort + 1)],
                                        extraArguments: ["--ignore-term"], socket: "{run}/other.sock", stopGraceSeconds: 2)
        let manager = makeManager([first, second])
        _ = try await manager.add(kind: "fake", version: nil)
        _ = try await manager.add(kind: "other", version: nil)
        let began = Date()
        manager.stopAll()
        let took = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(took, 1.9)
        XCTAssertLessThan(took, 3.5, "stopped side by side, not one after another")
        XCTAssertEqual(manager.statuses().map(\.state), [.stopped, .stopped])
    }
}
