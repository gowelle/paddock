import Combine
import Foundation

/// Sends one request to the daemon. `PaddockClient` in the app, a fake in tests.
public protocol ClientProtocol: Sendable {
    func send(_ r: Request) throws -> Response
}

extension PaddockClient: ClientProtocol {
    public func send(_ r: Request) throws -> Response {
        try send(r, timeout: 600)
    }
}

/// What the app does outside the daemon: starting and stopping it, login item, restore, PATH.
/// Every call may block, so the model makes them off the main thread.
public protocol AppServices: Sendable {
    var isSystemIntegrationEnabled: Bool { get }
    var startsAtLogin: Bool { get }
    var isShellConfigured: Bool { get }
    /// Starts the daemon exactly as `paddock start` does.
    func startDaemon() throws -> DaemonLauncher.Outcome
    func stopDaemon() throws
    func setStartsAtLogin(_ on: Bool) throws
    /// The `paddock uninstall` flow; returns its lines.
    func restorePreviousSetup() throws -> [String]
    func configureShell() throws
    func parkedFolders() -> [String]
}

/// Politely quits another application of the current user's. Lives in the app (it needs AppKit).
public protocol ApplicationQuitter: Sendable {
    func canQuit(pid: Int32) -> Bool
    func quit(pid: Int32) -> Bool
}

/// Everything the menu and settings window show, and every action they take. The views hold no logic.
@MainActor
public final class AppModel: ObservableObject {
    /// Nil while the daemon is not running.
    @Published public var status: EngineStatus?
    /// One quiet line under the menu and settings; cleared by the next successful action.
    @Published public var lastError: String?
    /// `busyKey`s of requests in flight.
    @Published public var busy: Set<String> = []
    /// The daemon's answer when a site could not be made trusted; shown under the sites table.
    @Published public var trustNotice: String?
    @Published public private(set) var parked: [String] = []
    @Published public private(set) var startsAtLogin = false
    @Published public private(set) var shellConfigured = true
    /// What "Restore previous setup" reported.
    @Published public private(set) var restoreMessage: String?

    /// Every PHP version Paddock can install.
    public let availablePHP: [PHPVersion]
    /// True when this app launched the daemon itself; it then shuts it down on quit.
    public private(set) var ownsDaemon = false

    public static let unavailableCaption = "Not available for this Paddock home."

    private let client: ClientProtocol
    private let services: AppServices?
    private let quitter: ApplicationQuitter?
    private let paths: Paths?
    private var watchers = 0
    private var refreshTask: Task<Void, Never>?
    /// Pause between start attempts while a quit application lets go of its port.
    var quitRetryDelay: UInt64 = 500_000_000

    public init(client: ClientProtocol, services: AppServices? = nil, quitter: ApplicationQuitter? = nil,
                availablePHP: [PHPVersion] = [], paths: Paths? = nil) {
        self.client = client
        self.paths = paths
        self.services = services
        self.quitter = quitter
        self.availablePHP = availablePHP.sorted()
        if let services {
            startsAtLogin = services.startsAtLogin
            shellConfigured = services.isShellConfigured
            parked = services.parkedFolders()
        }
    }

    // MARK: - Derived, for the views

    public var isRunning: Bool { status?.running ?? false }

    public var statusLine: String {
        if isRunning { return "Running" }
        if let holder = blockingHolder { return Messages.cantStart(holder) }
        return "Stopped"
    }

    /// The first listener keeping Paddock from starting.
    public var blockingHolder: PortHolder? {
        isRunning ? nil : status?.blockedBy.first
    }

    /// A `Quit <command>` button is offered only for an application of the current user's.
    public var canQuitBlockingHolder: Bool {
        guard let holder = blockingHolder, holder.ownedByCurrentUser, let pid = holder.pid,
              let quitter else { return false }
        return quitter.canQuit(pid: pid)
    }

    public var quitButtonTitle: String { "Quit \(blockingHolder?.command ?? "it")" }

    /// The plain explanation shown instead of a button.
    public var blockedExplanation: String? {
        guard let blocked = status?.blockedBy, !isRunning, !blocked.isEmpty, !canQuitBlockingHolder else { return nil }
        return Messages.portsBlocked(blocked)
    }

    public var sites: [Site] { status?.sites ?? [] }
    public var installedPHP: [PHPVersion] { (status?.installedPHP ?? []).sorted() }
    public var defaultPHP: PHPVersion? { status?.defaultPHP }
    public var phpMenuTitle: String { defaultPHP.map { "PHP \($0)" } ?? "PHP" }
    public var defaultPHPLabel: String { "Default (\(defaultPHP?.description ?? "none"))" }
    public var systemIntegrationEnabled: Bool { services?.isSystemIntegrationEnabled ?? false }
    public var sitesFolder: URL? { parked.first.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// The version's user-edited php.ini, once it exists.
    public func phpIni(_ v: PHPVersion) -> URL? {
        guard let ini = paths?.phpIni(v), FileManager.default.fileExists(atPath: ini.path) else { return nil }
        return ini
    }

    public func isBusy(_ r: Request) -> Bool { busy.contains(Self.busyKey(r)) }

    public static func busyKey(_ r: Request) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(r)).map { String(decoding: $0, as: UTF8.self) } ?? "\(r)"
    }

    // MARK: - Talking to the daemon

    /// Fetches the status (and the parked folders and login item) without blocking the main thread.
    public func refresh() async {
        let client = client
        let services = services
        let (result, extras) = await Task.detached { () -> (Result<Response, Error>, Extras?) in
            (Result { try client.send(.status) },
             services.map { Extras(parked: $0.parkedFolders(), startsAtLogin: $0.startsAtLogin,
                                   shellConfigured: $0.isShellConfigured) })
        }.value
        if let extras {
            parked = extras.parked
            startsAtLogin = extras.startsAtLogin
            shellConfigured = extras.shellConfigured
        }
        switch result {
        case .success(.ok(let fresh)): status = fresh
        case .success(.error(_, let message)): lastError = message
        case .failure(ClientError.daemonNotRunning): status = nil
        case .failure(let error): lastError = Self.describe(error)
        }
    }

    private struct Extras: Sendable {
        var parked: [String]
        var startsAtLogin: Bool
        var shellConfigured: Bool
    }

    /// Sends one request, marking it busy while it is in flight, then refreshes.
    public func perform(_ r: Request) async {
        let key = Self.busyKey(r)
        busy.insert(key)
        defer { busy.remove(key) }
        let client = client
        let result = await Task.detached { Result { try client.send(r) } }.value
        switch result {
        case .success(.ok(let fresh)):
            status = fresh
            lastError = nil
            if Self.isTrustRequest(r) { trustNotice = nil }
        case .success(.error(let code, let message)):
            if code == ErrorCode.needsTrust || code == ErrorCode.trustDisabled {
                trustNotice = message
            } else if code != ErrorCode.portsBlocked { // The status line already says it.
                lastError = message
            }
        case .failure(ClientError.daemonNotRunning):
            status = nil
            lastError = Messages.notRunning
        case .failure(let error):
            lastError = Self.describe(error)
        }
        await refresh()
    }

    private static func isTrustRequest(_ r: Request) -> Bool {
        switch r {
        case .secure, .unsecure, .trust: return true
        default: return false
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ClientError.daemonNotRunning: return Messages.notRunning
        case ClientError.timedOut: return Messages.didNotAnswer
        case let launch as DaemonLaunchError: return launch.message()
        default:
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return text
        }
    }

    // MARK: - Starting and stopping

    /// On launch: start Paddock unless it is already running. No windows, no questions.
    public func launch() async {
        await refresh()
        if status == nil { await start() }
    }

    /// Starts the daemon as `paddock start` does, then asks the engine to start.
    public func start() async {
        let key = Self.busyKey(.start)
        busy.insert(key)
        defer { busy.remove(key) }
        if let services {
            let outcome = await Task.detached { Result { try services.startDaemon() } }.value
            switch outcome {
            case .success(let how):
                if how == .spawned { ownsDaemon = true }
                if how == .viaSystem { ownsDaemon = false }
            case .failure(let error as DaemonLaunchError):
                lastError = error.message()
                await refresh()
                return
            case .failure(let error):
                lastError = "Couldn't start Paddock: \(Self.describe(error))"
                await refresh()
                return
            }
        }
        await perform(.start)
    }

    public func stop() async {
        let key = Self.busyKey(.stop)
        busy.insert(key)
        defer { busy.remove(key) }
        if let services {
            let result = await Task.detached { Result { try services.stopDaemon() } }.value
            if case .failure(let error) = result {
                lastError = "Couldn't stop Paddock: \(Self.describe(error))"
            } else {
                lastError = nil
                ownsDaemon = false
            }
            await refresh()
        } else {
            await perform(.stop)
        }
    }

    /// Asks the application holding the port to quit (never a signal), then starts once the port is free.
    public func quitBlockingHolder() async {
        guard canQuitBlockingHolder, let pid = blockingHolder?.pid, let quitter else { return }
        guard quitter.quit(pid: pid) else {
            lastError = "\(blockingHolder?.command ?? "That program") didn't quit."
            return
        }
        for _ in 0..<20 {
            await start()
            guard blockingHolder?.pid == pid else { return }
            try? await Task.sleep(nanoseconds: quitRetryDelay)
        }
    }

    /// Sends `shutdown` to a daemon this app launched itself. Blocks; for the app's last moments.
    public func shutDownOwnedDaemon() {
        guard ownsDaemon else { return }
        _ = try? client.send(.shutdown)
        ownsDaemon = false
    }

    // MARK: - General settings

    public func setStartsAtLogin(_ on: Bool) async {
        guard let services, services.isSystemIntegrationEnabled else { return }
        if on && ownsDaemon {
            // The LaunchAgent takes over from the daemon this app launched.
            _ = await Task.detached { try? services.stopDaemon() }.value
            ownsDaemon = false
        }
        let result = await Task.detached { Result { try services.setStartsAtLogin(on) } }.value
        if case .failure(let error) = result {
            lastError = Self.describe(error)
            await refresh()
            return
        }
        lastError = nil
        startsAtLogin = services.startsAtLogin
        // Removing the agent stopped the daemon; this app now runs it while it is open.
        await start()
    }

    public func restorePreviousSetup() async {
        guard let services, services.isSystemIntegrationEnabled else { return }
        let result = await Task.detached { Result { try services.restorePreviousSetup() } }.value
        switch result {
        case .success(let lines):
            // Uninstalling stops the LaunchAgent's daemon; one this app launched itself stops here.
            if ownsDaemon {
                _ = await Task.detached { try? services.stopDaemon() }.value
                ownsDaemon = false
            }
            restoreMessage = lines.joined(separator: "\n")
            lastError = nil
        case .failure(ResolverError.cancelled):
            lastError = "Paddock is still installed."
        case .failure(let error):
            lastError = "Couldn't restore your previous setup: \(Self.describe(error))"
        }
        await refresh()
    }

    public func addToTerminal() async {
        guard let services, services.isSystemIntegrationEnabled else { return }
        let result = await Task.detached { Result { try services.configureShell() } }.value
        if case .failure(let error) = result {
            lastError = Self.describe(error)
        } else {
            lastError = nil
        }
        shellConfigured = services.isShellConfigured
    }

    // MARK: - Refreshing while visible

    /// Call when the menu or settings window appears; refreshes every 2 seconds until the last one closes.
    public func beginWatching() {
        watchers += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }
}
