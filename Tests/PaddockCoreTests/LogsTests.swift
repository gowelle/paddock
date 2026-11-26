import XCTest
@testable import PaddockCore

private func temporaryFolder(_ test: XCTestCase) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdk logs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

final class LogTailTests: XCTestCase {
    func testTheFirstReadGivesTheLinesAndLaterReadsOnlyWhatWasAdded() throws {
        let log = try temporaryFolder(self).appendingPathComponent("a.log")
        try append("one\ntwo\n", to: log)
        let first = LogTail.read(log, after: nil)
        XCTAssertEqual(first.lines, ["one", "two"])
        XCTAssertTrue(first.restarted)
        XCTAssertEqual(first.position?.offset, 8)

        XCTAssertEqual(LogTail.read(log, after: first.position).lines, [], "nothing new")
        try append("three\n", to: log)
        let second = LogTail.read(log, after: first.position)
        XCTAssertEqual(second.lines, ["three"])
        XCTAssertFalse(second.restarted)
    }

    func testALineStillBeingWrittenWaitsForItsEnd() throws {
        let log = try temporaryFolder(self).appendingPathComponent("a.log")
        try append("done\nhalf a li", to: log)
        let first = LogTail.read(log, after: nil)
        XCTAssertEqual(first.lines, ["done"])
        try append("ne\n", to: log)
        XCTAssertEqual(LogTail.read(log, after: first.position).lines, ["half a line"])
    }

    func testARotatedOrCutDownLogStartsOver() throws {
        let folder = try temporaryFolder(self)
        let log = folder.appendingPathComponent("a.log")
        try append("old one\nold two\n", to: log)
        let before = LogTail.read(log, after: nil)

        // Rotated: another file under the same name.
        try FileManager.default.moveItem(at: log, to: folder.appendingPathComponent("a.log.1"))
        try append("fresh\n", to: log)
        let rotated = LogTail.read(log, after: before.position)
        XCTAssertTrue(rotated.restarted)
        XCTAssertEqual(rotated.lines, ["fresh"])

        // Cut down in place: shorter than where reading had got to.
        try append("more\nand more\n", to: log)
        let grown = LogTail.read(log, after: rotated.position)
        try Data("x\n".utf8).write(to: log, options: [])
        let cut = LogTail.read(log, after: grown.position)
        XCTAssertTrue(cut.restarted)
        XCTAssertEqual(cut.lines, ["x"])
    }

    func testALongLogIsReadFromItsEndWithoutAHalfLine() throws {
        let log = try temporaryFolder(self).appendingPathComponent("big.log")
        let line = String(repeating: "x", count: 99) + "\n"
        try append(String(repeating: line, count: 5000), to: log)   // 500 KB
        let chunk = LogTail.read(log, after: nil)
        XCTAssertTrue(chunk.restarted)
        XCTAssertLessThanOrEqual(chunk.lines.count, Int(LogTail.tailBytes) / 100)
        XCTAssertGreaterThan(chunk.lines.count, 2000)
        XCTAssertTrue(chunk.lines.allSatisfy { $0.count == 99 }, "no half line at the start")
        XCTAssertEqual(chunk.position?.offset, 500_000)
    }

    func testAMissingFileOrAFolderGivesNothingAndIsReadWhenItAppears() throws {
        let folder = try temporaryFolder(self)
        let log = folder.appendingPathComponent("later.log")
        let none = LogTail.read(log, after: nil)
        XCTAssertEqual(none.lines, [])
        XCTAssertNil(none.position)
        XCTAssertNil(LogTail.read(folder, after: nil).position, "a folder is not a log")
        try append("here now\n", to: log)
        XCTAssertEqual(LogTail.read(log, after: none.position).lines, ["here now"])
    }

    func testTerminalSequencesAndControlCharactersAreNotShown() {
        XCTAssertEqual(LogTail.clean("\u{1B}[32mINFO\u{1B}[39m  Running\r"), "INFO  Running")
        XCTAssertEqual(LogTail.clean("a\tb\u{07}c"), "a    bc")
        XCTAssertEqual(LogTail.clean("plain"), "plain")
    }
}

final class LogParserTests: XCTestCase {
    func testALaravelEntryKeepsItsLevelAndWhatFollowsIt() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append([
            "[2026-11-22 10:14:10] local.ERROR: Call to undefined method App\\Order::ship() {\"exception\":\"[object] (Error(code: 0)",
            "[stacktrace]",
            "#0 /Users/you/Code/shop/app/Http/Controllers/OrderController.php(42): ...",
            "\"}",
            "[2026-11-22T10:14:11.123456+09:00] production.WARNING: Slow query",
            "[2026-11-22 10:14:12] local.INFO: Order shipped",
        ], to: &entries)
        XCTAssertEqual(entries.map(\.level), ["ERROR", "WARNING", "INFO"])
        XCTAssertEqual(entries[0].detail.count, 3)
        XCTAssertTrue(entries[0].isProblem)
        XCTAssertTrue(entries[1].isWarning)
        XCTAssertFalse(entries[2].isProblem)
        XCTAssertEqual(entries.map(\.id), [0, 1, 2])

        // More of the same trace arriving in a later read still belongs to the last entry.
        parser.append(["#1 {main}"], to: &entries)
        XCTAssertEqual(entries[2].detail, ["#1 {main}"])
        XCTAssertTrue(entries[0].matches("ordercontroller"), "the filter looks inside the trace")
        XCTAssertFalse(entries[2].matches("ordercontroller"))
    }

    func testAnyOtherLogIsOneEntryPerLine() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append(["2026/11/22 10:14:10 caddy started", "  indented", "[notice] not laravel"], to: &entries)
        XCTAssertEqual(entries.map(\.text), ["2026/11/22 10:14:10 caddy started", "  indented", "[notice] not laravel"])
        XCTAssertTrue(entries.allSatisfy { $0.level == nil && $0.detail.isEmpty })
    }

    func testAVeryLongTraceIsCutWithACount() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append(["[2026-11-22 10:14:10] local.ERROR: Deep"] + (1...LogParser.detailLimit + 25).map { "#\($0) frame" },
                      to: &entries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].detail.count, LogParser.detailLimit + 1)
        XCTAssertEqual(entries[0].detail.last, "(25 more lines)")
    }

    func testPHPFPMAndPHPErrorLinesGetLevelsAndFoldWhatFollowsThem() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append([
            "[26-Nov-2026 10:14:10] NOTICE: fpm is running, pid 1234",
            "[26-Nov-2026 10:14:11] WARNING: [pool paddock] child 1234 exited on signal 11 (SIGSEGV)",
            "[26-Nov-2026 10:14:12]  [pool paddock] pid 9999",
            "script_filename = /Users/you/Code/shop/public/index.php",
            "[0x00007f8b8c0d9b20] run() /Users/you/Code/shop/vendor/laravel/framework/src/Illuminate/Foundation/Application.php:1",
            "[26-Nov-2026 10:14:13] ERROR: failed to ptrace(PEEKDATA) pid 1234: Input/output error (5)",
            "[26-Nov-2026 10:14:14 UTC] PHP Warning:  Undefined array key \"id\" in /app/routes.php on line 12",
            "[26-Nov-2026 10:14:15 UTC] PHP Fatal error:  Uncaught Error: Call to undefined method App\\Order::ship()",
            "Stack trace:",
            "#0 /app/x.php(10): foo()",
            "#1 {main}",
            "  thrown in /app/x.php on line 5",
        ], to: &entries)
        XCTAssertEqual(entries.map(\.level), ["NOTICE", "WARNING", nil, "ERROR", "WARNING", "ERROR"])
        XCTAssertEqual(entries[2].detail.count, 2, "the slowlog's script and stack lines belong to it")
        XCTAssertEqual(entries[5].detail.count, 4, "PHP's stack trace folds under its fatal error")
        XCTAssertTrue(entries[1].isWarning)
        XCTAssertTrue(entries[5].isProblem)
        XCTAssertFalse(entries[2].isProblem, "a slowlog entry has no error level of its own")
    }

    func testPostgresLinesGetLevelsAndTheirDetailsFold() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append([
            "2026-11-26 10:14:10.123 UTC [1234] LOG:  database system is ready to accept connections",
            "2026-11-26 10:14:12.000 UTC [1235] ERROR:  relation \"orders\" does not exist at character 15",
            "2026-11-26 10:14:12.000 UTC [1235] STATEMENT:  select * from orders;",
            "2026-11-26 10:14:12.000 UTC [1235] HINT:  Perhaps you meant to reference the table \"public.order\".",
            "2026-11-26 10:14:13.000 UTC [1236] FATAL:  the database system is starting up",
        ], to: &entries)
        XCTAssertEqual(entries.map(\.level), ["INFO", "ERROR", "CRITICAL"])
        XCTAssertEqual(entries[1].detail.count, 2)
        XCTAssertTrue(entries[1].isProblem)
        XCTAssertTrue(entries[2].isProblem)
    }

    func testMySQLLinesGetLevels() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append([
            "2026-11-26T10:14:10.123456Z 0 [System] [MY-010116] [Server] /usr/local/bin/mysqld (mysqld 8.4.4) starting as process 123",
            "2026-11-26T10:14:11.000000Z 12 [ERROR] [MY-000067] [Server] unknown variable 'foo=bar'",
            "2026-11-26T10:14:12.000000Z 12 [Warning] [MY-010055] [Server] IP address '1.2.3.4' could not be resolved",
        ], to: &entries)
        XCTAssertEqual(entries.map(\.level), ["INFO", "ERROR", "WARNING"])
        XCTAssertTrue(entries[1].isProblem)
        XCTAssertTrue(entries[2].isWarning)
    }

    func testCaddyJSONLinesGetLevelsAndShowTheirMessage() {
        var parser = LogParser()
        var entries: [LogEntry] = []
        parser.append([
            #"{"level":"info","ts":1700000000.1,"msg":"serving initial configuration"}"#,
            #"{"level":"error","ts":1700000001.2,"logger":"http.log.error","msg":"dial tcp 127.0.0.1:9000: connect: connection refused","request":{"remote_ip":"127.0.0.1"}}"#,
        ], to: &entries)
        XCTAssertEqual(entries.map(\.level), ["INFO", "ERROR"])
        XCTAssertEqual(entries.map(\.text), ["serving initial configuration",
                                             "dial tcp 127.0.0.1:9000: connect: connection refused"])
        XCTAssertEqual(entries[1].detail, ["logger=http.log.error"], "the other scalar fields stay, folded under it")
        XCTAssertTrue(entries[1].isProblem)
    }
}

final class LogCatalogTests: XCTestCase {
    func testTheLogsPaddockWritesAreGroupedAndNamed() throws {
        let home = try temporaryFolder(self)
        let paths = Paths(home: home)
        try FileManager.default.createDirectory(at: paths.log, withIntermediateDirectories: true)
        for name in ["paddockd.log", "caddy.log", "php-8.4.log", "php-fpm-8.4.log", "php-fpm-8.4.out.log", "php-fpm-8.5.log",
                     "service-mail.log", "service-gone.log", "notes.txt"] {
            try Data("x\n".utf8).write(to: paths.log.appendingPathComponent(name))
        }
        let mail = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1", displayName: "Mail", state: .running,
                                 ports: [:], env: [], openURL: nil, dataPath: "/d", autostart: true, mainPort: nil)
        let absent = ServiceStatus(id: "redis", name: "Redis (Valkey)", kind: "redis", version: "9", displayName: "Redis",
                                   state: .stopped, ports: [:], env: [], openURL: nil, dataPath: "/d", autostart: true, mainPort: nil)
        let status = EngineStatus(running: true, blockedBy: [], sites: [], installedPHP: [], defaultPHP: nil, processes: [:],
                                  resolverInstalled: true, trustEnabled: true, dnsRunning: true, portHelperInstalled: true,
                                  services: [mail, absent])
        let sections = LogCatalog.sections(paths: paths, status: status)
        XCTAssertEqual(sections.map(\.title), ["Paddock", "PHP", "Services"])
        XCTAssertEqual(sections[0].sources.map(\.title), ["Paddock", "Web server"])
        XCTAssertEqual(sections[1].sources.map(\.title), ["PHP-FPM 8.5", "PHP 8.4 errors", "PHP-FPM 8.4"])
        XCTAssertEqual(sections[2].sources.map(\.title), ["Mail"], "only services whose log exists")
        // Without a status, only what is in Paddock's own log folder.
        XCTAssertEqual(LogCatalog.sections(paths: paths, status: nil).map(\.title), ["Paddock", "PHP"])
        XCTAssertEqual(LogCatalog.sections(paths: Paths(home: home.appendingPathComponent("empty")), status: nil), [])
    }

    func testASitesOwnLogsAreItsRegularLogFilesWithLaravelsFirst() throws {
        let site = try temporaryFolder(self)
        let logs = site.appendingPathComponent("storage/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -5000)
        for (name, age) in [("orders.log", 10.0), ("laravel.log", 4000), ("payments.log", 200), ("notes.txt", 1)] {
            let file = logs.appendingPathComponent(name)
            try Data("x\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        // A symlink named like a log is never followed, and a folder is not a log.
        let secret = site.appendingPathComponent("secret")
        try Data("not a log".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked.log"), withDestinationURL: secret)
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("folder.log"), withIntermediateDirectories: true)
        _ = old

        XCTAssertEqual(LogCatalog.siteLogs(in: site).map(\.title), ["laravel.log", "orders.log", "payments.log"])
        XCTAssertEqual(LogCatalog.siteLogs(in: site.appendingPathComponent("no-such-site")), [])

        // Many logs: the newest, with laravel.log kept.
        for index in 0..<40 {
            let file = logs.appendingPathComponent("import-\(index).log")
            try Data("x\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(index))], ofItemAtPath: file.path)
        }
        let many = LogCatalog.siteLogs(in: site)
        XCTAssertEqual(many.count, LogCatalog.siteLogLimit)
        XCTAssertEqual(many.first?.title, "laravel.log")
        XCTAssertEqual(many[1].title, "import-0.log", "then the most recently written")
    }

    func testASitesTasksAndLogsEachGetASection() throws {
        let home = try temporaryFolder(self)
        let paths = Paths(home: home.appendingPathComponent("home"))
        let site = home.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: site.appendingPathComponent("storage/logs"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: site.appendingPathComponent("storage/logs/laravel.log"))
        let taskLog = paths.taskLog(site: "shop", task: "queue")
        try FileManager.default.createDirectory(at: taskLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: taskLog)
        var shop = Site(name: "shop", path: site.path, kind: .parked, secured: false, php: PHPVersion("8.4")!, pinned: false)
        shop.tasks = SiteTasksStatus(approval: .approved, tasks: [
            TaskStatus(name: "queue", run: "php artisan queue:work", state: .running(pid: 1), restartOnChange: false,
                       logPath: taskLog.path, warning: nil),
            TaskStatus(name: "never-ran", run: "x", state: .stopped(reason: nil), restartOnChange: false,
                       logPath: paths.taskLog(site: "shop", task: "never-ran").path, warning: nil),
        ], pending: [], pendingHash: nil, notice: nil)
        let status = EngineStatus(running: true, blockedBy: [], sites: [shop], installedPHP: [], defaultPHP: nil, processes: [:],
                                  resolverInstalled: true, trustEnabled: true, dnsRunning: true, portHelperInstalled: true)
        let sections = LogCatalog.sections(paths: paths, status: status)
        XCTAssertEqual(sections.map(\.title), ["shop: tasks", "shop: logs"])
        XCTAssertEqual(sections[0].sources.map(\.title), ["queue"], "a task that never logged has no log to show")
        XCTAssertEqual(sections[1].sources.map(\.id), [site.appendingPathComponent("storage/logs/laravel.log").path])
    }
}

@MainActor
final class LogsModelTests: XCTestCase {
    private func makeModel(_ folder: URL, _ names: [String], revealed: LogBox<[URL]>? = nil) -> LogsModel {
        let sources = names.map { LogSource(title: $0, url: folder.appendingPathComponent($0)) }
        return LogsModel(find: { [LogSection(title: "Test", sources: sources)] },
                         reveal: { url in revealed?.value.append(url) })
    }

    func testTheFirstLogIsShownAndNewLinesArriveOnTheNextLook() async throws {
        let folder = try temporaryFolder(self)
        try append("[2026-11-22 10:14:10] local.INFO: started\n", to: folder.appendingPathComponent("laravel.log"))
        let model = makeModel(folder, ["laravel.log", "other.log"])
        XCTAssertEqual(model.emptyText, "No logs yet. They appear here once Paddock has started.")
        await model.tick()
        XCTAssertEqual(model.selected?.title, "laravel.log")
        XCTAssertEqual(model.entries.map(\.level), ["INFO"])
        XCTAssertNil(model.emptyText)

        // An error thrown in the site shows on the next look, with its trace folded under it.
        try append("[2026-11-22 10:14:11] local.ERROR: Boom\n#0 app/Http/Kernel.php(10)\n", to: folder.appendingPathComponent("laravel.log"))
        let before = model.arrivals
        await model.tick()
        XCTAssertEqual(model.entries.map(\.level), ["INFO", "ERROR"])
        XCTAssertEqual(model.entries.last?.detail, ["#0 app/Http/Kernel.php(10)"])
        XCTAssertGreaterThan(model.arrivals, before)
        let error = try XCTUnwrap(model.entries.last)
        XCTAssertFalse(model.isExpanded(error))
        model.toggle(error)
        XCTAssertTrue(model.isExpanded(error))
        model.toggle(model.entries[0])
        XCTAssertFalse(model.isExpanded(model.entries[0]), "nothing to unfold")
    }

    func testChoosingAnotherLogShowsItFromItsEnd() async throws {
        let folder = try temporaryFolder(self)
        try append("a1\n", to: folder.appendingPathComponent("a.log"))
        try append("b1\nb2\n", to: folder.appendingPathComponent("b.log"))
        let model = makeModel(folder, ["a.log", "b.log"])
        await model.tick()
        XCTAssertEqual(model.entries.map(\.text), ["a1"])
        await model.select(folder.appendingPathComponent("b.log").path)
        XCTAssertEqual(model.entries.map(\.text), ["b1", "b2"])
        await model.show(path: folder.appendingPathComponent("a.log").path)
        XCTAssertEqual(model.entries.map(\.text), ["a1"])
        await model.show(path: "/not/listed.log")
        XCTAssertEqual(model.selected?.title, "a.log", "a log that isn't listed changes nothing")
    }

    func testTheFilterNarrowsWhatIsShownAndSaysWhenNothingMatches() async throws {
        let folder = try temporaryFolder(self)
        try append("alpha\nbeta\nAlphabet\n", to: folder.appendingPathComponent("a.log"))
        let model = makeModel(folder, ["a.log"])
        await model.tick()
        model.setFilter("ALPHA")
        XCTAssertEqual(model.shown.map(\.text), ["alpha", "Alphabet"])
        model.setFilter("zzz")
        XCTAssertEqual(model.emptyText, "Nothing in this log mentions \u{201C}zzz\u{201D}.")
        model.setFilter("  ")
        XCTAssertEqual(model.shown.count, 3)
    }

    func testErrorsOnlyKeepsTheProblemsAndSaysWhenThereAreNone() async throws {
        let folder = try temporaryFolder(self)
        try append("""
        [2026-11-22 10:14:10] local.INFO: started
        [2026-11-22 10:14:11] local.WARNING: slow
        [2026-11-22 10:14:12] local.ERROR: Boom

        """, to: folder.appendingPathComponent("laravel.log"))
        let model = makeModel(folder, ["laravel.log"])
        await model.tick()
        model.setProblemsOnly(true)
        XCTAssertEqual(model.shown.map(\.level), ["ERROR"])
        model.setFilter("started")
        XCTAssertEqual(model.emptyText, "Nothing in this log mentions \u{201C}started\u{201D}.")
        model.setFilter("")
        model.setProblemsOnly(false)
        XCTAssertEqual(model.shown.count, 3)

        try append("alpha\n", to: folder.appendingPathComponent("plain.log"))
        let plain = makeModel(folder, ["plain.log"])
        await plain.tick()
        plain.setProblemsOnly(true)
        XCTAssertEqual(plain.shown, [])
        XCTAssertEqual(plain.emptyText, "Nothing in this log is an error.")
    }

    func testPausedNothingIsAddedAndResumingCatchesUp() async throws {
        let folder = try temporaryFolder(self)
        let log = folder.appendingPathComponent("a.log")
        try append("one\n", to: log)
        let model = makeModel(folder, ["a.log"])
        await model.tick()
        await model.setPaused(true)
        try append("two\nthree\n", to: log)
        await model.tick()
        XCTAssertEqual(model.entries.map(\.text), ["one"])
        await model.setPaused(false)
        XCTAssertEqual(model.entries.map(\.text), ["one", "two", "three"])
    }

    func testARotatedLogReplacesWhatWasShownAndOnlySoManyEntriesAreKept() async throws {
        let folder = try temporaryFolder(self)
        let log = folder.appendingPathComponent("a.log")
        try append("old\n", to: log)
        let model = makeModel(folder, ["a.log"])
        await model.tick()
        try FileManager.default.removeItem(at: log)
        try append("new\n", to: log)
        await model.tick()
        XCTAssertEqual(model.entries.map(\.text), ["new"])

        try append((1...LogsModel.entryLimit + 50).map { "line \($0)\n" }.joined(), to: log)
        await model.tick()
        XCTAssertEqual(model.entries.count, LogsModel.entryLimit)
        XCTAssertEqual(model.entries.last?.text, "line \(LogsModel.entryLimit + 50)")
    }

    func testRevealShowsTheChosenLogsFile() async throws {
        let folder = try temporaryFolder(self)
        try append("x\n", to: folder.appendingPathComponent("a.log"))
        let revealed = LogBox<[URL]>([])
        let model = makeModel(folder, ["a.log"], revealed: revealed)
        model.revealSelected()
        XCTAssertEqual(revealed.value, [], "nothing chosen yet")
        await model.tick()
        model.revealSelected()
        XCTAssertEqual(revealed.value.map(\.lastPathComponent), ["a.log"])
    }

    func testALogThatLeavesTheListIsNoLongerShown() async throws {
        let folder = try temporaryFolder(self)
        try append("x\n", to: folder.appendingPathComponent("a.log"))
        let listed = LogBox<[String]>(["a.log"])
        let model = LogsModel(find: {
            let sources = listed.value.map { LogSource(title: $0, url: folder.appendingPathComponent($0)) }
            return sources.isEmpty ? [] : [LogSection(title: "Test", sources: sources)]
        })
        await model.tick()
        XCTAssertEqual(model.entries.count, 1)
        listed.value = []
        model.refreshSections()
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.entries, [])
    }
}

/// A value shared with a closure the model calls.
private final class LogBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
