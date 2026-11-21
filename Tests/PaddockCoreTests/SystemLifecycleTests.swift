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
                           environment: [String: String]? = nil, daemonRunning: Bool = true,
                           client: FakeDaemon? = nil) -> SystemLifecycle {
        let daemon = client ?? FakeDaemon(running: daemonRunning)
        return SystemLifecycle(
            services: SystemServices(runner: runner, resolverFile: resolverFile, launchAgents: agents),
            paths: paths, settings: settings,
            environment: environment ?? (enabled ? [:] : ["PADDOCK_HOME": paths.home.path]),
            userHome: dir, daemonIsRunning: { daemon.isRunning }, client: daemon)
    }

    private var rcFile: URL { dir.appendingPathComponent(".zshrc") }

    private func writeResolver(_ text: String) throws {
        try FileManager.default.createDirectory(at: resolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: resolverFile, atomically: true, encoding: .utf8)
    }

    private var desired: String { "nameserver 127.0.0.1\nport 53535\n" }
    private var plist: URL { agents.appendingPathComponent("app.paddock.paddockd.plist") }

    /// launchctl answered by a fake launchd (loaded or not), osascript and `security verify-cert` as given.
    private func runner(trusted: Bool = false, loaded: Bool = false, osascriptStatus: Int32 = 0,
                        osascriptOutput: String = "") -> RecordingCommandRunner {
        let launchd = FakeLaunchd(loaded: loaded)
        return RecordingCommandRunner { exe, args in
            if exe == "/usr/bin/osascript" { return (osascriptStatus, osascriptOutput) }
            if let answer = launchd.answer(exe, args) { return answer }
            if args.first == "verify-cert" { return (trusted ? 0 : 1, "") }
            return (0, "")
        }
    }

    private func engineStatus(blockedBy: [PortHolder] = [], notPermitted: [Int] = []) -> EngineStatus {
        EngineStatus(running: blockedBy.isEmpty && notPermitted.isEmpty, blockedBy: blockedBy,
                     portsNotPermitted: notPermitted, sites: [], installedPHP: [], defaultPHP: nil,
                     processes: [:], resolverInstalled: false, trustEnabled: true, dnsRunning: true)
    }

    /// Starts with the engine reporting `status`; records how many times the engine was asked.
    private func start(_ lifecycle: SystemLifecycle, daemon: URL? = nil, status: EngineStatus? = nil,
                       engineCalls: LockedCounter? = nil) throws -> Bool {
        try lifecycle.startViaSystem(daemon: daemon ?? self.daemon) {
            _ = engineCalls?.next()
            return status ?? self.engineStatus()
        }
    }

    private var herd: [PortHolder] {
        [80, 443].map { PortHolder(port: $0, pid: 7, command: "nginx", ownedByCurrentUser: true,
                                   executablePath: "/Applications/Herd.app/Contents/Resources/nginx") }
    }

    // MARK: - start

    func testEnabledStartLoadsTheAgentThenInstallsTheResolverOnce() throws {
        let fake = runner()
        let calls = LockedCounter()
        let started = try start(lifecycle(fake), engineCalls: calls)
        XCTAssertTrue(started)
        XCTAssertEqual(calls.next(), 1, "the engine was asked to start once")
        XCTAssertEqual(fake.calls.map(\.executable),
                       ["/bin/launchctl", "/bin/launchctl", "/usr/bin/osascript"])
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count, 1)
        XCTAssertEqual(fake.calls.prefix(2).map(\.arguments), [
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testBlockedStartNeverPromptsAndLeavesTheResolverAlone() throws {
        try writeResolver("nameserver 127.0.0.1\nport 53\n") // another tool's
        for status in [engineStatus(blockedBy: herd), engineStatus(notPermitted: [80, 443])] {
            let fake = runner()
            XCTAssertTrue(try start(lifecycle(fake), status: status))
            XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" }, "\(fake.calls)")
            XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 127.0.0.1\nport 53\n")
        }
    }

    func testTheFirstStartWithFreePortsAfterABlockedOneInstallsTheResolver() throws {
        _ = try start(lifecycle(runner()), status: engineStatus(blockedBy: herd))
        let fake = runner(loaded: true)
        _ = try start(lifecycle(fake))
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count, 1)
        XCTAssertFalse(fake.calls.contains { $0.arguments.first == "bootstrap" }, "the agent was already current")
    }

    func testEnabledStartSkipsResolverWhenAlreadyInstalled() throws {
        try writeResolver(desired)
        let fake = runner()
        _ = try start(lifecycle(fake))
        XCTAssertEqual(fake.calls.map(\.executable), ["/bin/launchctl", "/bin/launchctl"])
    }

    func testEnabledStartLeavesAnUpToDateLoadedAgentAlone() throws {
        try writeResolver(desired)
        _ = try start(lifecycle(runner()))
        let fake = runner(loaded: true)
        _ = try start(lifecycle(fake))
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target]])
    }

    func testLoadedAgentWhoseDaemonExitedIsKickstarted() throws {
        try writeResolver(desired)
        _ = try start(lifecycle(runner()))
        let fake = runner(loaded: true)
        _ = try start(lifecycle(fake, daemonRunning: false))
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["kickstart", target]])
        XCTAssertEqual(fake.calls.last?.executable, "/bin/launchctl")
    }

    func testWithoutADaemonBinaryACurrentLoadedAgentIsUsed() throws {
        try writeResolver(desired)
        let installed = try executableDaemon()
        _ = try start(lifecycle(runner()), daemon: installed)
        let fake = runner(loaded: true)
        XCTAssertTrue(try lifecycle(fake, daemonRunning: false).startViaSystem(daemon: nil) { self.engineStatus() })
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["kickstart", target]])
    }

    func testWithoutADaemonBinaryOrAnAgentStartFails() throws {
        let fake = runner()
        XCTAssertThrowsError(try lifecycle(fake).startViaSystem(daemon: nil) { self.engineStatus() }) {
            XCTAssertEqual($0 as? DaemonLaunchError, .noDaemonBinary)
        }
        XCTAssertFalse(fake.calls.contains { $0.arguments.first == "bootstrap" })
    }

    /// A stand-in `paddockd` file (never run).
    private func executableDaemon() throws -> URL {
        let exe = dir.appendingPathComponent("Paddock.app/Contents/MacOS/paddockd")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    func testResolverIgnoresPortEnvironmentWhenIntegrationIsEnabled() throws {
        var odd = Settings()
        odd.dnsPort = 9999
        try writeResolver(desired) // Paddock's own file, for the default port
        let fake = runner()
        _ = try start(lifecycle(fake, settings: odd, environment: ["PADDOCK_DNS_PORT": "9999"]))
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
    }

    func testCancelledPasswordRemovesTheAgentItJustInstalled() throws {
        let fake = runner(osascriptStatus: 1, osascriptOutput: "User canceled. (-128)")
        XCTAssertThrowsError(try start(lifecycle(fake))) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(fake.calls.filter { $0.executable == "/usr/bin/osascript" }.count, 1)
        XCTAssertEqual(fake.calls.last?.arguments.first, "print", "booted out again: \(fake.calls)")
        XCTAssertTrue(fake.calls.contains { $0.arguments.first == "bootout" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testDisabledStartIssuesNoCommandsAndSaysToLaunchDetached() throws {
        let fake = runner()
        let calls = LockedCounter()
        let started = try start(lifecycle(fake, enabled: false), engineCalls: calls)
        XCTAssertFalse(started)
        XCTAssertEqual(fake.calls, [])
        XCTAssertEqual(calls.next(), 0, "a development home's daemon is started by the launcher")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    // MARK: - stop

    // MARK: - start at login

    func testStartsAtLoginFollowsTheAgentPlist() throws {
        try writeResolver(desired)
        let fake = runner()
        XCTAssertFalse(lifecycle(fake).startsAtLogin)
        XCTAssertTrue(lifecycle(fake).runsWithoutAgent)
        try lifecycle(fake).setStartsAtLogin(true, daemon: daemon)
        XCTAssertTrue(lifecycle(fake).startsAtLogin)
        XCTAssertFalse(lifecycle(fake).runsWithoutAgent)
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["bootstrap", "gui/\(getuid())", plist.path]])

        let off = runner(loaded: true)
        try lifecycle(off).setStartsAtLogin(false, daemon: daemon)
        XCTAssertEqual(off.calls.map(\.arguments), [["print", target], ["bootout", target], ["print", target]])
        XCTAssertFalse(lifecycle(off).startsAtLogin)
        XCTAssertTrue(lifecycle(off).runsWithoutAgent)
    }

    func testRunsWithoutAgentOnlyOnceTheResolverIsPaddocks() throws {
        // First launch: nothing installed, so the normal start path (resolver + agent) applies.
        XCTAssertFalse(lifecycle(runner()).runsWithoutAgent)
    }

    func testStartAtLoginIsOffAndUntouchableForADevelopmentHome() throws {
        try writeResolver(desired)
        let fake = runner()
        try lifecycle(fake, enabled: false).setStartsAtLogin(true, daemon: daemon)
        XCTAssertEqual(fake.calls, [])
        XCTAssertFalse(lifecycle(fake, enabled: false).startsAtLogin)
        XCTAssertFalse(lifecycle(fake, enabled: false).runsWithoutAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testEnabledStopBootsTheAgentOut() throws {
        let fake = runner(loaded: true)
        XCTAssertTrue(try lifecycle(fake).stopViaSystem())
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["bootout", target], ["print", target]])
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
        XCTAssertEqual(steps, ["osascript", "print", "bootout", "print", "verify-cert", "remove-trusted-cert"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertNil(store.load().previousResolver)
        XCTAssertFalse(lines.contains { $0.contains(".zshrc") }, "\(lines)")
        XCTAssertEqual(lines.last, "Paddock is uninstalled. Your sites in ~/Paddock and Paddock's data in "
            + "~/Library/Application Support/Paddock were left in place.")
    }

    func testUninstallSkipsResolverPromptWhenFileIsNotPaddocks() throws {
        try writeResolver("nameserver 8.8.8.8\n")
        try store.update { $0.previousResolver = "nameserver 10.0.0.1\n" }
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

    func testUninstallRemovesThePathLineFromTheRcFileInTheUsersHome() throws {
        try Data("# mine\n".utf8).write(to: rcFile)
        try ShellPath.configure(rcFile: rcFile)
        XCTAssertTrue(ShellPath.isConfigured(rcFile: rcFile))
        _ = try lifecycle(runner()).uninstall()
        XCTAssertEqual(try String(contentsOf: rcFile, encoding: .utf8), "# mine\n")
    }

    func testDisabledUninstallLeavesTheRcFileAlone() throws {
        try ShellPath.configure(rcFile: rcFile)
        _ = try lifecycle(runner(), enabled: false).uninstall()
        XCTAssertTrue(ShellPath.isConfigured(rcFile: rcFile))
    }

    func testUninstallShutsDownADaemonTheAgentDidNotRun() throws {
        let daemon = FakeDaemon(running: true)
        let lines = try lifecycle(runner(), client: daemon).uninstall()
        XCTAssertEqual(daemon.requests, [.shutdown])
        XCTAssertFalse(daemon.isRunning)
        XCTAssertTrue(lines.last?.hasPrefix("Paddock is uninstalled.") == true)
    }

    func testUninstallSendsNoShutdownWhenNothingAnswers() throws {
        let daemon = FakeDaemon(running: false)
        _ = try lifecycle(runner(), client: daemon).uninstall()
        XCTAssertEqual(daemon.requests, [])
    }

    func testReRunningUninstallAfterTheResolverWasRestoredIsQuiet() throws {
        // A first run put the original back, then failed later on.
        try writeResolver("nameserver 10.0.0.1\n")
        let fake = runner()
        let lines = try lifecycle(fake).uninstall()
        XCTAssertFalse(lines.contains { $0.contains("changed by another program") }, "\(lines)")
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 10.0.0.1\n")
    }
}

/// A daemon that answers until it is sent `shutdown`. Records requests; never touches a real process.
final class FakeDaemon: ClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var recorded: [Request] = []

    init(running: Bool) { self.running = running }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ r: Request, timeout: TimeInterval) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard running else { throw ClientError.daemonNotRunning }
        recorded.append(r)
        if r == .shutdown { running = false }
        return .error(code: ErrorCode.internal, message: "fake")
    }
}
