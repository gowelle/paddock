import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The second hardening pass: the recipe that runs is validated wherever it comes from; programs, sockets
/// and paths are checked once rendered; orphans are only true orphans; failed automatic patches are not
/// retried; late listeners are caught. Fake service, free high ports only.
final class ServiceHardeningTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var daemon: Process?
    private var strays: [Int32] = []
    private var groups: Set<Int32> = []

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        if let daemon, daemon.isRunning {
            kill(daemon.processIdentifier, SIGTERM)
            if !waitFor(15, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        for pid in strays where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        for group in groups where ((try? TestSupport.pgrep(group: group)) ?? []).isEmpty == false { kill(-group, SIGKILL) }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private func makeManager(_ recipes: [ServiceRecipe] = [FakeService.recipe()], readyTimeout: TimeInterval? = nil,
                             phpBinary: URL? = nil, runner: CommandRunner = SystemCommandRunner(),
                             lateChecks: [TimeInterval] = [],
                             log: @escaping @Sendable (String) -> Void = { _ in }) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     portCheck: .withoutProbes, phpBinary: { phpBinary }, portBase: home.portBase,
                                     readyTimeout: readyTimeout, runner: runner, lateLoopbackChecks: lateChecks, log: log)
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

    private var storedRecipe: URL {
        home.paths.serviceBin(kind: "fake", version: "1.0").appendingPathComponent(".paddock-recipe.json")
    }

    private func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// Starts `program arguments` as a launchd orphan leading its own group (the fake's `spawn-orphan`).
    private func spawnOrphan(_ program: String, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = FakeService.binary
        p.arguments = ["spawn-orphan", program] + arguments
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        strays.append(pid)
        XCTAssertTrue(waitFor(5) { self.parent(of: pid) == 1 }, "an orphan of launchd")
        return pid
    }

    // MARK: - N1: the stored recipe is validated

    func testAnInvalidStoredRecipeIsNeverUsed() async throws {
        let first = makeManager()
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        var json = try String(contentsOf: storedRecipe, encoding: .utf8)
        json = json.replacingOccurrences(of: #"{bin}\/paddock-fake-service"#, with: #"\/bin\/sh"#)
        json = json.replacingOccurrences(of: "{bin}/paddock-fake-service", with: "/bin/sh")
        XCTAssertTrue(json.contains("/bin/sh") || json.contains(#"\/bin\/sh"#), json)
        try Data(json.utf8).write(to: storedRecipe)

        // The catalog still has 1.0 and its binaries are installed: that recipe runs, and is stored again.
        let lines = LockedBox<[String]>([])
        let second = makeManager(log: { line in lines.value.append(line) })
        try second.start("fake")
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first, FakeService.installed(paths: home.paths))
        XCTAssertFalse(try String(contentsOf: storedRecipe, encoding: .utf8).contains("bin\\/sh"))
        XCTAssertEqual(lines.value.filter { $0.contains("stored recipe") }.count, 1, "\(lines.value)")
        second.stopAll()

        // Without that recipe in the catalog there is nothing safe to run.
        try Data(json.utf8).write(to: storedRecipe)
        let third = makeManager([FakeService.recipe(kind: "other", displayName: "Other")])
        guard case .unavailable(let reason)? = status(third)?.state else {
            return XCTFail("\(String(describing: status(third)))")
        }
        XCTAssertTrue(reason.contains("recipe"), reason)
        XCTAssertThrowsError(try third.start("fake"))
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    // MARK: - N2: rendered paths are checked before anything runs

    /// A downloaded archive whose `server` is a symlink to /bin/sh: verified and unpacked, but never run.
    func testASymlinkOutOfTheBinariesIsNeverRun() async throws {
        let source = home.root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("server").path,
                                                   withDestinationPath: "/bin/sh")
        let archive = home.root.appendingPathComponent("server.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.path, "server"]
        try tar.run()
        tar.waitUntilExit()
        let digest = try sha256(archive)
        let asset = RecipeAsset(artifact: Artifact(url: archive, sha256: digest), archive: "tar.gz")

        func recipe(kind: String, initialise: Bool) -> ServiceRecipe {
            ServiceRecipe(kind: kind, displayName: "Shell", version: "1.0", seriesInID: false, licence: "MIT", assets: [asset],
                          initialise: initialise ? [RecipeCommand(executable: "{bin}/server", arguments: ["-c", "touch {data}/ran"])] : [],
                          start: RecipeCommand(executable: "{bin}/server", arguments: ["-c", "touch {data}/ran; sleep 60"]),
                          ready: .tcp(port: "{port.main}"), ports: [RecipePort(name: "main", preferred: 1100)])
        }
        let manager = makeManager([recipe(kind: "shell", initialise: false), recipe(kind: "shellinit", initialise: true)])
        let atStart = await serviceError { _ = try await manager.add(kind: "shell", version: nil) }
        guard case .unsafeRecipe(let name, let reason)? = atStart else { return XCTFail("\(String(describing: atStart))") }
        XCTAssertEqual(name, "Shell")
        XCTAssertTrue(reason.contains("server"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceData("shell").appendingPathComponent("ran").path))
        XCTAssertEqual(Engine.response(for: atStart!), .error(code: ErrorCode.serviceFailed, message: Messages.serviceError(atStart!)))

        let atInitialise = await serviceError { _ = try await manager.add(kind: "shellinit", version: nil) }
        guard case .unsafeRecipe? = atInitialise else { return XCTFail("\(String(describing: atInitialise))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("shellinit").path), "nothing kept")
    }

    func testAHandEditedInstanceNameIsIgnored() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        manager.stopAll()
        try StateStore(paths: home.paths).update { state in
            state.services = state.services.map { var edited = $0; edited.name = "../../evil\nname"; return edited }
        }
        let lines = LockedBox<[String]>([])
        let again = makeManager(log: { line in lines.value.append(line) })
        XCTAssertEqual(again.statuses(), [])
        XCTAssertThrowsError(try again.start("fake"))
        again.startAutostart()
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
        XCTAssertEqual(lines.value.filter { $0.contains("ignoring the saved service") }.count, 1, "\(lines.value)")
    }

    // MARK: - N3: legacy installs, idle updates, persisted series

    func testUpdateWhenUpToDateDoesNotRestart() async throws {
        let manager = makeManager()
        _ = try await manager.add(kind: "fake", version: nil)
        let before = try XCTUnwrap(pid(manager))
        let updated = try await manager.update("fake")
        XCTAssertEqual(updated.version, "1.0")
        XCTAssertEqual(pid(manager), before, "not restarted")
    }

    func testALegacyInstallGetsItsRecipeStoredAndItsSeriesSaved() async throws {
        let first = makeManager()
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        try FileManager.default.removeItem(at: storedRecipe)
        var text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        text = text.replacingOccurrences(of: #""series" : "1","#, with: "")
        try Data(text.utf8).write(to: home.paths.stateFile)

        let second = makeManager()
        second.startAutostart()
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedRecipe.path), "the catalog's recipe is stored")
        XCTAssertTrue(try String(contentsOf: home.paths.stateFile, encoding: .utf8).contains(#""series" : "1""#),
                      "the filled-in series is saved at daemon start")
    }

    // MARK: - N4: only true orphans are reclaimed

    /// A process that matches its record but whose parent is alive (another manager runs it) is not an orphan.
    func testALiveServiceOfAnotherSupervisorIsNotReclaimed() async throws {
        let first = makeManager()
        _ = try await first.add(kind: "fake", version: nil)
        let running = try XCTUnwrap(pid(first))
        let second = makeManager()
        XCTAssertThrowsError(try second.start("fake")) { error in
            guard case .portInUse? = error as? ServiceError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(kill(running, 0), 0, "never signalled")
        XCTAssertEqual(status(first)?.state, .running)
    }

    /// Paddock's PHP folder is an allowed program location only for recipes that run `{php}`.
    func testThePHPFolderCountsOnlyForPHPRecipes() async throws {
        let php = home.paths.phpDir(PHPVersion("8.5")!).appendingPathComponent("php")
        try FileManager.default.createDirectory(at: php.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FakeService.binary, to: php)
        let phpRecipe = ServiceRecipe(
            kind: "phpfake", displayName: "PHP Fake", version: "1.0", seriesInID: false, licence: "MIT", assets: [],
            start: RecipeCommand(executable: "{php}", arguments: ["serve", "{data}", "--port", "{port.main}"]),
            ready: .tcp(port: "{port.main}"), ports: [RecipePort(name: "main", preferred: 1200)], needsPHP: true)
        let manager = makeManager([FakeService.recipe(), phpRecipe], phpBinary: php)
        _ = try await manager.add(kind: "fake", version: nil)
        _ = try await manager.add(kind: "phpfake", version: nil)
        manager.stopAll()

        for id in ["fake", "phpfake"] {
            let data = home.root.appendingPathComponent("orphan-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let orphan = try spawnOrphan(php.path, ["serve", data.path])
            let record = try XCTUnwrap(ServiceProcessRecord.live(pid: orphan))
            try record.write(to: home.paths.serviceRun(id).appendingPathComponent("pid"))
            try manager.start(id)
            if id == "fake" {
                XCTAssertEqual(kill(orphan, 0), 0, "a {php}-less recipe never claims Paddock's PHP")
            } else {
                XCTAssertTrue(waitFor(5) { kill(orphan, 0) != 0 }, "a {php} recipe's orphan is reclaimed")
            }
        }
    }

    /// The leader died, a child of the same group (an orphan running the recipe's program) still holds the
    /// port: at daemon start that group is stopped too, and the service starts.
    func testALeaderlessGroupOfOrphansIsReclaimed() throws {
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [FakeService.recipe(extraArguments: ["--fork-child"])])).write(to: catalog)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon(catalog: catalog)
        guard case .ok(let added) = try client.send(.serviceAdd(kind: "fake", version: nil), timeout: 60) else {
            return XCTFail("add")
        }
        _ = try client.send(.stop, timeout: 60)
        let leader = try XCTUnwrap(added.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        groups.insert(leader)
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        self.daemon = nil
        kill(leader, SIGKILL)
        XCTAssertTrue(waitFor(5) { kill(leader, 0) != 0 })
        let members = try TestSupport.pgrep(group: leader)
        XCTAssertEqual(members.count, 1, "the child survives its leader")
        XCTAssertTrue(PortCheck.acceptsIPv4(port: home.fakePort))

        try launchDaemon(catalog: catalog)
        XCTAssertTrue(waitFor(30) {
            guard case .ok(let status)? = try? client.send(.status, timeout: 5) else { return false }
            return status.services.first?.state == .running
        }, "the service is running again")
        XCTAssertEqual(try TestSupport.pgrep(group: leader), [], "the leaderless group was stopped")
        if case .ok(let status)? = try? client.send(.status, timeout: 5),
           let fresh = status.processes["service-fake"].flatMap(TestSupport.pid(from:)) { groups.insert(fresh) }
    }

    // MARK: - N5: failed automatic patches

    func testAFailedAutomaticPatchIsRememberedAndNotRetried() async throws {
        let first = makeManager()
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let broken = FakeService.recipe(version: "1.1", extraArguments: ["--no-listen"], readyTimeoutSeconds: 2)
        let second = makeManager([FakeService.recipe(), broken])
        try second.start("fake")
        XCTAssertEqual(status(second)?.state, .running)
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.version, "1.0")
        XCTAssertEqual(StateStore(paths: home.paths).load().services.first?.skippedVersion, "1.1")
        XCTAssertEqual(status(second)?.updateAvailable, "1.1")
        XCTAssertEqual(status(second)?.notice, "Version 1.1 didn't start last time; run paddock service update fake to try again.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "fake", version: "1.1").path),
                       "the failed version's binaries are removed")
        second.stopAll()

        let third = makeManager([FakeService.recipe(), broken])
        let started = Date()
        try third.start("fake")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "not tried again")
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first, FakeService.installed(paths: home.paths))
        XCTAssertEqual(status(third)?.notice, "Version 1.1 didn't start last time; run paddock service update fake to try again.")
    }

    /// The newer patch fails and leaves data the old one refuses: both failures are reported, and the
    /// message says the data may have been upgraded.
    func testWhenGoingBackAlsoFailsBothFailuresAreReported() async throws {
        let old = FakeService.recipe(extraArguments: ["--refuse-poison"])
        let first = makeManager([old])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let broken = FakeService.recipe(version: "1.1", extraArguments: ["--poison-data", "--no-listen"], readyTimeoutSeconds: 2)
        let lines = LockedBox<[String]>([])
        let second = makeManager([old, broken], log: { line in lines.value.append(line) })
        XCTAssertThrowsError(try second.start("fake")) { error in
            guard case .rollbackFailed(let name, let id, let version, let previous, let newer, let older)? = error as? ServiceError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual([name, id, version, previous], ["Fake", "fake", "1.1", "1.0"])
            XCTAssertFalse(newer.isEmpty)
            XCTAssertTrue(older.contains("refusing data poisoned"), older)
            let message = Messages.serviceError(error as! ServiceError)
            XCTAssertTrue(message.contains("Fake couldn't go back to 1.0: version 1.1 may have upgraded its data. "
                                           + "Run paddock service update fake to try 1.1 again."), message)
        }
        XCTAssertTrue(lines.value.contains { $0.contains("couldn't go back to 1.0") }, "\(lines.value)")
        XCTAssertNotEqual(status(second)?.state, .running)
    }

    func testTheDataVersionIsWrittenRightAfterInitialise() async throws {
        let manager = makeManager([FakeService.recipe(extraArguments: ["--no-listen"], readyTimeoutSeconds: 1)])
        _ = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        let text = try String(contentsOf: home.paths.serviceHome("fake").appendingPathComponent("data-version"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains(#""series":"1""#), text)
    }

    // MARK: - N6: late listeners

    func testALateListenerBeyondThisMacStopsTheService() async throws {
        let late = TestSupport.freeTCPPort(excluding: [home.fakePort])
        let manager = makeManager([FakeService.recipe(extraArguments: ["--late-listen", "\(late)", "--late-delay", "1500"])],
                                  lateChecks: [3])
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertTrue(waitFor(15) { self.status(manager)?.state != .running }, "stopped after the late check")
        XCTAssertEqual(status(manager)?.notice, "Fake tried to listen on *:\(late), which is not this Mac only. Paddock stopped it.")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    func testAServiceWhoseListenersCantBeCheckedSaysSo() async throws {
        let manager = makeManager(runner: FailingRunner())
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(status(manager)?.state, .running, "fail-open")
        XCTAssertEqual(status(manager)?.notice, "Paddock couldn't check what Fake is listening on.")
    }

    // MARK: - Daemon

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
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53593))"
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
        if case .ok(let status)? = try? PaddockClient(paths: home.paths).send(.status, timeout: 5) {
            for description in status.processes.values { if let pid = TestSupport.pid(from: description) { groups.insert(pid) } }
        }
    }

    private func sha256(_ file: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return String(text.prefix(64))
    }
}

/// A runner whose every command fails, as when `lsof` can't run.
struct FailingRunner: CommandRunner {
    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String) {
        throw CommandRunnerError.timedOut(executable: executable, seconds: 5)
    }
}
