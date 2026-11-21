import Darwin
import XCTest
@testable import PaddockCore

/// `paddock.json`: reading it safely, every rule it must follow, the canonical hash approvals are tied to,
/// and the starter file.
final class SiteTasksFileTests: XCTestCase {
    private var root: URL!
    private var site: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/pdk-tf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        site = root.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to folder: URL? = nil) throws {
        try Data(text.utf8).write(to: (folder ?? site).appendingPathComponent("paddock.json"))
    }

    private func load() -> SiteTasksFile.LoadResult { SiteTasksFile.load(siteFolder: site) }

    private func reason(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        try write(text)
        guard case .invalid(let reason) = load() else {
            XCTFail("expected invalid, got \(load())", file: file, line: line)
            return nil
        }
        return reason
    }

    private func hash(_ text: String) throws -> String {
        try write(text)
        guard case .file(_, let hash) = load() else { XCTFail("expected a file: \(load())"); return "" }
        return hash
    }

    // MARK: - Reading

    func testNoFileIsNone() {
        XCTAssertEqual(load(), .none)
        XCTAssertEqual(SiteTasksFile.load(siteFolder: root.appendingPathComponent("missing")), .none)
    }

    func testAValidFileWithEveryOption() throws {
        try write("""
        {
          "tasks": {
            "queue": { "run": "php artisan queue:work redis --queue=default,scout --tries=3", "restartOnChange": true },
            "scheduler": { "run": "php artisan schedule:work", "autostart": false, "stopSeconds": 300 },
            "flutter-wave2": { "run": "bun run webhook:flutterwave:forward", "restartOnChange": false, "stopSeconds": 1 }
          },
          "proxy": { "/app": 8080, "/apps/v1.x_~-": 65535, "/low": 1024 }
        }
        """)
        guard case .file(let file, let hash) = load() else { return XCTFail("\(load())") }
        XCTAssertEqual(file.tasks["queue"], TaskDefinition(run: "php artisan queue:work redis --queue=default,scout --tries=3",
                                                           restartOnChange: true, autostart: nil, stopSeconds: nil))
        XCTAssertEqual(file.tasks["scheduler"]?.startsWithPaddock, false)
        XCTAssertEqual(file.tasks["scheduler"]?.stopGrace, 300)
        XCTAssertEqual(file.tasks["queue"]?.startsWithPaddock, true, "autostart defaults to true")
        XCTAssertEqual(file.tasks["queue"]?.stopGrace, 30, "stopSeconds defaults to 30")
        XCTAssertEqual(file.tasks["flutter-wave2"]?.restartOnChange, false)
        XCTAssertEqual(file.proxy, ["/app": 8080, "/apps/v1.x_~-": 65535, "/low": 1024])
        XCTAssertTrue(hash.hasPrefix("v1:"), hash)
        XCTAssertEqual(hash.count, 3 + 64)
    }

    func testAnEmptyObjectIsAFileWithNothingInIt() throws {
        try write("{}")
        guard case .file(let file, _) = load() else { return XCTFail("\(load())") }
        XCTAssertEqual(file, SiteTasksFile(tasks: [:], proxy: [:]))
    }

    func testEveryRuleHasItsReason() throws {
        let long = String(repeating: "a", count: 2001)
        let cases: [(String, String)] = [
            ("not json", "it isn't valid JSON"),
            ("[1, 2]", "it must be a JSON object"),
            (#"{"tasks": {}, "taks": 1}"#, #"unknown key "taks""#),
            (#"{"tasks": {"queue": {"run": "x", "restart": true}}}"#, #"unknown key "restart""#),
            (#"{"tasks": []}"#, #""tasks" must be an object of named tasks"#),
            (#"{"tasks": {"Queue": {"run": "x"}}}"#,
             #"task name "Queue" must start with a lowercase letter and use only lowercase letters, digits and dashes, up to 31 characters"#),
            (#"{"tasks": {"1queue": {"run": "x"}}}"#,
             #"task name "1queue" must start with a lowercase letter and use only lowercase letters, digits and dashes, up to 31 characters"#),
            (#"{"tasks": {"q_ueue": {"run": "x"}}}"#,
             #"task name "q_ueue" must start with a lowercase letter and use only lowercase letters, digits and dashes, up to 31 characters"#),
            ("{\"tasks\": {\"\(String(repeating: "q", count: 32))\": {\"run\": \"x\"}}}",
             "task name \"\(String(repeating: "q", count: 32))\" must start with a lowercase letter and use only lowercase letters, digits and dashes, up to 31 characters"),
            (#"{"tasks": {"queue": "php artisan queue:work"}}"#, #"task "queue" must be an object with a "run" command"#),
            (#"{"tasks": {"queue": {}}}"#, #"task "queue" has no "run" command"#),
            (#"{"tasks": {"queue": {"run": ""}}}"#, #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            ("{\"tasks\": {\"queue\": {\"run\": \"\(long)\"}}}",
             #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            (#"{"tasks": {"queue": {"run": "a\nb"}}}"#, #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            (#"{"tasks": {"queue": {"run": "a\rb"}}}"#, #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            (#"{"tasks": {"queue": {"run": "a\u0000b"}}}"#, #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            (#"{"tasks": {"queue": {"run": 5}}}"#, #"the "run" command of task "queue" must be one line of 1 to 2000 characters"#),
            (#"{"tasks": {"queue": {"run": "x", "autostart": "yes"}}}"#, #""autostart" of task "queue" must be true or false"#),
            (#"{"tasks": {"queue": {"run": "x", "restartOnChange": 1}}}"#, #""restartOnChange" of task "queue" must be true or false"#),
            (#"{"tasks": {"queue": {"run": "x", "stopSeconds": 0}}}"#, #""stopSeconds" of task "queue" must be a whole number from 1 to 300"#),
            (#"{"tasks": {"queue": {"run": "x", "stopSeconds": 301}}}"#, #""stopSeconds" of task "queue" must be a whole number from 1 to 300"#),
            (#"{"tasks": {"queue": {"run": "x", "stopSeconds": 2.5}}}"#, #""stopSeconds" of task "queue" must be a whole number from 1 to 300"#),
            (#"{"tasks": {"queue": {"run": "x", "stopSeconds": true}}}"#, #""stopSeconds" of task "queue" must be a whole number from 1 to 300"#),
            (#"{"proxy": [1]}"#, #""proxy" must be an object of paths and ports"#),
            (#"{"proxy": {"app": 8080}}"#, #"proxy path "app" must start with / and use only letters, digits and . _ ~ / -, without .. or //"#),
            (#"{"proxy": {"/": 8080}}"#, #"proxy path "/" must start with / and use only letters, digits and . _ ~ / -, without .. or //"#),
            (#"{"proxy": {"/a/../b": 8080}}"#, #"proxy path "/a/../b" must start with / and use only letters, digits and . _ ~ / -, without .. or //"#),
            (#"{"proxy": {"/a//b": 8080}}"#, #"proxy path "/a//b" must start with / and use only letters, digits and . _ ~ / -, without .. or //"#),
            (#"{"proxy": {"/a b": 8080}}"#, #"proxy path "/a b" must start with / and use only letters, digits and . _ ~ / -, without .. or //"#),
            (#"{"proxy": {"/app": 1023}}"#, #"the port for proxy path "/app" must be a whole number from 1024 to 65535"#),
            (#"{"proxy": {"/app": 65536}}"#, #"the port for proxy path "/app" must be a whole number from 1024 to 65535"#),
            (#"{"proxy": {"/app": "8080"}}"#, #"the port for proxy path "/app" must be a whole number from 1024 to 65535"#),
            (#"{"proxy": {"/app": 1e30}}"#, #"the port for proxy path "/app" must be a whole number from 1024 to 65535"#),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try reason(text), expected, text)
        }
        let longPath = "/" + String(repeating: "p", count: 101)
        XCTAssertEqual(try reason("{\"proxy\": {\"\(longPath)\": 8080}}"),
                       "proxy path \"\(longPath.prefix(64))\" must start with / and use only letters, digits and . _ ~ / -, without .. or //",
                       "a name from the file is shown at most 64 characters long")
    }

    func testAtMostSixteenTasksAndSixteenProxyPaths() throws {
        let sixteen = (1...16).map { "\"t\($0)\": {\"run\": \"x\"}" }.joined(separator: ", ")
        try write("{\"tasks\": {\(sixteen)}}")
        guard case .file = load() else { return XCTFail("16 tasks are allowed") }
        XCTAssertEqual(try reason("{\"tasks\": {\(sixteen), \"t17\": {\"run\": \"x\"}}}"), "it has more than 16 tasks")
        let proxies = (1...16).map { "\"/p\($0)\": 8080" }.joined(separator: ", ")
        try write("{\"proxy\": {\(proxies)}}")
        guard case .file = load() else { return XCTFail("16 proxy paths are allowed") }
        XCTAssertEqual(try reason("{\"proxy\": {\(proxies), \"/p17\": 8080}}"), "it has more than 16 proxy paths")
    }

    /// Text from the file is shown only as Paddock's sanitisers make it.
    func testAnUnknownKeyIsShownSanitised() throws {
        XCTAssertEqual(try reason("{\"ta\\u001b[31mks\": 1}"), #"unknown key "taks""#)
    }

    func testTheSizeCap() throws {
        let filler = String(repeating: " ", count: SiteTasksFile.maximumBytes - 2)
        try write("{" + filler + "}")
        guard case .file = load() else { return XCTFail("exactly 64 KB is allowed: \(load())") }
        XCTAssertEqual(try reason("{" + filler + " }"), "it is larger than 64 KB")
    }

    func testOnlyARegularFile() throws {
        try FileManager.default.createDirectory(at: site.appendingPathComponent("paddock.json"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(load(), .invalid(reason: "it isn't a regular file"))
        try FileManager.default.removeItem(at: site.appendingPathComponent("paddock.json"))
        XCTAssertEqual(mkfifo(site.appendingPathComponent("paddock.json").path, 0o600), 0)
        XCTAssertEqual(load(), .invalid(reason: "it isn't a regular file"), "a FIFO is never opened (it would block)")
    }

    func testASymlinkIsFollowedOnlyInsideTheSite() throws {
        let inside = site.appendingPathComponent("config/tasks.json")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tasks": {"queue": {"run": "php artisan queue:work"}}}"#.utf8).write(to: inside)
        try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("paddock.json").path,
                                                   withDestinationPath: "config/tasks.json")
        guard case .file(let file, _) = load() else { return XCTFail("\(load())") }
        XCTAssertEqual(file.tasks.keys.sorted(), ["queue"])

        let outside = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"tasks": {"evil": {"run": "x"}}}"#.utf8).write(to: outside)
        try FileManager.default.removeItem(at: site.appendingPathComponent("paddock.json"))
        try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("paddock.json").path,
                                                   withDestinationPath: outside.path)
        XCTAssertEqual(load(), .invalid(reason: "it is a link to a file outside the site's folder"))

        try FileManager.default.removeItem(at: site.appendingPathComponent("paddock.json"))
        try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("paddock.json").path,
                                                   withDestinationPath: "../shop/../elsewhere.json")
        XCTAssertEqual(load(), .invalid(reason: "it is a link to a file outside the site's folder"), "dot-dot tricks too")
    }

    /// A site folder that is itself a link (a linked site through a symlink) is read through it.
    func testASiteFolderReachedThroughALink() throws {
        try write(#"{"tasks": {"queue": {"run": "x"}}}"#)
        let link = root.appendingPathComponent("link-to-shop")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: site.path)
        guard case .file = SiteTasksFile.load(siteFolder: link) else { return XCTFail() }
    }

    /// What the cache is keyed on changes whenever the file is edited, and is nil without one.
    func testTheStampChangesWithTheFile() throws {
        XCTAssertNil(SiteTasksFile.stamp(siteFolder: site))
        try write(#"{"tasks": {}}"#)
        let first = try XCTUnwrap(SiteTasksFile.stamp(siteFolder: site))
        XCTAssertEqual(SiteTasksFile.stamp(siteFolder: site), first)
        try write(#"{"tasks": {"a": {"run": "x"}}}"#)
        XCTAssertNotEqual(SiteTasksFile.stamp(siteFolder: site), first)
    }

    // MARK: - The canonical hash

    func testTheHashIgnoresFormattingAndKeyOrder() throws {
        let a = try hash(#"{"tasks": {"queue": {"run": "php artisan queue:work", "stopSeconds": 10}, "b": {"run": "y"}}, "proxy": {"/app": 8080, "/b": 9000}}"#)
        let b = try hash("""
        {
            "proxy":   { "/b": 9000,
                         "/app": 8080 },
            "tasks": {
                "b": { "run": "y" },
                "queue": { "stopSeconds": 10, "run": "php artisan queue:work" }
            }
        }
        """)
        XCTAssertEqual(a, b)
    }

    func testDefaultsWrittenOutDoNotChangeTheHash() throws {
        let bare = try hash(#"{"tasks": {"queue": {"run": "x"}}}"#)
        XCTAssertEqual(try hash(#"{"tasks": {"queue": {"run": "x", "autostart": true, "stopSeconds": 30}}, "proxy": {}}"#), bare)
    }

    func testAnyChangeToWhatRunsChangesTheHash() throws {
        let base = #"{"tasks": {"queue": {"run": "x"}}, "proxy": {"/app": 8080}}"#
        let variants = [
            #"{"tasks": {"queue": {"run": "x "}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "X"}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue2": {"run": "x"}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x"}, "more": {"run": "x"}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x", "autostart": false}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x", "stopSeconds": 31}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x", "restartOnChange": true}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x", "restartOnChange": false}}, "proxy": {"/app": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x"}}, "proxy": {"/app": 8081}}"#,
            #"{"tasks": {"queue": {"run": "x"}}, "proxy": {"/apps": 8080}}"#,
            #"{"tasks": {"queue": {"run": "x"}}}"#,
        ]
        var seen = [try hash(base)]
        for text in variants {
            let next = try hash(text)
            XCTAssertFalse(seen.contains(next), text)
            seen.append(next)
        }
    }

    /// Unset and explicit `restartOnChange` are different approvals: what an unset one means may change.
    func testUnsetRestartOnChangeIsHashedAsUnset() throws {
        let file = SiteTasksFile(tasks: ["q": TaskDefinition(run: "x", restartOnChange: nil, autostart: nil, stopSeconds: nil)],
                                 proxy: [:])
        XCTAssertTrue(file.canonicalForm.contains("restartOnChange unset"), file.canonicalForm)
        XCTAssertTrue(file.canonicalForm.hasPrefix("paddock.json tasks v1\n"), "the canonical form is versioned")
    }

    /// Length-prefixed fields: no two different files share a canonical form however their text is split.
    func testTheCanonicalFormIsUnambiguous() {
        let one = SiteTasksFile(tasks: ["a": TaskDefinition(run: "x\nrun 1:y", restartOnChange: nil, autostart: nil,
                                                            stopSeconds: nil)], proxy: [:])
        let two = SiteTasksFile(tasks: ["a": TaskDefinition(run: "x", restartOnChange: nil, autostart: nil,
                                                            stopSeconds: nil)], proxy: [:])
        XCTAssertNotEqual(one.hash, two.hash)
    }

    // MARK: - Starter

    func testTheStarterIsForLaravelProjectsOnly() throws {
        XCTAssertNil(SiteTasksFile.starter(forSiteAt: site))
        try Data("<?php\n".utf8).write(to: site.appendingPathComponent("artisan"))
        let text = try XCTUnwrap(SiteTasksFile.starter(forSiteAt: site))
        guard case .file(let file, _) = SiteTasksFile.parse(Data(text.utf8)) else { return XCTFail(text) }
        XCTAssertEqual(file.tasks, ["queue": TaskDefinition(run: "php artisan queue:work", restartOnChange: nil,
                                                            autostart: nil, stopSeconds: nil),
                                    "scheduler": TaskDefinition(run: "php artisan schedule:work", restartOnChange: nil,
                                                                autostart: nil, stopSeconds: nil)])
        XCTAssertEqual(file.proxy, [:])
        guard case .file = SiteTasksFile.parse(Data(SiteTasksFile.example.utf8)) else {
            return XCTFail("the example for other projects is a valid file")
        }
    }
}
