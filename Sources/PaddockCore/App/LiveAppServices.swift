import Foundation

/// The app's `AppServices` on the real system: the same `SystemLifecycle` and `DaemonLauncher` the
/// CLI uses. With `PADDOCK_HOME` set, everything that touches the system does nothing.
public struct LiveAppServices: AppServices {
    let lifecycle: SystemLifecycle
    let launcher: DaemonLauncher
    let paths: Paths

    public init(paths: Paths = .current, settings: Settings = .current,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        lifecycle = SystemLifecycle(services: .production(settings: settings), paths: paths,
                                    settings: settings, environment: environment)
        launcher = DaemonLauncher(lifecycle: lifecycle, paths: paths)
    }

    public var isSystemIntegrationEnabled: Bool { lifecycle.isEnabled }
    public var startsAtLogin: Bool { lifecycle.startsAtLogin }
    /// Only reads `~/.zshrc`.
    public var isShellConfigured: Bool { ShellPath.isConfigured() }

    public func startDaemon() throws -> DaemonLauncher.Outcome {
        try launcher.ensureRunning(honouringLoginSetting: true)
    }

    public func stopDaemon() throws {
        _ = try launcher.stop()
    }

    public func setStartsAtLogin(_ on: Bool) throws {
        guard let daemon = launcher.daemon else { throw DaemonLaunchError.noDaemonBinary }
        try lifecycle.setStartsAtLogin(on, daemon: daemon)
    }

    public func restorePreviousSetup() throws -> [String] {
        try lifecycle.uninstall()
    }

    public func configureShell() throws {
        guard lifecycle.isEnabled else { return }
        try ShellPath.configure()
    }

    public func parkedFolders() -> [String] {
        StateStore(paths: paths).load().parked
    }
}
