import Darwin
import XCTest
@testable import PaddockCore

/// The bundled PHP builds against database servers this test owns. Never the real PostgreSQL: every
/// server here is a throwaway listener on a fresh free high port.
///
/// Regression: the static-php.dev "bulk" builds carried Swoole, whose hooks made
/// `new PDO("pgsql:host=127.0.0.1;…")` spin at 100% CPU forever instead of failing. Against a server
/// that closes at once those builds still fail quickly; against one that waits for the startup message,
/// as PostgreSQL does, the old 8.4 build never sends it and hangs: the ErrorResponse test catches that.
final class PHPDatabaseDriverTests: XCTestCase {
    /// Every manifest version's vendored `php`, which Scripts/fetch-vendor.sh unpacks from Vendor/builds.
    private func vendoredBuilds() throws -> [(PHPVersion, URL)] {
        try TestSupport.requireVendored()
        let manifest = try PHPManifest.bundled()
        let versions = Set(manifest.builds.map(\.version)).sorted()
        XCTAssertFalse(versions.isEmpty)
        return try versions.map { v in
            let dir = TestSupport.repoVendor.appendingPathComponent("php/\(v)/default", isDirectory: true)
            for name in ["php", "php-fpm"] {
                guard FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(name).path) else {
                    XCTFail("Vendor/php/\(v)/default/\(name) is missing; run Scripts/fetch-vendor.sh")
                    throw XCTSkip("PHP \(v) not vendored")
                }
            }
            // A stale Vendor/php (unpacked from other archives than the manifest names) must not pass.
            let recordFile = dir.appendingPathComponent(PHPBuildRecord.fileName)
            let record = try? JSONDecoder().decode(PHPBuildRecord.self, from: Data(contentsOf: recordFile))
            let build = try XCTUnwrap(manifest.build(for: v))
            XCTAssertEqual(record, PHPBuildRecord(build),
                           "Vendor/php/\(v)/default is not the manifest's build; run Scripts/fetch-vendor.sh")
            return (v, dir)
        }
    }

    // MARK: - PostgreSQL over TCP

    func testPDOPostgresOverTCPDoesNotHang() throws {
        let server = try ThrowawayServer(behaviour: .closeImmediately)
        defer { server.stop() }
        for (v, dir) in try vendoredBuilds() {
            let result = try connect(php: dir.appendingPathComponent("php"), port: server.port)
            XCTAssertFalse(result.killed, "PHP \(v): PDO pgsql connect hung until killed")
            XCTAssertLessThan(result.elapsed, 5, "PHP \(v) took \(result.elapsed)s")
            XCTAssertTrue(result.output.hasPrefix("PDOException:"), "PHP \(v): \(result.output)")
        }
    }

    func testPDOPostgresErrorResponseIsAnOrdinaryPDOException() throws {
        let server = try ThrowawayServer(behaviour: .postgresAuthenticationFailure)
        defer { server.stop() }
        for (v, dir) in try vendoredBuilds() {
            let result = try connect(php: dir.appendingPathComponent("php"), port: server.port)
            XCTAssertFalse(result.killed, "PHP \(v): PDO pgsql connect hung until killed")
            XCTAssertLessThan(result.elapsed, 5, "PHP \(v) took \(result.elapsed)s")
            XCTAssertTrue(result.output.hasPrefix("PDOException:"), "PHP \(v): \(result.output)")
            XCTAssertTrue(result.output.contains("password authentication failed for user \"u\""),
                          "PHP \(v): \(result.output)")
        }
    }

    // MARK: - Extensions

    func testNoSwooleInAnyBundledBuild() throws {
        for (v, dir) in try vendoredBuilds() {
            for name in ["php", "php-fpm"] {
                let modules = try self.modules(dir.appendingPathComponent(name))
                for forbidden in ["swoole", "openswoole", "opentelemetry", "imagick", "protobuf", "event"] {
                    XCTAssertFalse(modules.contains(forbidden), "PHP \(v) \(name) has \(forbidden)")
                }
            }
        }
    }

    /// The design's extension list, by the names `php -m` prints for these builds (lower-cased).
    static let requiredModules = [
        "apcu", "bcmath", "bz2", "calendar", "ctype", "curl", "dom", "exif", "fileinfo", "filter", "ftp", "gd",
        "gmp", "iconv", "igbinary", "intl", "mbstring", "mysqli", "mysqlnd", "zend opcache", "openssl", "pcntl",
        "pdo", "pdo_mysql", "pdo_pgsql", "pdo_sqlite", "pgsql", "phar", "posix", "readline", "redis", "session",
        "shmop", "simplexml", "soap", "sockets", "sodium", "sqlite3", "sysvmsg", "sysvsem", "sysvshm",
        "tokenizer", "xml", "xmlreader", "xmlwriter", "xsl", "zip", "zlib",
    ]

    func testRequiredExtensionsPresent() throws {
        for (v, dir) in try vendoredBuilds() {
            for name in ["php", "php-fpm"] {
                let modules = try self.modules(dir.appendingPathComponent(name))
                let missing = Self.requiredModules.filter { !modules.contains($0) }
                XCTAssertEqual(missing, [], "PHP \(v) \(name) lacks \(missing)")
            }
            let php = dir.appendingPathComponent("php")
            let drivers = try run(php, ["-n", "-r", "echo implode(',', PDO::getAvailableDrivers());"])
            XCTAssertEqual(drivers.output, "mysql,pgsql,sqlite", "PHP \(v)")
            let regex = try run(php, ["-n", "-r", "echo mb_ereg('b+', 'abbc', $m) ? $m[0] : 'none';"])
            XCTAssertEqual(regex.output, "bb", "PHP \(v): mb_ereg")
        }
    }

    // MARK: - Helpers

    private struct RunResult { let output: String; let elapsed: TimeInterval; let killed: Bool }

    private func connect(php: URL, port: Int) throws -> RunResult {
        let code = """
            try { new PDO("pgsql:host=127.0.0.1;port=\(port);dbname=x", "u", "p"); echo "connected"; }
            catch (PDOException $e) { echo "PDOException: ", $e->getMessage(); }
            """
        return try run(php, ["-n", "-r", code], cap: 8)
    }

    private func modules(_ binary: URL) throws -> Set<String> {
        let result = try run(binary, ["-n", "-m"])
        return Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    /// Runs a program under a time cap, killing it (our own child only) when the cap passes.
    private func run(_ binary: URL, _ arguments: [String], cap: TimeInterval = 30) throws -> RunResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-out-\(TestSupport.token())")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outFile) }
        let handle = try FileHandle(forWritingTo: outFile)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let began = Date()
        try process.run()
        var killed = false
        while process.isRunning {
            if Date().timeIntervalSince(began) > cap {
                kill(process.processIdentifier, SIGKILL)
                killed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(began)
        try handle.close()
        let output = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        return RunResult(output: output.trimmingCharacters(in: .whitespacesAndNewlines), elapsed: elapsed,
                         killed: killed)
    }
}

/// A TCP listener on 127.0.0.1 and a fresh free high port, owned by the test. It either closes each
/// connection at once, or answers like a PostgreSQL server that refuses the password.
final class ThrowawayServer: @unchecked Sendable {
    enum Behaviour { case closeImmediately, postgresAuthenticationFailure }

    let port: Int
    private let fd: Int32
    private let behaviour: Behaviour
    private let lock = NSLock()
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    init(behaviour: Behaviour) throws {
        self.behaviour = behaviour
        var listener: Int32 = -1
        var chosen = 0
        for _ in 0..<20 {
            let candidate = TestSupport.freeTCPPort()
            if let fd = try? TestSupport.listen(port: candidate) {
                listener = fd
                chosen = candidate
                break
            }
        }
        guard listener >= 0 else { throw POSIXError(.EADDRINUSE) }
        fd = listener
        port = chosen
        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
        finished.wait()
        close(fd)
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        defer { finished.signal() }
        while !shouldStop {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            if behaviour == .postgresAuthenticationFailure { answerAsPostgres(client) }
            close(client)
        }
    }

    /// Declines SSL and GSS encryption requests, reads the startup message and answers with an
    /// ErrorResponse (SQLSTATE 28P01), as a server refusing the password does. Like a real server it
    /// waits for the startup message longer than the tests' 8-second cap: a client that never sends it
    /// (the Swoole-hooked builds) hangs until killed instead of failing on a closed connection.
    private func answerAsPostgres(_ client: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        for _ in 0..<3 {
            guard let length = readInt32(client), length >= 8, length < 10_000,
                  let body = readExactly(client, count: Int(length) - 4), body.count >= 4 else { return }
            let code = body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if code == 80_877_103 || code == 80_877_104 { // SSLRequest, GSSENCRequest
                _ = [UInt8(ascii: "N")].withUnsafeBytes { write(client, $0.baseAddress, 1) }
                continue
            }
            break // the startup message
        }
        var fields = Data()
        for (type, value) in [("S", "FATAL"), ("V", "FATAL"), ("C", "28P01"),
                              ("M", "password authentication failed for user \"u\"")] {
            fields.append(Data(type.utf8))
            fields.append(Data(value.utf8))
            fields.append(0)
        }
        fields.append(0)
        var message = Data("E".utf8)
        let length = UInt32(fields.count + 4).bigEndian
        withUnsafeBytes(of: length) { message.append(contentsOf: $0) }
        message.append(fields)
        message.withUnsafeBytes { _ = write(client, $0.baseAddress, message.count) }
    }

    private func readInt32(_ client: Int32) -> UInt32? {
        guard let bytes = readExactly(client, count: 4) else { return nil }
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private func readExactly(_ client: Int32, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }
}
