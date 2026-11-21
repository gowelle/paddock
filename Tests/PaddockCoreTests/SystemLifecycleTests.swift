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
    private var helperSource: URL!
    private var helperBinary: URL!
    private var helperPlist: URL!
    /// What the user-level port check finds on 80/443, one answer per call (the last one repeats).
    private var held: LockedBox<[[PortHolder]]>!
    private var portChecks: LockedCounter!
    private let daemon = URL(fileURLWithPath: "/opt/Paddock/paddockd")
    private let target = "gui/\(getuid())/app.paddock.paddockd"

    override func setUpWithError() throws {
        // Short, so the home's socket paths fit macOS's 103-byte limit, which start checks before prompting.
        dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        paths = Paths(home: dir.appendingPathComponent("Library/Application Support/Paddock", isDirectory: true))
        store = StateStore(paths: paths)
        resolverFile = dir.appendingPathComponent("etc/resolver/test")
        agents = dir.appendingPathComponent("LaunchAgents", isDirectory: true)
        helperSource = dir.appendingPathComponent("Paddock.app/Contents/MacOS/paddock-ports")
        try FileManager.default.createDirectory(at: helperSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("helper bytes".utf8).write(to: helperSource)
        helperBinary = dir.appendingPathComponent("Library/PrivilegedHelperTools/app.paddock.ports")
        helperPlist = dir.appendingPathComponent("Library/LaunchDaemons/app.paddock.ports.plist")
        held = LockedBox([[]])
        portChecks = LockedCounter()
        try store.update { $0 = State(parked: [dir.appendingPathComponent("Paddock").path]) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func lifecycle(_ runner: CommandRunner, enabled: Bool = true, settings: Settings = Settings(),
                           environment: [String: String]? = nil, daemonRunning: Bool = true,
                           client: FakeDaemon? = nil) -> SystemLifecycle {
        let daemon = client ?? FakeDaemon(running: daemonRunning)
        let held = self.held!, checks = self.portChecks!
        return SystemLifecycle(
            services: services(runner),
            paths: paths, settings: settings,
            environment: environment ?? (enabled ? [:] : ["PADDOCK_HOME": paths.home.path]),
            userHome: dir, daemonIsRunning: { daemon.isRunning }, client: daemon,
            portHolders: { ports in
                XCTAssertEqual(ports, [80, 443])
                let n = checks.next()
                return held.value[min(n, held.value.count - 1)]
            })
    }

    private func services(_ runner: CommandRunner) -> SystemServices {
        SystemServices(runner: runner, resolverFile: resolverFile, launchAgents: agents,
                       portHelperSource: helperSource, portHelperBinary: helperBinary,
                       portHelperPlist: helperPlist, userName: "someone")
    }

    private var portHelper: PortHelper {
        PortHelper(source: helperSource, user: "someone", paths: paths, runner: RecordingCommandRunner(),
                   installedBinary: helperBinary, plist: helperPlist)
    }

    /// What a finished install leaves: the helper and its launchd plist, exactly as this build wants them.
    private func placeHelper(plist data: Data? = nil) throws {
        for file in [helperBinary!, helperPlist!] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(contentsOf: helperSource).write(to: helperBinary)
        try (data ?? portHelper.plistData()).write(to: helperPlist)
    }

    /// Everything a previous start set up: the resolver and the port helper.
    private func placeEverything() throws {
        try writeResolver(desired)
        try placeHelper()
    }

    private func osascripts(_ fake: RecordingCommandRunner) -> [String] {
        fake.calls.filter { $0.executable == "/usr/bin/osascript" }.map { $0.arguments[1] }
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    private let portsJob = "system/app.paddock.ports"

    private var rcFile: URL { dir.appendingPathComponent(".zshrc") }

    private func writeResolver(_ text: String) throws {
        try FileManager.default.createDirectory(at: resolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: resolverFile, atomically: true, encoding: .utf8)
    }

    private var desired: String { "nameserver 127.0.0.1\nport 53535\n" }
    private var plist: URL { agents.appendingPathComponent("app.paddock.paddockd.plist") }

    /// launchctl answered by a fake launchd (loaded or not), osascript and `security verify-cert` as given.
    /// `portsJobLoaded`: whether launchd has the `system/app.paddock.ports` job.
    private func runner(trusted: Bool = false, loaded: Bool = false, osascriptStatus: Int32 = 0,
                        osascriptOutput: String = "", portsJobLoaded: Bool = false) -> RecordingCommandRunner {
        let launchd = FakeLaunchd(loaded: loaded)
        let portsJob = self.portsJob
        return RecordingCommandRunner { exe, args in
            if exe == "/usr/bin/osascript" { return (osascriptStatus, osascriptOutput) }
            if exe == "/bin/launchctl" && args.last == portsJob { return (portsJobLoaded ? 0 : 113, "") }
            if let answer = launchd.answer(exe, args) { return answer }
            if args.first == "verify-cert" { return (trusted ? 0 : 1, "") }
            return (0, "")
        }
    }

    private func engineStatus(blockedBy: [PortHolder] = []) -> EngineStatus {
        EngineStatus(running: blockedBy.isEmpty, blockedBy: blockedBy,
                     sites: [], installedPHP: [], defaultPHP: nil,
                     processes: [:], resolverInstalled: false, trustEnabled: true, dnsRunning: true,
                     portHelperInstalled: true)
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

    func testFreshStartIssuesOnePromptWithThePortHelperThenTheResolverThenStartsTheEngine() throws {
        let fake = runner()
        let calls = LockedCounter()
        let commandsBeforeEngine = LockedBox(-1)
        let started = try lifecycle(fake).startViaSystem(daemon: daemon) {
            _ = calls.next()
            commandsBeforeEngine.value = fake.calls.count
            return self.engineStatus()
        }
        XCTAssertTrue(started)
        XCTAssertEqual(calls.next(), 1, "the engine was asked to start once")
        XCTAssertEqual(fake.calls.map(\.executable),
                       ["/bin/launchctl", "/bin/launchctl", "/usr/bin/osascript"])
        XCTAssertEqual(commandsBeforeEngine.value, 3, "the engine is asked after the prompt")
        XCTAssertEqual(fake.calls.prefix(2).map(\.arguments), [
            ["print", target],
            ["bootstrap", "gui/\(getuid())", plist.path],
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(portChecks.next(), 1, "the ports were checked once, before the prompt")

        let script = try XCTUnwrap(osascripts(fake).first)
        let port = try XCTUnwrap(script.range(of: PortHelper.busyMarker))
        XCTAssertTrue(script.contains(helperPlist.path), "installs the launchd entry")
        XCTAssertTrue(script.contains(b64("helper bytes")), "carries the helper")
        let resolverStep = try XCTUnwrap(script.range(of: b64(desired)))
        XCTAssertLessThan(port.lowerBound, resolverStep.lowerBound, "port helper first, then the resolver")
    }

    func testStartWithPortsHeldNeverPromptsAndReportsWhoHoldsThem() throws {
        try writeResolver("nameserver 127.0.0.1\nport 53\n") // another tool's
        held.value = [herd]
        let fake = runner()
        let calls = LockedCounter()
        XCTAssertThrowsError(try start(lifecycle(fake), engineCalls: calls)) {
            XCTAssertEqual($0 as? DaemonLaunchError, .portsBlocked(herd))
            XCTAssertEqual(($0 as? DaemonLaunchError)?.message(retry: "Run paddock start"), Messages.portsBlocked(herd))
        }
        XCTAssertEqual(osascripts(fake), [], "no password prompt")
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 127.0.0.1\nport 53\n")
        XCTAssertEqual(calls.next(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path), "the daemon keeps running for .test DNS")
    }

    func testABusyMarkerFromThePromptReportsTheHolders() throws {
        held.value = [[], herd] // free when checked first, taken by the time the script looked
        let fake = runner(osascriptOutput: "PADDOCK_PORTS_BUSY\n")
        XCTAssertThrowsError(try start(lifecycle(fake))) {
            XCTAssertEqual($0 as? DaemonLaunchError, .portsBlocked(herd))
        }
        XCTAssertEqual(osascripts(fake).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolverFile.path))
    }

    func testTheFirstStartWithFreePortsAfterABlockedOneInstallsEverything() throws {
        held.value = [herd]
        XCTAssertThrowsError(try start(lifecycle(runner())))
        held.value = [[]]
        let fake = runner(loaded: true)
        XCTAssertTrue(try start(lifecycle(fake)))
        XCTAssertEqual(osascripts(fake).count, 1)
        XCTAssertFalse(fake.calls.contains { $0.arguments.first == "bootstrap" }, "the agent was already current")
    }

    func testStartWithEverythingInstalledIssuesNoPrompt() throws {
        try placeEverything()
        let fake = runner()
        XCTAssertTrue(try start(lifecycle(fake)))
        XCTAssertEqual(fake.calls.map(\.executable), ["/bin/launchctl", "/bin/launchctl"])
        XCTAssertEqual(portChecks.next(), 0, "no port check either")
    }

    func testOnlyTheMissingPartIsInstalled() throws {
        try writeResolver(desired)
        let fake = runner()
        _ = try start(lifecycle(fake))
        let script = try XCTUnwrap(osascripts(fake).first)
        XCTAssertTrue(script.contains(PortHelper.busyMarker))
        XCTAssertFalse(script.contains(b64(desired)), "the resolver is already Paddock's")

        try FileManager.default.removeItem(at: resolverFile)
        try placeHelper()
        let second = runner(loaded: true)
        _ = try start(lifecycle(second))
        let resolverOnly = try XCTUnwrap(osascripts(second).first)
        XCTAssertFalse(resolverOnly.contains(PortHelper.busyMarker))
        XCTAssertTrue(resolverOnly.contains(b64(desired)))
    }

    func testAnOutdatedHelperIsReplacedWithOnePrompt() throws {
        try writeResolver(desired)
        try placeHelper(plist: Data("<plist>older</plist>".utf8))
        held.value = [herd] // launchd itself answers on 80/443 for the old job
        let fake = runner(portsJobLoaded: true)
        XCTAssertTrue(try start(lifecycle(fake)))
        XCTAssertEqual(osascripts(fake).count, 1)
        XCTAssertEqual(portChecks.next(), 0, "Paddock's own loaded job is not a blocker")
        XCTAssertTrue(fake.calls.contains { $0.arguments == ["print", portsJob] })
    }

    func testAnUnrestorableResolverFileIsLeftAloneWithoutAPrompt() throws {
        try writeResolver("nameserver 127.0.0.1\nweird line\n")
        let fake = runner()
        XCTAssertThrowsError(try start(lifecycle(fake))) {
            XCTAssertEqual($0 as? ResolverError, .cannotRestoreLater(path: resolverFile.path))
        }
        XCTAssertEqual(osascripts(fake), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path), "the agent this call installed is removed")
    }

    func testATooLongSocketPathFailsBeforeThePrompt() throws {
        let long = dir.appendingPathComponent(String(repeating: "u", count: 90), isDirectory: true)
        let longPaths = Paths(home: long)
        let fake = runner()
        let lifecycle = SystemLifecycle(services: services(fake), paths: longPaths, settings: Settings(),
                                        environment: [:], userHome: dir, daemonIsRunning: { true },
                                        client: FakeDaemon(running: true), portHolders: { _ in [] })
        XCTAssertThrowsError(try lifecycle.startViaSystem(daemon: daemon) { self.engineStatus() }) {
            XCTAssertEqual($0 as? EngineError, .socketPathTooLong(path: longPaths.httpSocket.path))
        }
        XCTAssertEqual(osascripts(fake), [])
    }

    func testEnabledStartLeavesAnUpToDateLoadedAgentAlone() throws {
        try placeEverything()
        _ = try start(lifecycle(runner()))
        let fake = runner(loaded: true)
        _ = try start(lifecycle(fake))
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target]])
    }

    func testLoadedAgentWhoseDaemonExitedIsKickstarted() throws {
        try placeEverything()
        _ = try start(lifecycle(runner()))
        let fake = runner(loaded: true)
        _ = try start(lifecycle(fake, daemonRunning: false))
        XCTAssertEqual(fake.calls.map(\.arguments), [["print", target], ["kickstart", target]])
        XCTAssertEqual(fake.calls.last?.executable, "/bin/launchctl")
    }

    func testWithoutADaemonBinaryACurrentLoadedAgentIsUsed() throws {
        try placeEverything()
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
        try placeEverything() // Paddock's own file, for the default port
        let fake = runner()
        _ = try start(lifecycle(fake, settings: odd, environment: ["PADDOCK_DNS_PORT": "9999"]))
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
    }

    func testCancelledPasswordLeavesNothingHalfInstalledAndTheAgentNotStarted() throws {
        let fake = runner(osascriptStatus: 1, osascriptOutput: "User canceled. (-128)")
        let calls = LockedCounter()
        XCTAssertThrowsError(try start(lifecycle(fake), engineCalls: calls)) {
            XCTAssertEqual($0 as? ResolverError, .cancelled)
        }
        XCTAssertEqual(osascripts(fake).count, 1)
        XCTAssertEqual(fake.calls.last?.arguments.first, "print", "booted out again: \(fake.calls)")
        XCTAssertTrue(fake.calls.contains { $0.arguments.first == "bootout" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(calls.next(), 0, "the engine was never asked to start")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolverFile.path))
        XCTAssertNil(store.load().previousResolver)
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
        try placeEverything()
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

    func testRunsWithoutAgentOnlyOnceTheResolverAndPortHelperArePaddocks() throws {
        // First launch: nothing installed, so the normal start path (resolver + agent) applies.
        XCTAssertFalse(lifecycle(runner()).runsWithoutAgent)
        try writeResolver(desired)
        XCTAssertFalse(lifecycle(runner()).runsWithoutAgent, "the port helper still needs the setup prompt")
        try placeHelper()
        XCTAssertTrue(lifecycle(runner()).runsWithoutAgent)
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
        try placeEverything()
        try store.update { $0.previousResolver = "nameserver 127.0.0.1\n" }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "x".write(to: plist, atomically: true, encoding: .utf8)
        let fake = runner(trusted: true, loaded: true)
        let lines = try lifecycle(fake).uninstall()

        let steps = fake.calls.map { $0.executable == "/usr/bin/osascript" ? "osascript" : ($0.arguments.first ?? "") }
        XCTAssertEqual(steps, ["osascript", "print", "bootout", "print", "verify-cert", "remove-trusted-cert"])
        // One prompt: the resolver restore, then the port helper's removal.
        let script = try XCTUnwrap(osascripts(fake).first)
        let resolverStep = try XCTUnwrap(script.range(of: b64("nameserver 127.0.0.1\n")))
        let removal = try XCTUnwrap(script.range(of: "bootout"))
        XCTAssertLessThan(resolverStep.lowerBound, removal.lowerBound)
        XCTAssertTrue(script.contains(helperPlist.path) && script.contains(helperBinary.path))
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
        XCTAssertTrue(fake.calls.contains { $0.arguments == ["print", portsJob] }, "checked for a loaded port job")
        XCTAssertTrue(lines.contains("\(resolverFile.path) was changed by another program, so Paddock left it alone."),
                      "\(lines)")
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 8.8.8.8\n")
    }

    func testUninstallSkippingAResolverThatIsNotPaddocksStillRemovesThePortHelper() throws {
        try writeResolver("nameserver 8.8.8.8\n")
        try store.update { $0.previousResolver = "nameserver 10.0.0.1\n" }
        try placeHelper()
        let fake = runner()
        let lines = try lifecycle(fake).uninstall()
        let scripts = osascripts(fake)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("bootout"), scripts[0])
        XCTAssertFalse(scripts[0].contains(b64("nameserver 10.0.0.1\n")), "the resolver is left alone")
        XCTAssertTrue(lines.contains("\(resolverFile.path) was changed by another program, so Paddock left it alone."))
    }

    func testUninstallRemovesALoadedPortJobEvenWithoutItsFiles() throws {
        try writeResolver(desired)
        let fake = runner(portsJobLoaded: true)
        _ = try lifecycle(fake).uninstall()
        let scripts = osascripts(fake)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("bootout"))
    }

    func testUninstallWithNothingInstalledAsksNoPassword() throws {
        let fake = runner()
        let lines = try lifecycle(fake).uninstall()
        XCTAssertFalse(fake.calls.contains { $0.executable == "/usr/bin/osascript" })
        XCTAssertEqual(fake.calls.map(\.arguments.first), ["print", "print", "verify-cert"])
        XCTAssertEqual(fake.calls.prefix(2).map(\.arguments), [["print", portsJob], ["print", target]])
        XCTAssertTrue(lines.last?.hasPrefix("Paddock is uninstalled.") == true)
    }

    func testUninstallCancelledPasswordLeavesTheAgentRunning() throws {
        try placeEverything()
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
        try placeEverything()
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
