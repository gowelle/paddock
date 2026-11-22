import Combine
import Foundation

/// Sends one request to the daemon. `PaddockClient` in the app, a fake in tests.
public protocol ClientProtocol: Sendable {
    /// Throws `ClientError.timedOut` when no answer arrives within `timeout` seconds.
    func send(_ r: Request, timeout: TimeInterval) throws -> Response
}

extension ClientProtocol {
    /// Requests may take a while (a PHP download), so the usual wait is generous.
    public func send(_ r: Request) throws -> Response {
        try send(r, timeout: 600)
    }
}

extension PaddockClient: ClientProtocol {}

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
    /// Throws (`DaemonLaunchError.developmentBuild`, `.runningAsRoot`) when this program may not change the
    /// owner's system or installed Paddock (`SystemLifecycle.checkMayChangeSystem`). Cheap; never blocks.
    func checkMayChangeSystem() throws
}

/// Politely quits another application of the current user's, found by its bundle folder (e.g.
/// `/Applications/Herd.app`). Lives in the app (it needs AppKit).
public protocol ApplicationQuitter: Sendable {
    func canQuit(appBundlePath: String) -> Bool
    func quit(appBundlePath: String) -> Bool
}

/// Everything the menu and settings window show, and every action they take. The views hold no logic.
@MainActor
public final class AppModel: ObservableObject {
    /// Nil while the daemon is not running.
    @Published public var status: EngineStatus?
    /// One quiet line under the menu and settings; cleared by the next successful action.
    @Published public var lastError: String? {
        didSet {
            errorCameFromRefresh = false
            lastErrorSource = nil
        }
    }
    /// The `busyKey` of the services or tasks action whose error `lastError` is: only that action succeeding on the
    /// same item clears it (`finish`). Nil for any other error.
    var lastErrorSource: String?
    /// True while `lastError` was set by a background refresh; the next successful refresh clears it.
    /// An action's error stays until the next successful action.
    private var errorCameFromRefresh = false
    /// `busyKey`s of requests in flight.
    @Published public var busy: Set<String> = []
    /// The daemon's answer when a site could not be made trusted; shown under the sites table.
    @Published public var trustNotice: String?
    @Published public private(set) var parked: [String] = []
    @Published public private(set) var startsAtLogin = false
    @Published public private(set) var shellConfigured = true
    /// What "Restore previous setup" reported.
    @Published public private(set) var restoreMessage: String?
    /// On the real system: who held ports 80/443 when the last start checked them before the setup prompt
    /// (no prompt was shown). Cleared by the next start that gets past the check.
    @Published public private(set) var setupBlockedBy: [PortHolder] = []
    /// The services Paddock can add, as the daemon last listed them (`loadCatalog`).
    @Published public internal(set) var catalogEntries: [CatalogEntry] = []
    /// What the last service action reported (where a removed service's data is, a database created); shown
    /// under the services list until another replaces it or `noticeLifetime` passes.
    @Published public internal(set) var serviceNotice: String?
    /// The same for the tasks list (a task with no log yet).
    @Published public internal(set) var taskNotice: String?
    /// The `Remove and Delete Data…` question being shown; nil once hidden (which alone confirms or cancels
    /// nothing).
    @Published public internal(set) var dataDeletionRequest: DataDeletionRequest?
    /// The one question whose confirmation may delete data: issued by `askToRemoveAndDeleteData`, ended by its use
    /// or by cancelling.
    var dataDeletionGrant: DataDeletionRequest?
    /// The site whose approval sheet is open.
    @Published public internal(set) var approvalSite: String?
    /// What the open approval sheet shows, set from every outcome of loading it (polling never changes it).
    @Published public internal(set) var approvalState: ApprovalSheetState = .loading
    /// The sheet's own error line: why approving failed. Starts empty each time the sheet opens.
    @Published public internal(set) var approvalError: String?

    /// Every PHP version Paddock can install.
    public let availablePHP: [PHPVersion]
    /// True when this app launched the daemon itself; it then shuts it down on quit.
    public private(set) var ownsDaemon = false

    public static let unavailableCaption = "Not available for this Paddock home."
    /// The action offered while setup is unfinished; it runs the same start path.
    public static let finishSetupTitle = "Finish Setup\u{2026}"
    /// The action offered while the web ports are held; it runs the same start path.
    public static let tryAgainTitle = "Try Again"
    /// The action offered while secured sites need trusting; it sends the `trust` request.
    public static let trustCertificateTitle = "Trust Certificate\u{2026}"

    let client: ClientProtocol
    /// Puts text on the pasteboard, marked concealed (kept out of clipboard histories) when it holds a secret.
    let copyText: (@MainActor (_ text: String, _ concealed: Bool) -> Void)?
    /// Opens a URL or file with the system's default handler.
    let openItem: (@MainActor (URL) -> Void)?
    /// Shows a log file in the app's own Logs window; without it a log opens with the system's default handler.
    let showLog: (@MainActor (URL) -> Void)?
    private let services: AppServices?
    private let quitter: ApplicationQuitter?
    private let paths: Paths?
    private var watchers = 0
    private var refreshTask: Task<Void, Never>?
    /// Pause between start attempts while a quit application lets go of its port.
    var quitRetryDelay: UInt64 = 500_000_000
    /// How long a services or tasks notice shows.
    static let noticeLifetime: TimeInterval = 4
    /// Runs `expire` after `seconds` (tests run it when they choose).
    var scheduleNoticeExpiry: @MainActor (_ seconds: TimeInterval, _ expire: @escaping @MainActor () -> Void) -> Void = {
        seconds, expire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            expire()
        }
    }
    /// Counts the notices shown on each line (services: false, tasks: true), so an expiry clears only the notice
    /// it was scheduled for.
    var noticeGeneration: [Bool: Int] = [:]

    /// This app's own program, to tell its daemon from another copy's.
    private let ownExecutable: String?

    public init(client: ClientProtocol, services: AppServices? = nil, quitter: ApplicationQuitter? = nil,
                availablePHP: [PHPVersion] = [], paths: Paths? = nil,
                ownExecutable: String? = PaddockBuild.runningExecutable,
                copyText: (@MainActor (_ text: String, _ concealed: Bool) -> Void)? = nil,
                open: (@MainActor (URL) -> Void)? = nil,
                showLog: (@MainActor (URL) -> Void)? = nil) {
        self.client = client
        self.copyText = copyText
        self.openItem = open
        self.showLog = showLog
        self.ownExecutable = ownExecutable
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

    /// The engine runs but launchd's port helper isn't installed (or is outdated), so nothing answers on
    /// ports 80/443 yet. Never true in a development home, whose engine runs its own helper.
    public var needsSetup: Bool { isRunning && status?.portHelperInstalled == false }

    /// Sites answer on the web ports.
    public var isServing: Bool { isRunning && !needsSetup }

    /// Something else holds the web ports, so Paddock can't serve.
    public var isBlocked: Bool { !isServing && !heldPorts.isEmpty }

    /// Who holds the web ports: what the engine found (a development home), else what the last start
    /// found before the setup prompt (the real system).
    private var heldPorts: [PortHolder] {
        if let blocked = status?.blockedBy, !blocked.isEmpty { return blocked }
        return setupBlockedBy
    }

    /// The start-path action to offer next to the status line, whether or not a Quit button is offered:
    /// `Try Again` while the ports are held, `Finish Setup…` while setup is unfinished, else nil.
    public var setupActionTitle: String? {
        if isBlocked { return Self.tryAgainTitle }
        if needsSetup { return Self.finishSetupTitle }
        return nil
    }

    /// Where the daemon answering runs from, when that is another install of Paddock than this app's
    /// (its outermost `.app`, else its program, with the home folder as `~`); nil otherwise.
    public var anotherCopyLocation: String? {
        guard isRunning, let running = status?.executablePath, let own = ownExecutable,
              SystemIntegration.installLocation(of: running) != SystemIntegration.installLocation(of: own)
        else { return nil }
        var path = PortHolder.enclosingApp(ofExecutable: running)?.path ?? running
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        return Messages.displayName(path, limit: 256)
    }

    public var statusLine: String {
        if isBlocked { return Messages.cantStart(heldPorts) }
        if needsSetup { return "Setup needed" }
        if let other = anotherCopyLocation { return "Running from another copy at \(other)" }
        if isRunning { return "Running" }
        return "Stopped"
    }

    /// The listener keeping Paddock from starting: the first one inside an application, else the first.
    public var blockingHolder: PortHolder? {
        guard isBlocked else { return nil }
        return heldPorts.first { $0.appBundlePath != nil } ?? heldPorts.first
    }

    /// A `Quit <app>` button is offered only when the holder belongs to an application that is running
    /// for the current user.
    public var canQuitBlockingHolder: Bool {
        guard let path = blockingHolder?.appBundlePath, blockingHolder?.appName != nil, let quitter else { return false }
        return quitter.canQuit(appBundlePath: path)
    }

    public var quitButtonTitle: String { "Quit \(blockingHolder?.appName.flatMap { Messages.displayName($0) } ?? "it")" }

    /// The plain explanation shown instead of a button.
    public var blockedExplanation: String? {
        guard isBlocked else { return nil }
        return canQuitBlockingHolder ? nil : Messages.portsBlocked(heldPorts)
    }

    /// `Trust Certificate…` while secured sites need macOS to trust Paddock's certificate (again, after
    /// the certificate authority was renamed), or an older Paddock certificate is still trusted; nil otherwise.
    public var trustActionTitle: String? {
        status?.needsTrust == true || status?.hasReplacedRootsToClean == true ? Self.trustCertificateTitle : nil
    }

    public var sites: [Site] { status?.sites ?? [] }
    public var installedPHP: [PHPVersion] { (status?.installedPHP ?? []).sorted() }
    public var defaultPHP: PHPVersion? { status?.defaultPHP }
    public var phpMenuTitle: String { defaultPHP.map { "PHP \($0)" } ?? "PHP" }
    public var defaultPHPLabel: String { "Default (\(defaultPHP?.description ?? "none"))" }
    public var systemIntegrationEnabled: Bool { services?.isSystemIntegrationEnabled ?? false }
    public var sitesFolder: URL? { parked.first.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// Xdebug is switched on for the version.
    public func isXdebugOn(_ v: PHPVersion) -> Bool { status?.xdebug.contains(v) ?? false }

    /// The version is installed and Paddock has an Xdebug for it.
    public func canSwitchXdebug(_ v: PHPVersion) -> Bool { status?.xdebugAvailable.contains(v) ?? false }

    /// True while the version's Xdebug is being switched either way.
    public func isSwitchingXdebug(_ v: PHPVersion) -> Bool {
        isBusy(.xdebug(version: v, enabled: true)) || isBusy(.xdebug(version: v, enabled: false))
    }

    /// Said under the PHP list while Xdebug is on for some version; nil otherwise.
    public var xdebugCaption: String? {
        guard let on = status?.xdebug, !on.isEmpty else { return nil }
        return "Xdebug starts when a request asks for it; your editor listens on port 9003."
    }

    /// Where Paddock's logs are, when this model knows its home.
    var logPaths: Paths? { paths }

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
        case .success(.ok(let fresh)), .success(.removed(_, let fresh)), .success(.databaseCreated(_, _, let fresh)):
            status = fresh
            // Setup finished meanwhile (say, from the command line): the held ports are old news.
            if fresh.running && fresh.portHelperInstalled { setupBlockedBy = [] }
            if errorCameFromRefresh { lastError = nil }
        case .success(.error(_, let message)):
            showRefreshError(message)
        case .success(.catalog), .success(.envLines):
            break
        case .failure(ClientError.daemonNotRunning):
            status = nil
            if errorCameFromRefresh { lastError = nil }
        case .failure(let error):
            showRefreshError(Self.describe(error))
        }
    }

    /// A refresh never replaces an action's error the user may not have read yet.
    private func showRefreshError(_ message: String) {
        guard lastError == nil || errorCameFromRefresh else { return }
        lastError = message
        errorCameFromRefresh = true
    }

    private struct Extras: Sendable {
        var parked: [String]
        var startsAtLogin: Bool
        var shellConfigured: Bool
    }

    /// Whether this program may change the system; if not, says why in `lastError`. Every action that
    /// starts, stops or restarts Paddock, changes setup, trust or the shell file asks this first.
    func mayChangeSystem() -> Bool {
        guard let refusal = systemChangeRefusal() else { return true }
        lastError = refusal
        return false
    }

    /// Why this program may not change the system, or nil when it may.
    private func systemChangeRefusal() -> String? {
        do {
            try services?.checkMayChangeSystem()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Sends one request, marking it busy while it is in flight, then refreshes. Its error goes to the error line
    /// as this action's; its success clears only an earlier error of this same action on this same item.
    public func perform(_ r: Request) async {
        let key = Self.busyKey(r)
        switch await exchange(r) {
        case .refused(let refusal):
            showError(refusal, from: key)
            return
        case .failed(let message):
            showError(message, from: key)
        case .answer(.ok), .answer(.removed), .answer(.databaseCreated), .answer(.catalog), .answer(.envLines):
            if lastErrorSource == key { lastError = nil }
            if Self.isTrustRequest(r) { trustNotice = nil }
        case .answer(.error(let code, let message)):
            if code == ErrorCode.needsTrust || code == ErrorCode.trustDisabled {
                trustNotice = message
            } else if code != ErrorCode.portsBlocked {
                // (The status line already says that.)
                showError(message, from: key)
            }
        }
        await refresh()
    }

    /// How one request went: the daemon's answer (its status already published), refused before sending (a
    /// development build changing the real system), or no answer (the daemon not running, a timeout).
    enum Exchange {
        case answer(Response)
        case refused(String)
        case failed(String)
    }

    /// Sends one request: refused first from a development build unless it only reads, marked busy while in
    /// flight, off the main thread. Touches neither the error line nor any notice.
    func exchange(_ r: Request, timeout: TimeInterval = 600) async -> Exchange {
        // From a development build on the real system only reads leave (the client refuses the rest too).
        if !r.isReadOnly, let refusal = systemChangeRefusal() { return .refused(refusal) }
        let key = Self.busyKey(r)
        busy.insert(key)
        defer { busy.remove(key) }
        let client = client
        let result = await Task.detached { Result { try client.send(r, timeout: timeout) } }.value
        switch result {
        case .success(let response):
            switch response {
            case .ok(let fresh), .removed(_, let fresh), .databaseCreated(_, _, let fresh): status = fresh
            case .error, .catalog, .envLines: break
            }
            return .answer(response)
        case .failure(ClientError.daemonNotRunning):
            status = nil
            return .failed(Messages.notRunning)
        case .failure(let error):
            return .failed(Self.describe(error))
        }
    }

    /// `exchange`, with a refusal or a failure to reach the daemon on the error line. Returns the answer, or nil.
    func send(_ r: Request, timeout: TimeInterval = 600) async -> Response? {
        switch await exchange(r, timeout: timeout) {
        case .answer(let response): return response
        case .refused(let message), .failed(let message):
            lastError = message
            return nil
        }
    }

    /// A services or tasks action: sends it, and puts its error on the error line, marked as this action's, or,
    /// when it worked, clears an earlier error of this same action on this same item (and no other). Returns the
    /// answer, or nil.
    /// `errorKey` names the action and item when the request alone names them too narrowly.
    func act(_ r: Request, timeout: TimeInterval = 600, errorKey: String? = nil) async -> Response? {
        let key = errorKey ?? Self.busyKey(r)
        switch await exchange(r, timeout: timeout) {
        case .answer(let response):
            finish(response, for: key)
            return response
        case .refused(let message), .failed(let message):
            showError(message, from: key)
            return nil
        }
    }

    func finish(_ response: Response, for key: String) {
        if case .error(_, let message) = response {
            showError(message, from: key)
        } else if lastErrorSource == key {
            lastError = nil
        }
    }

    func showError(_ message: String, from key: String) {
        lastError = message
        lastErrorSource = key
    }

    /// The user dismissed the error line.
    public func dismissError() {
        lastError = nil
    }

    /// Shows a services or tasks notice, replacing the one there, for `noticeLifetime`.
    func showNotice(_ text: String, tasks: Bool = false) {
        if tasks { taskNotice = text } else { serviceNotice = text }
        let generation = (noticeGeneration[tasks] ?? 0) + 1
        noticeGeneration[tasks] = generation
        scheduleNoticeExpiry(Self.noticeLifetime) { [weak self] in
            guard let self, self.noticeGeneration[tasks] == generation else { return }
            if tasks { self.taskNotice = nil } else { self.serviceNotice = nil }
        }
    }

    private static func isTrustRequest(_ r: Request) -> Bool {
        switch r {
        case .secure, .unsecure, .trust: return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ClientError.daemonNotRunning: return Messages.notRunning
        case ClientError.timedOut: return Messages.didNotAnswer
        case ClientError.developmentBuild: return Messages.developmentBuild
        case let launch as DaemonLaunchError: return launch.message()
        case let resolver as ResolverError: return resolver.message
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
        guard mayChangeSystem() else { return }
        let key = Self.busyKey(.start)
        busy.insert(key)
        defer { busy.remove(key) }
        if let services {
            let outcome = await Task.detached { Result { try services.startDaemon() } }.value
            switch outcome {
            case .success(let how):
                setupBlockedBy = []
                if how == .spawned { ownsDaemon = true }
                if how == .viaSystem { ownsDaemon = false }
            case .failure(DaemonLaunchError.portsBlocked(let holders)):
                // The status line says it, with a Quit button where one applies.
                setupBlockedBy = holders
                lastError = nil
                await refresh()
                return
            case .failure(let error as DaemonLaunchError):
                showError(error.message(), from: key)
                await refresh()
                return
            case .failure(let error):
                showError("Couldn't start Paddock: \(Self.describe(error))", from: key)
                await refresh()
                return
            }
        }
        await perform(.start)
    }

    /// `Finish Setup…` and `Try Again`: the start path, which checks the ports again and asks for the
    /// password once to install what is missing.
    public func finishSetup() async {
        await start()
    }

    /// `Trust Certificate…`: the existing `trust` request; macOS shows its own confirmation.
    public func trustCertificate() async {
        await perform(.trust)
    }

    public func stop() async {
        guard mayChangeSystem() else { return }
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
    /// Only ever called from the user's click on the Quit button.
    public func quitBlockingHolder() async {
        guard canQuitBlockingHolder, let app = blockingHolder?.appBundlePath, let quitter else { return }
        let name = blockingHolder?.appName.flatMap { Messages.displayName($0) } ?? "That application"
        guard quitter.quit(appBundlePath: app) else {
            lastError = "\(name) didn't quit."
            return
        }
        for _ in 0..<20 {
            await start()
            guard heldPorts.contains(where: { $0.appBundlePath == app }) else { return }
            try? await Task.sleep(nanoseconds: quitRetryDelay)
        }
    }

    /// How long quitting waits for the daemon to accept `shutdown`.
    public static let shutdownTimeout: TimeInterval = 5

    /// Sends `shutdown` to a daemon this app launched itself, for the app's last moments. Blocks for at
    /// most `shutdownTimeout`: if the daemon is busy (say, downloading PHP) the app gives up quietly;
    /// the daemon still handles the queued `shutdown` once that work is done.
    public func shutDownOwnedDaemon() {
        guard ownsDaemon else { return }
        _ = try? client.send(.shutdown, timeout: Self.shutdownTimeout)
        ownsDaemon = false
    }

    // MARK: - General settings

    public func setStartsAtLogin(_ on: Bool) async {
        guard let services, services.isSystemIntegrationEnabled, mayChangeSystem() else { return }
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
        guard let services, services.isSystemIntegrationEnabled, mayChangeSystem() else { return }
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
        guard let services, services.isSystemIntegrationEnabled, mayChangeSystem() else { return }
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
