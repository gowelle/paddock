import Foundation

/// The pieces of the owner's system Paddock integrates with. Tests substitute all of them.
public struct SystemServices: Sendable {
    public var runner: CommandRunner
    public var resolverFile: URL
    public var launchAgents: URL
    /// The bundled `paddock-ports` this build installs; nil when there is none beside this program.
    public var portHelperSource: URL?
    /// Where the port helper and its LaunchDaemon plist are installed.
    public var portHelperBinary: URL
    public var portHelperPlist: URL
    /// The short name of the user the port helper runs as.
    public var userName: String

    public init(runner: CommandRunner, resolverFile: URL, launchAgents: URL,
                portHelperSource: URL? = PortHelperLocator.binary(),
                portHelperBinary: URL = PortHelper.defaultInstalledBinary,
                portHelperPlist: URL = PortHelper.defaultPlist, userName: String = NSUserName()) {
        self.runner = runner
        self.resolverFile = resolverFile
        self.launchAgents = launchAgents
        self.portHelperSource = portHelperSource
        self.portHelperBinary = portHelperBinary
        self.portHelperPlist = portHelperPlist
        self.userName = userName
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
    /// Who answers on the given TCP ports (`PortCheck.holders`); tests substitute it.
    let portHolders: @Sendable ([Int]) -> [PortHolder]
    /// The shell rc file `ShellPath` adds its PATH line to: `~/.zshrc` in `userHome`.
    var rcFile: URL { userHome.appendingPathComponent(".zshrc") }

    /// With system integration on, the LaunchAgent starts a daemon with default settings, so the
    /// resolver is built from default `Settings()` and port environment variables are ignored.
    public init(services: SystemServices, paths: Paths, settings: Settings,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                daemonIsRunning: (@Sendable () -> Bool)? = nil, client: ClientProtocol? = nil,
                portHolders: (@Sendable ([Int]) -> [PortHolder])? = nil) {
        self.services = services
        self.portHolders = portHolders ?? { PortCheck.holders(of: $0) }
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
    /// Nil when this program has no `paddock-ports` beside it to install.
    private var portHelper: PortHelper? {
        services.portHelperSource.map {
            PortHelper(source: $0, user: services.userName, paths: paths, runner: services.runner,
                       installedBinary: services.portHelperBinary, plist: services.portHelperPlist)
        }
    }

    /// The web ports on the real system.
    private var webPorts: [Int] { [settings.httpPort, settings.httpsPort] }

    private var agent: LaunchAgent {
        LaunchAgent(runner: services.runner,
                    plist: services.launchAgents.appendingPathComponent("\(LaunchAgent.label).plist"),
                    paths: paths)
    }

    /// Brings the daemon up through the LaunchAgent (loading it, or kickstarting a loaded one). Then,
    /// unless the port helper and the resolver are both installed and current (when no privileged call
    /// is made at all), checks ports 80 and 443 as the user: if something other than Paddock's own launchd
    /// job answers there, throws `DaemonLaunchError.portsBlocked` naming it, without a password prompt,
    /// and leaves the resolver alone so another tool's `.test` keeps working. Otherwise installs whatever
    /// is missing or outdated with one password prompt. Finally asks the daemon to start with
    /// `startEngine` (which waits for it and returns its status).
    ///
    /// `daemon` may be nil when this program has no `paddockd` of its own; a loaded agent whose plist is
    /// current is then used as is. Returns false, having done nothing, for a development home: launch the
    /// daemon directly. Throws `ResolverError.cancelled` if the password prompt is dismissed; an agent
    /// this call installed is then removed again, and nothing was installed.
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

        do {
            try installSystemPieces()
        } catch let error as DaemonLaunchError {
            // Ports held: the daemon keeps answering .test DNS; a later start finishes setup.
            throw error
        } catch {
            if installedAgent { try? agent.uninstall() }
            throw error
        }
        _ = try startEngine()
        return true
    }

    /// The one privileged call of `startViaSystem`, if anything is missing.
    private func installSystemPieces() throws {
        let resolver = resolver
        guard let portHelper else {
            // Nothing to install the helper from (or to compare an installed one with).
            let fm = FileManager.default
            let installed = fm.fileExists(atPath: services.portHelperBinary.path)
                && fm.fileExists(atPath: services.portHelperPlist.path)
            guard installed && resolver.isInstalled() else { throw EngineError.portHelperMissing }
            return
        }
        let helperInstalled = portHelper.isInstalled()
        guard !(helperInstalled && resolver.isInstalled()) else { return }
        if let path = paths.tooLongSocket { throw EngineError.socketPathTooLong(path: path) }
        if !portHelper.ownsPorts() {
            let holders = portHolders(webPorts)
            if !holders.isEmpty { throw DaemonLaunchError.portsBlocked(holders) }
        }
        do {
            try resolver.install(preceding: helperInstalled ? nil : portHelper.installScriptFragment())
        } catch ResolverError.portsBusy {
            // Taken between the check and the prompt: name who took them.
            throw DaemonLaunchError.portsBlocked(portHolders(webPorts))
        }
    }

    /// True when the LaunchAgent's plist is in place, so the daemon starts at login.
    public var startsAtLogin: Bool {
        isEnabled && FileManager.default.fileExists(atPath: agent.plist.path)
    }

    /// The owner turned start at login off after setup: the resolver is Paddock's but there is no
    /// LaunchAgent. The app then runs the daemon itself, only while it is open.
    public var runsWithoutAgent: Bool {
        isEnabled && resolver.isInstalled() && (portHelper?.isInstalled() ?? false) && !startsAtLogin
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
    /// there was nothing to boot out (a development home, or a daemon the agent doesn't own). The port
    /// helper's launchd entry stays: ports 80 and 443 remain reserved for Paddock until uninstall.
    public func stopViaSystem() throws -> Bool {
        guard isEnabled else { return false }
        return try agent.stop()
    }

    /// Reverses `startViaSystem`, trust and the PATH line, leaving the owner's sites and Paddock's data
    /// alone. Returns the lines to print. Safe to run again after a partial failure.
    public func uninstall() throws -> [String] {
        guard isEnabled else { return ["Nothing to uninstall for this Paddock home."] }
        var lines: [String] = []
        // One prompt: the resolver first, then the port helper's launchd entry. If the prompt is cancelled
        // we stop here with the agent still running, so `.test` keeps resolving.
        let helper = portHelperForRemoval()
        let removal = helper.isPresent() ? helper.uninstallScriptFragment() : nil
        if try resolver.restore(then: removal) == .changedByAnotherProgram {
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

    /// The installed helper to remove; its source doesn't matter for removal, so it is found even when
    /// this program has no `paddock-ports` beside it.
    private func portHelperForRemoval() -> PortHelper {
        portHelper ?? PortHelper(source: services.portHelperBinary, user: services.userName, paths: paths,
                                 runner: services.runner, installedBinary: services.portHelperBinary,
                                 plist: services.portHelperPlist)
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
