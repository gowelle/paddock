import Darwin
import Foundation
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Site tasks end to end: nothing runs until approved, approved commands run in the site's folder with its
/// PHP, a changed file keeps the approved version, crash loops give up, stops wait for slow tasks, and the
/// daemon brings tasks back, reclaims its orphans and stops everything within its limit. Scratch homes,
/// scratch site folders, harmless shell commands, free high ports only.
final class SiteTasksTests: XCTestCase {
    private var home: TaskHome!
    private var engine: Engine?
    private var daemon: Process?
    private var strays: [Int32] = []

    override func setUpWithError() throws {
        home = try TaskHome()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        if let daemon, daemon.isRunning {
            kill(daemon.processIdentifier, SIGTERM)
            if !waitFor(30, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        // Anything a test left behind: only processes in this test's own folders.
        for pid in strays where kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        home?.cleanUp()
    }

    // MARK: - Helpers

    /// An engine for the scratch home (not started: tasks don't need the web side), with a fixed, injected
    /// shell environment and short restart delays.
    private func makeEngine(shutdownGrace: TimeInterval = SiteTaskManager.shutdownGraceCap,
                            backoffScale: TimeInterval = 0.02, started: Bool = false) async throws -> Engine {
        let engine = Engine(paths: home.paths, settings: home.settings, installAction: nil, backoffScale: backoffScale,
                            managesPortHelper: true, portHelper: TestSupport.portHelper,
                            portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [])),
                            taskEnvironment: { [home] in home!.environment }, taskShutdownGrace: shutdownGrace,
                            log: { _ in })
        self.engine = engine
        if started {
            try engine.start()
            XCTAssertTrue(engine.status().running, "blocked by \(engine.status().blockedBy)")
        }
        await engine.startTasks()
        return engine
    }

    private func tasks(_ engine: Engine, _ site: String) -> SiteTasksStatus? {
        engine.status().sites.first { $0.name == site }?.tasks
    }

    private func state(_ engine: Engine, _ site: String, _ task: String) -> TaskState? {
        tasks(engine, site)?.tasks.first { $0.name == task }?.state
    }

    private func pid(_ engine: Engine, _ site: String, _ task: String) -> Int32? {
        if case .running(let pid)? = state(engine, site, task) { return pid }
        return nil
    }

    @discardableResult
    private func approve(_ engine: Engine, _ site: String, file: StaticString = #filePath, line: UInt = #line) async throws
        -> EngineStatus {
        engine.tasks.refresh()
        let hash = try XCTUnwrap(tasks(engine, site)?.pendingHash, "a pending hash to approve", file: file, line: line)
        let response = await engine.handle(.tasksApprove(site: site, hash: hash))
        guard case .ok(let status) = response else {
            XCTFail("approve: \(response)", file: file, line: line)
            throw XCTSkip("approve failed")
        }
        return status
    }

    private func log(_ site: String, _ task: String) -> String {
        (try? String(contentsOf: home.paths.taskLog(site: site, task: task), encoding: .utf8)) ?? ""
    }

    private func waitForRunning(_ engine: Engine, _ site: String, _ task: String, timeout: TimeInterval = 15) -> Int32? {
        var found: Int32?
        _ = waitFor(timeout) {
            found = self.pid(engine, site, task)
            return found != nil
        }
        if let found { strays.append(found) }
        return found
    }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    // MARK: - Approval

    func testNothingRunsUntilApproved() async throws {
        let marker = home.root.appendingPathComponent("ran").path
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "touch '\#(marker)'; exec sleep 600"}}, "proxy": {"/app": 8080}}"#)
        let engine = try await makeEngine()

        let status = try XCTUnwrap(tasks(engine, "shop"))
        XCTAssertEqual(status.approval, .needsApproval)
        XCTAssertEqual(status.pending, [PendingTask(name: "queue", run: "touch '\(marker)'; exec sleep 600", port: nil),
                                        PendingTask(name: "/app", run: nil, port: 8080)])
        XCTAssertEqual(status.tasks.map(\.state), [.waitingForApproval])
        XCTAssertNotNil(status.pendingHash)
        try await Task.sleep(nanoseconds: 1000000000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "nothing ran")
        XCTAssertTrue(engine.tasks.supervisor.names.isEmpty, "no process was ever started")

        guard case .error(let code, _) = await engine.handle(.taskStart(site: "shop", task: "queue")) else {
            return XCTFail("starting an unapproved task")
        }
        XCTAssertEqual(code, ErrorCode.tasksNotApproved)
        guard case .error(let stale, _) = await engine.handle(.tasksApprove(site: "shop", hash: "v1:not-what-was-shown")) else {
            return XCTFail("approving another version than the one shown")
        }
        XCTAssertEqual(stale, ErrorCode.tasksChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "still nothing ran")

        let approved = try await approve(engine, "shop")
        XCTAssertEqual(approved.sites.first { $0.name == "shop" }?.tasks?.approval, .approved)
        XCTAssertNotNil(waitForRunning(engine, "shop", "queue"))
        XCTAssertTrue(waitFor(5) { FileManager.default.fileExists(atPath: marker) })
        XCTAssertEqual(tasks(engine, "shop")?.pending, [], "nothing pending once approved")
        let saved = try XCTUnwrap(StateStore(paths: home.paths).load().taskApprovals["shop"])
        XCTAssertEqual(saved.sitePath, SiteTasksFile.realPath(home.sites.appendingPathComponent("shop").path))
    }

    /// A Paddock whose tasks nobody approved never runs the user's shell to read its environment; approving
    /// reads it (again).
    func testTheShellIsAskedOnlyOnceSomethingIsApproved() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let asked = LockedBox(0)
        let environment = home.environment
        let engine = Engine(paths: home.paths, settings: home.settings, installAction: nil, managesPortHelper: true,
                            portHelper: TestSupport.portHelper, portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [])),
                            taskEnvironment: { asked.value += 1; return environment }, log: { _ in })
        self.engine = engine
        await engine.startTasks()
        engine.tasks.refresh()
        XCTAssertEqual(tasks(engine, "shop")?.approval, .needsApproval)
        XCTAssertEqual(asked.value, 0)
        try await approve(engine, "shop")
        XCTAssertEqual(asked.value, 1)
        XCTAssertNotNil(waitForRunning(engine, "shop", "queue"))
    }

    func testACommandThatCannotBeShownIsNeverApproved() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "echo hi\u001b[8m; exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        let status = try XCTUnwrap(tasks(engine, "shop"))
        XCTAssertEqual(status.pending.first?.run, "echo hi; exec sleep 600", "shown sanitised")
        XCTAssertTrue(status.notice?.contains("cannot be shown") ?? false, status.notice ?? "no notice")
        guard case .error(let code, let message) = await engine.handle(.tasksApprove(site: "shop", hash: status.pendingHash!))
        else { return XCTFail("approved a command that can't be shown") }
        XCTAssertEqual(code, ErrorCode.tasksInvalid)
        XCTAssertTrue(message.contains("cannot be shown"), message)
        XCTAssertNil(StateStore(paths: home.paths).load().taskApprovals["shop"])
    }

    /// Tasks run in the site's folder, with the PHP the site is pinned to and Paddock's `bin` first on PATH.
    func testApprovedTasksRunInTheSiteFolderWithItsPHP() async throws {
        try TestSupport.requireVendored()
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"report": {"run": "pwd -P; php -r 'echo PHP_VERSION, PHP_EOL;'; echo \"$PATH\" | cut -d: -f1; exec sleep 600"}}}"#)
        let engine = try await makeEngine(started: true)
        try installShims()
        try await installPHP84()
        guard case .ok = await engine.handle(.isolate(site: "shop", version: PHPVersion("8.4")!)) else {
            return XCTFail("pin")
        }
        try await approve(engine, "shop")
        XCTAssertNotNil(waitForRunning(engine, "shop", "report"))
        XCTAssertTrue(waitFor(15) { self.log("shop", "report").contains(self.home.paths.bin.path) }, log("shop", "report"))
        let lines = log("shop", "report").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("[paddock") }
        XCTAssertEqual(lines.first, SiteTasksFile.realPath(folder.path), "runs in the site's folder")
        XCTAssertTrue(lines.dropFirst().first?.hasPrefix("8.4.") ?? false, "the site's pinned PHP: \(lines)")
        XCTAssertEqual(lines.dropFirst(2).first, home.paths.bin.path, "Paddock's bin first on PATH")
    }

    func testAChangedFileKeepsTheApprovedVersion() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "echo version-one; exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(waitForRunning(engine, "shop", "queue"))

        try home.writeTasks("shop", #"{"tasks": {"queue": {"run": "echo version-two; exec sleep 600"}}}"#)
        engine.tasks.refresh()
        let changed = try XCTUnwrap(tasks(engine, "shop"))
        XCTAssertEqual(changed.approval, .changed)
        XCTAssertEqual(changed.pending.first?.run, "echo version-two; exec sleep 600")
        XCTAssertEqual(changed.tasks.first?.run, "echo version-one; exec sleep 600", "the approved version is what runs")
        XCTAssertEqual(pid(engine, "shop", "queue"), first, "still the same process")
        XCTAssertFalse(log("shop", "queue").contains("version-two"))
        XCTAssertTrue(Messages.siteTasksLines(engine.status().sites).contains { $0.contains("changed") })

        try await approve(engine, "shop")
        XCTAssertTrue(waitFor(15) { (self.pid(engine, "shop", "queue") ?? first) != first })
        XCTAssertFalse(alive(first), "the old version stopped")
        XCTAssertTrue(waitFor(5) { self.log("shop", "queue").contains("version-two") })
        XCTAssertEqual(tasks(engine, "shop")?.approval, .approved)
    }

    func testFormattingChangesNeedNoReapproval() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "stopSeconds": 5}, "b": {"run": "exec sleep 601"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(waitForRunning(engine, "shop", "queue"))
        try home.writeTasks("shop", """
        {
            "tasks": {
                "b":     { "run": "exec sleep 601" },
                "queue": { "stopSeconds": 5,   "run": "exec sleep 600", "autostart": true }
            },
            "proxy": {}
        }
        """)
        engine.tasks.refresh()
        XCTAssertEqual(tasks(engine, "shop")?.approval, .approved)
        XCTAssertEqual(pid(engine, "shop", "queue"), first, "not restarted")
    }

    func testInvalidFileAffectsOnlyThatSite() async throws {
        try home.makeSite("broken", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}, "extra": true}"#)
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        XCTAssertEqual(tasks(engine, "broken")?.approval, .invalid(reason: #"unknown key "extra""#))
        XCTAssertEqual(tasks(engine, "broken")?.tasks, [])
        guard case .error(let code, let message) = await engine.handle(.tasksApprove(site: "broken", hash: "v1:x")) else {
            return XCTFail("approved an invalid file")
        }
        XCTAssertEqual(code, ErrorCode.tasksInvalid)
        XCTAssertTrue(message.contains(#"unknown key "extra""#), message)
        try await approve(engine, "shop")
        XCTAssertNotNil(waitForRunning(engine, "shop", "queue"), "the other site's tasks run")
        XCTAssertTrue(Messages.siteTasksLines(engine.status().sites).contains { $0.hasPrefix("broken: paddock.json can't be used") })
    }

    // MARK: - Running

    func testCrashLoopGivesUpAndSaysSo() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"boom": {"run": "echo exploding; exit 3"}, "once": {"run": "echo done"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        XCTAssertTrue(waitFor(30) {
            if case .crashed(let reason)? = self.state(engine, "shop", "boom") { return reason.contains("stopped restarting") }
            return false
        }, "\(String(describing: state(engine, "shop", "boom")))")
        if case .crashed(let reason)? = state(engine, "shop", "boom") {
            XCTAssertTrue(reason.contains("status 3"), reason)
        }
        XCTAssertEqual(log("shop", "boom").components(separatedBy: "exploding").count - 1, 5, "five tries, then no more")

        XCTAssertTrue(waitFor(30) { self.state(engine, "shop", "once") == .stopped(reason: .exited) },
                      "a command that finishes by itself is stopped, not crashed: \(String(describing: state(engine, "shop", "once")))")
        XCTAssertEqual(log("shop", "once").components(separatedBy: "done").count - 1, 3)
        XCTAssertNotNil(tasks(engine, "shop")?.tasks.first { $0.name == "once" }?.warning)

        engine.tasks.refresh()
        try await Task.sleep(nanoseconds: 500000000)
        XCTAssertEqual(log("shop", "once").components(separatedBy: "done").count - 1, 3, "a refresh doesn't start it again")
        guard case .ok = await engine.handle(.taskRestart(site: "shop", task: "once")) else { return XCTFail("restart") }
        XCTAssertTrue(waitFor(10) { self.log("shop", "once").components(separatedBy: "done").count - 1 > 3 },
                      "restart runs it again")
    }

    func testStopWaitsForASlowTaskThenKills() async throws {
        try home.makeSite("shop", tasks: """
        {"tasks": {
          "stubborn": {"run": "trap '' TERM; while :; do sleep 0.1; done", "stopSeconds": 2},
          "careful": {"run": "trap 'sleep 1; echo finished-job; exit 0' TERM; while :; do sleep 0.1; done", "stopSeconds": 10}
        }}
        """)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let stubborn = try XCTUnwrap(waitForRunning(engine, "shop", "stubborn"))
        let careful = try XCTUnwrap(waitForRunning(engine, "shop", "careful"))
        try await Task.sleep(nanoseconds: 500000000) // Let the shells set their traps.

        var started = Date()
        guard case .ok(let stopped) = await engine.handle(.taskStop(site: "shop", task: "stubborn")) else { return XCTFail() }
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 1.8, "waited its stopSeconds")
        XCTAssertLessThan(took, 10, "then killed it")
        XCTAssertFalse(alive(stubborn))
        XCTAssertEqual(stopped.sites.first { $0.name == "shop" }?.tasks?.tasks.first { $0.name == "stubborn" }?.state,
                       .stopped(reason: .byYou))

        started = Date()
        guard case .ok = await engine.handle(.taskStop(site: "shop", task: "careful")) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertFalse(alive(careful))
        XCTAssertTrue(log("shop", "careful").contains("finished-job"), "it was given time to finish")
        XCTAssertEqual(StateStore(paths: home.paths).load().taskApprovals["shop"]?.stopped, ["stubborn", "careful"])

        guard case .error(let unknown, _) = await engine.handle(.taskStop(site: "shop", task: "nope")) else { return XCTFail() }
        XCTAssertEqual(unknown, ErrorCode.unknownTask)
        guard case .error(let site, _) = await engine.handle(.taskStop(site: "nope", task: "x")) else { return XCTFail() }
        XCTAssertEqual(site, ErrorCode.unknownSite)
    }

    func testASiteThatDisappearsHasItsTasksStopped() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(waitForRunning(engine, "shop", "queue"))

        let aside = home.root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: aside)
        engine.tasks.refresh()
        XCTAssertTrue(waitFor(10) { !self.alive(first) }, "stopped with its site")
        let kept = try XCTUnwrap(StateStore(paths: home.paths).load().taskApprovals["shop"], "the approval is kept a while")
        XCTAssertNotNil(kept.goneSince)
        XCTAssertTrue(log("shop", "queue").contains("folder is gone"), log("shop", "queue"))

        try FileManager.default.moveItem(at: aside, to: folder)
        engine.tasks.refresh()
        XCTAssertNotNil(waitForRunning(engine, "shop", "queue"), "back with its folder")
        XCTAssertNil(StateStore(paths: home.paths).load().taskApprovals["shop"]?.goneSince)

        // A month later without the folder, the approval goes.
        try FileManager.default.moveItem(at: folder, to: aside)
        engine.tasks.refresh()
        try StateStore(paths: home.paths).update { $0.taskApprovals["shop"]?.goneSince = Date().addingTimeInterval(-31 * 86400) }
        engine.tasks.refresh()
        XCTAssertNil(StateStore(paths: home.paths).load().taskApprovals["shop"])
    }

    /// The same site name at another folder (re-parked elsewhere) needs approving afresh.
    func testAnApprovalStaysWithItsFolder() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(waitForRunning(engine, "shop", "queue"))
        try FileManager.default.removeItem(at: folder)
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#, parent: home.otherSites)
        try StateStore(paths: home.paths).update { $0.parked = [self.home.otherSites.path] }
        engine.tasks.refresh()
        XCTAssertTrue(waitFor(10) { !self.alive(first) })
        XCTAssertEqual(tasks(engine, "shop")?.approval, .needsApproval)
        try await Task.sleep(nanoseconds: 500000000)
        XCTAssertNil(pid(engine, "shop", "queue"))
    }

    /// A process a pid record names that still runs but can't be proved Paddock's own (here: its parent, this
    /// test, is alive) is left alone, and no second copy starts.
    func testAProcessThatIsNotProvablyOursIsLeftAlone() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["600"]
        other.currentDirectoryURL = folder
        try other.run()
        strays.append(other.processIdentifier)
        defer { other.terminate() }
        let record = try XCTUnwrap(ServiceProcessRecord.live(pid: other.processIdentifier))
        let file = home.paths.taskRun(site: "shop", task: "queue").appendingPathComponent("pid")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try record.write(to: file)

        let engine = try await makeEngine()
        try await approve(engine, "shop")
        XCTAssertEqual(state(engine, "shop", "queue"), .alreadyRunning(pid: other.processIdentifier))
        XCTAssertTrue(alive(other.processIdentifier), "never signalled")
        XCTAssertTrue(engine.tasks.supervisor.names.isEmpty, "no second copy")
        XCTAssertEqual(Messages.taskState(.alreadyRunning(pid: 42)), "already running (pid 42), not started by this Paddock")

        other.terminate()
        other.waitUntilExit()
        engine.tasks.refresh()
        XCTAssertNotNil(waitForRunning(engine, "shop", "queue"), "once it is gone, the task starts")
    }

    func testShutdownStopsAllTasksWithinItsLimit() async throws {
        try home.makeSite("shop", tasks: """
        {"tasks": {
          "a": {"run": "trap '' TERM; while :; do sleep 0.1; done", "stopSeconds": 300},
          "b": {"run": "trap '' TERM; while :; do sleep 0.1; done", "stopSeconds": 300},
          "polite": {"run": "exec sleep 600"}
        }}
        """)
        let engine = try await makeEngine(shutdownGrace: 2)
        try await approve(engine, "shop")
        let pids = try ["a", "b", "polite"].map { try XCTUnwrap(waitForRunning(engine, "shop", $0)) }
        try await Task.sleep(nanoseconds: 500000000)
        let started = Date()
        await engine.shutDownAfterPendingWork()
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, 10, "both stubborn tasks were cut short at the same time, not after 300 seconds each")
        for pid in pids { XCTAssertFalse(alive(pid)) }
        XCTAssertTrue(log("shop", "a").contains("shutting down"), log("shop", "a"))
        XCTAssertFalse(log("shop", "polite").contains("shutting down"), "only a task that was cut short says so")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.taskRun(site: "shop", task: "a")
            .appendingPathComponent("pid").path), "no record is left for a task that stopped")
    }

    func testDevelopmentBuildCannotApproveOnARealHome() throws {
        let requests: [Request] = [.tasksApprove(site: "shop", hash: "v1:x"), .tasksRevoke(site: "shop"),
                                   .taskStart(site: "shop", task: "q"), .taskStop(site: "shop", task: "q"),
                                   .taskRestart(site: "shop", task: "q"), .tasksInit(site: "shop")]
        let client = PaddockClient(paths: home.paths, readOnly: true)
        for request in requests {
            XCTAssertFalse(request.isReadOnly, "\(request)")
            XCTAssertThrowsError(try client.send(request), "\(request)") {
                XCTAssertEqual($0 as? ClientError, .developmentBuild)
            }
        }
    }

    func testInitWritesTheStarterOnlyForLaravelAndNeverOverwrites() async throws {
        let laravel = try home.makeSite("shop", tasks: nil)
        try Data("<?php\n".utf8).write(to: laravel.appendingPathComponent("artisan"))
        try home.makeSite("plain", tasks: nil)
        let engine = try await makeEngine()
        guard case .ok(let status) = await engine.handle(.tasksInit(site: "shop")) else { return XCTFail("init") }
        XCTAssertEqual(status.sites.first { $0.name == "shop" }?.tasks?.approval, .needsApproval)
        XCTAssertEqual(try String(contentsOf: laravel.appendingPathComponent("paddock.json"), encoding: .utf8),
                       SiteTasksFile.starter(forSiteAt: laravel))
        guard case .error(let exists, _) = await engine.handle(.tasksInit(site: "shop")) else { return XCTFail() }
        XCTAssertEqual(exists, ErrorCode.tasksFileExists)
        guard case .error(let notLaravel, _) = await engine.handle(.tasksInit(site: "plain")) else { return XCTFail() }
        XCTAssertEqual(notLaravel, ErrorCode.invalidArgument)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.sites.appendingPathComponent("plain/paddock.json").path))
    }

    func testRevokingStopsAndForgets() async throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(waitForRunning(engine, "shop", "queue"))
        guard case .ok(let status) = await engine.handle(.tasksRevoke(site: "shop")) else { return XCTFail("revoke") }
        XCTAssertFalse(alive(first))
        XCTAssertEqual(status.sites.first { $0.name == "shop" }?.tasks?.approval, .needsApproval)
        XCTAssertNil(StateStore(paths: home.paths).load().taskApprovals["shop"])
    }

    /// Past 5 MB a task's log is copied aside (one previous file kept) and emptied; the task keeps appending.
    func testTheLogIsRotatedPastItsLimit() async throws {
        let engine = try await makeEngine()
        let log = home.paths.taskLog(site: "shop", task: "queue")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "a"), count: Int(SiteTaskManager.logLimit)).write(to: log)
        engine.tasks.rotateIfNeeded(log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path + ".1"), "not past the limit yet")
        try Data(repeating: UInt8(ascii: "b"), count: Int(SiteTaskManager.logLimit) + 1).write(to: log)
        engine.tasks.rotateIfNeeded(log)
        let previous = try FileManager.default.attributesOfItem(atPath: log.path + ".1")[.size] as? Int
        XCTAssertEqual(previous, Int(SiteTaskManager.logLimit) + 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int, 0)
    }

    // MARK: - The daemon

    func testTasksComeBackAfterADaemonRestart() throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}, "later": {"run": "exec sleep 601", "autostart": false}}}"#)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon()
        try approveThroughDaemon("shop")
        let first = try XCTUnwrap(waitForDaemonTask("shop", "queue"))
        XCTAssertEqual(daemonState("shop", "later"), .stopped(reason: .notAutostart))
        try stopDaemon()
        XCTAssertFalse(alive(first), "tasks stop with the daemon")

        try launchDaemon()
        let second = try XCTUnwrap(waitForDaemonTask("shop", "queue"), "the approved task came back")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(daemonState("shop", "later"), .stopped(reason: .notAutostart))
        _ = client
    }

    func testOrphanTasksOfAKilledDaemonAreReclaimed() throws {
        let unique = Int.random(in: 700_000...799_999)
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "sleep \#(unique)"}}}"#)
        try launchDaemon()
        try approveThroughDaemon("shop")
        let orphan = try XCTUnwrap(waitForDaemonTask("shop", "queue"))
        // The shell hands over to `sleep`; the record follows it.
        let recordFile = home.paths.taskRun(site: "shop", task: "queue").appendingPathComponent("pid")
        XCTAssertTrue(waitFor(20) { ServiceProcessRecord.read(from: recordFile)?.executable == "/bin/sleep" },
                      "\(String(describing: ServiceProcessRecord.read(from: recordFile)))")

        // The killed daemon's web stack is orphaned too: this test stops it at the end (each leads its own group).
        strays += (daemonStatus()?.processes.values ?? [:].values).compactMap(TestSupport.pid(from:))
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        self.daemon = nil
        XCTAssertTrue(alive(orphan), "the task outlived its daemon")
        XCTAssertTrue(waitFor(5) { ServiceProcessRecord.parent(of: orphan) == 1 })

        try launchDaemon()
        let again = try XCTUnwrap(waitForDaemonTask("shop", "queue"))
        XCTAssertNotEqual(again, orphan)
        XCTAssertTrue(waitFor(10) { !self.alive(orphan) }, "the orphan was stopped")
        XCTAssertEqual(try pgrep("sleep \(unique)").count, 1, "the task runs once")
        let daemonLog = (try? String(contentsOf: home.root.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(daemonLog.contains("stopping task shop/queue (process group \(orphan)), left running by an earlier Paddock"),
                      "recognised as Paddock's own orphan: \(daemonLog)")
    }

    func testUserStoppedTaskStaysStoppedAcrossRestart() throws {
        try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon()
        try approveThroughDaemon("shop")
        XCTAssertNotNil(waitForDaemonTask("shop", "queue"))
        guard case .ok = try client.send(.taskStop(site: "shop", task: "queue"), timeout: 60) else { return XCTFail() }
        try stopDaemon()
        try launchDaemon()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(daemonState("shop", "queue"), .stopped(reason: .byYou), "remembered across restarts")
        guard case .ok = try client.send(.taskStart(site: "shop", task: "queue"), timeout: 60) else { return XCTFail() }
        XCTAssertNotNil(waitForDaemonTask("shop", "queue"))
        try stopDaemon()
        try launchDaemon()
        XCTAssertNotNil(waitForDaemonTask("shop", "queue"), "started again, it starts with Paddock again")
    }

    // MARK: - Daemon helpers

    private func launchDaemon() throws {
        let binary = Bundle(for: TaskHome.self).bundleURL.deletingLastPathComponent().appendingPathComponent("paddockd")
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        env["PADDOCK_HTTP_PORT"] = "\(TestSupport.freeTCPPort())"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort())"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53596))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServicePorts.portBaseVariable] = "\(TestSupport.freeTCPPort())"
        env[ShellEnvironment.overrideVariable] = try home.environmentFile().path
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
        XCTAssertTrue(waitFor(60) { !daemon.isRunning }, "daemon exited")
        XCTAssertEqual(daemon.terminationStatus, 0)
        self.daemon = nil
    }

    private func daemonStatus() -> EngineStatus? {
        guard case .ok(let status)? = try? PaddockClient(paths: home.paths).send(.status, timeout: 10) else { return nil }
        return status
    }

    private func daemonState(_ site: String, _ task: String) -> TaskState? {
        daemonStatus()?.sites.first { $0.name == site }?.tasks?.tasks.first { $0.name == task }?.state
    }

    private func waitForDaemonTask(_ site: String, _ task: String) -> Int32? {
        var found: Int32?
        _ = waitFor(40) {
            if case .running(let pid)? = self.daemonState(site, task) { found = pid }
            return found != nil
        }
        if let found { strays.append(found) }
        return found
    }

    private func approveThroughDaemon(_ site: String) throws {
        var hash: String?
        XCTAssertTrue(waitFor(40) {
            hash = self.daemonStatus()?.sites.first { $0.name == site }?.tasks?.pendingHash
            return hash != nil
        }, "the daemon saw the site's paddock.json")
        guard case .ok = try PaddockClient(paths: home.paths).send(.tasksApprove(site: site, hash: try XCTUnwrap(hash)),
                                                                   timeout: 60) else {
            return XCTFail("approve")
        }
    }

    private func pgrep(_ pattern: String) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "-U", "\(getuid())", "^\(pattern)$"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: - PHP

    private var products: URL { Bundle(for: TaskHome.self).bundleURL.deletingLastPathComponent() }

    private func installShims() throws {
        let paddock = products.appendingPathComponent("paddock")
        guard FileManager.default.isExecutableFile(atPath: paddock.path) else {
            throw XCTSkip("paddock not built at \(paddock.path)")
        }
        try Shims.install(paths: home.paths, source: paddock, resources: TestSupport.repoVendor)
    }

    /// PHP 8.4 from Paddock's own build in Vendor/builds, verified, with no network.
    private func installPHP84() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineURLProtocol.self]
        let installer = PHPInstaller(paths: home.paths, manifest: try PHPManifest.bundled(),
                                     session: URLSession(configuration: config))
        do {
            try await installer.install(PHPVersion("8.4")!)
        } catch PHPInstallError.buildMissing {
            throw XCTSkip("Vendor/builds lacks the PHP 8.4 archives; build them with Scripts/build-php.sh 8.4")
        }
    }
}

/// A scratch Paddock home with a parked folder of scratch sites, under /tmp (short socket paths).
final class TaskHome {
    let root: URL
    let paths: Paths
    let sites: URL
    let otherSites: URL
    var settings = Settings()
    /// What tasks run with in these tests, instead of the user's real shell environment.
    let environment: ShellEnvironment

    init() throws {
        root = URL(fileURLWithPath: "/tmp/pdk-\(TestSupport.token())", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        sites = root.appendingPathComponent("sites", isDirectory: true)
        otherSites = root.appendingPathComponent("other", isDirectory: true)
        for folder in [sites, otherSites] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try paths.ensureDirectories()
        let parked = sites.path
        try StateStore(paths: paths).update { $0 = State(parked: [parked], defaultPHP: PHPVersion("8.5")) }
        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53595)
        environment = ShellEnvironment(variables: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
                                                   "LANG": "en_US.UTF-8"],
                                       usedFallback: false, shell: "/bin/zsh")
    }

    @discardableResult
    func makeSite(_ name: String, tasks: String?, parent: URL? = nil) throws -> URL {
        let folder = (parent ?? sites).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let tasks { try Data(tasks.utf8).write(to: folder.appendingPathComponent("paddock.json")) }
        return folder
    }

    func writeTasks(_ site: String, _ text: String) throws {
        try Data(text.utf8).write(to: sites.appendingPathComponent(site).appendingPathComponent("paddock.json"),
                                  options: .atomic)
    }

    /// The environment as a file a test daemon reads instead of asking the shell.
    func environmentFile() throws -> URL {
        let file = root.appendingPathComponent("task-environment.json")
        try JSONEncoder().encode(environment.variables).write(to: file)
        return file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
