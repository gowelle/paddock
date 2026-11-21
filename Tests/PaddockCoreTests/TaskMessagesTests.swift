import XCTest
@testable import PaddockCore

/// The sentences Paddock prints about site tasks.
final class TaskMessagesTests: XCTestCase {
    private func site(_ name: String, _ tasks: SiteTasksStatus?) -> Site {
        Site(name: name, path: "/p/\(name)", kind: .parked, secured: false, php: PHPVersion("8.4")!, pinned: false,
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

    func testWhatApprovingShows() {
        XCTAssertEqual(Messages.approvalLines([PendingTask(name: "queue", run: "php artisan queue:work", port: nil),
                                               PendingTask(name: "/app", run: nil, port: 8080)]),
                       ["queue: php artisan queue:work", "proxy /app → 127.0.0.1:8080"])
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
        XCTAssertEqual(Messages.taskError(.notShowable(site: "shop", task: "queue")),
                       #"The command of task "queue" contains characters that cannot be shown, so Paddock won't approve it. "#
                       + "Make it plain text in paddock.json.")
        XCTAssertEqual(Messages.taskError(.alreadyRunning(site: "shop", task: "queue", pid: 7)),
                       "queue is already running (pid 7), not started by this Paddock. Stop that process first.")
        XCTAssertEqual(Messages.taskError(.notLaravel(site: "shop")),
                       "shop isn't a Laravel project, so Paddock has no starter paddock.json for it.")
        XCTAssertEqual(Messages.taskError(.fileExists(site: "shop", path: "/p/shop/paddock.json")),
                       "/p/shop/paddock.json already exists; Paddock never overwrites it.")
        XCTAssertEqual(Messages.taskError(.unknownSite("nope")), "Paddock doesn't serve a site named nope.")
    }

    func testNotesInATasksLog() {
        XCTAssertEqual(Messages.taskCutShort(after: 60, allowed: 300),
                       "Paddock was shutting down, so it stopped this task after 60 seconds instead of waiting the 300 "
                       + "its stopSeconds allow.")
        XCTAssertEqual(Messages.taskKeepsExiting,
                       "It finished by itself 3 times within 10 seconds, so Paddock stopped restarting it. "
                       + "A task should be a command that keeps running.")
        XCTAssertTrue(Messages.tasksUseBasicEnvironment.hasSuffix("paddock tasks on"))
    }
}
