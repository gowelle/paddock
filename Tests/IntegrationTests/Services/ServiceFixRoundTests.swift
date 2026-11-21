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

    private func makeManager(_ recipes: [ServiceRecipe], readyTimeout: TimeInterval? = nil,
                             inspector: ServiceProcessInspector = .live,
                             log: @escaping @Sendable (String) -> Void = { _ in }) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     portCheck: .withoutProbes, portBase: home.portBase, readyTimeout: readyTimeout,
                                     processInspector: inspector, log: log)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String = "fake") -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func start(_ program: URL, _ arguments: [String], in directory: URL? = nil) throws -> Process {
        let p = Process()
        p.executableURL = program
        p.arguments = arguments
        if let directory { p.currentDirectoryURL = directory }
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

    /// A pid that names nobody any more (`true`, already reaped).
    private func deadPid() throws -> Int32 {
        let p = try start(URL(fileURLWithPath: "/usr/bin/true"), [])
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// A lock naming this instance's own server (its program, running in this instance's folder) is left
    /// alone and the start refused: Paddock never starts a second copy over the same data.
    func testALockNamingThisInstancesOwnServerRefusesTheStart() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let elsewhere = home.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = try start(URL(fileURLWithPath: FakeService.installed(paths: home.paths)),
                             ["serve", elsewhere.path, "--no-listen"], in: home.paths.serviceData("fake"))
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

    /// A pid reused by a live server of ANOTHER instance of the same kind (same binaries, its own folder) is
    /// not this instance's: the lock is removed, the start succeeds, and the other server keeps serving.
    func testALockNamingAnotherInstanceOfTheSameKindIsRemoved() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        let other = home.root.appendingPathComponent("other-instance", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherPort = TestSupport.freeTCPPort(excluding: [home.fakePort])
        let copy = try start(URL(fileURLWithPath: FakeService.installed(paths: home.paths)),
                             ["serve", other.path, "--port", "\(otherPort)"], in: other)
        XCTAssertTrue(waitFor(5) { PortCheck.acceptsIPv4(port: otherPort) })
        try Data("\(copy.processIdentifier)\n".utf8).write(to: pidLock)
        try Data("\(copy.processIdentifier)\n".utf8).write(to: runLock(home.fakePort))

        try manager.start("fake")
        XCTAssertEqual(status(manager)?.state, .running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLock(home.fakePort).path))
        XCTAssertTrue(copy.isRunning, "never signalled")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: otherPort), "the other instance still serves")
    }

    /// A lock naming a dead pid, or one that is empty or not a pid, is left for the service itself (PostgreSQL
    /// removes such a lock, and checks its shared memory too): Paddock removes nothing and starts it.
    func testADeadOrUnreadableLockIsLeftToTheServiceItself() async throws {
        let lines = LockedBox<[String]>([])
        let manager = makeManager([lockingFake], log: { line in lines.value.append(line) })
        _ = try await manager.add(kind: "fake", version: nil)
        for content in ["\(try deadPid())\n", "", "not a pid\n123\n"] {
            manager.stop("fake")
            try Data(content.utf8).write(to: runLock(home.fakePort))
            try manager.start("fake")
            XCTAssertEqual(status(manager)?.state, .running, content)
            XCTAssertEqual(try String(contentsOf: runLock(home.fakePort), encoding: .utf8), content, "left alone")
        }
        XCTAssertEqual(lines.value.filter { $0.contains("lock file") }, [], "nothing removed")
    }

    /// A live process of this user that macOS won't describe (no program path, or no working folder) may be
    /// this instance's server: the lock is left and the start refused, naming the file and the pid.
    func testALockNamingAProcessThatCantBeInspectedRefusesTheStart() async throws {
        let other = try start(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        for inspector in [ServiceProcessInspector(executable: { _ in nil }, workingDirectory: { _ in "/" }),
                          ServiceProcessInspector(executable: { _ in FakeService.installed(paths: self.home.paths) },
                                                  workingDirectory: { _ in nil })] {
            let manager = makeManager([lockingFake], inspector: inspector)
            if StateStore(paths: home.paths).load().services.isEmpty {
                _ = try await manager.add(kind: "fake", version: nil)
            }
            manager.stopAll()
            try Data("\(other.processIdentifier)\n".utf8).write(to: runLock(home.fakePort))
            XCTAssertThrowsError(try manager.start("fake")) { error in
                guard case .unavailable(_, let reason)? = error as? ServiceError else { return XCTFail("\(error)") }
                XCTAssertTrue(reason.contains("lock-\(home.fakePort)") && reason.contains("\(other.processIdentifier)"), reason)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: runLock(home.fakePort).path))
        }
        XCTAssertTrue(other.isRunning)
    }

    /// Services run as this user, so a pid that now belongs to another user (launchd, pid 1) is not theirs.
    func testALockNamingAnotherUsersProcessIsRemoved() async throws {
        let manager = makeManager([lockingFake])
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stop("fake")
        try Data("1\n".utf8).write(to: runLock(home.fakePort))
        try manager.start("fake")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runLock(home.fakePort).path))
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
                                            arguments: ["init", "{data}/slow", "--sleep", "30"]),
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
        XCTAssertLessThan(Date().timeIntervalSince(stopping), 15, "the stop did not wait for the 30-second action")
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
        XCTAssertLessThan(Date().timeIntervalSince(began), 15, "shutdown did not wait for the 30-second action")
        guard case .error(let code, let message) = await create.value else { return XCTFail("not cancelled") }
        XCTAssertEqual(code, ErrorCode.serviceCancelled)
        XCTAssertEqual(message, "Creating the database in Fake was cancelled.")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    // MARK: - A6: services stop side by side

    /// Three services that ignore their stop signal, each with two seconds' grace: one after another would
    /// take six seconds; side by side, about two.
    func testServicesAreStoppedSideBySide() async throws {
        let recipes = (0..<3).map { index in
            FakeService.recipe(kind: index == 0 ? "fake" : "other\(index)", displayName: index == 0 ? "Fake" : "Other \(index)",
                               ports: [RecipePort(name: "main", preferred: FakeService.preferredPort + index)],
                               extraArguments: ["--ignore-term"], socket: "{run}/s\(index).sock", stopGraceSeconds: 2)
        }
        let manager = makeManager(recipes)
        for recipe in recipes { _ = try await manager.add(kind: recipe.kind, version: nil) }
        let began = Date()
        manager.stopAll()
        let took = Date().timeIntervalSince(began)
        let serial = Double(recipes.map(\.stopGraceSeconds).reduce(0, +))
        XCTAssertGreaterThanOrEqual(took, 1.9, "each was given its grace")
        XCTAssertLessThan(took, serial - 1.5, "side by side, well under the \(serial) seconds of one after another")
        XCTAssertEqual(manager.statuses().map(\.state), [.stopped, .stopped, .stopped])
    }
}
