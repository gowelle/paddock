import XCTest
@testable import PaddockCore

/// The sentences Paddock prints about site tasks.
final class TaskMessagesTests: XCTestCase {
    private func site(_ name: String, _ tasks: SiteTasksStatus?, secured: Bool = false) -> Site {
        Site(name: name, path: "/p/\(name)", kind: .parked, secured: secured, php: PHPVersion("8.4")!, pinned: false,
             tasks: tasks)
    }

    private func task(_ name: String, _ state: TaskState) -> TaskStatus {
        TaskStatus(name: name, run: "x", state: state, restartOnChange: false, logPath: "/l", warning: nil)
    }

    func testTheApprovalLineIsExactly() {
        XCTAssertEqual(Messages.tasksWaitingForApproval(site: "t-market"),
                       "t-market: paddock.json has tasks waiting for your approval. Review them with: paddock tasks on --show")
    }

    func testEveryTaskState() {
        XCTAssertEqual(Messages.taskState(.running(pid: 12)), "running (pid 12)")
        XCTAssertEqual(Messages.taskState(.starting), "starting")
        XCTAssertEqual(Messages.taskState(.stopped(reason: nil)), "stopped")
        XCTAssertEqual(Messages.taskState(.stopped(reason: .byYou)), "stopped by you")
        XCTAssertEqual(Messages.taskState(.stopped(reason: .exited)), "stopped: it keeps finishing by itself")
        XCTAssertEqual(Messages.taskState(.stopped(reason: .notAutostart)), "stopped (doesn't start with Paddock)")
        XCTAssertEqual(Messages.taskState(.crashed(reason: Messages.taskRestarting(status: 1))),
                       "crashed: exited with status 1; Paddock restarts it in a moment")
        XCTAssertEqual(Messages.taskState(.crashed(reason: Messages.taskGaveUp(status: 3, task: "queue"))),
                       "crashed: exited with status 3 5 times within a minute, so Paddock stopped restarting it. "
                       + "See: paddock tasks logs queue")
        XCTAssertEqual(Messages.taskState(.waitingForApproval), "waiting for your approval")
        XCTAssertEqual(Messages.taskState(.alreadyRunning(pid: 9)), "already running (pid 9), not started by this Paddock")
    }

    func testStatusLinesForEachKindOfSite() {
        let approved = SiteTasksStatus(approval: .approved, tasks: [task("queue", .running(pid: 4)),
                                                                    task("scheduler", .stopped(reason: .byYou))],
                                       pending: [], pendingHash: nil, notice: nil)
        let changed = SiteTasksStatus(approval: .changed, tasks: [task("queue", .running(pid: 5))], pending: [],
                                      pendingHash: "v1:x", notice: Messages.tasksChanged(site: "blog"))
        let waiting = SiteTasksStatus(approval: .needsApproval, tasks: [], pending: [], pendingHash: "v1:y", notice: nil)
        let invalid = SiteTasksStatus(approval: .invalid(reason: #"unknown key "taks""#), tasks: [], pending: [],
                                      pendingHash: nil, notice: nil)
        XCTAssertEqual(Messages.siteTasksLines([site("shop", approved), site("blog", changed), site("new", waiting),
                                                site("bad", invalid), site("plain", nil)]), [
            "shop/queue: running (pid 4)",
            "shop/scheduler: stopped by you",
            "blog/queue: running (pid 5)",
            "blog: paddock.json changed since you approved it; the approved version keeps running. "
                + "Review the change with: paddock tasks on --show",
            "new: paddock.json has tasks waiting for your approval. Review them with: paddock tasks on --show",
            #"bad: paddock.json can't be used: unknown key "taks"."#,
        ])
    }

    func testTheTaskTable() {
        let status = SiteTasksStatus(
            approval: .changed,
            tasks: [task("queue", .running(pid: 4)),
                    TaskStatus(name: "once", run: "php artisan migrate", state: .stopped(reason: .exited), restartOnChange: false,
                               logPath: "/l", warning: Messages.taskKeepsFinishing(task: "once"))],
            pending: [], pendingHash: nil, notice: Messages.tasksChanged(site: "shop"))
        XCTAssertEqual(Messages.taskTable(status), """
        TASK   STATE                                  COMMAND
        queue  running (pid 4)                        x
        once   stopped: it keeps finishing by itself  php artisan migrate
        once: \(Messages.taskKeepsFinishing(task: "once"))
        \(Messages.tasksChanged(site: "shop"))
        """)
    }

    func testTheTableSaysWhichTasksRestartWhenCodeChanges() {
        let status = SiteTasksStatus(
            approval: .approved,
            tasks: [TaskStatus(name: "queue", run: "x", state: .running(pid: 4), restartOnChange: true, logPath: "/l", warning: nil),
                    task("web", .running(pid: 5))],
            pending: [], pendingHash: nil, notice: nil)
        XCTAssertEqual(Messages.taskTable(status), """
        TASK   STATE            COMMAND
        queue  running (pid 4)  x
        web    running (pid 5)  x
        queue: restarts when code changes
        """)
    }

    func testWhatApprovingShows() {
        let pending = [PendingTask(name: "queue", run: "php artisan queue:work", port: nil),
                       PendingTask(name: "/app", run: nil, port: 8080)]
        XCTAssertEqual(Messages.approvalLines(pending, site: site("shop", nil, secured: true)),
                       ["queue: php artisan queue:work", "forward https://shop.test/app → 127.0.0.1:8080"])
        XCTAssertEqual(Messages.approvalLines(pending, site: site("blog", nil)),
                       ["queue: php artisan queue:work", "forward http://blog.test/app → 127.0.0.1:8080"])
    }

    /// A site's routes in effect show in `paddock tasks` and `paddock status`; one to Paddock's own port says so.
    func testRoutesInTheTableAndTheStatus() {
        let status = SiteTasksStatus(approval: .approved, tasks: [task("queue", .running(pid: 4))], pending: [],
                                     pendingHash: nil, notice: nil, routes: ["/app": 8080, "/ws": 6001])
        XCTAssertEqual(Messages.routeLines(status, site: site("shop", status, secured: true)),
                       ["forward https://shop.test/app → 127.0.0.1:8080", "forward https://shop.test/ws → 127.0.0.1:6001"])
        XCTAssertEqual(Messages.siteTasksLines([site("shop", status, secured: true)]), [
            "shop/queue: running (pid 4)",
            "shop: forward https://shop.test/app → 127.0.0.1:8080",
            "shop: forward https://shop.test/ws → 127.0.0.1:6001",
        ])
        XCTAssertEqual(Messages.routeOnPaddocksPort(prefix: "/app", port: 443),
                       "The route /app isn't used: port 443 is Paddock's own.")
        XCTAssertEqual(Messages.proxyRoutesNotApplied("bad config"),
                       "Paddock couldn't apply this site's proxy routes, so it serves it without them: bad config")
    }

    func testErrors() {
        XCTAssertEqual(Messages.taskError(.notApproved(site: "shop")),
                       "shop's tasks aren't approved yet. Review and approve them with: paddock tasks on")
        XCTAssertEqual(Messages.taskError(.noTasksFile(site: "shop")), "shop has no paddock.json. Start one with: paddock tasks init")
        XCTAssertEqual(Messages.taskError(.unknownTask(site: "shop", task: "qu\u{1B}[2Keue")),
                       #"shop has no task named "queue". See: paddock tasks"#, "a typed name is shown sanitised")
        XCTAssertEqual(Messages.taskError(.invalid(site: "shop", reason: "it isn't valid JSON")),
                       "shop's paddock.json can't be used: it isn't valid JSON.")
        XCTAssertEqual(Messages.taskError(.changedSinceShown(site: "shop")),
                       "shop's paddock.json changed after it was shown, so Paddock approved nothing. "
                       + "Review it again with: paddock tasks on --show")
        XCTAssertEqual(Messages.taskError(.notShowable(site: "shop", task: "queue",
                                                       problem: .character(position: 7, codePoint: 0x9))),
                       #"The command of task "queue" has a character that cannot be shown, at position 7 (U+0009), "#
                       + "so Paddock won't approve it. Make it plain text in paddock.json.")
        XCTAssertEqual(Messages.taskError(.stillStopping(task: "queue")), "queue is still stopping.")
        XCTAssertEqual(Messages.waitingForTask("queue"), "Waiting for queue to finish…")
        XCTAssertEqual(Messages.leftoversStopped(task: "queue", stopped: [12, 34], left: []),
                       "Stopped 2 processes left from an earlier run of queue: 12, 34.")
        XCTAssertEqual(Messages.leftoversStopped(task: "queue", stopped: [], left: []),
                       "Found no processes left from an earlier run of queue.")
        XCTAssertEqual(Messages.leftoversStopped(task: "queue", stopped: [12],
                                                 left: [(56, .notInSiteFolder), (78, .startedEarlier), (90, .runByPaddock)]),
                       "Stopped 1 process left from an earlier run of queue: 12. Left 3 that aren't provably that "
                       + "task's: 56 (not in the site's folder), 78 (started before the task's record), "
                       + "90 (run by Paddock).")
        XCTAssertEqual(Messages.leftoversStopped(task: "queue", stopped: [], left: [(5, .anotherUser), (6, .anotherBoot)]),
                       "Found no processes left from an earlier run of queue that are provably that task's. "
                       + "Left 2: 5 (another user's), 6 (the record is from another boot).")
        XCTAssertEqual(Messages.taskError(.alreadyRunning(site: "shop", task: "queue", pid: 7)),
                       "queue is already running (pid 7), not started by this Paddock. Stop that process first.")
        XCTAssertEqual(Messages.taskError(.notLaravel(site: "shop")),
                       "shop isn't a Laravel project, so Paddock has no starter paddock.json for it.")
        XCTAssertEqual(Messages.taskError(.fileExists(site: "shop", path: "/p/shop/paddock.json")),
                       "/p/shop/paddock.json already exists; Paddock never overwrites it.")
        XCTAssertEqual(Messages.taskError(.unknownSite("nope")), "Paddock doesn't serve a site named nope.")
    }

    func testWhatTasksInitAndOnSay() {
        XCTAssertEqual(Messages.noSiteHasTasks,
                       "No site has a paddock.json yet. Start one in a Laravel project with: paddock tasks init")
        XCTAssertEqual(Messages.tasksExample(site: "blog", path: "/p/blog/paddock.json"),
                       "blog isn't a Laravel project, so here is an example to start from. Save it as /p/blog/paddock.json:")
        XCTAssertEqual(Messages.tasksFileWritten(path: "/p/shop/paddock.json"),
                       "Wrote /p/shop/paddock.json. Review and approve its tasks with: paddock tasks on")
        XCTAssertEqual(Messages.nothingToApprove(path: "/p/shop/paddock.json"),
                       "/p/shop/paddock.json has no tasks or proxy paths to approve.")
    }

    func testNotesInATasksLog() {
        XCTAssertEqual(Messages.taskCutShort(after: 60, allowed: 300),
                       "Paddock was shutting down, so it stopped this task after 60 seconds instead of waiting the 300 "
                       + "its stopSeconds allow.")
        XCTAssertEqual(Messages.taskKeepsFinishing(task: "queue"),
                       "queue keeps finishing by itself, so Paddock stopped restarting it. Tasks are for commands that keep running.")
        XCTAssertEqual(Messages.taskState(.stopping), "stopping")
        XCTAssertTrue(Messages.tasksUseBasicEnvironment(.timedOut).hasSuffix("paddock tasks on"))
    }
}
