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
        LaunchAgent(runner: runner, plist: plist, paths: paths)
    }

    /// Answers `launchctl print` with `loaded`, everything else with success.
    private func fake(loaded: Bool) -> RecordingCommandRunner {
        RecordingCommandRunner { _, args in (args.first == "print" ? (loaded ? 0 : 113) : 0, "") }
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
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
    }

    func testInstallThrowsWhenBootstrapFails() {
        let runner = RecordingCommandRunner { _, args in (args.first == "bootstrap" ? 5 : 1, "Bootstrap failed: 5") }
        XCTAssertThrowsError(try agent(runner).install(daemon: daemon)) {
            XCTAssertEqual($0 as? LaunchAgentError, .failed("Bootstrap failed: 5"))
        }
    }

    func testIsLoadedFollowsPrintExitStatus() {
        XCTAssertTrue(agent(fake(loaded: true)).isLoaded())
        XCTAssertFalse(agent(fake(loaded: false)).isLoaded())
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        try agent(fake(loaded: false)).install(daemon: daemon)
        let runner = fake(loaded: true)
        try agent(runner).uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["print", target], ["bootout", target]])
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
        XCTAssertEqual(runner.calls.map(\.arguments), [["print", target], ["bootout", target]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testKickstartRunsLaunchctlKickstart() throws {
        let runner = fake(loaded: true)
        try agent(runner).kickstart()
        XCTAssertEqual(runner.calls, [.init(executable: "/bin/launchctl", arguments: ["kickstart", target])])
    }
}
