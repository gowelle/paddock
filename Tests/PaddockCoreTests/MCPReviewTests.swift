import XCTest
@testable import PaddockCore

/// What a review of `paddock mcp` found, each pinned.
final class MCPReviewTests: MCPToolsTestCase {
    private func section(_ url: URL) -> [LogSection] {
        [LogSection(title: "shop: logs", sources: [LogSource(title: url.lastPathComponent, url: url)])]
    }

    func testAMailIdThatIsNotAnIdNeverReachesTheMailService() async throws {
        let message = MailMessage(id: "x", from: nil, subject: "s", text: "the newest message")
        var mail = MCPFakeMail()
        for id in ["latest/link-check", "abc/raw", "..", "../messages", "a b", "a?b=1", String(repeating: "a", count: 65)] {
            mail.messages[id] = message
        }
        let tools = self.tools(daemon(), mail: mail)
        for id in mail.messages.keys {
            let result = try await call(tools, "mail_read", .object(["id": .string(id)]))
            XCTAssertTrue(result.isError, id)
            XCTAssertFalse(result.text.contains("the newest message"), id)
        }
        mail.messages["Abc_123-xyz"] = message
        let fine = try await call(self.tools(daemon(), mail: mail), "mail_read", .object(["id": "Abc_123-xyz"]))
        XCTAssertFalse(fine.isError, fine.text)
    }

    func testALargeLogThatEndsInOneLongLineStillShowsItsEnd() async throws {
        let log = try write(String(repeating: "é", count: 200_000) + "THE END\n", to: "long.log")
        let answer = try await self.answer(tools(daemon(), logs: section(log)), "logs_read", .object(["id": .string(log.path)]))
        XCTAssertEqual(answer["truncated"], true)
        let lines = try XCTUnwrap(answer["lines"]?.array)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.string?.contains("ééé"), true)
        XCTAssertEqual(lines.first?.string?.contains("\u{FFFD}"), false, "cut between characters, not inside one")
    }

    func testALineOfVeryLargeCharactersIsCutByItsSize() async throws {
        let family = "👨‍👩‍👧‍👦"
        let marks = "a" + String(repeating: "\u{0301}", count: 60_000)
        let log = try write(String(repeating: family, count: 4000) + "\n" + marks + "\nlast\n", to: "emoji.log")
        let answer = try await self.answer(tools(daemon(), logs: section(log)), "logs_read", .object(["id": .string(log.path)]))
        XCTAssertEqual(answer["truncated"], true)
        XCTAssertEqual(answer["lines"]?.array?.count, 3)
        XCTAssertEqual(answer["lines"]?.array?.last, "last")
    }

    func testASitesLogFolderThatLeadsOutOfTheSiteIsNotRead() async throws {
        let outside = folder.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("the secret\n".utf8).write(to: outside.appendingPathComponent("system.log"))
        let storage = URL(fileURLWithPath: shopPath).appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("logs"), withDestinationURL: outside)

        let log = storage.appendingPathComponent("logs/system.log")
        let result = try await call(tools(daemon(), logs: section(log)), "logs_read", .object(["id": .string(log.path)]))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("the secret"))
    }

    func testASitesLogFolderLinkedElsewhereInsideTheSiteIsRead() async throws {
        let site = URL(fileURLWithPath: shopPath)
        let shared = site.appendingPathComponent("shared/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("fine\n".utf8).write(to: shared.appendingPathComponent("laravel.log"))
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("storage"),
                                                   withDestinationURL: site.appendingPathComponent("shared"))
        let log = site.appendingPathComponent("storage/logs/laravel.log")
        let answer = try await self.answer(tools(daemon(), logs: section(log)), "logs_read", .object(["id": .string(log.path)]))
        XCTAssertEqual(answer["lines"], .strings(["fine"]))
    }

    func testTheToolsNameCommandsThatExist() {
        let text = MCPTools.doing.map(\.description).joined(separator: " ")
        XCTAssertFalse(text.contains("tasks approve"))
        XCTAssertTrue(text.contains("paddock tasks on"))
    }

    func testSiteWithNoArgumentAsksForOne() async throws {
        let neither = try await call(tools(daemon()), "site")
        XCTAssertFalse(neither.text.contains("not both"), neither.text)
    }
}
