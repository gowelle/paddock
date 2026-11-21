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

    /// With system integration on, the LaunchAgent starts a daemon with default settings, so the
    /// resolver is built from default `Settings()` and port environment variables are ignored.
    public init(services: SystemServices, paths: Paths, settings: Settings,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                daemonIsRunning: (@Sendable () -> Bool)? = nil) {
        self.services = services
        self.paths = paths
        self.settings = SystemIntegration.isEnabled(environment: environment) ? Settings() : settings
        self.daemonIsRunning = daemonIsRunning ?? { PaddockClient(paths: paths).daemonIsRunning }
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

    /// Installs the resolver if needed, then loads the LaunchAgent, which starts the daemon.
    /// Returns false, having done nothing, when this is a development home: launch the daemon directly.
    /// Throws `ResolverError.cancelled` without starting the agent if the password prompt is dismissed.
    public func startViaSystem(daemon: URL) throws -> Bool {
        guard isEnabled else { return false }
        if !resolver.isInstalled() { try resolver.install() }
        let agent = agent
        if agent.isCurrent(daemon: daemon) && agent.isLoaded() {
            // launchd doesn't restart a daemon that exited cleanly (KeepAlive SuccessfulExit false).
            if !daemonIsRunning() { try agent.kickstart() }
        } else {
            try agent.install(daemon: daemon)
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

    /// Reverses `startViaSystem` and trust, leaving the owner's sites and Paddock's data alone.
    /// Returns the lines to print.
    public func uninstall() throws -> [String] {
        guard isEnabled else { return ["Nothing to uninstall for this Paddock home."] }
        var lines: [String] = []
        // Resolver first: if the password prompt is cancelled we stop here with the agent still
        // running, so `.test` keeps resolving.
        if try resolver.restore() == .changedByAnotherProgram {
            lines.append("\(services.resolverFile.path) was changed by another program, so Paddock left it alone.")
        }
        try agent.uninstall()

        let trust = CertificateTrust(paths: paths, runner: services.runner)
        if trust.isTrusted() { try trust.untrust() }

        lines.append("The PATH line Paddock added to ~/.zshrc was left alone.")
        let sites = store.load().parked.map(abbreviated).joined(separator: ", ")
        lines.append("Paddock is uninstalled. Your sites in \(sites.isEmpty ? "~/Paddock" : sites) "
            + "and Paddock's data in \(abbreviated(paths.home.path)) were left in place.")
        return lines
    }

    private func abbreviated(_ path: String) -> String {
        let home = userHome.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
