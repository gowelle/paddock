import Darwin
import Foundation

public struct EngineStatus: Codable, Equatable, Sendable {
    public var running: Bool
    /// Listeners on the HTTP/HTTPS ports that stopped the last `start()`.
    public var blockedBy: [PortHolder]
    public var sites: [Site]
    public var installedPHP: [PHPVersion]
    public var defaultPHP: PHPVersion?
    /// Supervised process name -> its `ProcessStatus` description.
    public var processes: [String: String]
    public var resolverInstalled: Bool
    /// True iff this engine can make macOS trust Paddock's certificate (it has a trust object).
    public var trustEnabled: Bool
    /// Whether the `.test` DNS responder is answering. It runs whenever the daemon does, even while
    /// the web server is stopped or blocked.
    public var dnsRunning: Bool
    /// Whether something forwards the web ports to Caddy's Unix sockets: always true in a development
    /// home, whose engine runs the helper itself; on the real system, whether launchd's helper is installed.
    public var portHelperInstalled: Bool

    public init(running: Bool, blockedBy: [PortHolder], sites: [Site],
                installedPHP: [PHPVersion], defaultPHP: PHPVersion?, processes: [String: String],
                resolverInstalled: Bool, trustEnabled: Bool, dnsRunning: Bool, portHelperInstalled: Bool) {
        self.running = running
        self.blockedBy = blockedBy
        self.sites = sites
        self.installedPHP = installedPHP
        self.defaultPHP = defaultPHP
        self.processes = processes
        self.resolverInstalled = resolverInstalled
        self.trustEnabled = trustEnabled
        self.dnsRunning = dnsRunning
        self.portHelperInstalled = portHelperInstalled
    }
}

public enum EngineError: Error, Equatable {
    /// A process did not become ready in time, or exited while starting. `log` is its log file.
    case notReady(process: String, log: String)
    case caddyReloadFailed(output: String)
    /// A Unix socket under the Paddock home would be longer than macOS allows.
    case socketPathTooLong(path: String)
    /// A development home needs `paddock-ports` and there is none to run.
    case portHelperMissing
}

/// Runs the web stack (one PHP-FPM per PHP version in use, Caddy in front) and the DNS responder.
/// Caddy listens only on two owner-only Unix sockets; something else forwards the HTTP and HTTPS ports to
/// them. In a development home that is the engine's own `paddock-ports` child; on the real system it is
/// launchd's helper, so the engine neither runs it nor checks the ports.
/// The DNS responder is independent of the web stack: it starts with the first `start()` (or
/// `startDNS()`) and stops only in `shutdown()`, when the daemon exits.
public final class Engine: @unchecked Sendable {
    public let paths: Paths
    public let settings: Settings
    public let store: StateStore
    public let installer: PHPInstaller
    /// Makes macOS trust Caddy's local CA when a site is secured; nil leaves trust alone.
    let trust: CertificateTrust?
    /// The file `status().resolverInstalled` reads; `/etc/resolver/<tld>` unless a test says otherwise.
    let resolverFile: URL
    /// True in a development home: the engine checks the web ports and runs `paddock-ports` on them.
    let managesPortHelper: Bool
    /// The helper the engine runs when it manages one.
    private let portHelper: URL?
    /// On the real system, whether launchd's helper is installed.
    private let portHelperInstalled: @Sendable () -> Bool

    private let supervisor: Supervisor
    private let dns: DNSResponder
    /// Held for the whole of `start`, `stop` and `reload`, including slow waits. Never taken by `status`.
    private let operationLock = NSLock()
    /// Guards only the fields `status` reads; held for an instant, never across slow work.
    private let flagsLock = NSLock()
    private var isRunning = false
    private var blockedBy: [PortHolder] = []
    private var dnsUp = false
    private var shuttingDown = false
    /// The PHP install in progress, if any; shutting down cancels it. Guarded by `flagsLock`.
    private var installInProgress: Task<Void, Error>?
    /// Only touched while holding `operationLock`.
    private var fpmVersions: Set<PHPVersion> = []
    /// Replaces the real download in `installPHP` requests; tests use it to make installs slow.
    let installAction: (@Sendable (PHPVersion) async throws -> Void)?
    /// Serializes requests that change state, so each one's update and reload finish before the next.
    let mutations = AsyncMutex()
    /// One line for the daemon log (stderr under the daemon). Tests capture it.
    let log: @Sendable (String) -> Void

    private static let caddyName = "caddy"
    private static let portHelperName = "ports"
    private static let readyTimeout: TimeInterval = 15

    /// `portHelperInstalled` answers, on the real system, whether launchd's port helper is installed and
    /// current (`PortHelper.isInstalled`); a development home runs its own helper and ignores it.
    public convenience init(paths: Paths = .current, settings: Settings = .current,
                            trust: CertificateTrust? = nil, resolverFile: URL? = nil,
                            portHelperInstalled: @escaping @Sendable () -> Bool = { false }) {
        self.init(paths: paths, settings: settings, installAction: nil, trust: trust, resolverFile: resolverFile,
                  portHelperInstalled: portHelperInstalled)
    }

    /// `backoffScale` shortens the supervisor's restart delays (tests only). `managesPortHelper` defaults to
    /// "this is a development home" (`SystemIntegration`); tests set it to exercise either mode.
    init(paths: Paths, settings: Settings, installAction: (@Sendable (PHPVersion) async throws -> Void)?,
         trust: CertificateTrust? = nil, backoffScale: TimeInterval = 1, resolverFile: URL? = nil,
         managesPortHelper: Bool = !SystemIntegration.isEnabled(environment: ProcessInfo.processInfo.environment),
         portHelper: URL? = PortHelperLocator.binary(),
         portHelperInstalled: @escaping @Sendable () -> Bool = { false },
         log: @escaping @Sendable (String) -> Void = { fputs("paddockd: \($0)\n", stderr) }) {
        self.installAction = installAction
        self.managesPortHelper = managesPortHelper
        self.portHelper = portHelper
        self.portHelperInstalled = portHelperInstalled
        self.log = log
        self.trust = trust
        self.resolverFile = resolverFile ?? Resolver.defaultFile(settings: settings)
        supervisor = Supervisor(backoffScale: backoffScale)
        self.paths = paths
        self.settings = settings
        store = StateStore(paths: paths)
        installer = PHPInstaller(paths: paths, manifest: (try? PHPManifest.bundled()) ?? PHPManifest(builds: []))
        dns = DNSResponder(port: settings.dnsPort, tld: settings.tld)
    }

    deinit { shutdown() }

    /// Starts the DNS responder (if it isn't answering yet), then the web stack. In a development home,
    /// if something already accepts connections on the HTTP/HTTPS ports, it starts no web server and
    /// reports who in `status().blockedBy`. Returns once Caddy accepts connections on its sockets and,
    /// in a development home, the port helper on both ports.
    public func start() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        startDNS()
        if flags.running {
            // Caddy or the helper crashed and was given up on: tear down what is left and start afresh.
            guard caddyCrashed || helperCrashed else { return }
            stopLocked()
        }

        if let path = paths.tooLongSocket { throw EngineError.socketPathTooLong(path: path) }
        try paths.ensureDirectories()
        do { try installShims() } catch {
            log("could not install the php and composer commands: \(error.localizedDescription)")
        }
        let state = try prepareState()

        var helper: URL?
        if managesPortHelper {
            let holders = PortCheck.holders(of: webPorts)
            setFlags(blockedBy: holders)
            guard holders.isEmpty else { return }
            guard let portHelper else { throw EngineError.portHelperMissing }
            helper = portHelper
        } else {
            setFlags(blockedBy: [])
        }

        do {
            try writeConfigs(state)
            for v in versionsInUse(state).sorted() { try startFPM(v) }
            try startCaddy()
            try waitUntilReady()
            if let helper {
                try startPortHelper(helper)
                // Someone took a port between the check and the helper's bind: that is the blocked case.
                guard try waitForPortHelper() else { return }
            }
            setFlags(running: true)
        } catch {
            stopLocked()
            throw error
        }
    }

    private var webPorts: [Int] { [settings.httpPort, settings.httpsPort] }

    /// Puts the `paddock` binary that sits next to the running daemon into `bin/`, with `php` and
    /// `composer` linking to it. Does nothing when there is no such binary (e.g. under tests).
    /// Safe to call on every start.
    public func installShims() throws {
        try installShims(runningExecutable: Bundle.main.executableURL)
    }

    func installShims(runningExecutable: URL?) throws {
        let sibling = runningExecutable?.deletingLastPathComponent().appendingPathComponent("paddock")
        try Shims.install(paths: paths, source: sibling, resources: Bundled.resources)
    }

    /// Starts the `.test` DNS responder unless it is already answering. A failure (its port taken) is
    /// logged and shows as `status().dnsRunning == false`; the next `start()` tries again.
    public func startDNS() {
        do {
            try dns.start()
            setFlags(dnsRunning: true)
        } catch {
            setFlags(dnsRunning: false)
            log("the .test DNS responder could not listen on port \(settings.dnsPort): \(error)")
        }
    }

    /// Stops Caddy and every PHP-FPM (with its workers). The DNS responder keeps answering.
    public func stop() {
        operationLock.lock()
        defer { operationLock.unlock() }
        stopLocked()
        setFlags(blockedBy: [])
    }

    /// Stops the web stack and the DNS responder; for the daemon's exit.
    public func shutdown() {
        operationLock.lock()
        defer { operationLock.unlock() }
        stopLocked()
        dns.stop()
        setFlags(blockedBy: [], dnsRunning: false)
    }

    /// Regenerates configs; when running, also starts/stops FPM pools to match the versions in use
    /// and has Caddy load the new Caddyfile.
    public func reload() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try paths.ensureDirectories()
        let state = try prepareState()
        try writeConfigs(state)
        guard flags.running else { return }

        let wanted = versionsInUse(state)
        for v in fpmVersions.subtracting(wanted) {
            supervisor.stop(Self.fpmName(v))
            fpmVersions.remove(v)
        }
        for v in wanted.sorted() where !isFPMRunning(v) { try startFPM(v) }
        // With Caddy down there is nothing to wait for or reload; the supervisor (or `start`)
        // brings it up from the Caddyfile written above.
        guard !caddyCrashed else { return }
        try waitUntilReady()
        try reloadCaddy()
    }

    /// Answers promptly even while `start`, `reload` or a PHP install is in progress: it takes only
    /// short-lived locks, never `operationLock`. `running` is false while Caddy (or, in a development
    /// home, the port helper) is crashed.
    public func status() -> EngineStatus {
        let current = flags
        let state = store.load()
        let sites = state.defaultPHP.map {
            SiteRegistry(state: state, defaultPHP: $0, settings: settings).sites()
        } ?? []
        var processes: [String: String] = [:]
        for name in supervisor.names { processes[name] = supervisor.status(name).description }
        return EngineStatus(running: current.running && !caddyCrashed && !helperCrashed,
                            blockedBy: current.blockedBy,
                            sites: sites,
                            installedPHP: installer.installed(), defaultPHP: state.defaultPHP,
                            processes: processes,
                            resolverInstalled: (try? String(contentsOf: resolverFile, encoding: .utf8))
                                == Resolver.desiredContents(settings: settings),
                            trustEnabled: trust != nil, dnsRunning: current.dnsRunning,
                            portHelperInstalled: managesPortHelper || portHelperInstalled())
    }

    // MARK: - State and configs

    /// Installs the bundled PHP if none is installed, makes sure the default PHP is installed,
    /// and creates the first parked directory if it can (it may be on a volume that isn't mounted).
    private func prepareState() throws -> State {
        var installed = installer.installed()
        if installed.isEmpty {
            try installer.installBundled()
            installed = installer.installed()
        }
        let state = try store.update { state in
            if state.defaultPHP.map({ !installed.contains($0) }) ?? true {
                state.defaultPHP = installed.max()
            }
        }
        if let first = state.parked.first {
            try? FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        }
        return state
    }

    /// The default PHP plus every pinned version that is installed.
    private func versionsInUse(_ state: State) -> Set<PHPVersion> {
        Set(([state.defaultPHP].compactMap { $0 } + state.phpPins.values).filter(installer.isInstalled))
    }

    private func writeConfigs(_ state: State) throws {
        try RouterConfig.write(state: state, paths: paths, settings: settings)
        for v in versionsInUse(state) { try FPMConfig.write(version: v, paths: paths) }
        guard let defaultPHP = state.defaultPHP else { return }
        let sites = SiteRegistry(state: state, defaultPHP: defaultPHP, settings: settings).sites()
        let text = Caddyfile.render(sites: sites, defaultPHP: defaultPHP, paths: paths, settings: settings)
        try Data(text.utf8).write(to: paths.caddyfile, options: .atomic)
    }

    // MARK: - Processes

    private static func fpmName(_ v: PHPVersion) -> String { "php-fpm-\(v)" }

    private func isFPMRunning(_ v: PHPVersion) -> Bool {
        if case .running = supervisor.status(Self.fpmName(v)) { return true }
        return false
    }

    private func startFPM(_ v: PHPVersion) throws {
        let conf = try FPMConfig.write(version: v, paths: paths)
        try? FileManager.default.removeItem(at: paths.fpmSocket(v))
        try supervisor.start(ProcessSpec(
            name: Self.fpmName(v), executable: installer.fpmBinary(v),
            arguments: ["-y", conf.path, "-c", paths.phpIni(v).path, "-F"],
            logFile: paths.log.appendingPathComponent("\(Self.fpmName(v)).out.log")))
        fpmVersions.insert(v)
    }

    /// Caddy keeps its data and config (CA, certificates, autosave) inside the Paddock home.
    private var caddyEnvironment: [String: String] {
        ["XDG_DATA_HOME": paths.caddyData.appendingPathComponent("data").path,
         "XDG_CONFIG_HOME": paths.caddyData.appendingPathComponent("config").path]
    }

    private var caddyBinary: URL { Bundled.resources.appendingPathComponent("caddy") }

    private var caddyLog: URL { paths.log.appendingPathComponent("caddy.log") }

    private func startCaddy() throws {
        for socket in [paths.caddyAdminSocket, paths.httpSocket, paths.httpsSocket] {
            try? FileManager.default.removeItem(at: socket)
        }
        try supervisor.start(ProcessSpec(
            name: Self.caddyName, executable: caddyBinary,
            arguments: ["run", "--config", paths.caddyfile.path, "--adapter", "caddyfile"],
            environment: caddyEnvironment, logFile: caddyLog))
    }

    private func reloadCaddy() throws {
        let caddy = Process()
        caddy.executableURL = caddyBinary
        caddy.arguments = ["reload", "--config", paths.caddyfile.path, "--adapter", "caddyfile",
                           "--address", "unix/" + paths.caddyAdminSocket.path]
        caddy.environment = ProcessInfo.processInfo.environment.merging(caddyEnvironment) { $1 }
        let output = Pipe()
        caddy.standardOutput = output
        caddy.standardError = output
        try caddy.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        caddy.waitUntilExit()
        guard caddy.terminationStatus == 0 else {
            throw EngineError.caddyReloadFailed(output: String(decoding: data, as: UTF8.self))
        }
    }

    /// Forwards the web ports to Caddy's sockets. It keeps running while Caddy restarts: a connection
    /// that arrives while Caddy is down is closed at once.
    private func startPortHelper(_ helper: URL) throws {
        try supervisor.start(ProcessSpec(
            name: Self.portHelperName, executable: helper,
            arguments: ["listen", "\(settings.httpPort)", "\(settings.httpsPort)",
                        paths.httpSocket.path, paths.httpsSocket.path],
            logFile: portHelperLog))
    }

    private var portHelperLog: URL { paths.log.appendingPathComponent("paddock-ports.log") }

    /// Waits until the helper accepts connections on both ports. False when it could not take them
    /// because something else holds one: the web stack is stopped again and the holders are reported.
    private func waitForPortHelper() throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while !webPorts.allSatisfy(PortCheck.accepts(port:)) {
            guard case .running = supervisor.status(Self.portHelperName), Date() < deadline else {
                stopLocked()
                let holders = PortCheck.holders(of: webPorts)
                guard holders.isEmpty else {
                    setFlags(blockedBy: holders)
                    return false
                }
                throw EngineError.notReady(process: Self.portHelperName, log: portHelperLog.path)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    /// Waits until every FPM socket exists and Caddy accepts connections on its HTTP socket. Caddy
    /// opens all its listeners before it serves a configuration, and its HTTPS socket exists only
    /// while some site is secured, so the HTTP socket (the catch-all is always there) stands for both.
    private func waitUntilReady() throws {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        var pending: [(name: String, log: URL, ready: () -> Bool)] = fpmVersions.sorted().map { v in
            (Self.fpmName(v), paths.log.appendingPathComponent("php-fpm-\(v).log"),
             { [paths] in FileManager.default.fileExists(atPath: paths.fpmSocket(v).path) })
        }
        if supervisor.names.contains(Self.caddyName) {
            pending.append((Self.caddyName, caddyLog, { [paths] in
                Self.acceptsConnection(onSocket: paths.httpSocket.path)
            }))
        }
        for item in pending {
            while !item.ready() {
                guard case .running = supervisor.status(item.name), Date() < deadline else {
                    throw EngineError.notReady(process: item.name, log: item.log.path)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Waits until Caddy has written its root certificate, which it does lazily after the first
    /// secured site is loaded. False if it did not appear in time.
    func waitForRootCertificate(_ trust: CertificateTrust, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: trust.rootCertificate.path) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    /// Whether Caddy is up, so a root certificate can be expected.
    var isServing: Bool { flags.running && !caddyCrashed }

    private static func acceptsConnection(onSocket path: String) -> Bool {
        guard let fd = Wire.connect(to: path) else { return false }
        close(fd)
        return true
    }

    private func stopLocked() {
        supervisor.stopAll()
        fpmVersions = []
        setFlags(running: false)
    }

    private var caddyCrashed: Bool {
        if case .crashed = supervisor.status(Self.caddyName) { return true }
        return false
    }

    /// Only ever true in a development home, the one place the engine runs the helper.
    private var helperCrashed: Bool {
        if case .crashed = supervisor.status(Self.portHelperName) { return true }
        return false
    }

    private var flags: (running: Bool, blockedBy: [PortHolder], dnsRunning: Bool) {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return (isRunning, blockedBy, dnsUp)
    }

    private func setFlags(running: Bool? = nil, blockedBy: [PortHolder]? = nil, dnsRunning: Bool? = nil) {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        if let running { isRunning = running }
        if let blockedBy { self.blockedBy = blockedBy }
        if let dnsRunning { dnsUp = dnsRunning }
    }

    /// Set once the daemon begins to exit; from then on every request that changes anything is refused.
    var isShuttingDown: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return shuttingDown
    }

    /// Refuses all further changes and cancels a PHP install in progress, so shutting down never waits
    /// for a download.
    func markShuttingDown() {
        flagsLock.lock()
        shuttingDown = true
        let install = installInProgress
        flagsLock.unlock()
        install?.cancel()
    }

    /// Records the PHP install in progress (nil when it is over). One registered after shutting down
    /// began is cancelled at once.
    func setInstallInProgress(_ task: Task<Void, Error>?) {
        flagsLock.lock()
        installInProgress = task
        let cancel = shuttingDown
        flagsLock.unlock()
        if cancel { task?.cancel() }
    }
}
