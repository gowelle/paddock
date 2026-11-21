import Foundation

/// The pieces of the owner's system Paddock integrates with. Tests substitute all three.
public struct SystemServices: Sendable {
    public var runner: CommandRunner
    public var resolverFile: URL
    public var launchAgents: URL

    public init(runner: CommandRunner, resolverFile: URL, launchAgents: URL) {
        self.runner = runner
        self.resolverFile = resolverFile
        self.launchAgents = launchAgents
    }

    /// The real system.
    public static func production(settings: Settings) -> SystemServices {
        SystemServices(runner: SystemCommandRunner(),
                       resolverFile: Resolver.defaultFile(settings: settings),
                       launchAgents: LaunchAgent.defaultDirectory)
    }
}

/// What `paddock start`, `stop` and `uninstall` do to the system. Every method does nothing at all
/// (no commands, no files) unless `SystemIntegration` allows touching the system for `environment`.
public struct SystemLifecycle: Sendable {
    let services: SystemServices
    let paths: Paths
    let settings: Settings
    let environment: [String: String]
    let userHome: URL
    let daemonIsRunning: @Sendable () -> Bool
    /// Talks to the daemon; uninstall uses it to shut down a daemon the LaunchAgent didn't run.
    let client: ClientProtocol
    /// The shell rc file `ShellPath` adds its PATH line to: `~/.zshrc` in `userHome`.
    var rcFile: URL { userHome.appendingPathComponent(".zshrc") }

    /// With system integration on, the LaunchAgent starts a daemon with default settings, so the
    /// resolver is built from default `Settings()` and port environment variables are ignored.
    public init(services: SystemServices, paths: Paths, settings: Settings,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                daemonIsRunning: (@Sendable () -> Bool)? = nil, client: ClientProtocol? = nil) {
        self.services = services
        self.paths = paths
        self.settings = SystemIntegration.isEnabled(environment: environment) ? Settings() : settings
        self.daemonIsRunning = daemonIsRunning ?? { PaddockClient(paths: paths).daemonIsRunning }
        self.client = client ?? PaddockClient(paths: paths)
        self.environment = environment
        self.userHome = userHome
    }

    public var resolverPath: String { services.resolverFile.path }

    public var isEnabled: Bool { SystemIntegration.isEnabled(environment: environment) }

    private var store: StateStore { StateStore(paths: paths) }
    private var resolver: Resolver {
        Resolver(file: services.resolverFile, settings: settings, store: store, runner: services.runner)
    }
    private var agent: LaunchAgent {
        LaunchAgent(runner: services.runner,
                    plist: services.launchAgents.appendingPathComponent("\(LaunchAgent.label).plist"),
                    paths: paths)
    }

    /// Brings the daemon up through the LaunchAgent (loading it, or kickstarting a loaded one), asks it
    /// to start with `startEngine` (which waits for it and returns its status), and only then routes
    /// `.test` to it: the resolver is installed (one password prompt) only when the web ports are free.
    /// With them held or not permitted the resolver is left alone, so another tool's `.test` keeps
    /// working; a later start that finds the ports free installs it.
    ///
    /// `daemon` may be nil when this program has no `paddockd` of its own; a loaded agent whose plist is
    /// current is then used as is. Returns false, having done nothing, for a development home: launch the
    /// daemon directly. Throws `ResolverError.cancelled` if the password prompt is dismissed; an agent
    /// this call installed is then removed again.
    public func startViaSystem(daemon: URL?, startEngine: () throws -> EngineStatus) throws -> Bool {
        guard isEnabled else { return false }
        let agent = agent
        var installedAgent = false
        // The plist is current if it runs this daemon (or, with none of our own, any daemon still there).
        let plistIsCurrent = daemon.map(agent.isCurrent(daemon:)) ?? (agent.installedDaemon() != nil)
        if plistIsCurrent && agent.isLoaded() {
            // launchd doesn't restart a daemon that exited cleanly (KeepAlive SuccessfulExit false).
            if !daemonIsRunning() { try agent.kickstart() }
        } else if let daemon {
            try agent.install(daemon: daemon)
            installedAgent = true
        } else {
            throw DaemonLaunchError.noDaemonBinary
        }

        let status = try startEngine()
        guard status.blockedBy.isEmpty, !resolver.isInstalled() else { return true }
        do {
            try resolver.install()
        } catch {
            if installedAgent { try? agent.uninstall() }
            throw error
        }
        return true
    }

    /// True when the LaunchAgent's plist is in place, so the daemon starts at login.
    public var startsAtLogin: Bool {
        isEnabled && FileManager.default.fileExists(atPath: agent.plist.path)
    }

    /// The owner turned start at login off after setup: the resolver is Paddock's but there is no
    /// LaunchAgent. The app then runs the daemon itself, only while it is open.
    public var runsWithoutAgent: Bool {
        isEnabled && resolver.isInstalled() && !startsAtLogin
    }

    /// Installs and loads the LaunchAgent (which starts the daemon), or boots it out and deletes it
    /// (which stops the daemon). Does nothing for a development home.
    public func setStartsAtLogin(_ on: Bool, daemon: URL) throws {
        guard isEnabled else { return }
        let agent = agent
        if on {
            if !(agent.isCurrent(daemon: daemon) && agent.isLoaded()) { try agent.install(daemon: daemon) }
        } else {
            try agent.uninstall()
        }
    }

    /// Boots the LaunchAgent out; the daemon gets SIGTERM and shuts down cleanly. Returns false when
    /// there was nothing to boot out (a development home, or a daemon the agent doesn't own).
    public func stopViaSystem() throws -> Bool {
        guard isEnabled else { return false }
        return try agent.stop()
    }

    /// Reverses `startViaSystem`, trust and the PATH line, leaving the owner's sites and Paddock's data
    /// alone. Returns the lines to print. Safe to run again after a partial failure.
    public func uninstall() throws -> [String] {
        guard isEnabled else { return ["Nothing to uninstall for this Paddock home."] }
        var lines: [String] = []
        // Resolver first: if the password prompt is cancelled we stop here with the agent still
        // running, so `.test` keeps resolving.
        if try resolver.restore() == .changedByAnotherProgram {
            lines.append("\(services.resolverFile.path) was changed by another program, so Paddock left it alone.")
        }
        try agent.uninstall()
        shutDownRemainingDaemon()

        let trust = CertificateTrust(paths: paths, runner: services.runner)
        if trust.isTrusted() { try trust.untrust() }

        try ShellPath.unconfigure(rcFile: rcFile)
        let sites = store.load().parked.map(abbreviated).joined(separator: ", ")
        lines.append("Paddock is uninstalled. Your sites in \(sites.isEmpty ? "~/Paddock" : sites) "
            + "and Paddock's data in \(abbreviated(paths.home.path)) were left in place.")
        return lines
    }

    /// A daemon started without the agent (start at login off, or left over after an app crash) is
    /// still answering after the bootout: ask it to shut down and give it a moment to go.
    private func shutDownRemainingDaemon() {
        guard daemonIsRunning() else { return }
        _ = try? client.send(.shutdown, timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        while daemonIsRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func abbreviated(_ path: String) -> String {
        let home = userHome.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
