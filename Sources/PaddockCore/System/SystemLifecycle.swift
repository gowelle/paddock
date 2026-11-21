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

    public init(services: SystemServices, paths: Paths, settings: Settings,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.services = services
        self.paths = paths
        self.settings = settings
        self.environment = environment
        self.userHome = userHome
    }

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
        if !(agent.isCurrent(daemon: daemon) && agent.isLoaded()) { try agent.install(daemon: daemon) }
        return true
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
        try agent.uninstall()

        let resolver = resolver
        if try resolver.restore() == .changedByAnotherProgram {
            lines.append("\(services.resolverFile.path) was changed by another program, so Paddock left it alone.")
        }

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
