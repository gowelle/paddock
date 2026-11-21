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
}

public enum EngineError: Error, Equatable {
    /// A process did not become ready in time, or exited while starting. `log` is its log file.
    case notReady(process: String, log: String)
    case caddyReloadFailed(output: String)
}

/// Runs the web stack: one PHP-FPM per PHP version in use, Caddy in front, and the DNS responder.
public final class Engine: @unchecked Sendable {
    public let paths: Paths
    public let settings: Settings
    public let store: StateStore
    public let installer: PHPInstaller

    private let supervisor = Supervisor()
    private let dns: DNSResponder
    private let lock = NSLock()
    private var isRunning = false
    private var blockedBy: [PortHolder] = []
    private var fpmVersions: Set<PHPVersion> = []

    private static let caddyName = "caddy"
    private static let readyTimeout: TimeInterval = 15

    public init(paths: Paths = .current, settings: Settings = .current) {
        self.paths = paths
        self.settings = settings
        store = StateStore(paths: paths)
        installer = PHPInstaller(paths: paths, manifest: (try? PHPManifest.bundled()) ?? PHPManifest(builds: []))
        dns = DNSResponder(port: settings.dnsPort, tld: settings.tld)
    }

    deinit { stop() }

    /// Starts everything, unless the HTTP/HTTPS ports are held, in which case it starts nothing
    /// and reports the holders in `status().blockedBy`. Returns once Caddy accepts connections.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        try paths.ensureDirectories()
        let state = try prepareState()

        blockedBy = PortCheck.holders(of: [settings.httpPort, settings.httpsPort])
        guard blockedBy.isEmpty else { return }

        do {
            try writeConfigs(state)
            for v in versionsInUse(state).sorted() { try startFPM(v) }
            try startCaddy()
            try waitUntilReady()
            try dns.start()
            isRunning = true
        } catch {
            stopLocked()
            throw error
        }
    }

    /// Stops Caddy, every PHP-FPM (with its workers) and the DNS responder.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        blockedBy = []
    }

    /// Regenerates configs; when running, also starts/stops FPM pools to match the versions in use
    /// and has Caddy load the new Caddyfile.
    public func reload() throws {
        lock.lock()
        defer { lock.unlock() }
        try paths.ensureDirectories()
        let state = try prepareState()
        try writeConfigs(state)
        guard isRunning else { return }

        let wanted = versionsInUse(state)
        for v in fpmVersions.subtracting(wanted) {
            supervisor.stop(Self.fpmName(v))
            fpmVersions.remove(v)
        }
        for v in wanted.sorted() where !isFPMRunning(v) { try startFPM(v) }
        try waitUntilReady()
        try reloadCaddy()
    }

    public func status() -> EngineStatus {
        lock.lock()
        defer { lock.unlock() }
        let state = store.load()
        let sites = state.defaultPHP.map {
            SiteRegistry(state: state, defaultPHP: $0, settings: settings).sites()
        } ?? []
        var processes: [String: String] = [:]
        for name in supervisor.names { processes[name] = supervisor.status(name).description }
        return EngineStatus(running: isRunning, blockedBy: blockedBy, sites: sites,
                            installedPHP: installer.installed(), defaultPHP: state.defaultPHP,
                            processes: processes,
                            resolverInstalled: false) // Task 13: check /etc/resolver/<tld>.
    }

    // MARK: - State and configs

    /// Installs the bundled PHP if none is installed, makes sure the default PHP is installed,
    /// and creates the first parked directory.
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
            try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
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
        try? FileManager.default.removeItem(at: paths.caddyAdminSocket)
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

    /// Waits until every FPM socket exists and Caddy accepts TCP connections on the HTTP port.
    private func waitUntilReady() throws {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        var pending: [(name: String, log: URL, ready: () -> Bool)] = fpmVersions.sorted().map { v in
            (Self.fpmName(v), paths.log.appendingPathComponent("php-fpm-\(v).log"),
             { [paths] in FileManager.default.fileExists(atPath: paths.fpmSocket(v).path) })
        }
        if supervisor.names.contains(Self.caddyName) {
            pending.append((Self.caddyName, caddyLog, { [settings] in Self.accepts(port: settings.httpPort) }))
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

    private static func accepts(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func stopLocked() {
        supervisor.stopAll()
        dns.stop()
        fpmVersions = []
        isRunning = false
    }
}
