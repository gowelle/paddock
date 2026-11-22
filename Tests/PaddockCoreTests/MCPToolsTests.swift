import XCTest
@testable import PaddockCore

/// Stands in for the daemon: records what it was sent and answers with `answer`.
final class MCPFakeDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Request] = []
    private var handler: (Request) throws -> Response

    init(_ handler: @escaping (Request) throws -> Response) {
        self.handler = handler
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func send(_ request: Request) throws -> Response {
        lock.lock()
        sent.append(request)
        let handler = self.handler
        lock.unlock()
        return try handler(request)
    }
}

struct MCPFakeMail: MailReading {
    var inbox = MailInbox(total: 0, unread: 0, messages: [])
    var messages: [String: MailMessage] = [:]
    var failing: MailError?

    func inbox(at base: URL, limit: Int) async throws -> MailInbox {
        if let failing { throw failing }
        return MailInbox(total: inbox.total, unread: inbox.unread, messages: Array(inbox.messages.prefix(limit)))
    }

    func search(at base: URL, query: String, limit: Int) async throws -> MailInbox {
        if let failing { throw failing }
        let found = inbox.messages.filter { $0.subject.localizedCaseInsensitiveContains(query) }
        return MailInbox(total: inbox.total, unread: inbox.unread, messages: Array(found.prefix(limit)))
    }

    func message(at base: URL, id: String) async throws -> MailMessage {
        if let failing { throw failing }
        guard let message = messages[id] else { throw MailError.badAnswer(status: 404) }
        return message
    }
}

class MCPToolsTestCase: XCTestCase {
    var folder: URL!
    var shopPath: String { folder.appendingPathComponent("Sites/shop").path }

    override func setUpWithError() throws {
        // Symlinks resolved, as a site's folder is compared.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        folder = base.appendingPathComponent("pdk mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sites/shop/app/Http"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sites/blog"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func tasks(_ approval: TaskApprovalState = .approved) -> SiteTasksStatus {
        SiteTasksStatus(
            approval: approval,
            tasks: [
                TaskStatus(name: "queue", run: "php artisan queue:work", state: .running(pid: 42), restartOnChange: true,
                           logPath: folder.appendingPathComponent("queue.log").path, warning: nil),
                TaskStatus(name: "schedule", run: "php artisan schedule:work", state: .stopped(reason: .byYou),
                           restartOnChange: false, logPath: folder.appendingPathComponent("schedule.log").path,
                           warning: "Stopped by you."),
            ],
            pending: [], pendingHash: nil, notice: nil)
    }

    func status(approval: TaskApprovalState = .approved, services: [ServiceStatus]? = nil) -> EngineStatus {
        let php85 = PHPVersion(major: 8, minor: 5), php84 = PHPVersion(major: 8, minor: 4)
        let mail = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1.27.0", displayName: "Mail",
                                 state: .running, ports: ["http": 8025, "smtp": 1025],
                                 env: ["MAIL_HOST=127.0.0.1", "MAIL_PORT=1025"], openURL: "http://127.0.0.1:8025",
                                 dataPath: "/Users/someone/Library/Paddock/services/mail", autostart: true, mainPort: 1025)
        let postgres = ServiceStatus(id: "postgres", name: "PostgreSQL", kind: "postgres", version: "18.1",
                                     displayName: "PostgreSQL 18", state: .stopped, ports: ["main": 5432],
                                     env: ["DB_CONNECTION=pgsql", "DB_PORT=5432"], openURL: nil,
                                     dataPath: "/Users/someone/Library/Paddock/services/postgres", autostart: true,
                                     mainPort: 5432, secretEnvNames: ["DB_PASSWORD"])
        return EngineStatus(
            running: true, blockedBy: [],
            sites: [
                Site(name: "shop", path: shopPath, kind: .parked, secured: true, php: php84, pinned: true,
                     tasks: tasks(approval)),
                Site(name: "blog", path: folder.appendingPathComponent("Sites/blog").path, kind: .linked, secured: false,
                     php: php85, pinned: false),
            ],
            installedPHP: [php84, php85], defaultPHP: php85, processes: ["caddy": "running (pid 1)"],
            resolverInstalled: true, trustEnabled: true, dnsRunning: true, portHelperInstalled: true,
            services: services ?? [mail, postgres], notices: ["The web server's log is very large."], xdebug: [php84],
            executablePath: "/Applications/Paddock.app/Contents/MacOS/paddockd")
    }

    /// A daemon that answers everything with `status`.
    func daemon(_ status: EngineStatus? = nil) -> MCPFakeDaemon {
        let answer = status ?? self.status()
        return MCPFakeDaemon { _ in .ok(answer) }
    }

    func tools(_ daemon: MCPFakeDaemon, options: MCPTools.Options = .init(), logs: [LogSection] = [],
               mail: MCPFakeMail = MCPFakeMail()) -> MCPTools {
        MCPTools(options: options, send: { try daemon.send($0) }, logSections: { _ in logs }, mail: mail)
    }

    /// Calls a tool that must be on offer.
    func call(_ tools: MCPTools, _ name: String, _ arguments: JSONValue = .object([:]),
              file: StaticString = #filePath, line: UInt = #line) async throws -> MCPToolResult {
        let result = await tools.call(name, arguments: arguments)
        return try XCTUnwrap(result, "no tool named \(name)", file: file, line: line)
    }

    /// Calls a tool that must answer, and reads its answer.
    func answer(_ tools: MCPTools, _ name: String, _ arguments: JSONValue = .object([:]),
                file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let result = try await call(tools, name, arguments, file: file, line: line)
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        XCTAssertLessThanOrEqual(result.text.utf8.count, MCPTools.resultLimit, file: file, line: line)
        return try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    func write(_ text: String, to name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

final class MCPSeeingTests: MCPToolsTestCase {
    func testStatusGivesSitesServicesAndPHPAndLeavesPathsOfPaddockOut() async throws {
        let daemon = self.daemon()
        let tools = self.tools(daemon)
        let result = try await call(tools, "status")
        let answer = try await self.answer(tools, "status")

        XCTAssertEqual(answer["running"], true)
        let shop = try XCTUnwrap(answer["sites"]?.array?.first)
        XCTAssertEqual(shop["name"], "shop")
        XCTAssertEqual(shop["url"], "https://shop.test")
        XCTAssertEqual(shop["path"], .string(shopPath))
        XCTAssertEqual(shop["php"], "8.4")
        XCTAssertEqual(shop["pinned"], true)
        XCTAssertEqual(shop["https"], true)
        XCTAssertEqual(shop["kind"], "parked")
        XCTAssertNil(shop["tasks"], "tasks come with the site tool")
        XCTAssertEqual(answer["php"]?["installed"], .strings(["8.4", "8.5"]))
        XCTAssertEqual(answer["php"]?["default"], "8.5")
        XCTAssertEqual(answer["php"]?["xdebug"], .strings(["8.4"]))
        let mail = try XCTUnwrap(answer["services"]?.array?.first)
        XCTAssertEqual(mail["id"], "mail")
        XCTAssertEqual(mail["state"], "running")
        XCTAssertEqual(mail["ports"]?["smtp"], 1025)
        XCTAssertEqual(mail["env"], .strings(["MAIL_HOST=127.0.0.1", "MAIL_PORT=1025"]))
        XCTAssertEqual(answer["services"]?.array?.last?["state"], "stopped")
        XCTAssertEqual(answer["notices"], .strings(["The web server's log is very large."]))

        for hidden in ["dataPath", "executablePath", "Library/Paddock", "paddockd", "processes", "caddy"] {
            XCTAssertFalse(result.text.contains(hidden), "\(hidden) is Paddock's own business")
        }
        XCTAssertEqual(daemon.requests, [.status, .status])
    }

    func testSiteByNameAndByAFolderInsideIt() async throws {
        let tools = self.tools(daemon())
        for arguments: JSONValue in [.object(["name": "shop"]), .object(["name": "Shop.test"]),
                                     .object(["path": .string(shopPath)]),
                                     .object(["path": .string(shopPath + "/app/Http")])] {
            let answer = try await self.answer(tools, "site", arguments)
            XCTAssertEqual(answer["name"], "shop", "\(arguments)")
            XCTAssertEqual(answer["tasks"]?["approval"], "approved")
            let queue = try XCTUnwrap(answer["tasks"]?["tasks"]?.array?.first)
            XCTAssertEqual(queue["name"], "queue")
            XCTAssertEqual(queue["run"], "php artisan queue:work")
            XCTAssertEqual(queue["state"], "running")
            let schedule = try XCTUnwrap(answer["tasks"]?["tasks"]?.array?.last)
            XCTAssertEqual(schedule["state"], "stopped")
            XCTAssertEqual(schedule["reason"], "byYou")
            XCTAssertEqual(schedule["warning"], "Stopped by you.")
        }
    }

    func testAFolderBesideASiteWithALongerNameIsNotThatSite() async throws {
        let result = try await call(tools(daemon()), "site", .object(["path": .string(shopPath + "-old")]))
        XCTAssertTrue(result.isError)
    }

    func testSiteWithNeitherOrBothArgumentsFails() async throws {
        let tools = self.tools(daemon())
        let neither = try await call(tools, "site")
        XCTAssertTrue(neither.isError)
        XCTAssertTrue(neither.text.contains("name") && neither.text.contains("path"), neither.text)
        let both = try await call(tools, "site", .object(["name": "shop", "path": .string(shopPath)]))
        XCTAssertTrue(both.isError)
    }

    func testAnUnknownSiteFailsInOneSentence() async throws {
        let result = try await call(tools(daemon()), "site", .object(["name": "nope"]))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("\n"))
        XCTAssertTrue(result.text.contains("shop") && result.text.contains("blog"), "it names the sites there are")
        let elsewhere = try await call(tools(daemon()), "site", .object(["path": "/tmp"]))
        XCTAssertTrue(elsewhere.isError)
    }

    func testSiteAsksTheDaemonToReadTheTasksAgain() async throws {
        let daemon = self.daemon()
        _ = try await answer(tools(daemon), "site", .object(["name": "shop"]))
        XCTAssertEqual(daemon.requests, [.status, .tasksStatus(site: "shop")])
    }

    // MARK: Logs

    private func sections(_ urls: URL...) -> [LogSection] {
        [LogSection(title: "shop: logs", sources: urls.map { LogSource(title: $0.lastPathComponent, url: $0) })]
    }

    func testLogsListGivesTheSectionsAndTheirIds() async throws {
        let log = try write("a\n", to: "laravel.log")
        let answer = try await self.answer(tools(daemon(), logs: sections(log)), "logs_list")
        let section = try XCTUnwrap(answer["sections"]?.array?.first)
        XCTAssertEqual(section["title"], "shop: logs")
        XCTAssertEqual(section["logs"]?.array?.first?["id"], .string(log.path))
        XCTAssertEqual(section["logs"]?.array?.first?["title"], "laravel.log")
    }

    func testLogsReadGivesTheLastLinesAndFilters() async throws {
        let log = try write((1...150).map { "line \($0)" + ($0 % 50 == 0 ? " ERROR" : "") }.joined(separator: "\n") + "\n",
                            to: "laravel.log")
        let tools = self.tools(daemon(), logs: sections(log))
        let all = try await answer(tools, "logs_read", .object(["id": .string(log.path)]))
        XCTAssertEqual(all["lines"]?.array?.count, 100, "100 unless asked otherwise")
        XCTAssertEqual(all["lines"]?.array?.last, "line 150 ERROR")
        XCTAssertEqual(all["truncated"], false)
        XCTAssertNotNil(all["note"]?.string)

        let few = try await answer(tools, "logs_read", .object(["id": .string(log.path), "lines": 2]))
        XCTAssertEqual(few["lines"], .strings(["line 149", "line 150 ERROR"]))

        let errors = try await answer(tools, "logs_read", .object(["id": .string(log.path), "contains": "error"]))
        XCTAssertEqual(errors["lines"], .strings(["line 50 ERROR", "line 100 ERROR", "line 150 ERROR"]))
    }

    func testLogsReadClampsLines() async throws {
        let log = try write((1...700).map { "l\($0)" }.joined(separator: "\n") + "\n", to: "big.log")
        let tools = self.tools(daemon(), logs: sections(log))
        let many = try await answer(tools, "logs_read", .object(["id": .string(log.path), "lines": 100_000]))
        XCTAssertEqual(many["lines"]?.array?.count, 500)
        let none = try await answer(tools, "logs_read", .object(["id": .string(log.path), "lines": -3]))
        XCTAssertEqual(none["lines"], .strings(["l700"]))
    }

    func testLogsReadRefusesAnIdOutsideTheCatalog() async throws {
        let log = try write("a\n", to: "laravel.log")
        let secret = try write("the secret\n", to: "secret.txt")
        let tools = self.tools(daemon(), logs: sections(log))
        for id in [secret.path, "/etc/hosts", log.path + "/../secret.txt", ""] {
            let result = try await call(tools, "logs_read", .object(["id": .string(id)]))
            XCTAssertTrue(result.isError, id)
            XCTAssertFalse(result.text.contains("secret\n"))
        }
    }

    func testLogsReadRefusesALogThatIsNowASymlink() async throws {
        let secret = try write("the secret\n", to: "secret.txt")
        let link = folder.appendingPathComponent("laravel.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let result = try await call(tools(daemon(), logs: sections(link)), "logs_read", .object(["id": .string(link.path)]))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("the secret"))
    }

    func testALogThatHasGoneSaysSo() async throws {
        let gone = folder.appendingPathComponent("gone.log")
        let result = try await call(tools(daemon(), logs: sections(gone)), "logs_read", .object(["id": .string(gone.path)]))
        XCTAssertTrue(result.isError)
    }

    func testAHugeLogIsCutToTheLimitAndStaysValidJSON() async throws {
        let line = String(repeating: "é", count: 400)
        let log = try write((1...400).map { "\($0) \(line)" }.joined(separator: "\n") + "\n", to: "wide.log")
        let tools = self.tools(daemon(), logs: sections(log))
        let answer = try await self.answer(tools, "logs_read", .object(["id": .string(log.path), "lines": 500]))
        XCTAssertEqual(answer["truncated"], true)
        let lines = try XCTUnwrap(answer["lines"]?.array)
        XCTAssertGreaterThan(lines.count, 10)
        XCTAssertLessThan(lines.count, 400)
        XCTAssertEqual(lines.last?.string?.hasPrefix("400 "), true, "the newest lines are the ones kept")
    }

    func testOneVeryLongLineIsCutToo() async throws {
        let log = try write(String(repeating: "é", count: 100_000) + "\n", to: "one.log")
        let answer = try await self.answer(tools(daemon(), logs: sections(log)), "logs_read", .object(["id": .string(log.path)]))
        XCTAssertEqual(answer["truncated"], true)
        XCTAssertEqual(answer["lines"]?.array?.count, 1)
    }

    func testWithoutLogsTheLogToolsAreGone() async {
        let tools = self.tools(daemon(), options: .init(logs: false))
        XCTAssertFalse(tools.toolNames.contains { $0.hasPrefix("logs_") })
        XCTAssertTrue(tools.toolNames.contains("status"))
        let result = await tools.call("logs_list", arguments: .object([:]))
        XCTAssertNil(result)
    }

    // MARK: Mail

    private var mailbox: MCPFakeMail {
        let ada = MailAddress(name: "Ada", address: "ada@example.test")
        return MCPFakeMail(
            inbox: MailInbox(total: 2, unread: 1, messages: [
                MailSummary(id: "m2", read: false, from: ada, to: [MailAddress(address: "bob@example.test")],
                            subject: "Reset your password", created: Date(timeIntervalSince1970: 1_800_000_000),
                            attachments: 1, snippet: "Click the link"),
                MailSummary(id: "m1", read: true, from: ada, subject: "Welcome"),
            ]),
            messages: [
                "m2": MailMessage(id: "m2", from: ada, to: [MailAddress(address: "bob@example.test")],
                                  subject: "Reset your password", text: "Click https://shop.test/reset/abc",
                                  html: "<p>Click</p>",
                                  attachments: [MailPart(partID: "2", fileName: "terms.pdf", contentType: "application/pdf",
                                                         size: 2048)]),
                "m1": MailMessage(id: "m1", from: ada, subject: "Welcome", text: "", html: "<h1>Welcome</h1>"),
                "big": MailMessage(id: "big", from: ada, subject: "Big", text: String(repeating: "né ", count: 60_000)),
            ])
    }

    func testMailListAndRead() async throws {
        let tools = self.tools(daemon(), mail: mailbox)
        let list = try await answer(tools, "mail_list")
        XCTAssertEqual(list["total"], 2)
        XCTAssertEqual(list["unread"], 1)
        let first = try XCTUnwrap(list["messages"]?.array?.first)
        XCTAssertEqual(first["id"], "m2")
        XCTAssertEqual(first["from"], "Ada <ada@example.test>")
        XCTAssertEqual(first["to"], .strings(["bob@example.test"]))
        XCTAssertEqual(first["subject"], "Reset your password")
        XCTAssertEqual(first["read"], false)
        XCTAssertEqual(first["date"], "2027-01-15T08:00:00Z")

        let found = try await answer(tools, "mail_list", .object(["query": "welcome", "limit": 1]))
        XCTAssertEqual(found["messages"]?.array?.map { $0["id"] }, ["m1"])

        let message = try await answer(tools, "mail_read", .object(["id": "m2"]))
        XCTAssertEqual(message["subject"], "Reset your password")
        XCTAssertEqual(message["body"], "Click https://shop.test/reset/abc")
        XCTAssertEqual(message["bodyKind"], "text")
        XCTAssertEqual(message["attachments"], .array([.object(["name": "terms.pdf", "type": "application/pdf", "size": 2048])]))
        XCTAssertNotNil(message["note"]?.string)
    }

    func testMailReadFallsBackToHTML() async throws {
        let message = try await answer(tools(daemon(), mail: mailbox), "mail_read", .object(["id": "m1"]))
        XCTAssertEqual(message["body"], "<h1>Welcome</h1>")
        XCTAssertEqual(message["bodyKind"], "html")
    }

    func testALongMailBodyIsCut() async throws {
        let message = try await answer(tools(daemon(), mail: mailbox), "mail_read", .object(["id": "big"]))
        XCTAssertEqual(message["truncated"], true)
        XCTAssertEqual(message["body"]?.string?.hasPrefix("né né "), true)
    }

    func testMailWithoutAServiceSaysSo() async throws {
        let none = self.tools(daemon(status(services: [])), mail: mailbox)
        let list = try await call(none, "mail_list")
        XCTAssertTrue(list.isError)
        XCTAssertTrue(list.text.contains("paddock service add mail"), list.text)

        let stopped = ServiceStatus(id: "mail", name: "Mail", kind: "mail", version: "1", displayName: "Mail",
                                    state: .stopped, ports: ["http": 8025], env: [], openURL: nil, dataPath: "/x",
                                    autostart: true, mainPort: 1025)
        let read = try await call(tools(daemon(status(services: [stopped])), mail: mailbox), "mail_read", .object(["id": "m1"]))
        XCTAssertTrue(read.isError)
        XCTAssertTrue(read.text.contains("isn't running"), read.text)

        var failing = mailbox
        failing.failing = .unreachable
        let unreachable = try await call(tools(daemon(), mail: failing), "mail_list")
        XCTAssertEqual(unreachable, .failure(MailError.unreachable.sentence))
    }

    // MARK: Arguments and the daemon

    func testAWrongTypedArgumentFailsNamingIt() async throws {
        let tools = self.tools(daemon(), mail: mailbox)
        let wrong: [(String, JSONValue, String)] = [
            ("logs_read", .object(["id": 5]), "id"),
            ("logs_read", .object(["id": "x", "lines": "many"]), "lines"),
            ("logs_read", .object(["id": "x", "lines": 1.5]), "lines"),
            ("mail_read", .object([:]), "id"),
            ("mail_list", .object(["limit": true]), "limit"),
            ("site", .object(["name": .array([])]), "name"),
            ("site", .array([]), "name"),
        ]
        for (tool, arguments, named) in wrong {
            let result = try await call(tools, tool, arguments)
            XCTAssertTrue(result.isError, "\(tool) \(arguments)")
            XCTAssertTrue(result.text.contains(named), result.text)
        }
    }

    func testWhenTheDaemonIsNotRunningEveryToolSaysSo() async throws {
        let daemon = MCPFakeDaemon { _ in throw ClientError.daemonNotRunning }
        let tools = self.tools(daemon, mail: mailbox)
        let arguments: [String: JSONValue] = [
            "site": .object(["name": "shop"]), "logs_read": .object(["id": "/x.log"]), "mail_read": .object(["id": "m1"]),
            "site_php": .object(["site": "shop", "version": "8.4"]), "xdebug": .object(["version": "8.4", "on": true]),
            "service_control": .object(["name": "mail", "action": "restart"]),
            "database_create": .object(["service": "postgres", "database": "shop"]),
            "task_control": .object(["site": "shop", "task": "queue", "action": "restart"]),
        ]
        XCTAssertGreaterThanOrEqual(tools.toolNames.count, 6)
        for name in tools.toolNames + tools.toolNames {
            let result = try await call(tools, name, arguments[name] ?? .object([:]))
            XCTAssertEqual(result, .failure(Messages.daemonNotRunning), name)
        }
    }

    func testOtherTroubleReachingTheDaemonIsASentenceToo() async throws {
        let timedOut = try await call(tools(MCPFakeDaemon { _ in throw ClientError.timedOut }), "status")
        XCTAssertEqual(timedOut, .failure(Messages.didNotAnswer))
        let development = try await call(tools(MCPFakeDaemon { _ in throw ClientError.developmentBuild }), "status")
        XCTAssertEqual(development, .failure(Messages.developmentBuild))
        let refused = try await call(tools(MCPFakeDaemon { _ in .error(code: ErrorCode.internal, message: "No.") }), "status")
        XCTAssertEqual(refused, .failure("No."))
        let odd = try await call(tools(MCPFakeDaemon { _ in .envLines(["A=b"]) }), "status")
        XCTAssertTrue(odd.isError)
        XCTAssertFalse(odd.text.contains("A=b"))
    }
}
