import Darwin
import XCTest
@testable import PaddockCore

/// Starts real Caddy and PHP-FPM from Vendor/ on high ports with a throwaway PADDOCK_HOME.
final class EngineTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var parked: URL!
    private var settings = Settings()
    private var engine: Engine?

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    override func setUpWithError() throws {
        for binary in ["caddy", "php/8.5/default/php-fpm"] {
            guard FileManager.default.isExecutableFile(
                atPath: Bundled.resources.appendingPathComponent(binary).path) else {
                throw XCTSkip("Vendored \(binary) missing; run Scripts/fetch-vendor.sh")
            }
        }
        try makeHome(rootName: "pdk-\(Self.token())")
    }

    override func tearDown() {
        engine?.stop()
        engine = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Tests

    func testServesParkedPlainSite() throws {
        try startEngine()
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testServesLaravelFrontController() throws {
        try startEngine()
        let r = try get("laravel-like.test", "/users/7")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body, "laravel:/users/7")
    }

    func testServesStaticFile() throws {
        try startEngine()
        let r = try get("laravel-like.test", "/robots.txt")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body.trimmingCharacters(in: .whitespacesAndNewlines), "static-ok")
    }

    func testUnknownSiteIs404() throws {
        try startEngine()
        XCTAssertEqual(try get("nope.test", "/").status, 404)
    }

    func testNewFolderIsServedWithoutReload() throws {
        try startEngine()
        let fresh = parked.appendingPathComponent("fresh-site", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("<?php echo 'fresh:ok';".utf8).write(to: fresh.appendingPathComponent("index.php"))
        let r = try get("fresh-site.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertEqual(r.body, "fresh:ok")
    }

    func testBlockedPortsReported() throws {
        let holder = try listen(port: settings.httpPort)
        defer { close(holder) }
        let engine = Engine(paths: paths, settings: settings)
        self.engine = engine
        try engine.start()
        let status = engine.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.blockedBy.first?.port, settings.httpPort)
        XCTAssertEqual(status.blockedBy.first?.pid, getpid())
        XCTAssertTrue(status.processes.values.allSatisfy { $0 == "stopped" }, "\(status.processes)")
        XCTAssertTrue(try canBindUDP(port: settings.dnsPort), "DNS responder started while blocked")
    }

    func testServesFolderWithSpaceInName() throws {
        try copyFixture("plain-php", as: "My App")
        try startEngine()
        let r = try get("my-app.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testWorksWithSpaceInHomePath() throws {
        try FileManager.default.removeItem(at: root)
        try makeHome(rootName: "pdk \(Self.token())")
        XCTAssertTrue(paths.home.path.contains(" "))
        try startEngine()
        let r = try get("plain-php.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:8.5"), r.body)
    }

    func testStatusWhileRunning() throws {
        try startEngine()
        let status = try XCTUnwrap(engine).status()
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.blockedBy, [])
        XCTAssertEqual(status.defaultPHP, PHPVersion("8.5"))
        XCTAssertEqual(status.installedPHP, [PHPVersion("8.5")!])
        XCTAssertEqual(status.sites.map(\.name), ["laravel-like", "plain-php"])
        XCTAssertTrue(status.processes["caddy"]?.hasPrefix("running") == true, "\(status.processes)")
        XCTAssertTrue(status.processes["php-fpm-8.5"]?.hasPrefix("running") == true, "\(status.processes)")
        XCTAssertFalse(status.resolverInstalled)
        XCTAssertNoThrow(try JSONEncoder().encode(status))
    }

    func testReloadPicksUpNewFolderWithSpaceInName() throws {
        try startEngine()
        try copyFixture("plain-php", as: "Late Comer")
        try XCTUnwrap(engine).reload()
        let r = try get("late-comer.test", "/")
        XCTAssertEqual(r.status, 200, r.body)
        XCTAssertTrue(r.body.hasPrefix("plain:"), r.body)
    }

    func testStopLeavesNoProcessesAndFreesPorts() throws {
        try startEngine()
        let engine = try XCTUnwrap(self.engine)
        XCTAssertEqual(try get("plain-php.test", "/").status, 200) // spawns an FPM worker
        let groups = engine.status().processes.values.compactMap(Self.pid(from:))
        XCTAssertEqual(groups.count, 2)

        engine.stop()

        for group in groups {
            XCTAssertEqual(try pgrep(group: group), [], "process group \(group) still has members")
        }
        XCTAssertFalse(engine.status().running)
        XCTAssertEqual(PortCheck.holders(of: [settings.httpPort, settings.httpsPort]), [])
        XCTAssertTrue(try canBindUDP(port: settings.dnsPort), "DNS responder still bound")
    }

    func testCaddyWritesNothingToTheUsersCaddyDirectory() throws {
        let before = Self.userCaddySnapshot()
        // A secured site makes Caddy create its local CA and a certificate.
        try StateStore(paths: paths).update { $0.secured = ["plain-php"] }
        try startEngine()
        XCTAssertEqual(try get("laravel-like.test", "/").status, 200)
        try XCTUnwrap(engine).reload()
        engine?.stop()
        XCTAssertEqual(Self.userCaddySnapshot(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.caddyData.appendingPathComponent("pki").path),
                      "Caddy's local CA should live in the Paddock home")
    }

    // MARK: - Helpers

    private static func token() -> String {
        String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// Short root under /tmp: unix socket paths are limited to ~104 bytes.
    private func makeHome(rootName: String) throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(rootName, isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        parked = root.appendingPathComponent("sites", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        try copyFixture("plain-php")
        try copyFixture("laravel-like")
        let parkedPath = parked.path
        try StateStore(paths: paths).update { $0 = State(parked: [parkedPath]) }

        settings = Settings()
        settings.httpPort = freeTCPPort(preferred: 18080)
        settings.httpsPort = freeTCPPort(preferred: 18443)
        settings.dnsPort = freeUDPPort(preferred: 53598)
    }

    private func copyFixture(_ name: String, as folder: String? = nil) throws {
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name),
                                         to: parked.appendingPathComponent(folder ?? name))
    }

    private func startEngine() throws {
        let engine = Engine(paths: paths, settings: settings)
        self.engine = engine
        try engine.start()
        XCTAssertTrue(engine.status().running, "blocked by \(engine.status().blockedBy)")
    }

    private struct Response { let status: Int; let body: String }

    /// Plain HTTP/1.1 request to 127.0.0.1 with the given Host header, via the system curl.
    private func get(_ host: String, _ path: String) throws -> Response {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "10", "-H", "Host: \(host)",
                          "-w", "\n%{http_code}", "http://127.0.0.1:\(settings.httpPort)\(path)"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        var text = String(decoding: data, as: UTF8.self)
        let newline = try XCTUnwrap(text.lastIndex(of: "\n"), "curl output: \(text)")
        let status = Int(text[text.index(after: newline)...]) ?? -1
        text = String(text[..<newline])
        return Response(status: status, body: text)
    }

    /// Every path and modification date under ~/Library/Application Support/Caddy (empty if absent).
    private static func userCaddySnapshot() -> [String: Date] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Caddy")
        var out: [String: Date] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = e?.nextObject() as? URL {
            out[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return out
    }

    private func pgrep(group: Int32) throws -> [String] {
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

    private static func pid(from description: String) -> Int32? {
        guard let range = description.range(of: "pid ") else { return nil }
        return Int32(description[range.upperBound...].prefix { $0.isNumber })
    }

    private func socketAddress(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    private func bindSocket(type: Int32, port: Int) -> Int32? {
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

    private func listen(port: Int) throws -> Int32 {
        guard let fd = bindSocket(type: SOCK_STREAM, port: port), Darwin.listen(fd, 4) == 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    private func canBindUDP(port: Int) throws -> Bool {
        guard let fd = bindSocket(type: SOCK_DGRAM, port: port) else { return false }
        close(fd)
        return true
    }

    private func freeTCPPort(preferred: Int) -> Int {
        if PortCheck.holders(of: [preferred]).isEmpty { return preferred }
        for _ in 0..<50 {
            let port = Int.random(in: 20000...40000)
            if PortCheck.holders(of: [port]).isEmpty { return port }
        }
        return preferred
    }

    private func freeUDPPort(preferred: Int) -> Int {
        if (try? canBindUDP(port: preferred)) == true { return preferred }
        for _ in 0..<50 {
            let port = Int.random(in: 40001...50000)
            if (try? canBindUDP(port: port)) == true { return port }
        }
        return preferred
    }
}
