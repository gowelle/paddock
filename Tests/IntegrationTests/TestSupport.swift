import Darwin
import XCTest
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

    static func socketAddress(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    static func bindSocket(type: Int32, port: Int) -> Int32? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        var addr = socketAddress(port: port)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        return fd
    }

    /// A listening TCP socket on 127.0.0.1:<port>; the caller closes it.
    static func listen(port: Int) throws -> Int32 {
        guard let fd = bindSocket(type: SOCK_STREAM, port: port), Darwin.listen(fd, 4) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    static func canBindUDP(port: Int) throws -> Bool {
        guard let fd = bindSocket(type: SOCK_DGRAM, port: port) else { return false }
        close(fd)
        return true
    }

    static func freeTCPPort(preferred: Int) -> Int {
        if PortCheck.holders(of: [preferred]).isEmpty { return preferred }
        for _ in 0..<50 {
            let port = Int.random(in: 20000...40000)
            if PortCheck.holders(of: [port]).isEmpty { return port }
        }
        return preferred
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

    /// The pid in a `ProcessStatus` description such as "running (pid 123)".
    static func pid(from description: String) -> Int32? {
        guard let range = description.range(of: "pid ") else { return nil }
        return Int32(description[range.upperBound...].prefix { $0.isNumber })
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

        settings.httpPort = TestSupport.freeTCPPort(preferred: 18080)
        settings.httpsPort = TestSupport.freeTCPPort(preferred: 18443)
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
