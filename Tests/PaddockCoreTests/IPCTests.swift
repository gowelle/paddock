import Darwin
import XCTest
@testable import PaddockCore

final class IPCTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var server: IPCServer?

    private let v84 = PHPVersion("8.4")!

    override func setUpWithError() throws {
        // Short root under /tmp: unix socket paths are limited to ~104 bytes.
        root = URL(fileURLWithPath: "/tmp/pdk-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleStatus() -> EngineStatus {
        EngineStatus(
            running: true,
            blockedBy: [PortHolder(port: 80, pid: 42, command: "nginx", ownedByCurrentUser: false)],
            sites: [Site(name: "blog", path: "/tmp/blog", kind: .parked, secured: true, php: v84, pinned: false)],
            installedPHP: [v84], defaultPHP: v84, processes: ["caddy": "running (pid 7)"],
            resolverInstalled: false)
    }

    // MARK: - Protocol

    func testRequestRoundTripsForEveryCase() throws {
        let requests: [Request] = [
            .status, .start, .stop, .restart,
            .park(path: "/Users/me/Sites"), .forget(path: "/Users/me/Sites"),
            .link(name: "blog", path: "/tmp/blog"), .unlink(name: "blog"),
            .secure(site: "blog"), .unsecure(site: "blog"),
            .isolate(site: "blog", version: v84), .unisolate(site: "blog"),
            .use(version: v84), .installPHP(version: v84), .removePHP(version: v84),
            .shutdown,
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(Request.self, from: data), request, "\(request)")
        }
    }

    func testResponseRoundTrips() throws {
        let responses: [Response] = [
            .ok(sampleStatus()),
            .error(code: "unknown_site", message: "No site named nope"),
        ]
        for response in responses {
            let data = try JSONEncoder().encode(response)
            XCTAssertEqual(try JSONDecoder().decode(Response.self, from: data), response)
        }
    }

    // MARK: - Server and client

    func testClientGetsStatusFromInProcessServer() throws {
        let expected = sampleStatus()
        let seen = Locked<[Request]>([])
        let server = IPCServer(socket: paths.daemonSocket) { request in
            seen.withValue { $0.append(request) }
            return .ok(expected)
        }
        try server.start()
        self.server = server

        let client = PaddockClient(paths: paths)
        XCTAssertTrue(client.daemonIsRunning)
        XCTAssertEqual(try client.send(.status), .ok(expected))
        XCTAssertEqual(try client.send(.park(path: "/x")), .ok(expected))
        XCTAssertEqual(seen.value, [.status, .status, .park(path: "/x")]) // daemonIsRunning asks too
    }

    func testSocketFileIsOwnerOnly() throws {
        let server = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        try server.start()
        self.server = server
        var info = stat()
        XCTAssertEqual(stat(paths.daemonSocket.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testDaemonNotRunningWhenSocketAbsent() {
        let client = PaddockClient(paths: paths)
        XCTAssertFalse(client.daemonIsRunning)
        XCTAssertThrowsError(try client.send(.status)) {
            XCTAssertEqual($0 as? ClientError, .daemonNotRunning)
        }
    }

    func testDaemonNotRunningWhenSocketIsStale() throws {
        try makeStaleSocketFile()
        let client = PaddockClient(paths: paths)
        XCTAssertFalse(client.daemonIsRunning)
        XCTAssertThrowsError(try client.send(.status)) {
            XCTAssertEqual($0 as? ClientError, .daemonNotRunning)
        }
    }

    func testStartRemovesStaleSocketFile() throws {
        try makeStaleSocketFile()
        let server = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        try server.start()
        self.server = server
        XCTAssertEqual(try PaddockClient(paths: paths).send(.status), .ok(sampleStatus()))
    }

    func testStartRefusesWhenLiveServerAnswers() throws {
        let first = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        try first.start()
        server = first

        let second = IPCServer(socket: paths.daemonSocket) { _ in .error(code: "internal", message: "second") }
        XCTAssertThrowsError(try second.start())
        // The first server still owns the socket.
        XCTAssertEqual(try PaddockClient(paths: paths).send(.status), .ok(sampleStatus()))
    }

    func testStartRejectsOverlongSocketPath() {
        let long = root.appendingPathComponent(String(repeating: "a", count: 120)).appendingPathComponent("s.sock")
        XCTAssertThrowsError(try IPCServer(socket: long) { _ in .ok(self.sampleStatus()) }.start())
    }

    func testStopRemovesSocketFile() throws {
        let server = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        try server.start()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemonSocket.path))
        XCTAssertFalse(PaddockClient(paths: paths).daemonIsRunning)
    }

    func testMalformedRequestGetsErrorResponse() throws {
        try startEchoServer()
        let reply = try rawExchange(Data("{not json}\n".utf8))
        guard case .error(let code, _) = try JSONDecoder().decode(Response.self, from: reply) else {
            return XCTFail("expected an error response")
        }
        XCTAssertEqual(code, "internal")
        XCTAssertEqual(try PaddockClient(paths: paths).send(.status), .ok(sampleStatus()))
    }

    func testOversizedRequestIsRejected() throws {
        try startEchoServer()
        let big = Data(repeating: UInt8(ascii: "a"), count: 200_000)
        let reply = try rawExchange(big + Data("\n".utf8))
        guard case .error(let code, let message) = try JSONDecoder().decode(Response.self, from: reply) else {
            return XCTFail("expected an error response")
        }
        XCTAssertEqual(code, "internal")
        XCTAssertTrue(message.contains("large"), message)
        XCTAssertEqual(try PaddockClient(paths: paths).send(.status), .ok(sampleStatus()))
    }

    func testSilentClientDoesNotHangTheServer() throws {
        let server = IPCServer(socket: paths.daemonSocket, requestTimeout: 0.5) { _ in .ok(self.sampleStatus()) }
        try server.start()
        self.server = server

        let fd = try connectRaw()
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let started = Date()
        var byte: UInt8 = 0
        // Server gives up on us and closes (possibly after an error reply); read drains to EOF.
        while read(fd, &byte, 1) > 0 {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "server held the connection open")
        XCTAssertEqual(try PaddockClient(paths: paths).send(.status), .ok(sampleStatus()))
    }

    func testSlowHandlerDoesNotBlockOtherRequests() throws {
        let server = IPCServer(socket: paths.daemonSocket) { request in
            if case .installPHP = request { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            return .ok(self.sampleStatus())
        }
        try server.start()
        self.server = server
        let client = PaddockClient(paths: paths)

        let slow = expectation(description: "slow request")
        DispatchQueue.global().async {
            _ = try? client.send(.installPHP(version: self.v84))
            slow.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        XCTAssertEqual(try client.send(.status), .ok(sampleStatus()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        wait(for: [slow], timeout: 10)
    }

    func testDidRespondRunsAfterTheReplyIsWritten() throws {
        let responded = expectation(description: "didRespond")
        let server = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        server.didRespond = { request in
            if request == .shutdown { responded.fulfill() }
        }
        try server.start()
        self.server = server
        XCTAssertEqual(try PaddockClient(paths: paths).send(.shutdown), .ok(sampleStatus()))
        wait(for: [responded], timeout: 5)
    }

    // MARK: - Helpers

    private func startEchoServer() throws {
        let server = IPCServer(socket: paths.daemonSocket) { _ in .ok(self.sampleStatus()) }
        try server.start()
        self.server = server
    }

    private func sockaddrUn() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = paths.daemonSocket.path
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        return addr
    }

    private func connectRaw() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddrUn()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    /// Writes `payload` and reads until the server closes or sends a newline.
    private func rawExchange(_ payload: Data) throws -> Data {
        let fd = try connectRaw()
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // The server may reply and close before taking everything; ignore a failed write.
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
            if reply.last == UInt8(ascii: "\n") { break }
        }
        return reply
    }

    /// A socket file with nothing listening, as left behind by a dead daemon.
    private func makeStaleSocketFile() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddrUn()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemonSocket.path))
    }
}

/// Minimal thread-safe box for values touched by the server's handler threads.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func withValue(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
