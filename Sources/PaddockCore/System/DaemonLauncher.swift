import Darwin
import Foundation

public enum DaemonLaunchError: Error, Equatable {
    case noDaemonBinary
    /// The password prompt for the resolver was dismissed.
    case passwordCancelled
    case resolverChangedDuringInstall(path: String)
    case resolverFailed(String)
    case didNotStart(logPath: String)
    case failed(String)

    /// The plain sentence for this failure. `retry` is how the reader tries again (e.g. `Run paddock start`).
    public func message(retry: String? = nil) -> String {
        let again = retry.map { " \($0) to try again." } ?? ""
        switch self {
        case .noDaemonBinary: return "Can't find paddockd next to paddock."
        case .passwordCancelled: return "Paddock needs your password once to route .test domains." + again
        case .resolverChangedDuringInstall(let path):
            return "\(path) changed while Paddock was waiting for your password." + again
        case .resolverFailed(let message): return "Couldn't route .test domains to Paddock: \(message)"
        case .didNotStart(let log): return "Paddock didn't start within 10 seconds. See \(log)"
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

    /// Makes sure a daemon is answering. On the owner's system this installs the resolver (one
    /// password prompt) and the LaunchAgent if needed.
    ///
    /// `honouringLoginSetting` (the app): when the owner turned start at login off, launch the daemon
    /// directly instead of reinstalling the LaunchAgent.
    public func ensureRunning(honouringLoginSetting: Bool = false) throws -> Outcome {
        guard let daemon else { throw DaemonLaunchError.noDaemonBinary }
        if honouringLoginSetting && lifecycle.runsWithoutAgent {
            if client.daemonIsRunning { return .alreadyRunning }
            try spawn(daemon)
            return .spawned
        }
        let started: Bool
        do {
            started = try lifecycle.startViaSystem(daemon: daemon)
        } catch ResolverError.cancelled {
            throw DaemonLaunchError.passwordCancelled
        } catch ResolverError.changedDuringInstall {
            throw DaemonLaunchError.resolverChangedDuringInstall(path: lifecycle.resolverPath)
        } catch ResolverError.failed(let message) {
            throw DaemonLaunchError.resolverFailed(message)
        } catch {
            throw DaemonLaunchError.failed("\(error)")
        }
        if started {
            try waitForDaemon()
            return .viaSystem
        }
        if client.daemonIsRunning { return .alreadyRunning }
        try spawn(daemon)
        return .spawned
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

    /// `paddockd` next to the running executable (following symlinks), if it is there.
    public static func daemonBinary() -> URL? {
        var directories: [URL] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return directories.map { $0.appendingPathComponent("paddockd") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .resolvingSymlinksInPath()
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
