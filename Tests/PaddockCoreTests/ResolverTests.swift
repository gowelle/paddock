import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Everything here runs against temp files and the recording fake: nothing touches /etc.
final class ResolverTests: XCTestCase {
    private var dir: URL!
    private var paths: Paths!
    private var store: StateStore!
    private var file: URL!
    private let osascript = "/usr/bin/osascript"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(home: dir.appendingPathComponent("Application Support/Paddock", isDirectory: true))
        store = StateStore(paths: paths)
        file = dir.appendingPathComponent("resolver/test")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func resolver(_ runner: CommandRunner, settings: Settings = Settings()) -> Resolver {
        Resolver(file: file, settings: settings, store: store, runner: runner)
    }

    private func writeFile(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Contents

    func testDesiredContentsUseDNSPort() {
        XCTAssertEqual(resolver(RecordingCommandRunner()).desiredContents, "nameserver 127.0.0.1\nport 53535\n")
        var settings = Settings()
        settings.dnsPort = 9999
        XCTAssertEqual(resolver(RecordingCommandRunner(), settings: settings).desiredContents,
                       "nameserver 127.0.0.1\nport 9999\n")
    }

    func testDefaultFileFollowsTLD() {
        var settings = Settings()
        settings.tld = "dev"
        XCTAssertEqual(Resolver.defaultFile(settings: settings).path, "/etc/resolver/dev")
    }

    func testIsInstalledOnlyWhenContentsMatch() throws {
        let r = resolver(RecordingCommandRunner())
        XCTAssertFalse(r.isInstalled())
        try writeFile("nameserver 127.0.0.1\n")
        XCTAssertFalse(r.isInstalled())
        try writeFile(r.desiredContents)
        XCTAssertTrue(r.isInstalled())
    }

    // MARK: - Install

    func testInstallSavesExistingFileAndIssuesOneScriptThatWritesDesiredContents() throws {
        try writeFile("nameserver 127.0.0.1\n")
        let staged = LockedBox<String?>(nil)
        let pending = paths.home.appendingPathComponent("resolver.pending")
        let runner = RecordingCommandRunner { _, _ in
            staged.value = try? String(contentsOf: pending, encoding: .utf8)
            return (0, "")
        }
        let r = resolver(runner)
        try r.install()

        XCTAssertEqual(store.load().previousResolver, "nameserver 127.0.0.1\n")
        XCTAssertEqual(runner.calls.count, 1)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, osascript)
        XCTAssertEqual(call.arguments.first, "-e")
        let script = call.arguments[1]
        XCTAssertTrue(script.hasPrefix("do shell script \""), script)
        XCTAssertTrue(script.contains("with prompt \"Paddock needs your password to route .test domains to this Mac.\""), script)
        XCTAssertTrue(script.hasSuffix("with administrator privileges"), script)
        XCTAssertTrue(script.contains("mkdir -p"), script)
        XCTAssertTrue(script.contains("chmod 644"), script)
        XCTAssertEqual(staged.value, r.desiredContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "staging file is cleaned up")
    }

    func testInstallWithNoFileSavesNothing() throws {
        let runner = RecordingCommandRunner()
        try resolver(runner).install()
        XCTAssertNil(store.load().previousResolver)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSecondInstallDoesNotOverwriteSavedValue() throws {
        try writeFile("nameserver 10.0.0.1\n")
        let r = resolver(RecordingCommandRunner())
        try r.install()
        try writeFile(r.desiredContents) // what the privileged script did
        try r.install()
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.1\n")
    }

    func testInstallWhenAlreadyPaddocksDoesNothing() throws {
        let runner = RecordingCommandRunner()
        let r = resolver(runner)
        try writeFile(r.desiredContents)
        try r.install()
        XCTAssertEqual(runner.calls, [])
        XCTAssertNil(store.load().previousResolver)
    }

    func testInstallKeepsAlreadySavedValueWhenFileChangedAgain() throws {
        try store.update { $0.previousResolver = "original\n" }
        try writeFile("someone else's\n")
        try resolver(RecordingCommandRunner()).install()
        XCTAssertEqual(store.load().previousResolver, "original\n")
    }

    func testCancelledPasswordPromptThrowsCancelled() throws {
        let runner = RecordingCommandRunner { _, _ in (1, "execution error: User canceled. (-128)") }
        XCTAssertThrowsError(try resolver(runner).install()) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
    }

    func testOtherFailureThrowsFailedWithMessage() throws {
        let runner = RecordingCommandRunner { _, _ in (1, "cp: broken") }
        XCTAssertThrowsError(try resolver(runner).install()) {
            XCTAssertEqual($0 as? ResolverError, .failed("cp: broken"))
        }
    }

    // MARK: - Restore

    func testRestoreWritesSavedTextBackAndClearsIt() throws {
        let r = resolver(RecordingCommandRunner())
        try writeFile(r.desiredContents)
        try store.update { $0.previousResolver = "nameserver 127.0.0.1\n" }
        let staged = LockedBox<String?>(nil)
        let pending = paths.home.appendingPathComponent("resolver.pending")
        let runner = RecordingCommandRunner { _, _ in
            staged.value = try? String(contentsOf: pending, encoding: .utf8)
            return (0, "")
        }
        let outcome = try resolver(runner).restore()
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, osascript)
        XCTAssertEqual(staged.value, "nameserver 127.0.0.1\n")
        XCTAssertNil(store.load().previousResolver)
    }

    func testRestoreWithNothingSavedRemovesTheFile() throws {
        let r = resolver(RecordingCommandRunner())
        try writeFile(r.desiredContents)
        let runner = RecordingCommandRunner()
        let outcome = try resolver(runner).restore()
        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(runner.calls.count, 1)
        let script = runner.calls[0].arguments[1]
        XCTAssertTrue(script.contains("rm -f"), script)
        XCTAssertFalse(script.contains("cp "), script)
    }

    func testRestoreLeavesAFileSomeoneElseChanged() throws {
        try writeFile("nameserver 8.8.8.8\n")
        try store.update { $0.previousResolver = "original\n" }
        let runner = RecordingCommandRunner()
        let outcome = try resolver(runner).restore()
        XCTAssertEqual(outcome, .changedByAnotherProgram)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(store.load().previousResolver, "original\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "nameserver 8.8.8.8\n")
    }

    func testRestoreWithNoFileDoesNothing() throws {
        let runner = RecordingCommandRunner()
        XCTAssertEqual(try resolver(runner).restore(), .notInstalled)
        XCTAssertEqual(runner.calls, [])
    }

    func testRestoreCancelledKeepsSavedValue() throws {
        let r = resolver(RecordingCommandRunner())
        try writeFile(r.desiredContents)
        try store.update { $0.previousResolver = "original\n" }
        let runner = RecordingCommandRunner { _, _ in (1, "User canceled.") }
        XCTAssertThrowsError(try resolver(runner).restore()) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(store.load().previousResolver, "original\n")
    }

    // MARK: - Quoting

    func testShellQuotingSurvivesSpaceSingleAndDoubleQuote() {
        XCTAssertEqual(Resolver.shellQuote("/a b/it's \"x\""), "'/a b/it'\\''s \"x\"'")
        XCTAssertEqual(Resolver.shellQuote("plain"), "'plain'")
    }

    func testAppleScriptEscapingDoublesBackslashesAndEscapesQuotes() {
        XCTAssertEqual(Resolver.appleScriptEscape("a\\b \"c\""), "a\\\\b \\\"c\\\"")
    }

    func testScriptForTrickyPathIsQuotedForShellThenAppleScript() throws {
        let tricky = "/Users/x/Application Support/it's \"odd\"/resolver.pending"
        let target = URL(fileURLWithPath: "/etc/resolver/test")
        let shell = Resolver.installShellScript(staged: URL(fileURLWithPath: tricky), target: target)
        XCTAssertEqual(shell, "mkdir -p '/etc/resolver' && cp '/Users/x/Application Support/it'\\''s \"odd\"/resolver.pending' '/etc/resolver/test' && chmod 644 '/etc/resolver/test'")
        let apple = Resolver.appleScript(shell: shell)
        // Un-escaping the AppleScript string literal gives back exactly the shell script.
        let literalStart = try XCTUnwrap(apple.range(of: "do shell script \""))
        let literalEnd = try XCTUnwrap(apple.range(of: "\" with prompt"))
        let literal = String(apple[literalStart.upperBound..<literalEnd.lowerBound])
        let unescaped = literal.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        XCTAssertEqual(unescaped, shell)
        XCTAssertFalse(literal.replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\\"", with: "").contains("\""))
    }

    // MARK: - Engine status

    func testEngineStatusReadsTheResolverFile() throws {
        let settings = Settings()
        let engine = Engine(paths: paths, settings: settings, resolverFile: file)
        XCTAssertFalse(engine.status().resolverInstalled)
        try writeFile(resolver(RecordingCommandRunner()).desiredContents)
        XCTAssertTrue(engine.status().resolverInstalled)
        try writeFile("nameserver 127.0.0.1\n")
        XCTAssertFalse(engine.status().resolverInstalled)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
