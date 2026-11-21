import Darwin
import Foundation
import XCTest
@testable import PaddockCore

/// Tasks that restart when the site's code changes (FSEvents, debounced, coalesced), and the warning for a task
/// listening beyond this Mac. Scratch homes and sites, harmless commands, free high ports. FSEvents can take a
/// few seconds on a loaded machine: the limits are generous.
final class RestartOnChangeTests: XCTestCase {
    private var home: TaskHome!
    private var engine: Engine?

    override func setUpWithError() throws {
        home = try TaskHome()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        if let home { for pid in home.leftoverProcesses() where home.owns(pid) { kill(pid, SIGKILL) } }
        home?.cleanUp()
    }

    private func makeEngine(backoffScale: TimeInterval = 0.02, shutdownGrace: TimeInterval = SiteTaskManager.shutdownGraceCap)
        async -> Engine {
        let engine = Engine(paths: home.paths, settings: home.settings, installAction: nil, backoffScale: backoffScale,
                            managesPortHelper: true, portHelper: TestSupport.portHelper,
                            portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [])),
                            taskEnvironment: { [home] in home!.environment }, taskShutdownGrace: shutdownGrace, log: { _ in })
        self.engine = engine
        await engine.startTasks()
        return engine
    }

    private func approve(_ engine: Engine, _ site: String) async throws {
        engine.tasks.refresh()
        let hash = try XCTUnwrap(engine.status().sites.first { $0.name == site }?.tasks?.pendingHash)
        guard case .ok = await engine.handle(.tasksApprove(site: site, hash: hash)) else { return XCTFail("approve") }
    }

    private func task(_ engine: Engine, _ site: String, _ name: String) -> TaskStatus? {
        engine.status().sites.first { $0.name == site }?.tasks?.tasks.first { $0.name == name }
    }

    private func pid(_ engine: Engine, _ site: String, _ name: String) -> Int32? {
        if case .running(let pid)? = task(engine, site, name)?.state { return pid }
        return nil
    }

    private func running(_ engine: Engine, _ site: String, _ name: String, otherThan old: Int32? = nil,
                         timeout: TimeInterval = 20) -> Int32? {
        var found: Int32?
        _ = waitFor(timeout) {
            found = self.pid(engine, site, name)
            return found != nil && found != old
        }
        return found == old ? nil : found
    }

    private func starts(_ site: String, _ name: String) -> Int {
        let text = (try? String(contentsOf: home.paths.taskLog(site: site, task: name), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "] Starting.").count - 1
    }

    private func touch(_ folder: URL, _ path: String, _ text: String = "<?php // \(UUID())\n") throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    // MARK: - Restart on change

    func testAPHPChangeRestartsTheTaskOnceAndOtherFilesDont() async throws {
        let folder = try home.makeSite("shop", tasks: """
        {"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true},
                   "steady": {"run": "exec sleep 601", "restartOnChange": false}}}
        """)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "queue"))
        let steady = try XCTUnwrap(running(engine, "shop", "steady"))
        try await pause(1.5) // Let the stream start.

        try touch(folder, "app/Foo.php")
        let second = try XCTUnwrap(running(engine, "shop", "queue", otherThan: first), "restarted after a code change")
        XCTAssertEqual(starts("shop", "queue"), 2)

        // A burst of 20 writes: one more restart, not twenty.
        for i in 0..<20 { try touch(folder, "app/Burst\(i).php") }
        let third = try XCTUnwrap(running(engine, "shop", "queue", otherThan: second))
        try await pause(6)
        XCTAssertEqual(pid(engine, "shop", "queue"), third)
        XCTAssertEqual(starts("shop", "queue"), 3, "the burst caused one restart")

        // Not code: vendor, storage, anything else.
        try touch(folder, "vendor/x.php")
        try touch(folder, "storage/logs/laravel.log", "log line\n")
        try touch(folder, "README.md", "hello\n")
        try await pause(6)
        XCTAssertEqual(pid(engine, "shop", "queue"), third, "vendor, storage and other files change nothing")
        XCTAssertEqual(pid(engine, "shop", "steady"), steady, "restartOnChange false: never restarted")
        XCTAssertEqual(task(engine, "shop", "queue")?.restartOnChange, true)
        XCTAssertEqual(task(engine, "shop", "steady")?.restartOnChange, false)
    }

    /// Editors write a temporary file and rename it into place: that is one change.
    func testARenameIntoPlaceRestartsOnce() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        try touch(folder, "app/Foo.php")
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "queue"))
        try await pause(1.5)
        try touch(folder, "app/.Foo.php.swp", "swap")
        try touch(folder, "app/Foo.php.tmp-123", "<?php // new\n")
        XCTAssertEqual(rename(folder.appendingPathComponent("app/Foo.php.tmp-123").path,
                              folder.appendingPathComponent("app/Foo.php").path), 0)
        XCTAssertNotNil(running(engine, "shop", "queue", otherThan: first))
        try await pause(5)
        XCTAssertEqual(starts("shop", "queue"), 2)
    }

    /// 200 writes over 3 seconds (a checkout): at most two restarts.
    func testALongBurstRestartsAtMostTwice() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        _ = try XCTUnwrap(running(engine, "shop", "queue"))
        try await pause(1.5)
        for i in 0..<200 {
            try touch(folder, "app/Checkout\(i % 40).php")
            try await pause(0.015)
        }
        XCTAssertTrue(waitFor(20) { self.starts("shop", "queue") >= 2 })
        try await pause(8)
        XCTAssertLessThanOrEqual(starts("shop", "queue"), 3, "at most two restarts")
        XCTAssertNotNil(pid(engine, "shop", "queue"))
    }

    /// A task the supervisor gave up on runs again when the code changes (fixing the code is how it recovers); a
    /// task the user stopped doesn't.
    func testAChangeRestartsACrashedTaskButNotAStoppedOne() async throws {
        let folder = try home.makeSite("shop", tasks: """
        {"tasks": {"boom": {"run": "echo boom; exit 3", "restartOnChange": true},
                   "held": {"run": "exec sleep 600", "restartOnChange": true}}}
        """)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        XCTAssertTrue(waitFor(30) {
            if case .crashed(let reason)? = self.task(engine, "shop", "boom")?.state { return reason.contains("stopped restarting") }
            return false
        })
        _ = try XCTUnwrap(running(engine, "shop", "held"))
        guard case .ok = await engine.handle(.taskStop(site: "shop", task: "held")) else { return XCTFail("stop") }
        let before = starts("shop", "boom")
        try await pause(1.5)
        try touch(folder, "app/Fixed.php")
        XCTAssertTrue(waitFor(20) { self.starts("shop", "boom") > before }, "the crashed task runs again")
        try await pause(3)
        XCTAssertEqual(task(engine, "shop", "held")?.state, .stopped(reason: .byYou), "a stopped task stays stopped")
    }

    func testEditingPaddockJSONIsNoticedByTheWatcher() async throws {
        _ = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600"}}}"#)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        _ = try XCTUnwrap(running(engine, "shop", "queue"))
        try await pause(1.5)
        try home.writeTasks("shop", #"{"tasks": {"queue": {"run": "exec sleep 601"}}}"#)
        XCTAssertTrue(waitFor(20) { engine.status().sites.first { $0.name == "shop" }?.tasks?.approval == .changed },
                      "without any request or the 30-second timer")
    }

    /// A revoked site's watcher, and every watcher at shutdown, is gone: no callback after it stopped.
    func testWatchersAreTornDown() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        let blog = try home.makeSite("blog", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        try await approve(engine, "blog")
        let shopWatcher = try XCTUnwrap(engine.tasks.watcher(site: "shop"))
        let blogWatcher = try XCTUnwrap(engine.tasks.watcher(site: "blog"))
        guard case .ok = await engine.handle(.tasksRevoke(site: "shop")) else { return XCTFail("revoke") }
        XCTAssertNil(engine.tasks.watcher(site: "shop"))
        XCTAssertTrue(shopWatcher.isStopped)
        await engine.shutDownAfterPendingWork()
        XCTAssertTrue(blogWatcher.isStopped)
        for i in 0..<5 { try touch(folder, "app/After\(i).php"); try touch(blog, "app/After\(i).php") }
        try await pause(4)
        XCTAssertEqual(shopWatcher.callbacksAfterStop + blogWatcher.callbacksAfterStop, 0)
    }

    /// At most one change-triggered restart per task every 10 seconds (scaled with the restart delays: 5 seconds
    /// here); changes inside that window become one restart at its end.
    func testChangeRestartsAreRateLimitedAndCoalesced() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        let engine = await makeEngine(backoffScale: 0.5)
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "queue"))
        try await pause(1.5)
        try touch(folder, "app/A.php")
        let second = try XCTUnwrap(running(engine, "shop", "queue", otherThan: first))
        try touch(folder, "app/B.php")
        try await pause(1.2)
        try touch(folder, "app/C.php")
        try await pause(1.5)
        XCTAssertEqual(pid(engine, "shop", "queue"), second, "not again within the window")
        _ = try XCTUnwrap(running(engine, "shop", "queue", otherThan: second), "once, at the end of the window")
        try await pause(7)
        XCTAssertEqual(starts("shop", "queue"), 3, "B and C made one restart")
    }

    /// A change while the task is stopping for a restart needs no second restart: the new launch reads the new
    /// code anyway.
    func testAChangeDuringARestartCausesNoSecondOne() async throws {
        let folder = try home.makeSite("shop", tasks: """
        {"tasks": {"careful": {"run": "trap 'sleep 2; exit 0' TERM; while :; do sleep 0.1; done",
                               "restartOnChange": true, "stopSeconds": 10}}}
        """)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "careful"))
        try await pause(1.5)
        try touch(folder, "app/A.php")
        XCTAssertTrue(waitFor(20) { self.task(engine, "shop", "careful")?.state == .stopping })
        try touch(folder, "app/B.php")
        _ = try XCTUnwrap(running(engine, "shop", "careful", otherThan: first))
        try await pause(6)
        XCTAssertEqual(starts("shop", "careful"), 2)
    }

    /// A change whose files are older than the running launch (FSEvents can deliver a write made just before the
    /// watcher started, seconds later on a loaded machine) needs no restart: that launch already read them.
    func testAChangeOlderThanTheLaunchCausesNoRestart() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        try touch(folder, "app/Early.php")
        let before = Date()
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "queue"))
        engine.tasks.siteChanged("shop", SiteWatcher.Changes(code: true, codeChangedAt: before.addingTimeInterval(-1)))
        try await pause(3)
        XCTAssertEqual(pid(engine, "shop", "queue"), first)
        XCTAssertEqual(starts("shop", "queue"), 1)
        engine.tasks.siteChanged("shop", SiteWatcher.Changes(code: true, codeChangedAt: Date()))
        XCTAssertNotNil(running(engine, "shop", "queue", otherThan: first), "a newer change does restart it")
    }

    /// Nothing starts once the daemon is shutting down: a change delivered while shutdown waits on a slow stop
    /// starts nothing.
    func testAChangeDuringShutdownStartsNothing() async throws {
        // The slow stop is another site's, so nothing but the shutdown rule keeps "shop" from starting again.
        _ = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        _ = try home.makeSite("blog", tasks: """
        {"tasks": {"slow": {"run": "trap '' TERM; while :; do sleep 0.1; done", "stopSeconds": 300}}}
        """)
        let engine = await makeEngine(shutdownGrace: 3)
        try await approve(engine, "shop")
        try await approve(engine, "blog")
        _ = try XCTUnwrap(running(engine, "shop", "queue"))
        _ = try XCTUnwrap(running(engine, "blog", "slow"))
        try await pause(0.5)
        let shutdown = Task { await engine.shutDownAfterPendingWork() }
        XCTAssertTrue(waitFor(10) { self.task(engine, "blog", "slow")?.state == .stopping }, "shutdown waits on the slow stop")
        XCTAssertTrue(waitFor(10) { self.pid(engine, "shop", "queue") == nil }, "shop's task has stopped")
        engine.tasks.siteChanged("shop", SiteWatcher.Changes(code: true))
        engine.tasks.refresh()
        await shutdown.value
        try await pause(2)
        XCTAssertEqual(home.leftoverProcesses(), [], "nothing of the site runs")
    }

    /// A folder renamed into place (`mv app.new app`) restarts the task.
    func testAFolderRenamedIntoPlaceRestarts() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        try touch(folder, "app/Foo.php")
        try touch(folder, "app.new/Foo.php")
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let first = try XCTUnwrap(running(engine, "shop", "queue"))
        try await pause(1.5)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("app"), to: folder.appendingPathComponent("app.old"))
        XCTAssertEqual(rename(folder.appendingPathComponent("app.new").path, folder.appendingPathComponent("app").path), 0)
        XCTAssertNotNil(running(engine, "shop", "queue", otherThan: first))
    }

    /// A site whose folder goes away loses its watcher with its tasks.
    func testTheWatcherGoesWithTheSitesFolder() async throws {
        let folder = try home.makeSite("shop", tasks: #"{"tasks": {"queue": {"run": "exec sleep 600", "restartOnChange": true}}}"#)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        _ = try XCTUnwrap(running(engine, "shop", "queue"))
        let watcher = try XCTUnwrap(engine.tasks.watcher(site: "shop"))
        try FileManager.default.moveItem(at: folder, to: home.root.appendingPathComponent("aside"))
        engine.tasks.refresh()
        XCTAssertNil(engine.tasks.watcher(site: "shop"))
        XCTAssertTrue(watcher.isStopped)
    }

    // MARK: - Listening

    func testATaskListeningEverywhereIsWarnedButKeepsRunning() async throws {
        try FakeService.requireBuilt()
        let open = TestSupport.freeTCPPort()
        let local = TestSupport.freeTCPPort(excluding: [open])
        let data = try home.makeDirectory("data")
        for name in ["open", "local"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let fake = FakeService.binary.path
        _ = try home.makeSite("shop", tasks: """
        {"tasks": {
          "open": {"run": "exec '\(fake)' serve '\(data.path)/open' --port \(open) --any-address"},
          "local": {"run": "exec '\(fake)' serve '\(data.path)/local' --port \(local)"}
        }}
        """)
        let engine = await makeEngine()
        try await approve(engine, "shop")
        let pid = try XCTUnwrap(running(engine, "shop", "open"))
        XCTAssertTrue(waitFor(30) { self.task(engine, "shop", "open")?.warning != nil }, "checked 5 seconds after it started")
        XCTAssertEqual(task(engine, "shop", "open")?.warning, Messages.listening(ListeningAddress(host: "*", port: open))!)
        XCTAssertEqual(self.pid(engine, "shop", "open"), pid, "not stopped")
        XCTAssertNil(task(engine, "shop", "local")?.warning)
        XCTAssertTrue(Messages.taskTable(engine.status().sites.first { $0.name == "shop" }!.tasks!)
            .contains("open: \(Messages.listening(ListeningAddress(host: "*", port: open))!)"))
    }
}
