import Darwin
import Foundation

/// Which build of Paddock this is, so a client can tell a daemon from another build.
public enum PaddockBuild {
    /// Raised with every release whose daemon and clients must match (it is in every status reply).
    public static let number = 32

    /// The running program, symlinks resolved.
    public static var runningExecutable: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }
}

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
    /// The daemon's `PaddockBuild.number`; 0 from a daemon older than this field.
    public var version: Int
    /// The daemon's own program, if it reported one.
    public var executablePath: String?
    /// Some site is secured but macOS doesn't trust Paddock's current root (say, after the certificate
    /// authority was renamed): the owner should run `paddock trust`. False when trust is turned off.
    public var needsTrust: Bool
    /// A root set aside when the certificate authority was renamed is still trusted: `paddock trust`
    /// removes that trust. False when trust is turned off.
    public var hasReplacedRootsToClean: Bool
    /// Added services and what each is doing.
    public var services: [ServiceStatus]
    /// Sentences about Paddock itself (a web-stack log grown very large); empty from an older daemon.
    public var notices: [String]
    /// The installed PHP versions Xdebug is switched on for; empty from an older daemon.
    public var xdebug: [PHPVersion]
    /// The installed PHP versions Paddock has an Xdebug build for; empty from an older daemon.
    public var xdebugAvailable: [PHPVersion]
    /// The loopback port PHP sends its dumps to, when it does; nil otherwise and from an older daemon.
    public var dumpsTo: Int?
    /// The LAN listener (nil from a daemon older than LAN exposure).
    public var lan: LanStatus?

    public init(running: Bool, blockedBy: [PortHolder], sites: [Site],
                installedPHP: [PHPVersion], defaultPHP: PHPVersion?, processes: [String: String],
                resolverInstalled: Bool, trustEnabled: Bool, dnsRunning: Bool, portHelperInstalled: Bool,
                needsTrust: Bool = false, hasReplacedRootsToClean: Bool = false, services: [ServiceStatus] = [],
                notices: [String] = [], xdebug: [PHPVersion] = [], xdebugAvailable: [PHPVersion] = [],
                dumpsTo: Int? = nil, lan: LanStatus? = nil,
                version: Int = PaddockBuild.number, executablePath: String? = PaddockBuild.runningExecutable) {
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
        self.needsTrust = needsTrust
        self.hasReplacedRootsToClean = hasReplacedRootsToClean
        self.services = services
        self.notices = notices
        self.xdebug = xdebug
        self.xdebugAvailable = xdebugAvailable
        self.dumpsTo = dumpsTo
        self.lan = lan
        self.version = version
        self.executablePath = executablePath
    }

    private enum CodingKeys: String, CodingKey {
        case running, blockedBy, sites, installedPHP, defaultPHP, processes, resolverInstalled, trustEnabled
        case dnsRunning, portHelperInstalled, needsTrust, hasReplacedRootsToClean, version, executablePath
        case services, notices, xdebug, xdebugAvailable, dumpsTo, lan
    }

    /// Tolerates a reply from another build: anything missing gets a safe default (not running, nothing
    /// installed, version 0), so a newer client can still read an older daemon and see it is outdated.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        blockedBy = try c.decodeIfPresent([PortHolder].self, forKey: .blockedBy) ?? []
        sites = try c.decodeIfPresent([Site].self, forKey: .sites) ?? []
        installedPHP = try c.decodeIfPresent([PHPVersion].self, forKey: .installedPHP) ?? []
        defaultPHP = try c.decodeIfPresent(PHPVersion.self, forKey: .defaultPHP)
        processes = try c.decodeIfPresent([String: String].self, forKey: .processes) ?? [:]
        resolverInstalled = try c.decodeIfPresent(Bool.self, forKey: .resolverInstalled) ?? false
        trustEnabled = try c.decodeIfPresent(Bool.self, forKey: .trustEnabled) ?? false
        dnsRunning = try c.decodeIfPresent(Bool.self, forKey: .dnsRunning) ?? false
        portHelperInstalled = try c.decodeIfPresent(Bool.self, forKey: .portHelperInstalled) ?? false
        needsTrust = try c.decodeIfPresent(Bool.self, forKey: .needsTrust) ?? false
        hasReplacedRootsToClean = try c.decodeIfPresent(Bool.self, forKey: .hasReplacedRootsToClean) ?? false
        // One service this build can't read never costs the whole status.
        services = (try? c.decodeIfPresent([Lenient<ServiceStatus>].self, forKey: .services))?
            .compactMap(\.value) ?? []
        notices = (try? c.decodeIfPresent([String].self, forKey: .notices)) ?? []
        xdebug = (try? c.decodeIfPresent([PHPVersion].self, forKey: .xdebug)) ?? []
        xdebugAvailable = (try? c.decodeIfPresent([PHPVersion].self, forKey: .xdebugAvailable)) ?? []
        dumpsTo = (try? c.decodeIfPresent(Int.self, forKey: .dumpsTo)) ?? nil
        lan = try? c.decodeIfPresent(LanStatus.self, forKey: .lan)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath)
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
    /// Paddock's Xdebug builds for the installed PHP versions.
    public let xdebug: Xdebug
    /// Makes macOS trust Caddy's local CA when a site is secured; nil leaves trust alone.
    let trust: CertificateTrust?
    /// Whether macOS trusts the current root, for `status().needsTrust`: kept for a few seconds and
    /// worked out off the request path, so `status` never waits for `security`. Nil without `trust`.
    let rootTrusted: CachedCheck?
    /// Whether a replaced root is still trusted, for `status().hasReplacedRootsToClean`; cached the same way.
    let replacedRootsTrusted: CachedCheck?
    /// Who holds the web ports (`PortCheck.holders`); tests substitute one that probes nothing.
    private let portHolders: @Sendable ([Int]) -> [PortHolder]
    /// False renders Caddy's default CA names, as homes made before Paddock named its own (tests only).
    var namesCertificateAuthority = true
    /// The file `status().resolverInstalled` reads; `/etc/resolver/<tld>` unless a test says otherwise.
    let resolverFile: URL
    /// True in a development home: the engine checks the web ports and runs `paddock-ports` on them.
    let managesPortHelper: Bool
    /// The helper the engine runs when it manages one.
    private let portHelper: URL?
    /// On the real system, whether launchd's helper is installed.
    private let portHelperInstalled: @Sendable () -> Bool
    /// Picks the LAN listener's port: the saved one when free, else the next free in the fallback range.
    private let lanPortChooser: @Sendable (Int?) -> Int?
    /// Makes the LAN names resolve; tests replace it so runs never touch mDNS.
    private let lanAdvertiser: @Sendable () -> any LANAdvertising
    /// This Mac's address on the network, as the LAN listener is reached; tests fix it.
    private let lanAddress: @Sendable () -> String?

    private let supervisor: Supervisor
    private let dns: DNSResponder
    /// Added services (databases, mail…). They have their own supervisor: stopping the web side leaves
    /// them running; only `shutdown` stops them.
    public let services: ServiceManager
    /// Sites' own tasks (`paddock.json`), once approved. Their own supervisor too: they run whatever the web
    /// side does, and stop only in `shutdown`.
    public let tasks: SiteTaskManager
    /// Held for the whole of `start`, `stop` and `reload`, including slow waits. Never taken by `status`.
    private let operationLock = NSLock()
    /// Guards only the fields `status` reads; held for an instant, never across slow work.
    private let flagsLock = NSLock()
    private var isRunning = false
    private var blockedBy: [PortHolder] = []
    private var dnsUp = false
    private var shuttingDown = false
    /// The PHP install or service add in progress, if any; shutting down cancels it. Guarded by `flagsLock`.
    private var installInProgress: Task<Void, Error>?
    /// Why the sites' proxy routes couldn't be applied, and which sites have routes (guarded by `flagsLock`).
    /// Sites' routes as Caddy serves them now, and as they should be (`flagsLock`).
    private var appliedRoutes: [String: [String: Int]] = [:]
    private var wantedRoutes: [String: [String: Int]] = [:]
    /// The last apply that failed (or a config refused), until one succeeds (`flagsLock`).
    private var routeFailure: RouteFailure?
    private var lastLoggedRouteFailure: String?
    /// What the last written Caddyfile has (`flagsLock`).
    private var rendered: (routes: [String: [String: Int]], refusal: String?) = ([:], nil)
    /// Whether a routes apply is queued (`flagsLock`).
    private var routesApplyQueued = false
    /// The web stack's very large logs, as the last `checkLogSizes` found them (`flagsLock`).
    private var logNotices: [String] = []
    private var logCheckTimer: DispatchSourceTimer?
    /// Applies sites' routes one at a time, off every lock but the engine's own.
    let routesQueue = DispatchQueue(label: "app.paddock.routes")
    /// Multiplies the backoff between retries of a failing apply (tests shorten it).
    private let routeRetryScale: TimeInterval
    private var testing = RouteTesting()

    private struct RouteFailure {
        var reason: String
        /// The routes it tried to apply.
        var wanted: [String: [String: Int]]
        var attempts: Int
        var at: Date
        var retryAt: Date
    }

    /// Test-only knobs, behind `flagsLock` like everything the routes queue reads.
    private struct RouteTesting {
        var reloads = 0
        var failReloads: String?
        var validationOverride: (@Sendable (String) -> String?)?
        var validationRunner: (@Sendable (String) throws -> ServiceStepRunner.Outcome)?
        var webServerDown = false
        var beforeReload: (@Sendable () -> Void)?
    }

    /// How many times the web side was reloaded for sites' routes (tests).
    var routeReloads: Int { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.reloads }
    /// Tests: make a routes reload fail with this message.
    var failRouteReloadsForTesting: String? {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.failReloads }
        set { flagsLock.lock(); testing.failReloads = newValue; flagsLock.unlock() }
    }
    /// Tests: what `caddy validate` says (nil: valid) instead of running it.
    var validationOverrideForTesting: (@Sendable (String) -> String?)? {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.validationOverride }
        set { flagsLock.lock(); testing.validationOverride = newValue; flagsLock.unlock() }
    }
    /// Tests: runs `caddy validate` (given the config file's path) instead of the bundled caddy.
    var validationRunnerForTesting: (@Sendable (String) throws -> ServiceStepRunner.Outcome)? {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.validationRunner }
        set { flagsLock.lock(); testing.validationRunner = newValue; flagsLock.unlock() }
    }
    /// Tests: the web server counts as down for an apply.
    var webServerDownForTesting: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.webServerDown }
        set { flagsLock.lock(); testing.webServerDown = newValue; flagsLock.unlock() }
    }
    /// Tests: called in an apply right before it reloads.
    var beforeRoutesReloadForTesting: (@Sendable () -> Void)? {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return testing.beforeReload }
        set { flagsLock.lock(); testing.beforeReload = newValue; flagsLock.unlock() }
    }
    static let validationTimeout: TimeInterval = 15
    /// Only touched while holding `operationLock`.
    private var fpmVersions: Set<PHPVersion> = []
    /// The port the LAN listener holds, when it does. `lanLock`, so the supervisor's exit report can read it.
    private var runningLANPort: Int?
    /// Announces the shared sites' names over mDNS while the LAN listener runs. `lanLock`.
    private var lanPublisher: LANPublisher?
    /// Guards the LAN listener's fields: the supervisor reports its exit on another thread.
    private let lanLock = NSLock()
    /// Set when the LAN listener exits on its own, so `start` knows to bring it back. `flagsLock`.
    private var lanStopped = false
    /// Versions whose build update failed in this daemon: not tried (or logged) again. `operationLock`.
    private var failedBuildUpdates: Set<PHPVersion> = []
    /// Whether this engine has cleared stale install staging folders. `operationLock`.
    private var sweptStaleStaging = false
    /// Replaces the real download in `installPHP` requests; tests use it to make installs slow.
    let installAction: (@Sendable (PHPVersion) async throws -> Void)?
    /// Serializes requests that change state, so each one's update and reload finish before the next.
    let mutations = AsyncMutex()
    /// One line for the daemon log (stderr under the daemon). Tests capture it.
    let log: @Sendable (String) -> Void

    private static let caddyName = "caddy"
    private static let portHelperName = "ports"
    private static let lanName = "lan"
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
         portHolders: @escaping @Sendable ([Int]) -> [PortHolder] = { PortCheck.holders(of: $0) },
         lanPortChooser: @escaping @Sendable (Int?) -> Int? = { LANPort.choose(saved: $0) },
         lanAdvertiser: @escaping @Sendable () -> any LANAdvertising = { MDNSAdvertiser() },
         lanAddress: @escaping @Sendable () -> String? = { LANAddress.primaryIPv4() },
         phpEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         serviceSetup: ServiceSetup = .from(environment: ProcessInfo.processInfo.environment),
         taskEnvironment: (@Sendable () -> ShellEnvironment)? = nil,
         taskShutdownGrace: TimeInterval = SiteTaskManager.shutdownGraceCap,
         log: @escaping @Sendable (String) -> Void = { fputs("paddockd: \($0)\n", stderr) }) {
        self.installAction = installAction
        routeRetryScale = backoffScale
        self.managesPortHelper = managesPortHelper
        self.portHelper = portHelper
        self.portHelperInstalled = portHelperInstalled
        self.portHolders = portHolders
        self.lanPortChooser = lanPortChooser
        self.lanAdvertiser = lanAdvertiser
        self.lanAddress = lanAddress
        self.log = log
        self.trust = trust
        // Assumed trusted until checked: nobody is asked to trust anything on a guess.
        rootTrusted = trust.map { trust in CachedCheck(initial: true) { trust.isTrusted() } }
        replacedRootsTrusted = trust.map { trust in CachedCheck(initial: false) { trust.hasTrustedReplacedRoots() } }
        self.resolverFile = resolverFile ?? Resolver.defaultFile(settings: settings)
        supervisor = Supervisor(backoffScale: backoffScale)
        self.paths = paths
        self.settings = settings
        store = StateStore(paths: paths)
        let manifest = (try? PHPManifest.bundled()) ?? PHPManifest(builds: [])
        installer = PHPInstaller(paths: paths, manifest: manifest, environment: phpEnvironment)
        xdebug = Xdebug(paths: paths, manifest: manifest, downloader: ArtifactDownloader(environment: phpEnvironment))
        dns = DNSResponder(port: settings.dnsPort, tld: settings.tld)
        services = ServiceManager(
            paths: paths, catalog: serviceSetup.catalog, store: store, supervisor: Supervisor(backoffScale: backoffScale),
            downloader: ArtifactDownloader(session: serviceSetup.session, environment: phpEnvironment),
            portCheck: serviceSetup.portCheck,
            phpBinary: { [store, installer] in store.load().defaultPHP.map(installer.phpBinary) },
            portBase: serviceSetup.portBase, readyTimeout: serviceSetup.readyTimeout, environment: phpEnvironment, log: log)
        tasks = SiteTaskManager(
            paths: paths, store: store, supervisor: Supervisor(backoffScale: backoffScale),
            environment: taskEnvironment ?? { ShellEnvironment.forDaemon(environment: ProcessInfo.processInfo.environment) },
            sites: { [store, installer, settings] in
                let state = store.load()
                let php = state.defaultPHP ?? installer.installed().max() ?? PHPVersion(major: 8, minor: 1)
                return SiteRegistry(state: state, defaultPHP: php, settings: settings).sites()
            },
            shutdownGrace: taskShutdownGrace, timeScale: backoffScale,
            supervisedPids: { [supervisor, services] in supervisor.runningPids.union(services.supervisor.runningPids) },
            reservedPorts: { [settings] in [settings.httpPort, settings.httpsPort, settings.dnsPort] },
            log: log)
        tasks.routesMayHaveChanged = { [weak self] wanted in self?.routesMayHaveChanged(wanted) }
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
            // Caddy, the helper or the LAN listener crashed and was given up on: tear down what is
            // left and start afresh.
            guard caddyCrashed || helperCrashed || lanStoppedUnexpectedly else { return }
            stopLocked()
        }

        if let path = paths.tooLongSocket { throw EngineError.socketPathTooLong(path: path) }
        try paths.ensureDirectories()
        do { try installShims() } catch {
            log("could not install the php and composer commands: \(error.localizedDescription)")
        }
        if !sweptStaleStaging {
            // A daemon killed mid-install or mid-update leaves its staging folder; nothing installs yet.
            installer.removeStaleStaging()
            sweptStaleStaging = true
        }
        let state = try prepareState(updatingBuilds: true)
        replaceDefaultNamedAuthority()
        let chosenState = chooseLANPort(state)

        var helper: URL?
        if managesPortHelper {
            let holders = portHolders(webPorts)
            setFlags(blockedBy: holders)
            guard holders.isEmpty else { return }
            guard let portHelper else { throw EngineError.portHelperMissing }
            helper = portHelper
        } else {
            setFlags(blockedBy: [])
        }

        do {
            try writeConfigs(chosenState)
            for v in versionsInUse(chosenState).sorted() { try startFPM(v) }
            try startCaddy()
            try waitUntilReady()
            if let helper {
                try startPortHelper(helper)
                // Someone took a port between the check and the helper's bind: that is the blocked case.
                guard try waitForPortHelper() else { return }
            }
            startLANListener(chosenState)
            setFlags(running: true)
            commitRoutes()
        } catch {
            stopLocked()
            throw error
        }
        refreshTrustChecks()
    }

    /// Where Caddy keeps the local CA, and the certificates it issued, under `storage file_system`.
    private var authorityDirectory: URL { paths.caddyData.appendingPathComponent("pki/authorities/local") }
    private var issuedCertificatesDirectory: URL { paths.caddyData.appendingPathComponent("certificates/local") }
    private var rootCertificate: URL { authorityDirectory.appendingPathComponent("root.crt") }

    /// Caddy keeps using the root in its storage whatever the Caddyfile names, so a root made under
    /// Caddy's default names (before Paddock named its own) is replaced: it is moved aside to a
    /// replaced-root file (whose trust the owner's next `paddock trust` removes), then the CA and the
    /// certificates it issued are deleted so Caddy makes new ones. Runs no `security` command, so start
    /// never waits on a dialog. Only paths inside Paddock's Caddy storage are touched. Call while Caddy is
    /// not running.
    private func replaceDefaultNamedAuthority() {
        guard namesCertificateAuthority,
              let name = CertificateTrust.commonName(ofCertificateAt: rootCertificate),
              !name.hasPrefix(Caddyfile.authorityName) else { return }
        let kept: URL
        do { kept = try CertificateTrust.keepReplacedRoot(rootCertificate, paths: paths) } catch {
            // Without the old root kept, its trust could never be removed: leave the CA as it is.
            log("could not set aside the old certificate authority's root: \(error.localizedDescription)")
            return
        }
        for directory in [authorityDirectory, issuedCertificatesDirectory] {
            try? FileManager.default.removeItem(at: directory)
        }
        log("the certificate authority was renamed to \(Caddyfile.authorityName); the old certificate was "
            + "kept at \(kept.path) until you approve the change with paddock trust")
    }

    /// Works out now whether macOS trusts the current root, when that matters (trust on, a secured site,
    /// a root on disk), and whether a replaced root is still trusted. Only from paths that may wait:
    /// `start` and the trust attempts of `secure` and `trust`.
    func refreshTrustChecks() {
        if let replacedRootsTrusted, trust?.replacedRoots().isEmpty == false { replacedRootsTrusted.refresh() }
        guard let rootTrusted, FileManager.default.fileExists(atPath: rootCertificate.path),
              !store.load().secured.isEmpty else { return }
        rootTrusted.refresh()
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

    /// Stops the web stack, the DNS responder, and every service and site task (those two side by side); for
    /// the daemon's exit.
    public func shutdown() {
        operationLock.lock()
        defer { operationLock.unlock() }
        stopLocked()
        dns.stop()
        setFlags(blockedBy: [], dnsRunning: false)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { [tasks] in tasks.stopAll() }
        services.stopAll()
        group.wait()
    }

    /// Regenerates configs; when running, also starts/stops FPM pools to match the versions in use
    /// and has Caddy load the new Caddyfile.
    public func reload() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try reloadLocked()
    }

    /// For sites' routes: reloads unless the daemon is shutting down or the web server isn't serving, both checked
    /// under the engine's lock (so it never runs after `shutdown` took over). False when it didn't reload.
    private func reloadForRoutes() throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown, flags.running, !caddyCrashed, !webServerDownForTesting else { return false }
        flagsLock.lock()
        testing.reloads += 1
        let failure = testing.failReloads
        flagsLock.unlock()
        if let failure { throw EngineError.caddyReloadFailed(output: failure) }
        try reloadLocked()
        return true
    }

    private func reloadLocked() throws {
        try paths.ensureDirectories()
        var state = try prepareState(updatingBuilds: false)
        if flags.running { state = chooseLANPort(state) }
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
        commitRoutes()
        startLANListener(state)
    }

    /// Picks (and saves) the LAN listener's port when the master switch is on: the saved one while it
    /// is free, otherwise the next free one in the fallback range. A listener that already holds the
    /// saved port keeps it: the probe can't bind a port in use, and it is in use by Paddock itself.
    private func chooseLANPort(_ state: State) -> State {
        guard state.lanEnabled else { return state }
        lanLock.lock()
        let holding = runningLANPort
        lanLock.unlock()
        if holding == state.lanPort, case .running = supervisor.status(Self.lanName) {
            return state
        }
        guard let port = lanPortChooser(state.lanPort) else {
            log("no free port for the LAN listener (tried \(LAN.defaultPort)–\(LAN.fallbackPorts.upperBound))")
            return state
        }
        guard port != state.lanPort else { return state }
        do {
            return try store.update { $0.lanPort = port }
        } catch {
            log("could not save the LAN port: \(error.localizedDescription)")
            return state
        }
    }

    /// Starts the LAN listener when the master switch is on, and stops it when it is off. Failure
    /// (no free port, `paddock-ports` missing, the bind lost a race) leaves the LAN not running;
    /// the rest of Paddock carries on.
    private func startLANListener(_ state: State) {
        guard state.lanEnabled else {
            stopLANListener()
            return
        }
        guard let port = state.lanPort else {
            log("the LAN listener has no port; turn the LAN off and on again to pick one")
            return
        }
        let hosts = lanHosts(state)
        lanLock.lock()
        if runningLANPort == port, case .running = supervisor.status(Self.lanName) {
            let publisher = lanPublisher
            lanLock.unlock()
            publisher?.update(hosts: hosts)
            return
        }
        lanLock.unlock()
        guard let portHelper else {
            log("the LAN listener needs paddock-ports next to paddockd")
            return
        }
        stopLANListener()
        var spec = ProcessSpec(
            name: Self.lanName, executable: portHelper,
            arguments: ["lan", "\(port)", paths.lanSocket.path], logFile: lanLog)
        // Not restarted on its own: a taken port would only be retried on the next start or change.
        spec.exitDecision = { _ in .stop }
        spec.didExit = { [weak self] code, _ in self?.lanListenerExited(code: code) }
        do {
            try supervisor.start(spec)
        } catch {
            log("could not start the LAN listener on port \(port): \(error.localizedDescription)")
            return
        }
        let publisher = LANPublisher(advertiser: lanAdvertiser(), address: lanAddress)
        lanLock.lock()
        runningLANPort = port
        lanPublisher = publisher
        lanLock.unlock()
        guard waitForLANListener(port: port) else {
            log("the LAN listener did not answer on port \(port); see \(lanLog.path)")
            stopLANListener()
            return
        }
        publisher.start(hosts: hosts)
    }

    /// The names other devices use for the sites the owner shares; empty when no site is shared.
    private func lanHosts(_ state: State) -> [String] {
        guard let defaultPHP = state.defaultPHP else { return [] }
        return SiteRegistry(state: state, defaultPHP: defaultPHP, settings: settings).sites()
            .filter(\.lan).map { LAN.host(for: $0.name) }
    }

    private func stopLANListener() {
        lanLock.lock()
        let publisher = lanPublisher
        runningLANPort = nil
        lanPublisher = nil
        lanLock.unlock()
        supervisor.stop(Self.lanName)
        publisher?.stop()
        setLANStopped(false)
    }

    /// The LAN listener exited without being asked: stop announcing names at a dead port, and let
    /// `start` bring it back. Ignored when a newer listener already replaced it.
    private func lanListenerExited(code: Int32) {
        lanLock.lock()
        if case .running = supervisor.status(Self.lanName) {
            lanLock.unlock()
            return
        }
        let publisher = lanPublisher
        lanPublisher = nil
        runningLANPort = nil
        lanLock.unlock()
        publisher?.stop()
        flagsLock.lock()
        let shuttingDown = self.shuttingDown
        if !shuttingDown { lanStopped = true }
        flagsLock.unlock()
        if !shuttingDown {
            log("the LAN listener stopped unexpectedly (exit \(code)); run paddock start")
        }
    }

    private var lanStoppedUnexpectedly: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return lanStopped
    }

    private func setLANStopped(_ value: Bool) {
        flagsLock.lock()
        lanStopped = value
        flagsLock.unlock()
    }

    private func waitForLANListener(port: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while !PortCheck.accepts(port: port) {
            guard case .running = supervisor.status(Self.lanName), Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    private var lanLog: URL { paths.log.appendingPathComponent("lan.log") }

    /// Answers promptly even while `start`, `reload` or a PHP install is in progress: it takes only
    /// short-lived locks, never `operationLock`. `running` is false while Caddy (or, in a development
    /// home, the port helper) is crashed.
    public func status() -> EngineStatus {
        let current = flags
        let state = store.load()
        let taskStatuses = tasks.statuses()
        let sites = (state.defaultPHP.map {
            SiteRegistry(state: state, defaultPHP: $0, settings: settings).sites()
        } ?? []).map { site in
            var site = site
            // Routes show only as Caddy serves them; ones that couldn't be applied are noted instead.
            let (routes, problem) = routesStatus(site: site.name)
            site.tasks = taskStatuses[site.name].map { tasks in
                SiteTasksStatus(approval: tasks.approval, tasks: tasks.tasks, pending: tasks.pending,
                                pendingHash: tasks.pendingHash,
                                notice: [tasks.notice, problem].compactMap { $0 }.joined(separator: " ").nonEmpty,
                                routes: routes, folder: tasks.folder)
            }
            if site.tasks == nil { site.notice = problem }
            return site
        }
        var processes = services.processes
        for name in supervisor.names { processes[name] = supervisor.status(name).description }
        let installed = installer.installed()
        var lanUp = false
        if case .running = supervisor.status(Self.lanName) { lanUp = true }
        return EngineStatus(running: current.running && !caddyCrashed && !helperCrashed,
                            blockedBy: current.blockedBy,
                            sites: sites,
                            installedPHP: installed, defaultPHP: state.defaultPHP,
                            processes: processes,
                            resolverInstalled: (try? String(contentsOf: resolverFile, encoding: .utf8))
                                == Resolver.desiredContents(settings: settings),
                            trustEnabled: trust != nil, dnsRunning: current.dnsRunning,
                            portHelperInstalled: managesPortHelper || portHelperInstalled(),
                            needsTrust: needsTrust(sites: sites),
                            hasReplacedRootsToClean: hasReplacedRootsToClean,
                            services: services.statuses(), notices: currentLogNotices,
                            xdebug: installed.filter(state.xdebug.contains),
                            xdebugAvailable: xdebug.available(among: installed), dumpsTo: state.dumpsTo,
                            lan: LanStatus(enabled: state.lanEnabled, running: lanUp && current.running,
                                           port: state.lanPort ?? LAN.defaultPort,
                                           address: state.lanEnabled ? lanAddress() : nil))
    }

    private var currentLogNotices: [String] {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return logNotices
    }

    /// A replaced root on disk that macOS (as last checked) still trusts. Never waits.
    private var hasReplacedRootsToClean: Bool {
        guard let trust, let replacedRootsTrusted, !trust.replacedRoots().isEmpty else { return false }
        return replacedRootsTrusted.value
    }

    /// A secured site, a root on disk, and macOS (as last checked) not trusting it. Never waits.
    private func needsTrust(sites: [Site]) -> Bool {
        guard let rootTrusted, sites.contains(where: \.secured),
              FileManager.default.fileExists(atPath: rootCertificate.path) else { return false }
        return !rootTrusted.value
    }

    // MARK: - State and configs

    /// Installs the bundled PHP if none is installed; with `updatingBuilds` (on start only) brings
    /// installed builds up to the app's own before any PHP-FPM starts, so the pools run the new binaries,
    /// trying a version that failed only once per daemon. Makes sure the default PHP is installed, and
    /// creates the first parked directory if it can (it may be on a volume that isn't mounted).
    private func prepareState(updatingBuilds: Bool) throws -> State {
        var installed = installer.installed()
        if installed.isEmpty {
            try installer.installBundled()
            installed = installer.installed()
        }
        if updatingBuilds {
            failedBuildUpdates.formUnion(installer.updateOutdatedBuilds(skipping: failedBuildUpdates, log: log))
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
        let proxies = TaskApproval.routes(state: state, sites: sites, reservedPorts: reservedPorts)
        let lan = state.lanEnabled ? Caddyfile.LANSharing(
            sites: sites.filter(\.lan).map(\.name), port: state.lanPort ?? LAN.defaultPort) : nil
        var text = Caddyfile.render(sites: sites, defaultPHP: defaultPHP, paths: paths, settings: settings,
                                    namesAuthority: namesCertificateAuthority, proxies: proxies, dumpsTo: state.dumpsTo,
                                    lan: lan)
        // Sites' proxy routes are checked before they are used: a config Caddy would refuse (or that can't be
        // checked) never replaces the one it serves; the sites are served without any routes, and say why.
        var refusal: String?
        if !proxies.isEmpty, let problem = validationProblem(text) {
            refusal = problem
            text = Caddyfile.render(sites: sites, defaultPHP: defaultPHP, paths: paths, settings: settings,
                                    namesAuthority: namesCertificateAuthority, dumpsTo: state.dumpsTo, lan: lan)
        }
        flagsLock.lock()
        rendered = (refusal == nil ? proxies : [:], refusal)
        wantedRoutes = proxies
        flagsLock.unlock()
        try Data(text.utf8).write(to: paths.caddyfile, options: .atomic)
    }

    /// The config just written is now what Caddy serves: its routes are in effect. A config written without its
    /// routes (refused by caddy validate) counts as a failed apply.
    private func commitRoutes() {
        flagsLock.lock()
        appliedRoutes = rendered.routes
        let refusal = rendered.refusal
        let wanted = wantedRoutes
        flagsLock.unlock()
        if let refusal { recordRouteFailure(refusal, wanted: wanted) } else { routesApplied() }
    }

    /// Ports of Paddock's own (its web ports and the DNS responder's): never a proxy route's target.
    var reservedPorts: Set<Int> { [settings.httpPort, settings.httpsPort, settings.dnsPort] }

    /// What `caddy validate` says about a config it refuses (nil when it accepts it, or can't be run).
    private func validationProblem(_ text: String) -> String? {
        if let override = validationOverrideForTesting { return override(text) }
        let file = paths.config.appendingPathComponent("Caddyfile.check")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? Data(text.utf8).write(to: file, options: .atomic)) != nil else {
            return "Paddock couldn't write the configuration to check it"
        }
        let outcome: ServiceStepRunner.Outcome
        do {
            if let runner = validationRunnerForTesting { outcome = try runner(file.path) } else {
                outcome = try ServiceStepRunner.run(
                    executable: caddyBinary.path, arguments: ["validate", "--config", file.path, "--adapter", "caddyfile"],
                    environment: ProcessInfo.processInfo.environment.merging(caddyEnvironment) { $1 }, directory: paths.home,
                    stdin: nil, timeout: Self.validationTimeout, isCancelled: { false })
            }
        } catch {
            return "Paddock couldn't run caddy validate"
        }
        switch outcome.end {
        case .exited(0): return nil
        case .timedOut: return "caddy validate took longer than \(Int(Self.validationTimeout)) seconds"
        case .cancelled: return "caddy validate was cancelled"
        case .exited: break
        }
        let lines = outcome.output.split(separator: "\n").map(String.init)
        return Messages.printable(lines.last { $0.contains("Error") } ?? lines.last ?? "", limit: 200) ?? "Caddy refused it"
    }

    // MARK: - Processes

    private static func fpmName(_ v: PHPVersion) -> String { "php-fpm-\(v)" }

    /// The logs PHP-FPM writes itself (`FPMConfig`): its error log and the pool's PHP errors.
    private func fpmOwnLogs(_ v: PHPVersion) -> [URL] {
        [paths.log.appendingPathComponent("php-fpm-\(v).log"), paths.log.appendingPathComponent("php-\(v).log")]
    }

    /// Every web-stack process's logs: its output and the files it writes itself.
    private func webStackLogs() -> [(process: String, log: URL)] {
        var logs = [(Self.caddyName, caddyLog), (Self.portHelperName, portHelperLog), (Self.lanName, lanLog)]
        for v in fpmVersions.sorted() {
            logs.append((Self.fpmName(v), paths.log.appendingPathComponent("\(Self.fpmName(v)).out.log")))
            logs += fpmOwnLogs(v).map { (Self.fpmName(v), $0) }
        }
        return logs
    }

    /// How often `checkLogSizes` runs in the daemon.
    public static let logCheckInterval: TimeInterval = 3600

    /// Notes every log a running process holds that has grown very large (services on the service; the web stack
    /// in the status), and forgets the notes of those that no longer are. Never cuts or renames a held file.
    public func checkLogSizes() {
        services.checkLogSizes()
        let notices = webStackLogs().compactMap { process, log -> String? in
            guard case .running = supervisor.status(process) else { return nil }
            return LogFiles.veryLargeNotice(log)
        }
        flagsLock.lock()
        logNotices = notices
        flagsLock.unlock()
    }

    /// Runs `checkLogSizes` every `logCheckInterval` for as long as the daemon runs.
    public func startLogSizeChecks() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.logCheckInterval, repeating: Self.logCheckInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.checkLogSizes() }
        timer.resume()
        flagsLock.lock()
        logCheckTimer = timer
        flagsLock.unlock()
    }

    private func isFPMRunning(_ v: PHPVersion) -> Bool {
        if case .running = supervisor.status(Self.fpmName(v)) { return true }
        return false
    }

    private func startFPM(_ v: PHPVersion) throws {
        let conf = try FPMConfig.write(version: v, paths: paths)
        // PHP-FPM's own logs, opened by it: set aside before it starts when large.
        for log in fpmOwnLogs(v) { LogFiles.setAsideIfLarge(log) }
        try? FileManager.default.removeItem(at: paths.fpmSocket(v))
        try supervisor.start(ProcessSpec(
            name: Self.fpmName(v), executable: installer.fpmBinary(v),
            arguments: ["-y", conf.path, "-c", paths.phpIni(v).path, "-F"]
                + Xdebug.arguments(for: v, state: store.load(), paths: paths),
            logFile: paths.log.appendingPathComponent("\(Self.fpmName(v)).out.log")))
        fpmVersions.insert(v)
    }

    /// Stops and starts one version's PHP-FPM, so it runs with its current command line (Xdebug on or off), and
    /// waits until it serves again. Nothing to do when Paddock isn't running or no site uses the version.
    func restartFPM(_ v: PHPVersion) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard flags.running, fpmVersions.contains(v) else { return }
        supervisor.stop(Self.fpmName(v))
        fpmVersions.remove(v)
        try startFPM(v)
        try waitUntilReady()
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
                let holders = portHolders(webPorts)
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
        // Nothing is served, so nothing is in effect, and no failure to apply is owed a notice.
        flagsLock.lock()
        appliedRoutes = [:]
        routeFailure = nil
        lastLoggedRouteFailure = nil
        flagsLock.unlock()
        supervisor.stopAll()
        fpmVersions = []
        stopLANListener()
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

    /// The routes that should be in effect now: served sites' intact approvals for their very folders.
    func desiredRoutes() -> [String: [String: Int]] {
        let state = store.load()
        guard let defaultPHP = state.defaultPHP else { return [:] }
        let sites = SiteRegistry(state: state, defaultPHP: defaultPHP, settings: settings).sites()
        return TaskApproval.routes(state: state, sites: sites, reservedPorts: reservedPorts)
    }

    /// Told after every refresh of the sites' tasks (never from a read-only request), with the routes the manager
    /// worked out: if they differ from those Caddy serves, an apply is queued, once for a burst, on `routesQueue`.
    /// After a failed apply, only when the routes wanted change or its backoff has passed. Only compares here:
    /// it is called under the manager's lock.
    func routesMayHaveChanged(_ wanted: [String: [String: Int]]) {
        flagsLock.lock()
        wantedRoutes = wanted
        let backingOff = routeFailure.map { $0.wanted == wanted && Date() < $0.retryAt } ?? false
        let needed = wanted != appliedRoutes && !backingOff && !routesApplyQueued && !shuttingDown && isRunning
        if needed { routesApplyQueued = true }
        flagsLock.unlock()
        guard needed else { return }
        routesQueue.async { [weak self] in
            guard let self else { return }
            self.flagsLock.lock()
            self.routesApplyQueued = false
            self.flagsLock.unlock()
            self.applyRoutesIfChanged(forced: false)
        }
    }

    /// Applies the routes that should be in effect (read afresh) if they differ from those served: regenerate and
    /// reload. On `routesQueue`. Unless `forced` (approving or withdrawing: retry now, but not twice for one
    /// request, `since`), a failed apply waits for its backoff or for the routes wanted to change. With the web
    /// server down it doesn't count as a failure: `start` writes and serves the routes when it is back.
    func applyRoutesIfChanged(forced: Bool, since: Date = .distantPast) {
        guard !isShuttingDown else { return }
        let desired = desiredRoutes()
        flagsLock.lock()
        wantedRoutes = desired
        let failure = routeFailure
        let upToDate = desired == appliedRoutes && failure == nil
        let down = !isRunning || testing.webServerDown
        let hook = testing.beforeReload
        flagsLock.unlock()
        if upToDate || down || caddyCrashed { return }
        if let failure, failure.wanted == desired {
            if forced ? failure.at >= since : Date() < failure.retryAt { return }
        }
        hook?()
        do {
            _ = try reloadForRoutes()
        } catch {
            let reason: String
            if case EngineError.caddyReloadFailed(let output) = error { reason = output } else { reason = "\(error)" }
            recordRouteFailure(Messages.printable(reason, limit: 200) ?? "the web server refused it", wanted: desired)
        }
    }

    /// A failed apply: retried when the routes wanted change, or after 30 s, 1 min, 2 min… up to 10 min. Logged
    /// once per reason.
    private func recordRouteFailure(_ reason: String, wanted: [String: [String: Int]]) {
        let now = Date()
        flagsLock.lock()
        let attempts = routeFailure.map { $0.wanted == wanted ? $0.attempts + 1 : 1 } ?? 1
        let delay = min(30 * pow(2, Double(attempts - 1)), 600) * routeRetryScale
        routeFailure = RouteFailure(reason: reason, wanted: wanted, attempts: attempts, at: now,
                                    retryAt: now.addingTimeInterval(delay))
        let logIt = lastLoggedRouteFailure != reason
        lastLoggedRouteFailure = reason
        flagsLock.unlock()
        if logIt { log("could not apply sites' forwarding: \(reason)") }
    }

    /// The routes wanted are served: any failure is over (logged once, when it clears).
    private func routesApplied() {
        flagsLock.lock()
        let cleared = routeFailure != nil
        routeFailure = nil
        lastLoggedRouteFailure = nil
        flagsLock.unlock()
        if cleared { log("sites' forwarding applied again") }
    }

    /// A site's routes and notice as clients see them: served routes that are what the site should have are in
    /// effect; a site whose routes differ while an apply has failed is noted (forwarding still active for a site
    /// that should have none, or not applied).
    func routesStatus(site: String) -> (routes: [String: Int], notice: String?) {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        let applied = appliedRoutes[site] ?? [:]
        let wanted = wantedRoutes[site] ?? [:]
        if applied == wanted { return (applied, nil) }
        guard let routeFailure else { return (wanted.isEmpty ? applied : [:], nil) }
        if wanted.isEmpty { return (applied, Messages.forwardingStillActive(routeFailure.reason)) }
        return ([:], Messages.proxyRoutesNotApplied(routeFailure.reason))
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
        services.cancelPendingWork()
        tasks.beginShutdown()
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

extension String {
    /// Nil for an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}
