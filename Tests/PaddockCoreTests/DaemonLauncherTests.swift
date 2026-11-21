import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Finding `paddockd` and the checks `paddock start` makes before launching anything. Never launches.
final class DaemonLauncherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// An executable placeholder file (never run).
    @discardableResult
    private func placeholder(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private var app: URL { dir.appendingPathComponent("Paddock.app") }

    func testTheDaemonBesideTheExecutableComesFirst() throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let daemon = try placeholder("Paddock.app/Contents/MacOS/paddockd")
        XCTAssertEqual(DaemonLauncher.daemonBinary(executableDirectories: [macOS])?.path,
                       daemon.resolvingSymlinksInPath().path)
    }

    func testTheCopyInBinFindsTheDaemonThroughItsResourcesRecord() throws {
        let daemon = try placeholder("Paddock.app/Contents/MacOS/paddockd")
        let bin = dir.appendingPathComponent("home/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try placeholder("home/bin/paddock")
        try Data(app.appendingPathComponent("Contents/Resources").path.utf8)
            .write(to: bin.appendingPathComponent(".resources"))
        XCTAssertEqual(DaemonLauncher.daemonBinary(executableDirectories: [bin])?.path,
                       daemon.resolvingSymlinksInPath().path)
    }

    func testNoDaemonAnywhereIsNil() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertNil(DaemonLauncher.daemonBinary(executableDirectories: [bin]))
        // A record naming resources without a daemon next to them doesn't count either.
        try Data(dir.appendingPathComponent("Gone.app/Contents/Resources").path.utf8)
            .write(to: bin.appendingPathComponent(".resources"))
        XCTAssertNil(DaemonLauncher.daemonBinary(executableDirectories: [bin]))
    }

    private func launcher(home: URL, daemon: URL?) -> (DaemonLauncher, RecordingCommandRunner) {
        let runner = RecordingCommandRunner()
        let paths = Paths(home: home)
        let lifecycle = SystemLifecycle(
            services: SystemServices(runner: runner, resolverFile: dir.appendingPathComponent("resolver/test"),
                                     launchAgents: dir.appendingPathComponent("LaunchAgents")),
            paths: paths, settings: Settings(), environment: ["PADDOCK_HOME": home.path],
            userHome: dir, daemonIsRunning: { false })
        return (DaemonLauncher(lifecycle: lifecycle, paths: paths, daemon: daemon), runner)
    }

    func testATooLongHomeIsReportedUpFrontNotAsATimeout() throws {
        let home = dir.appendingPathComponent(String(repeating: "h", count: 110), isDirectory: true)
        let (launcher, runner) = launcher(home: home, daemon: try placeholder("paddockd"))
        XCTAssertThrowsError(try launcher.ensureRunning()) { error in
            let socket = home.appendingPathComponent("run/paddockd.sock").path
            XCTAssertEqual(error as? DaemonLaunchError, .socketPathTooLong(path: socket))
            XCTAssertEqual((error as? DaemonLaunchError)?.message(),
                           "Paddock can't run from this folder: the path \(socket) is too long for macOS. "
                           + "Use a shorter PADDOCK_HOME.")
        }
        XCTAssertEqual(runner.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("run").path),
                       "nothing was launched")
    }

    /// On the real system (no PADDOCK_HOME) a build outside Paddock.app starts, restarts and stops nothing.
    func testADevelopmentBuildOnTheRealSystemNeitherStartsNorStopsAnything() throws {
        let home = URL(fileURLWithPath: "/tmp/pdk-dev-\(TestSupportToken.make())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = RecordingCommandRunner()
        let client = FakeDaemon(running: true)
        let paths = Paths(home: home)
        let lifecycle = SystemLifecycle(
            services: SystemServices(runner: runner, resolverFile: dir.appendingPathComponent("resolver/test"),
                                     launchAgents: dir.appendingPathComponent("LaunchAgents"),
                                     portHelperSource: nil,
                                     portHelperBinary: dir.appendingPathComponent("helper"),
                                     portHelperPlist: dir.appendingPathComponent("helper.plist")),
            paths: paths, settings: Settings(), environment: [:], userHome: dir,
            daemonIsRunning: { client.isRunning }, client: client, portHolders: { _ in [] })
        let launcher = DaemonLauncher(lifecycle: lifecycle, paths: paths, daemon: try placeholder("paddockd"))
        for (name, action) in [("start", { _ = try launcher.ensureRunning() }),
                               ("app start", { _ = try launcher.ensureRunning(honouringLoginSetting: true) }),
                               ("stop", { _ = try launcher.stop() })] as [(String, () throws -> Void)] {
            XCTAssertThrowsError(try action(), name) { XCTAssertEqual($0 as? DaemonLaunchError, .developmentBuild) }
        }
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(client.requests, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("run").path),
                       "nothing was launched")
    }

    func testADevelopmentHomeWithoutADaemonSaysSo() throws {
        let home = URL(fileURLWithPath: "/tmp/pdk-launch-\(TestSupportToken.make())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let (launcher, runner) = launcher(home: home, daemon: nil)
        XCTAssertThrowsError(try launcher.ensureRunning()) {
            XCTAssertEqual($0 as? DaemonLaunchError, .noDaemonBinary)
        }
        XCTAssertEqual(runner.calls, [])
    }
}

private enum TestSupportToken {
    static func make() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}
