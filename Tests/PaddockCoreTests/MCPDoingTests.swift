import XCTest
@testable import PaddockCore

final class MCPDoingTests: MCPToolsTestCase {
    private let php84 = PHPVersion(major: 8, minor: 4), php85 = PHPVersion(major: 8, minor: 5)

    func testSitePHPPinsAnInstalledVersionAndUnpins() async throws {
        let daemon = self.daemon()
        let tools = self.tools(daemon)
        let pinned = try await answer(tools, "site_php", .object(["site": "blog.test", "version": "8.4"]))
        XCTAssertNotNil(pinned["message"]?.string)
        XCTAssertEqual(pinned["site"]?["name"], "blog")
        XCTAssertEqual(daemon.requests, [.status, .isolate(site: "blog", version: php84)])

        let unpinned = self.daemon()
        _ = try await answer(self.tools(unpinned), "site_php", .object(["site": "shop"]))
        _ = try await answer(self.tools(unpinned), "site_php", .object(["site": "shop", "version": .null]))
        XCTAssertEqual(unpinned.requests, [.status, .unisolate(site: "shop"), .status, .unisolate(site: "shop")])
    }

    func testSitePHPRefusesAVersionThatIsNotInstalled() async throws {
        let daemon = self.daemon()
        for version in ["8.3", "banana"] {
            let result = try await call(tools(daemon), "site_php", .object(["site": "shop", "version": .string(version)]))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("8.4") && result.text.contains("8.5"), "it names the installed ones")
        }
        XCTAssertEqual(daemon.requests, [.status, .status], "nothing was changed")
    }

    func testXdebugSwitchesOnAndOff() async throws {
        let daemon = self.daemon()
        let on = try await answer(tools(daemon), "xdebug", .object(["version": "8.5", "on": true]))
        XCTAssertEqual(on["xdebug"], .strings(["8.4"]), "as the daemon's answer says")
        _ = try await answer(tools(daemon), "xdebug", .object(["version": "8.4", "on": false]))
        XCTAssertEqual(daemon.requests, [.status, .xdebug(version: php85, enabled: true),
                                         .status, .xdebug(version: php84, enabled: false)])
        let missing = try await call(tools(daemon), "xdebug", .object(["version": "7.4", "on": true]))
        XCTAssertTrue(missing.isError)
    }

    func testServiceControlSendsTheAction() async throws {
        let daemon = self.daemon()
        let tools = self.tools(daemon)
        let started = try await answer(tools, "service_control", .object(["name": "postgresql", "action": "start"]))
        XCTAssertEqual(started["service"]?["id"], "postgres")
        _ = try await answer(tools, "service_control", .object(["name": "mail", "action": "stop"]))
        _ = try await answer(tools, "service_control", .object(["name": "Mail", "action": "restart"]))
        XCTAssertEqual(daemon.requests.filter { $0 != .status },
                       [.serviceStart(name: "postgres"), .serviceStop(name: "mail"), .serviceRestart(name: "mail")])

        let unknown = try await call(tools, "service_control", .object(["name": "redis", "action": "start"]))
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("mail") && unknown.text.contains("postgres"), unknown.text)
    }

    func testAnUnknownActionFails() async throws {
        let daemon = self.daemon()
        let tools = self.tools(daemon)
        for (tool, arguments): (String, JSONValue) in [
            ("service_control", .object(["name": "mail", "action": "remove"])),
            ("service_control", .object(["name": "mail"])),
            ("task_control", .object(["site": "shop", "task": "queue", "action": "approve"])),
        ] {
            let result = try await call(tools, tool, arguments)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("action"), result.text)
        }
        XCTAssertTrue(daemon.requests.allSatisfy { $0 == .status })
    }

    func testDatabaseCreate() async throws {
        let status = self.status()
        let daemon = MCPFakeDaemon { request in
            if case .serviceCreateDatabase(_, let database) = request {
                return .databaseCreated(database: database, alreadyExisted: true, status: status)
            }
            return .ok(status)
        }
        let answer = try await self.answer(tools(daemon), "database_create", .object(["service": "postgres", "database": "shop"]))
        XCTAssertEqual(answer["database"], "shop")
        XCTAssertEqual(answer["alreadyExisted"], true)
        XCTAssertEqual(daemon.requests, [.status, .serviceCreateDatabase(name: "postgres", database: "shop")])
    }

    func testTaskControlSendsTheAction() async throws {
        let daemon = self.daemon()
        let tools = self.tools(daemon)
        let restarted = try await answer(tools, "task_control", .object(["site": "shop", "task": "queue", "action": "restart"]))
        XCTAssertEqual(restarted["site"]?["tasks"]?["tasks"]?.array?.count, 2)
        XCTAssertEqual(restarted["message"]?.string?.contains("has changed"), false)
        _ = try await answer(tools, "task_control", .object(["site": "shop", "task": "queue", "action": "stop"]))
        _ = try await answer(tools, "task_control", .object(["site": "shop", "task": "schedule", "action": "start"]))
        XCTAssertEqual(daemon.requests.filter { $0 != .status },
                       [.taskRestart(site: "shop", task: "queue"), .taskStop(site: "shop", task: "queue"),
                        .taskStart(site: "shop", task: "schedule")])
    }

    func testTaskControlSaysWhenTheFileHasChanged() async throws {
        let answer = try await self.answer(tools(daemon(status(approval: .changed))), "task_control",
                                           .object(["site": "shop", "task": "queue", "action": "restart"]))
        let message = try XCTUnwrap(answer["message"]?.string)
        XCTAssertTrue(message.contains("paddock.json has changed since it was approved"), message)
    }

    func testADaemonErrorIsPassedOnAsItsSentence() async throws {
        let status = self.status()
        let daemon = MCPFakeDaemon { request in
            request == .status ? .ok(status) : .error(code: ErrorCode.tasksNotApproved, message: "shop's tasks need approving first.")
        }
        let result = try await call(tools(daemon), "task_control", .object(["site": "shop", "task": "queue", "action": "start"]))
        XCTAssertEqual(result, .failure("shop's tasks need approving first."))
    }

    func testReadOnlyLeavesTheDoingToolsOut() async {
        let daemon = self.daemon()
        let tools = self.tools(daemon, options: .init(readOnly: true))
        XCTAssertEqual(tools.toolNames, ["status", "site", "logs_list", "logs_read", "mail_list", "mail_read"])
        let refused = await tools.call("site_php", arguments: .object(["site": "shop"]))
        XCTAssertNil(refused)
        XCTAssertEqual(daemon.requests, [])
        XCTAssertEqual(self.tools(daemon).toolNames.count, 11)
        XCTAssertEqual(self.tools(daemon, options: .init(readOnly: true, logs: false)).toolNames,
                       ["status", "site", "mail_list", "mail_read"])
    }

    func testEveryToolSaysWhatItIs() {
        for tool in tools(daemon()).definitions {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            XCTAssertEqual(tool.inputSchema["type"], "object", tool.name)
            let properties = Set((tool.inputSchema["properties"].flatMap { value -> [String]? in
                if case .object(let members) = value { return Array(members.keys) }
                return nil
            }) ?? [])
            let required = Set(tool.inputSchema["required"]?.array?.compactMap(\.string) ?? [])
            XCTAssertTrue(required.isSubset(of: properties), tool.name)
        }
        let doing = MCPTools.doing.map(\.name)
        XCTAssertEqual(doing, ["site_php", "xdebug", "service_control", "database_create", "task_control"])
        XCTAssertTrue(MCPTools.doing.allSatisfy { !$0.readOnly })
    }

    /// The line the server draws: whatever an agent asks, only these requests ever reach the daemon.
    func testOnlyTheAllowedRequestsAreEverSent() async throws {
        let allowed: Set<String> = ["status", "tasksStatus", "isolate", "unisolate", "xdebug", "serviceStart",
                                    "serviceStop", "serviceRestart", "serviceCreateDatabase", "taskStart", "taskStop",
                                    "taskRestart"]
        let daemon = self.daemon()
        let log = try write("a\n", to: "a.log")
        let tools = self.tools(daemon, logs: [LogSection(title: "x", sources: [LogSource(title: "a", url: log)])])
        let words = ["start", "stop", "restart", "remove", "approve", "trust", "secure", "env", "shop", "mail",
                     "postgres", "queue", "8.4", log.path]
        for name in tools.toolNames {
            for a in words {
                for b in ["start", "stop", "restart", "queue", "shop"] {
                    var arguments: [String: JSONValue] = [:]
                    for key in ["name", "site", "service", "task", "id", "version", "database"] { arguments[key] = .string(a) }
                    arguments["action"] = .string(b)
                    arguments["on"] = .bool(a.count % 2 == 0)
                    if name == "site" { arguments["path"] = nil }
                    _ = await tools.call(name, arguments: .object(arguments))
                    arguments["site"] = "shop"; arguments["task"] = .string(a); arguments["service"] = "postgres"
                    arguments["name"] = name == "site" ? "shop" : "mail"; arguments["version"] = "8.4"
                    _ = await tools.call(name, arguments: .object(arguments))
                }
            }
        }
        _ = await tools.call("site_php", arguments: .object(["site": "shop"]))
        let sent = Set(daemon.requests.map { String(String(describing: $0).prefix { $0 != "(" }) })
        XCTAssertEqual(sent, allowed, "every allowed request was exercised, and nothing else was sent")
    }
}
