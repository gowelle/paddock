import Darwin
import XCTest
import PaddockTestSupport
@testable import PaddockCore

/// Shared helpers for integration tests that start real Caddy and PHP-FPM on high ports.
enum TestSupport {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static let repoVendor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor", isDirectory: true)

    static func token() -> String {
        String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    static func requireVendored() throws {
        for binary in ["caddy", "php/8.5/default/php-fpm"] {
            guard FileManager.default.isExecutableFile(
                atPath: Bundled.resources.appendingPathComponent(binary).path) else {
                throw XCTSkip("Vendored \(binary) missing; run Scripts/fetch-vendor.sh")
            }
        }
    }

    // MARK: Ports

    static func socketAddress(port: Int, host: String = "127.0.0.1") -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(host))
        return addr
    }

    static func bindSocket(type: Int32, port: Int, host: String = "127.0.0.1") -> Int32? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        var addr = socketAddress(port: port, host: host)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        return fd
    }

    /// A listening TCP socket on <host>:<port> (loopback unless given); the caller closes it.
    static func listen(port: Int, host: String = "127.0.0.1") throws -> Int32 {
        guard let fd = bindSocket(type: SOCK_STREAM, port: port, host: host), Darwin.listen(fd, 4) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    static func canBindUDP(port: Int) throws -> Bool {
        guard let fd = bindSocket(type: SOCK_DGRAM, port: port) else { return false }
        close(fd)
        return true
    }

    /// A TCP port in 20000...40000, chosen afresh each time (never a fixed one, whose connections from an
    /// earlier test may still be in TIME_WAIT), that nothing accepts on and that binds without
    /// SO_REUSEADDR right now. Never one of `excluding`.
    static func freeTCPPort(excluding: Set<Int> = []) -> Int {
        while true {
            let port = Int.random(in: 20000...40000)
            guard !excluding.contains(port), !PortCheck.accepts(port: port),
                  let fd = bindSocket(type: SOCK_STREAM, port: port) else { continue }
            close(fd)
            return port
        }
    }

    /// The environment of a program run "on the real system" (no PADDOCK_HOME) whose home directory is
    /// nevertheless `scratchHome`: HOME and CFFIXED_USER_HOME (which Foundation's home directory follows)
    /// both point there, so even a bug can't reach the owner's real home. High ports only.
    static func realSystemEnvironment(scratchHome: URL, settings: Settings) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = nil
        env["HOME"] = scratchHome.path
        env["CFFIXED_USER_HOME"] = scratchHome.path
        env["PADDOCK_HTTP_PORT"] = "\(settings.httpPort)"
        env["PADDOCK_HTTPS_PORT"] = "\(settings.httpsPort)"
        env["PADDOCK_DNS_PORT"] = "\(settings.dnsPort)"
        env["PADDOCK_RESOURCES"] = repoVendor.path
        return env
    }

    /// Every file and folder under `directory`, relative to it.
    static func contents(of directory: URL) -> [String] {
        (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []).sorted()
    }

    /// `PortCheck.holders` for engines under test: `lsof` still names visible listeners, but a hidden holder
    /// is never probed over HTTP and launchd is never asked.
    static let portHoldersWithoutProbes: @Sendable ([Int]) -> [PortHolder] = { ports in
        PortCheck.holders(of: ports, runner: NoCommands(), serverHeader: { _ in nil })
    }

    /// Runs nothing: every command "fails".
    private struct NoCommands: CommandRunner {
        func run(_ executable: String, _ arguments: [String],
                 environment: [String: String]?) throws -> (status: Int32, output: String) { (1, "") }
    }

    static func freeUDPPort(preferred: Int) -> Int {
        if (try? canBindUDP(port: preferred)) == true { return preferred }
        for _ in 0..<50 {
            let port = Int.random(in: 40001...50000)
            if (try? canBindUDP(port: port)) == true { return port }
        }
        return preferred
    }

    /// The `dig +short` answer for an A query of `name` against 127.0.0.1:<port>.
    static func dig(_ name: String, port: Int) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        p.arguments = ["+short", "+time=2", "+tries=1", "-p", "\(port)", "@127.0.0.1", name, "A"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Processes

    /// Pids in a process group, via pgrep.
    static func pgrep(group: Int32) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-g", "\(group)"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The built `paddock-ports` helper, in the build products directory next to the test bundle.
    static var portHelper: URL {
        Bundle(for: TestHome.self).bundleURL.deletingLastPathComponent().appendingPathComponent("paddock-ports")
    }

    /// `lsof` lines for the TCP sockets `pid` is listening on (empty when there are none).
    static func tcpListeners(pid: Int32) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pid in a `ProcessStatus` description such as "running (pid 123)".
    /// The libraries a Mach-O file links (`otool -L`, its own install name included).
    static func linkedLibraries(_ file: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        p.arguments = ["-L", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").dropFirst().compactMap { line in
            line.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility").first
        }
    }

    static func pid(from description: String) -> Int32? {
        guard let range = description.range(of: "pid ") else { return nil }
        return Int32(description[range.upperBound...].prefix { $0.isNumber })
    }
}

extension Engine {
    /// An engine for a development home, as `paddockd` runs one when PADDOCK_HOME is set: it runs the
    /// built `paddock-ports` helper itself on the test's high ports.
    static func development(paths: Paths, settings: Settings, trust: CertificateTrust? = nil,
                            installAction: (@Sendable (PHPVersion) async throws -> Void)? = nil,
                            backoffScale: TimeInterval = 1,
                            phpEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                            lanPortChooser: @escaping @Sendable (Int?) -> Int? = { LANPort.choose(saved: $0) },
                            lanAdvertiser: @escaping @Sendable () -> any LANAdvertising = {
                                RecordingLANAdvertiser()
                            },
                            lanAddress: @escaping @Sendable () -> String? = { "192.168.1.50" },
                            log: @escaping @Sendable (String) -> Void = { fputs("paddockd: \($0)\n", stderr) })
        -> Engine {
        Engine(paths: paths, settings: settings, installAction: installAction, trust: trust,
               backoffScale: backoffScale, managesPortHelper: true, portHelper: TestSupport.portHelper,
               portHolders: TestSupport.portHoldersWithoutProbes, lanPortChooser: lanPortChooser,
               lanAdvertiser: lanAdvertiser, lanAddress: lanAddress,
               phpEnvironment: phpEnvironment, log: log)
    }
}

/// A throwaway Paddock home with fixture sites and free high ports. Roots live directly under
/// /tmp because unix socket paths are limited to ~104 bytes.
final class TestHome {
    let root: URL
    let paths: Paths
    let parked: URL
    var settings = Settings()

    init(rootName: String = "pdk-\(TestSupport.token())", withFixtures: Bool = true) throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(rootName, isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        parked = root.appendingPathComponent("sites", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        if withFixtures {
            try copyFixture("plain-php")
            try copyFixture("laravel-like")
        }
        let parkedPath = parked.path
        try StateStore(paths: paths).update { $0 = State(parked: [parkedPath]) }

        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53598)
    }

    func copyFixture(_ name: String, as folder: String? = nil) throws {
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent(name),
                                         to: parked.appendingPathComponent(folder ?? name))
    }

    func makeDirectory(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
