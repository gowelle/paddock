import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The CLI's `start`, `stop` and `uninstall` decisions, driven with the recording fake and temp paths.
final class SystemLifecycleTests: XCTestCase {
    private var dir: URL!
    private var paths: Paths!
    private var store: StateStore!
    private var resolverFile: URL!
    private var agents: URL!
    private let daemon = URL(fileURLWithPath: "/opt/Paddock/paddockd")
    private let target = "gui/\(getuid())/app.paddock.paddockd"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: dir.appendingPathComponent("Library/Application Support/Paddock", isDirectory: true))
        store = StateStore(paths: paths)
        resolverFile = dir.appendingPathComponent("etc/resolver/test")
        agents = dir.appendingPathComponent("LaunchAgents", isDirectory: true)
        try store.update { $0 = State(parked: [dir.appendingPathComponent("Paddock").path]) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func lifecycle(_ runner: CommandRunner, enabled: Bool = true, settings: Settings = Settings(),
                           environment: [String: String]? = nil, daemonRunning: Bool = true) -> SystemLifecycle {
        SystemLifecycle(
            services: SystemServices(runner: runner, resolverFile: resolverFile, launchAgents: agents),
            paths: paths, settings: settings,
            environment: environment ?? (enabled ? [:] : ["PADDOCK_HOME": paths.home.path]),
            userHome: dir, daemonIsRunning: { daemonRunning })
    }

    private func writeResolver(_ text: String) throws {
        try FileManager.default.createDirectory(at: resolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: resolverFile, atomically: true, encoding: .utf8)
    }

    private var desired: String { "nameserver 127.0.0.1\nport 53535\n" }
    private var plist: URL { agents.appendingPathComponent("app.paddock.paddockd.plist") }

    private func runner(trusted: Bool = false, loaded: Bool = false, osascriptStatus: Int32 = 0,
                        osascriptOutput: String = "") -> RecordingCommandRunner {
        RecordingCommandRunner { exe, args in
            if exe == "/usr/bin/osascript" { return (osascriptStatus, osascriptOutput) }
            if args.first == "print" { return (loaded ? 0 : 113, "") }
            if args.first == "verify-cert" { return (trusted ? 0 : 1, "") }
            return (0, "")
        }
    }

    // MARK: - start

    func testEnabledStartIssuesOneOsascriptThenLaunchctlInOrder() throws {
        let fake = runner()
        let started = try lifecycle(fake).startViaSystem(daemon: daemon)
        XCTAssertTrue(started)
        XCTAssertEqual(fake.calls.map(\.executable),
                       ["/usr/bin/osascript", "/bin/launchctl", "/bin/launchctl"])
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count, 1)
        XCTAssertEqual(fake.calls.dropFirst().map(\.arguments), [
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testEnabledStartSkipsResolverWhenAlreadyInstalled() throws {
        try writeResolver(desired)
        let fake = runner()
        _ = try lifecycle(fake).startViaSystem(daemon: daemon)
        XCTAssertEqual(fake.calls.map(\.executable), ["/bin/launchctl", "/bin/launchctl"])
    }

    func testEnabledStartLeavesAnUpToDateLoadedAgentAlone() throws {
        try writeResolver(desired)
        _ = try lifecycle(runner()).startViaSystem(daemon: daemon)
        let fake = runner(loaded: true)
        _ = try lifecycle(fake).startViaSystem(daemon: daemon)
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target]])
    }

    func testLoadedAgentWhoseDaemonExitedIsKickstarted() throws {
        try writeResolver(desired)
        _ = try lifecycle(runner()).startViaSystem(daemon: daemon)
        let fake = runner(loaded: true)
        _ = try lifecycle(fake, daemonRunning: false).startViaSystem(daemon: daemon)
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["kickstart", target]])
        XCTAssertEqual(fake.calls.last?.executable, "/bin/launchctl")
    }

    func testResolverIgnoresPortEnvironmentWhenIntegrationIsEnabled() throws {
        var odd = Settings()
        odd.dnsPort = 9999
        try writeResolver(desired) // Paddock's own file, for the default port
        let fake = runner()
        _ = try lifecycle(fake, settings: odd, environment: ["PADDOCK_DNS_PORT": "9999"]).startViaSystem(daemon: daemon)
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
    }

    func testCancelledPasswordDoesNotStartTheAgent() throws {
        let fake = runner(osascriptStatus: 1, osascriptOutput: "User canceled. (-128)")
        XCTAssertThrowsError(try lifecycle(fake).startViaSystem(daemon: daemon)) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(fake.calls.map(\.executable), ["/usr/bin/osascript"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testDisabledStartIssuesNoCommandsAndSaysToLaunchDetached() throws {
        let fake = runner()
        let started = try lifecycle(fake, enabled: false).startViaSystem(daemon: daemon)
        XCTAssertFalse(started)
        XCTAssertEqual(fake.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    // MARK: - stop

    func testEnabledStopBootsTheAgentOut() throws {
        let fake = runner(loaded: true)
        XCTAssertTrue(try lifecycle(fake).stopViaSystem())
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["bootout", target]])
    }

    func testEnabledStopWithNoAgentLoadedReportsNothingToBootOut() throws {
        let fake = runner(loaded: false)
        XCTAssertFalse(try lifecycle(fake).stopViaSystem())
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target]])
    }

    func testDisabledStopIssuesNothing() throws {
        let fake = runner(loaded: true)
        XCTAssertFalse(try lifecycle(fake, enabled: false).stopViaSystem())
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - uninstall

    func testDisabledUninstallDoesNothing() throws {
        let fake = runner()
        let lines = try lifecycle(fake, enabled: false).uninstall()
        XCTAssertEqual(lines, ["Nothing to uninstall for this Paddock home."])
        XCTAssertEqual(fake.calls, [])
    }

    func testUninstallDoesEverythingInOrderAndReportsWhatItLeft() throws {
        try writeResolver(desired)
        try store.update { $0.previousResolver = "nameserver 127.0.0.1\n" }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "x".write(to: plist, atomically: true, encoding: .utf8)
        let fake = runner(trusted: true, loaded: true)
        let lines = try lifecycle(fake).uninstall()

        let steps = fake.calls.map { $0.executable == "/usr/bin/osascript" ? "osascript" : ($0.arguments.first ?? "") }
        XCTAssertEqual(steps, ["osascript", "print", "bootout", "verify-cert", "remove-trusted-cert"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertNil(store.load().previousResolver)
        XCTAssertTrue(lines.contains { $0.contains(".zshrc") }, "\(lines)")
        XCTAssertEqual(lines.last, "Paddock is uninstalled. Your sites in ~/Paddock and Paddock's data in "
            + "~/Library/Application Support/Paddock were left in place.")
    }

    func testUninstallSkipsResolverPromptWhenFileIsNotPaddocks() throws {
        try writeResolver("nameserver 8.8.8.8\n")
        let fake = runner()
        let lines = try lifecycle(fake).uninstall()
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
        XCTAssertTrue(lines.contains("\(resolverFile.path) was changed by another program, so Paddock left it alone."),
                      "\(lines)")
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 8.8.8.8\n")
    }

    func testUninstallWithNothingInstalledAsksNoPassword() throws {
        let fake = runner()
        let lines = try lifecycle(fake).uninstall()
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
        XCTAssertEqual(fake.calls.map(\.arguments.first), ["print", "verify-cert"])
        XCTAssertTrue(lines.last?.hasPrefix("Paddock is uninstalled.") == true)
    }

    func testUninstallCancelledPasswordLeavesTheAgentRunning() throws {
        try writeResolver(desired)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "x".write(to: plist, atomically: true, encoding: .utf8)
        let fake = runner(trusted: true, loaded: true, osascriptStatus: 1, osascriptOutput: "User canceled.")
        XCTAssertThrowsError(try lifecycle(fake).uninstall()) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(fake.calls.map(\.executable), ["/usr/bin/osascript"], "nothing else ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testUninstallFailedResolverRestoreLeavesTheAgentRunning() throws {
        try writeResolver(desired)
        let fake = runner(osascriptStatus: 1, osascriptOutput: "boom")
        XCTAssertThrowsError(try lifecycle(fake).uninstall()) {
            XCTAssertEqual($0 as? ResolverError, .failed("boom"))
        }
        XCTAssertEqual(fake.calls.map(\.executable), ["/usr/bin/osascript"])
    }
}
