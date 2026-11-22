import XCTest
@testable import PaddockCore

/// A mail reader for tests that must never be asked.
struct NoMail: MailReading {
    func inbox(at base: URL, limit: Int) async throws -> MailInbox { throw MailError.unreachable }
    func search(at base: URL, query: String, limit: Int) async throws -> MailInbox { throw MailError.unreachable }
    func message(at base: URL, id: String) async throws -> MailMessage { throw MailError.unreachable }
}

final class MCPServerTests: XCTestCase {
    private func server() -> MCPServer {
        MCPServer(tools: MCPTools(
            options: .init(),
            send: { request in
                XCTFail("the protocol tests reach no tool, but the daemon was sent \(request)")
                throw ClientError.daemonNotRunning
            },
            logSections: { _ in [] },
            mail: NoMail()))
    }

    private func reply(_ line: String, file: StaticString = #filePath, line number: UInt = #line) async throws -> JSONValue {
        let answer = await server().handle(line: line)
        let text = try XCTUnwrap(answer, "no reply", file: file, line: number)
        XCTAssertFalse(text.contains("\n"), "a reply is one line", file: file, line: number)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func initialize(_ version: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
    }

    func testInitializeAnswersWithTheClientsVersionWhenKnown() async throws {
        let answer = try await reply(initialize("2025-06-18"))
        XCTAssertEqual(answer["jsonrpc"], .string("2.0"))
        XCTAssertEqual(answer["id"], .number(1))
        let result = try XCTUnwrap(answer["result"])
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(result["serverInfo"]?["name"], .string("paddock"))
        XCTAssertEqual(result["serverInfo"]?["version"], .string(String(PaddockBuild.number)))
        XCTAssertEqual(result["capabilities"]?["tools"], .object([:]))
    }

    func testInitializeWithAnUnknownVersionAnswersTheNewest() async throws {
        let answer = try await reply(initialize("1999-01-01"))
        XCTAssertEqual(answer["result"]?["protocolVersion"], .string("2025-11-25"))
    }

    func testPingAnswersAnEmptyResult() async throws {
        let answer = try await reply(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        XCTAssertEqual(answer["id"], .string("p"))
        XCTAssertEqual(answer["result"], .object([:]))
    }

    func testANotificationGetsNoReply() async {
        let known = await server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(known)
        let unknown = await server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/x","params":{}}"#)
        XCTAssertNil(unknown)
        // A request-shaped method with no id is a notification too: no reply, whatever it names.
        let nameless = await server().handle(line: #"{"jsonrpc":"2.0","method":"nope"}"#)
        XCTAssertNil(nameless)
    }

    func testAnUnknownMethodIsMethodNotFound() async throws {
        let numbered = try await reply(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        XCTAssertEqual(numbered["id"], .number(7))
        XCTAssertEqual(numbered["error"]?["code"], .number(-32601))
        XCTAssertNil(numbered["result"])
        let named = try await reply(#"{"jsonrpc":"2.0","id":"abc","method":"nope"}"#)
        XCTAssertEqual(named["id"], .string("abc"))
        XCTAssertEqual(named["error"]?["code"], .number(-32601))
    }

    func testALineThatIsNotJSONIsAParseError() async throws {
        let answer = try await reply("{not json")
        XCTAssertEqual(answer["error"]?["code"], .number(-32700))
        XCTAssertEqual(answer["id"], .null)
        let empty = await server().handle(line: "   ")
        XCTAssertNil(empty)
    }

    func testARequestThatIsNotAnObjectIsInvalid() async throws {
        let answer = try await reply("[1,2]")
        XCTAssertEqual(answer["error"]?["code"], .number(-32600))
        let methodless = try await reply(#"{"jsonrpc":"2.0","id":3}"#)
        XCTAssertEqual(methodless["error"]?["code"], .number(-32600))
        XCTAssertEqual(methodless["id"], .number(3))
    }

    func testCallingAnUnknownToolIsInvalidParams() async throws {
        let answer = try await reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        XCTAssertEqual(answer["error"]?["code"], .number(-32602))
        let nameless = try await reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(nameless["error"]?["code"], .number(-32602))
    }

    func testRunAnswersEachLineInOrderUntilTheInputEnds() async throws {
        var input = [#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#]
        var output: [String] = []
        await server().run(readLine: { input.isEmpty ? nil : input.removeFirst() }, write: { output.append($0) })
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output[0].contains(#""id":1"#))
        XCTAssertTrue(output[1].contains(#""id":2"#))
    }

    func testAWholeNumberIsWrittenWithoutAFraction() throws {
        let value = JSONValue.object(["a": .number(100), "b": .number(1.5), "c": .string("x/y")])
        XCTAssertEqual(value.compact, #"{"a":100,"b":1.5,"c":"x/y"}"#)
    }
}
