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

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    func testInstallSavesExistingFileAndIssuesOneScriptThatWritesDesiredContents() throws {
        try writeFile("nameserver 127.0.0.1\n")
        let runner = RecordingCommandRunner()
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
        XCTAssertTrue(script.contains("mktemp"), script)
        XCTAssertTrue(script.contains("chmod 644"), script)
        XCTAssertTrue(script.contains(b64(r.desiredContents)), "writes desiredContents")
        XCTAssertTrue(script.contains(b64("nameserver 127.0.0.1\n")), "guards on the file it saw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("resolver.pending").path),
                       "no staged file")
        XCTAssertFalse(script.contains(paths.home.path))
    }

    func testInstallThrowsChangedDuringInstallAndSavesNothing() throws {
        try writeFile("nameserver 127.0.0.1\n")
        let runner = RecordingCommandRunner { _, _ in (0, Resolver.changedMarker) }
        XCTAssertThrowsError(try resolver(runner).install()) {
            XCTAssertEqual($0 as? ResolverError, .changedDuringInstall)
        }
        XCTAssertNil(store.load().previousResolver)
    }

    func testCancelledInstallSavesNothing() throws {
        try writeFile("nameserver 127.0.0.1\n")
        let runner = RecordingCommandRunner { _, _ in (1, "User canceled. (-128)") }
        XCTAssertThrowsError(try resolver(runner).install())
        XCTAssertNil(store.load().previousResolver)
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
        try store.update { $0.previousResolver = "nameserver 10.0.0.9\n" }
        try writeFile("someone else's\n")
        try resolver(RecordingCommandRunner()).install()
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.9\n")
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
        let runner = RecordingCommandRunner()
        let outcome = try resolver(runner).restore()
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executable, osascript)
        let script = runner.calls[0].arguments[1]
        XCTAssertTrue(script.contains(b64("nameserver 127.0.0.1\n")), script)
        XCTAssertTrue(script.contains(b64(r.desiredContents)), "guards on Paddock's own contents")
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
        XCTAssertTrue(script.contains("/bin/rm -f"), script)
        XCTAssertFalse(script.contains("mktemp"), script)
    }

    func testRestoreWhenScriptFindsFileChangedKeepsSavedValue() throws {
        let r = resolver(RecordingCommandRunner())
        try writeFile(r.desiredContents)
        try store.update { $0.previousResolver = "nameserver 10.0.0.9\n" }
        let runner = RecordingCommandRunner { _, _ in (0, Resolver.changedMarker) }
        XCTAssertEqual(try resolver(runner).restore(), .changedByAnotherProgram)
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.9\n")
    }

    func testRestoreLeavesAFileSomeoneElseChanged() throws {
        try writeFile("nameserver 8.8.8.8\n")
        try store.update { $0.previousResolver = "nameserver 10.0.0.9\n" }
        let runner = RecordingCommandRunner()
        let outcome = try resolver(runner).restore()
        XCTAssertEqual(outcome, .changedByAnotherProgram)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.9\n")
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
        try store.update { $0.previousResolver = "nameserver 10.0.0.9\n" }
        let runner = RecordingCommandRunner { _, _ in (1, "User canceled.") }
        XCTAssertThrowsError(try resolver(runner).restore()) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.9\n")
    }

    // MARK: - Keeping the owner's original safe (D7)

    private var backupFile: URL { paths.backup.appendingPathComponent("resolver-test.orig") }

    func testInstallSavesTheOriginalBeforeThePromptToStateAndABackupFile() throws {
        try writeFile("nameserver 10.0.0.1\n")
        let store = self.store!, backup = backupFile
        // What state and the backup hold at the moment the privileged script runs.
        let seen = LockedBox<(String?, String?)>((nil, nil))
        let runner = RecordingCommandRunner { _, _ in
            seen.value = (store.load().previousResolver, try? String(contentsOf: backup, encoding: .utf8))
            return (0, "")
        }
        try resolver(runner).install()
        XCTAssertEqual(seen.value.0, "nameserver 10.0.0.1\n")
        XCTAssertEqual(seen.value.1, "nameserver 10.0.0.1\n")
    }

    func testCancelledOrRacedInstallRollsBackWhatItSaved() throws {
        for answer in [(Int32(1), "User canceled. (-128)"), (Int32(1), "boom"), (Int32(0), Resolver.changedMarker)] {
            try writeFile("nameserver 10.0.0.1\n")
            XCTAssertThrowsError(try resolver(RecordingCommandRunner { _, _ in answer }).install())
            XCTAssertNil(store.load().previousResolver, "\(answer)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backupFile.path), "\(answer)")
        }
    }

    func testCancelledInstallKeepsAValueSavedEarlier() throws {
        try store.update { $0.previousResolver = "nameserver 10.0.0.9\n" }
        try writeFile("nameserver 10.0.0.1\n")
        XCTAssertThrowsError(try resolver(RecordingCommandRunner { _, _ in (1, "User canceled.") }).install())
        XCTAssertEqual(store.load().previousResolver, "nameserver 10.0.0.9\n")
    }

    func testTheBackupIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: paths.backup, withIntermediateDirectories: true)
        try Data("nameserver 10.0.0.2\n".utf8).write(to: backupFile)
        try writeFile("nameserver 10.0.0.1\n")
        try resolver(RecordingCommandRunner()).install()
        XCTAssertEqual(try String(contentsOf: backupFile, encoding: .utf8), "nameserver 10.0.0.2\n")
    }

    func testRestoreFallsBackToTheBackupFileAndRemovesItAfterwards() throws {
        let r = resolver(RecordingCommandRunner())
        try writeFile(r.desiredContents)
        try FileManager.default.createDirectory(at: paths.backup, withIntermediateDirectories: true)
        try Data("nameserver 10.0.0.2\n".utf8).write(to: backupFile)
        let runner = RecordingCommandRunner()
        XCTAssertEqual(try resolver(runner).restore(), .restored)
        XCTAssertTrue(runner.calls[0].arguments[1].contains(b64("nameserver 10.0.0.2\n")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupFile.path))
    }

    func testSuccessfulRestoreRemovesTheBackup() throws {
        try writeFile("nameserver 10.0.0.1\n")
        let r = resolver(RecordingCommandRunner())
        try r.install()
        try writeFile(r.desiredContents)
        XCTAssertEqual(try r.restore(), .restored)
        XCTAssertNil(store.load().previousResolver)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupFile.path))
    }

    func testRestoreRefusesSavedContentsThatAreNotAResolverFile() throws {
        let r = resolver(RecordingCommandRunner())
        for bad in ["nameserver 127.0.0.1\nrm -rf /\n", "#!/bin/sh\n", "nameserverX 1.2.3.4\n",
                    "nameserver 127.0.0.1\n" + String(repeating: "search a\n", count: 120)] {
            try writeFile(r.desiredContents)
            try store.update { $0.previousResolver = bad }
            let runner = RecordingCommandRunner()
            XCTAssertThrowsError(try resolver(runner).restore()) {
                XCTAssertEqual($0 as? ResolverError, .savedCopyRejected, bad)
            }
            XCTAssertEqual(runner.calls, [], "nothing runs as root")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), r.desiredContents)
        }
    }

    func testEveryResolverKeywordIsAcceptedOnRestore() throws {
        let good = "nameserver 127.0.0.1\nport 53\n\nsearch_order 1\ntimeout 5\ndomain test\nsearch test\noptions x\n"
        XCTAssertTrue(Resolver.isSafeToRestore(good))
        XCTAssertTrue(Resolver.isSafeToRestore("  nameserver 10.0.0.1\n"))
        XCTAssertFalse(Resolver.isSafeToRestore("# comment\n"))
    }

    // MARK: - Re-running after a partial failure (I4c)

    func testRestoreWithNothingSavedAndAFileThatIsNotPaddocksIsSilent() throws {
        try writeFile("nameserver 8.8.8.8\n")
        let runner = RecordingCommandRunner()
        XCTAssertEqual(try resolver(runner).restore(), .notInstalled)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "nameserver 8.8.8.8\n")
    }

    func testRestoreOfAFileAlreadyPutBackIsSilentAndForgetsTheCopy() throws {
        // The privileged write succeeded but saving state afterwards didn't.
        try writeFile("nameserver 10.0.0.1\n")
        try store.update { $0.previousResolver = "nameserver 10.0.0.1\n" }
        let runner = RecordingCommandRunner()
        XCTAssertEqual(try resolver(runner).restore(), .notInstalled)
        XCTAssertEqual(runner.calls, [])
        XCTAssertNil(store.load().previousResolver)
    }

    // MARK: - Quoting

    func testShellQuotingSurvivesSpaceSingleAndDoubleQuote() {
        XCTAssertEqual(Resolver.shellQuote("/a b/it's \"x\""), "'/a b/it'\\''s \"x\"'")
        XCTAssertEqual(Resolver.shellQuote("plain"), "'plain'")
    }

    func testAppleScriptEscapingDoublesBackslashesAndEscapesQuotes() {
        XCTAssertEqual(Resolver.appleScriptEscape("a\\b \"c\""), "a\\\\b \\\"c\\\"")
    }

    func testScriptForTrickyDestinationIsQuotedForShellThenAppleScript() throws {
        let tricky = URL(fileURLWithPath: "/Users/x/Application Support/it's \"odd\"/test")
        let shell = Resolver.guardedScript(destination: tricky, expected: nil, action: .remove)
        XCTAssertTrue(shell.hasPrefix("D='/Users/x/Application Support/it'\\''s \"odd\"/test'; "
            + "DIR='/Users/x/Application Support/it'\\''s \"odd\"'; "), shell)
        let apple = Resolver.appleScript(shell: shell)
        let literalStart = try XCTUnwrap(apple.range(of: "do shell script \""))
        let literalEnd = try XCTUnwrap(apple.range(of: "\" with prompt"))
        let literal = String(apple[literalStart.upperBound..<literalEnd.lowerBound])
        let unescaped = literal.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        XCTAssertEqual(unescaped, shell)
    }

    // MARK: - The privileged script itself, run as the current user on temp files

    private func runShell(_ script: String) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private var tricky: URL { dir.appendingPathComponent("it's a \"dir\"/test") }

    func testScriptWritesNewFileAtomicallyWithMode644() throws {
        let result = try runShell(Resolver.guardedScript(destination: tricky, expected: nil, action: .write("hello\n")))
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertEqual(try String(contentsOf: tricky, encoding: .utf8), "hello\n")
        let mode = try FileManager.default.attributesOfItem(atPath: tricky.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tricky.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["test"])
    }

    func testScriptReplacesFileOnlyWhileItStillMatchesExpected() throws {
        try FileManager.default.createDirectory(at: tricky.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old\n".write(to: tricky, atomically: true, encoding: .utf8)
        let ok = try runShell(Resolver.guardedScript(destination: tricky, expected: "old\n", action: .write("new\n")))
        XCTAssertEqual(ok.status, 0, ok.out)
        XCTAssertEqual(try String(contentsOf: tricky, encoding: .utf8), "new\n")

        let raced = try runShell(Resolver.guardedScript(destination: tricky, expected: "old\n", action: .write("x\n")))
        XCTAssertEqual(raced.status, 0)
        XCTAssertTrue(raced.out.contains(Resolver.changedMarker), raced.out)
        XCTAssertEqual(try String(contentsOf: tricky, encoding: .utf8), "new\n", "untouched")
    }

    func testScriptWithExpectedAbsentRefusesWhenFileAppeared() throws {
        try FileManager.default.createDirectory(at: tricky.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "theirs\n".write(to: tricky, atomically: true, encoding: .utf8)
        let result = try runShell(Resolver.guardedScript(destination: tricky, expected: nil, action: .write("x\n")))
        XCTAssertTrue(result.out.contains(Resolver.changedMarker), result.out)
        XCTAssertEqual(try String(contentsOf: tricky, encoding: .utf8), "theirs\n")
    }

    func testScriptRemoveOnlyWhenStillMatching() throws {
        try FileManager.default.createDirectory(at: tricky.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine\n".write(to: tricky, atomically: true, encoding: .utf8)
        let kept = try runShell(Resolver.guardedScript(destination: tricky, expected: "other\n", action: .remove))
        XCTAssertTrue(kept.out.contains(Resolver.changedMarker), kept.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tricky.path))
        let removed = try runShell(Resolver.guardedScript(destination: tricky, expected: "mine\n", action: .remove))
        XCTAssertEqual(removed.status, 0, removed.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tricky.path))
    }

    func testScriptTreatsASymlinkDestinationAsChanged() throws {
        try FileManager.default.createDirectory(at: tricky.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("elsewhere")
        try "mine\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tricky, withDestinationURL: target)
        let result = try runShell(Resolver.guardedScript(destination: tricky, expected: "mine\n", action: .remove))
        XCTAssertTrue(result.out.contains(Resolver.changedMarker), result.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
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
