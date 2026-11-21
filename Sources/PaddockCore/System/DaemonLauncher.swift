import Darwin
import Foundation

public enum DaemonLaunchError: Error, Equatable {
    case noDaemonBinary
    /// The password prompt for the resolver was dismissed.
    case passwordCancelled
    case resolverChangedDuringInstall(path: String)
    case resolverFailed(String)
    case didNotStart(logPath: String)
    /// The control socket's path is longer than macOS allows for a unix socket (103 bytes).
    case socketPathTooLong(path: String)
    /// Something other than Paddock answers on port 80 or 443, so setup didn't ask for the password.
    case portsBlocked([PortHolder])
    /// The resolver file isn't one Paddock could put back on uninstall, so it was left alone.
    case resolverUnrestorable(path: String)
    /// The privileged script's port-helper steps failed.
    case portsSetupFailed(String)
    /// The real system, but this program isn't inside Paddock.app: no system changes from it.
    case developmentBuild
    /// Run as root (`sudo`).
    case runningAsRoot
    /// The daemon answering belongs to another install of Paddock (at `path`, nil if unknown), so this
    /// one leaves it alone.
    case anotherCopyRunning(path: String?)
    case failed(String)

    /// The plain sentence for this failure. `retry` is how the reader tries again (e.g. `Run paddock start`).
    public func message(retry: String? = nil) -> String {
        let again = retry.map { " \($0) to try again." } ?? ""
        switch self {
        case .noDaemonBinary: return "Can't find paddockd next to paddock."
        case .passwordCancelled: return "Paddock needs your password once to finish setup." + again
        case .resolverChangedDuringInstall(let path):
            return "\(path) changed while Paddock was waiting for your password." + again
        case .resolverFailed(let message): return "Couldn't route .test domains to Paddock: \(message)"
        case .didNotStart(let log): return "Paddock didn't start within 10 seconds. See \(log)"
        case .socketPathTooLong(let path):
            return "Paddock can't run from this folder: the path \(path) is too long for macOS. "
                + "Use a shorter PADDOCK_HOME."
        case .portsBlocked(let holders): return Messages.portsBlocked(holders)
        case .resolverUnrestorable(let path): return ResolverError.cannotRestoreLater(path: path).message
        case .portsSetupFailed(let detail): return Messages.portsSetupFailed(detail)
        case .developmentBuild: return Messages.developmentBuild
        case .runningAsRoot: return Messages.runningAsRoot
        case .anotherCopyRunning(let path): return Messages.anotherCopyRunning(path: path)
        case .failed(let message): return "Couldn't start Paddock: \(message)"
        }
    }
}

/// Starts and stops `paddockd` the way `paddock start` and `paddock stop` do, for the CLI and the app:
/// through the LaunchAgent on the owner's system, or as a detached process for a development home.
public struct DaemonLauncher: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// A development home whose daemon was already answering.
        case alreadyRunning
        /// The LaunchAgent runs the daemon.
        case viaSystem
        /// This process launched the daemon itself (a development home, or no LaunchAgent).
        case spawned
    }

    public enum StopOutcome: Sendable, Equatable { case stopped, notRunning }

    let lifecycle: SystemLifecycle
    let paths: Paths
    public let daemon: URL?

    public init(lifecycle: SystemLifecycle, paths: Paths, daemon: URL? = DaemonLauncher.daemonBinary()) {
        self.lifecycle = lifecycle
        self.paths = paths
        self.daemon = daemon
    }

    private var client: PaddockClient { PaddockClient(paths: paths) }
    private var logPath: String { paths.log.appendingPathComponent("paddockd.log").path }

    /// Makes sure a daemon is answering. On the owner's system this installs the LaunchAgent if needed,
    /// then, unless the port helper and the resolver are both in place, (only if the web ports are free)
    /// installs them with one password prompt, and has the engine start.
    ///
    /// `honouringLoginSetting` (the app): when the owner turned start at login off, finish or update setup
    /// without the LaunchAgent (`SystemLifecycle.completeSetup`) and launch the daemon directly, restarting
    /// one of another build, instead of reinstalling the LaunchAgent.
    public func ensureRunning(honouringLoginSetting: Bool = false) throws -> Outcome {
        guard Wire.socketAddress(paths.daemonSocket.path) != nil else {
            throw DaemonLaunchError.socketPathTooLong(path: paths.daemonSocket.path)
        }
        if honouringLoginSetting && lifecycle.runsWithoutAgent {
            try Self.plainErrors(resolverPath: lifecycle.resolverPath) { try lifecycle.completeSetup() }
            if client.daemonIsRunning {
                guard try lifecycle.shouldReplaceDaemon(with: daemon) else { return .alreadyRunning }
                _ = try? client.send(.shutdown, timeout: 60)
                waitForDaemonToExit()
            }
            guard let daemon else { throw DaemonLaunchError.noDaemonBinary }
            try spawn(daemon)
            return .spawned
        }
        let started = try Self.plainErrors(resolverPath: lifecycle.resolverPath) {
            try lifecycle.startViaSystem(daemon: daemon, startEngine: startEngine)
        }
        if started { return .viaSystem }
        if client.daemonIsRunning { return .alreadyRunning }
        guard let daemon else { throw DaemonLaunchError.noDaemonBinary }
        try spawn(daemon)
        return .spawned
    }

    /// Runs `body`, turning resolver, setup and engine errors into `DaemonLaunchError`s with plain sentences.
    private static func plainErrors<T>(resolverPath: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DaemonLaunchError {
            throw error
        } catch ResolverError.cancelled {
            throw DaemonLaunchError.passwordCancelled
        } catch ResolverError.changedDuringInstall {
            throw DaemonLaunchError.resolverChangedDuringInstall(path: resolverPath)
        } catch ResolverError.failed(let message) {
            throw DaemonLaunchError.resolverFailed(message)
        } catch ResolverError.portsSetupFailed(let detail) {
            throw DaemonLaunchError.portsSetupFailed(detail)
        } catch ResolverError.cannotRestoreLater(let path) {
            throw DaemonLaunchError.resolverUnrestorable(path: path)
        } catch let error as ResolverError {
            throw DaemonLaunchError.resolverFailed(error.message)
        } catch EngineError.socketPathTooLong(let path) {
            throw DaemonLaunchError.failed(Messages.socketPathTooLong(path))
        } catch EngineError.portHelperMissing {
            throw DaemonLaunchError.failed(Messages.portHelperMissing)
        } catch {
            throw DaemonLaunchError.failed("\(error)")
        }
    }

    /// Waits for the daemon, asks it to start (queued behind its own start, so the port check is done
    /// when this returns) and returns its status.
    private func startEngine() throws -> EngineStatus {
        try waitForDaemon()
        // An error here (ports held, a process that didn't come up) shows in the status that follows.
        _ = try? client.send(.start, timeout: 600)
        let response: Response
        do {
            response = try client.send(.status, timeout: 30)
        } catch {
            throw DaemonLaunchError.failed(Messages.unexpectedAnswer(error))
        }
        switch response {
        case .ok(let status): return status
        case .error(_, let message): throw DaemonLaunchError.failed(message)
        }
    }

    /// Boots the LaunchAgent out, or asks a directly launched daemon to shut down, and waits for it to go.
    public func stop() throws -> StopOutcome {
        if try lifecycle.stopViaSystem() {
            waitForDaemonToExit()
            return .stopped
        }
        guard client.daemonIsRunning else { return .notRunning }
        if case .error(_, let message) = try client.send(.shutdown, timeout: 60) {
            throw DaemonLaunchError.failed(message)
        }
        waitForDaemonToExit()
        return .stopped
    }

    /// Launches the daemon in its own session, so it outlives this process, and waits until it answers.
    public func spawn(_ binary: URL) throws {
        try? paths.ensureDirectories()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own session, so closing the terminal or exiting the client doesn't take the daemon down.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = Self.withCStrings([binary.path]) { argv in
            Self.withCStrings(environment) { envp in
                posix_spawn(&pid, binary.path, &actions, &attributes, argv, envp)
            }
        }
        guard rc == 0 else { throw DaemonLaunchError.failed("\(String(cString: strerror(rc))).") }
        try waitForDaemon()
    }

    private func waitForDaemon() throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if client.daemonIsRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DaemonLaunchError.didNotStart(logPath: logPath)
    }

    /// The daemon exits right after replying (or on SIGTERM); give it a moment so `status` agrees.
    private func waitForDaemonToExit() {
        let deadline = Date().addingTimeInterval(5)
        while client.daemonIsRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    /// `paddockd` for the running executable (following symlinks), if there is one: next to it, or, for
    /// the copy of `paddock` in `bin/`, in the app whose resources its `.resources` record names
    /// (`<Resources>/../MacOS/paddockd`).
    public static func daemonBinary() -> URL? {
        var directories: [URL] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return daemonBinary(executableDirectories: directories)
    }

    static func daemonBinary(executableDirectories directories: [URL]) -> URL? {
        let fm = FileManager.default
        let beside = directories.map { $0.appendingPathComponent("paddockd") }
        let recorded = directories.compactMap { directory -> URL? in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(".resources"), encoding: .utf8)
            else { return nil }
            let resources = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resources.isEmpty else { return nil }
            return URL(fileURLWithPath: resources, isDirectory: true)
                .deletingLastPathComponent().appendingPathComponent("MacOS/paddockd").standardizedFileURL
        }
        return (beside + recorded).first { fm.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath()
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
