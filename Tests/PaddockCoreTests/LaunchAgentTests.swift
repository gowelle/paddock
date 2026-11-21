import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

final class LaunchAgentTests: XCTestCase {
    private var dir: URL!
    private var paths: Paths!
    private var plist: URL!
    private let daemon = URL(fileURLWithPath: "/Applications/Paddock.app/Contents/MacOS/paddockd")
    private let target = "gui/\(getuid())/app.paddock.paddockd"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: dir.appendingPathComponent("Application Support/Paddock", isDirectory: true))
        plist = dir.appendingPathComponent("LaunchAgents/app.paddock.paddockd.plist")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func agent(_ runner: CommandRunner) -> LaunchAgent {
        LaunchAgent(runner: runner, plist: plist, paths: paths,
                    waits: .init(unload: 0.3, poll: 0.01, bootstrapRetry: 0.01))
    }

    /// A launchd that starts with the job `loaded` or not; bootout unloads it, bootstrap loads it.
    private func fake(loaded: Bool) -> RecordingCommandRunner {
        FakeLaunchd(loaded: loaded).runner()
    }

    func testPlistContentsIsAValidPropertyListWithTheRequiredKeys() throws {
        let text = agent(RecordingCommandRunner()).plistContents(daemon: daemon)
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        let dict = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(dict["Label"] as? String, "app.paddock.paddockd")
        XCTAssertEqual(dict["ProgramArguments"] as? [String], [daemon.path])
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((dict["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
        let log = paths.log.appendingPathComponent("paddockd.log").path
        XCTAssertEqual(dict["StandardOutPath"] as? String, log)
        XCTAssertEqual(dict["StandardErrorPath"] as? String, log)
        XCTAssertEqual(dict["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(dict["ExitTimeOut"] as? Int, 20, "time for a clean shutdown before launchd kills it")
        XCTAssertNil(dict["EnvironmentVariables"])
        XCTAssertFalse(text.contains("PADDOCK_"))
    }

    func testDefaultPlistLivesInUserLaunchAgents() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/app.paddock.paddockd.plist").path
        XCTAssertEqual(LaunchAgent.defaultPlist.path, expected)
    }

    func testInstallWritesPlistThenBootstraps() throws {
        let runner = fake(loaded: false)
        try agent(runner).install(daemon: daemon)
        XCTAssertEqual(try String(contentsOf: plist, encoding: .utf8), agent(runner).plistContents(daemon: daemon))
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
        XCTAssertTrue(runner.calls.allSatisfy { $0.executable == "/bin/launchctl" })
    }

    func testInstallBootsOutFirstWhenAlreadyLoaded() throws {
        let runner = fake(loaded: true)
        try agent(runner).install(daemon: daemon)
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["print", target],
            ["bootout", target],
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
    }

    func testInstallWaitsUntilBootoutHasUnloadedTheJobBeforeBootstrapping() throws {
        // bootout returns before launchd has let go of the job: it stays loaded for two more prints.
        let prints = LockedCounter()
        let runner = RecordingCommandRunner { _, args in
            switch args.first {
            case "print": return (prints.next() < 3 ? 0 : 113, "")
            default: return (0, "")
            }
        }
        try agent(runner).install(daemon: daemon)
        XCTAssertEqual(runner.calls.map { $0.arguments.first! }, ["print", "bootout", "print", "print", "print", "bootstrap"])
    }

    func testInstallRetriesAFailedBootstrapOnce() throws {
        let launchd = FakeLaunchd(loaded: true, bootstrapFailures: 1)
        let runner = launchd.runner()
        try agent(runner).install(daemon: daemon)
        XCTAssertEqual(runner.calls.map { $0.arguments.first! }, ["print", "bootout", "print", "bootstrap", "bootstrap"])
        XCTAssertTrue(launchd.loaded)
    }

    func testInstallGivesUpAfterTheSecondFailedBootstrap() {
        let runner = FakeLaunchd(bootstrapFailures: 2).runner()
        XCTAssertThrowsError(try agent(runner).install(daemon: daemon)) {
            XCTAssertEqual($0 as? LaunchAgentError, .failed("Bootstrap failed: 5: Input/output error"))
        }
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "bootstrap" }.count, 2)
    }

    func testStopSucceedsWhenBootoutFailsButTheJobIsGone() throws {
        let launchd = FakeLaunchd(loaded: true, bootoutStatus: 5)
        XCTAssertTrue(try agent(launchd.runner()).stop())
        XCTAssertFalse(launchd.loaded)
    }

    func testStopFailsWhenTheJobStaysLoaded() {
        let launchd = FakeLaunchd(loaded: true, bootoutStatus: 5, bootoutUnloads: false)
        XCTAssertThrowsError(try agent(launchd.runner()).stop()) {
            XCTAssertEqual($0 as? LaunchAgentError, .failed("Boot-out failed: 5: Input/output error"))
        }
    }

    func testInstalledDaemonIsReadFromACurrentPlistOnly() throws {
        let exe = dir.appendingPathComponent("MacOS/paddockd")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertNil(agent(fake(loaded: false)).installedDaemon(), "no plist")
        try agent(fake(loaded: false)).install(daemon: exe)
        XCTAssertEqual(agent(fake(loaded: true)).installedDaemon()?.path, exe.path)

        try FileManager.default.removeItem(at: exe)
        XCTAssertNil(agent(fake(loaded: true)).installedDaemon(), "the plist's daemon is gone")
    }


    func testIsLoadedFollowsPrintExitStatus() {
        XCTAssertTrue(agent(fake(loaded: true)).isLoaded())
        XCTAssertFalse(agent(fake(loaded: false)).isLoaded())
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        try agent(fake(loaded: false)).install(daemon: daemon)
        let runner = fake(loaded: true)
        try agent(runner).uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["print", target], ["bootout", target], ["print", target]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testUninstallWhenNotLoadedOnlyRemovesPlist() throws {
        try agent(fake(loaded: false)).install(daemon: daemon)
        let runner = fake(loaded: false)
        try agent(runner).uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["print", target]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testStopBootsOutButKeepsPlist() throws {
        try agent(fake(loaded: false)).install(daemon: daemon)
        let runner = fake(loaded: true)
        try agent(runner).stop()
        XCTAssertEqual(runner.calls.map(\.arguments), [["print", target], ["bootout", target], ["print", target]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testKickstartRunsLaunchctlKickstart() throws {
        let runner = fake(loaded: true)
        try agent(runner).kickstart()
        XCTAssertEqual(runner.calls, [.init(executable: "/bin/launchctl", arguments: ["kickstart", target])])
    }

    func testRestartKillsAndStartsTheLoadedJob() throws {
        let runner = fake(loaded: true)
        try agent(runner).restart()
        XCTAssertEqual(runner.calls.map(\.arguments), [["kickstart", "-k", target]])
    }

    /// A plist that already says what `install` would write is left as it is (only loaded if it isn't).
    func testInstallDoesNotRewriteACurrentPlist() throws {
        let fake = fake(loaded: false)
        try agent(fake).install(daemon: daemon)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: plist.path)
        let again = self.fake(loaded: false)
        try agent(again).install(daemon: daemon)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: plist.path)[.modificationDate] as? Date, old)
        XCTAssertEqual(again.calls.map { $0.arguments.first ?? "" }, ["print", "bootstrap"])
    }
}
