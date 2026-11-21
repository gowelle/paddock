import CryptoKit
import Darwin
import XCTest
import PaddockTestSupport

/// Runs the built `paddock-ports` helper in its `listen` form on free high ports, forwarding to
/// test-owned Unix-socket servers. The socket directory has a space in its name, like the real
/// `~/Library/Application Support/Paddock/run/`.
final class PortHelperTests: XCTestCase {
    private var root: URL!
    private var httpPort = 0
    private var httpsPort = 0
    private var httpSocket = ""
    private var httpsSocket = ""
    private var helper: Process?
    private let helperStderr = LockedBox(Data())
    private var servers: [UnixServer] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/pp-\(TestSupport.token())", isDirectory: true)
        let run = root.appendingPathComponent("run dir", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        httpSocket = run.appendingPathComponent("http.sock").path
        httpsSocket = run.appendingPathComponent("https.sock").path
        httpPort = TestSupport.freeTCPPort(preferred: 28080)
        httpsPort = TestSupport.freeTCPPort(preferred: httpPort + 1)
        if httpsPort == httpPort { httpsPort = TestSupport.freeTCPPort(preferred: httpPort + 2) }
    }

    override func tearDown() {
        if let helper, helper.isRunning {
            kill(helper.processIdentifier, SIGKILL)
            helper.waitUntilExit()
        }
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Forwarding

    func testForwardsRequestAndResponse() throws {
        startServer(at: httpSocket, handler: UnixServer.taggedEcho("http:"))
        startServer(at: httpsSocket, handler: UnixServer.taggedEcho("https:"))
        try startHelper()

        try assertExchange(port: httpPort, send: "GET / HTTP/1.1\r\n", reply: "http:GET / HTTP/1.1\r\n")
        try assertExchange(port: httpsPort, send: "hello tls", reply: "https:hello tls")
    }

    func testIPv6LoopbackIsServed() throws {
        startServer(at: httpSocket, handler: UnixServer.taggedEcho("http:"))
        startServer(at: httpsSocket, handler: UnixServer.taggedEcho("https:"))
        try startHelper()

        try assertExchange(host: "::1", port: httpPort, send: "v6", reply: "http:v6")
        try assertExchange(host: "::1", port: httpsPort, send: "v6", reply: "https:v6")
    }

    func testUpstreamDownClosesConnectionPromptly() throws {
        try startHelper()

        let fd = try Client.connect(port: httpPort)
        defer { close(fd) }
        Client.setReceiveTimeout(fd, seconds: 1)
        let started = Date()
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        let failure = errno
        XCTAssertTrue(n == 0 || (n < 0 && failure == ECONNRESET), "read returned \(n), errno \(failure)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(helper!.isRunning)

        startServer(at: httpSocket, handler: UnixServer.taggedEcho("http:"))
        try assertExchange(port: httpPort, send: "again", reply: "http:again")
    }

    func testLargeTransferIsCompleteAndOrdered() throws {
        startServer(at: httpSocket, handler: UnixServer.echo)
        try startHelper()

        var payload = Data(count: 8 * 1024 * 1024)
        payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let fd = try Client.connect(port: httpPort)
        defer { close(fd) }
        let writer = Thread {
            _ = Client.writeAll(fd, payload)
            shutdown(fd, SHUT_WR)
        }
        writer.start()
        let received = Client.readToEOF(fd)

        XCTAssertEqual(received.count, payload.count)
        XCTAssertEqual(SHA256.hash(data: received), SHA256.hash(data: payload))
    }

    func testHalfCloseStillDeliversResponse() throws {
        startServer(at: httpSocket, handler: UnixServer.replyAfterEOF)
        try startHelper()

        let fd = try Client.connect(port: httpPort)
        defer { close(fd) }
        XCTAssertTrue(Client.writeAll(fd, Data("request body".utf8)))
        shutdown(fd, SHUT_WR)
        XCTAssertEqual(String(decoding: Client.readToEOF(fd), as: UTF8.self), "got 12 bytes: request body")
    }

    func testAbruptClientResetDoesNotKillHelper() throws {
        startServer(at: httpSocket, handler: UnixServer.echo)
        try startHelper()
        let pid = helper!.processIdentifier
        let baseline = try openFileCount(pid: pid)

        let fd = try Client.connect(port: httpPort)
        Client.setNonBlocking(fd)
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        for _ in 0..<16 { if Client.sendAvailable(fd, chunk) < chunk.count { break } }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&poller, 1, 2000), 1, "no echo arrived before the reset")
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(fd)

        try waitUntil("helper's open files return to baseline (\(baseline))") {
            try openFileCount(pid: pid) <= baseline
        }
        XCTAssertTrue(helper!.isRunning)
        try assertExchange(port: httpPort, send: "still here", reply: "still here")
    }

    func testManyParallelConnections() throws {
        startServer(at: httpSocket, handler: UnixServer.echo)
        try startHelper()

        let clients = try (0..<100).map { _ in try Client.connect(port: httpPort) }
        defer { clients.forEach { close($0) } }
        for (i, fd) in clients.enumerated() {
            XCTAssertTrue(Client.writeAll(fd, Data("message \(i);".utf8)))
        }
        for (i, fd) in clients.enumerated() {
            let expected = "message \(i);"
            XCTAssertEqual(String(decoding: Client.readExactly(fd, count: expected.utf8.count), as: UTF8.self),
                           expected)
        }
    }

    func testStalledConnectionDoesNotBlockOthers() throws {
        startServer(at: httpSocket, handler: UnixServer.echo)
        try startHelper()

        // A client that sends but never reads: every buffer on the way fills, then its writes stop.
        let stalled = try Client.connect(port: httpPort)
        defer { close(stalled) }
        Client.setNonBlocking(stalled)
        let chunk = Data(repeating: 0x62, count: 64 * 1024)
        var sent = 0
        let limit = 64 * 1024 * 1024
        while sent < limit {
            sent += Client.sendAvailable(stalled, chunk)
            var poller = pollfd(fd: stalled, events: Int16(POLLOUT), revents: 0)
            if poll(&poller, 1, 500) == 0 { break }
        }
        XCTAssertLessThan(sent, limit, "the helper buffered without bound instead of applying back-pressure")

        let started = Date()
        try assertExchange(port: httpPort, send: "unaffected", reply: "unaffected")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: - Holding resources

    func testIdleClientIsReleasedAfterUpstreamCloses() throws {
        startServer(at: httpSocket, handler: UnixServer.sayGoodbye)
        try startHelper(tuning: ["1"])
        let pid = helper!.processIdentifier
        let baseline = try openFileCount(pid: pid)

        // Reads the reply and the EOF, then sits idle without closing.
        let idle = try Client.connect(port: httpPort)
        defer { close(idle) }
        XCTAssertEqual(String(decoding: Client.readToEOF(idle), as: UTF8.self), "bye")
        XCTAssertGreaterThan(try openFileCount(pid: pid), baseline, "connection should still be held")

        try waitUntil("idle connection released", timeout: 5) { try openFileCount(pid: pid) <= baseline }
        XCTAssertTrue(helper!.isRunning)
        let next = try Client.connect(port: httpPort)
        defer { close(next) }
        XCTAssertEqual(String(decoding: Client.readToEOF(next), as: UTF8.self), "bye")
    }

    func testSlowReplyAfterHalfCloseIsComplete() throws {
        // The idle timeout is between reads, not a total: a reply that keeps making progress
        // for longer than the timeout still arrives whole.
        startServer(at: httpSocket, handler: UnixServer.slowReplyAfterEOF)
        try startHelper(tuning: ["1"])

        let fd = try Client.connect(port: httpPort)
        defer { close(fd) }
        XCTAssertTrue(Client.writeAll(fd, Data("request".utf8)))
        shutdown(fd, SHUT_WR)
        let started = Date()
        XCTAssertEqual(String(decoding: Client.readToEOF(fd), as: UTF8.self), "one two three four five ")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.5)
    }

    func testConnectionCapClosesExtraConnections() throws {
        startServer(at: httpSocket, handler: UnixServer.echo)
        try startHelper(tuning: ["60", "4"])

        var held = try (0..<4).map { _ in try Client.connect(port: httpPort) }
        defer { held.forEach { close($0) } }
        for (i, fd) in held.enumerated() {
            XCTAssertTrue(Client.writeAll(fd, Data("held \(i)".utf8)))
            XCTAssertEqual(String(decoding: Client.readExactly(fd, count: 6), as: UTF8.self), "held \(i)")
        }

        let extra = try Client.connect(port: httpPort)
        defer { close(extra) }
        Client.setReceiveTimeout(extra, seconds: 1)
        let started = Date()
        var byte: UInt8 = 0
        let n = read(extra, &byte, 1)
        let failure = errno
        XCTAssertTrue(n == 0 || (n < 0 && failure == ECONNRESET), "read returned \(n), errno \(failure)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        close(held.removeFirst())
        try waitUntil("a slot frees up") {
            let fd = try Client.connect(port: httpPort)
            defer { close(fd) }
            guard Client.writeAll(fd, Data("again".utf8)) else { return false }
            return String(decoding: Client.readExactly(fd, count: 5), as: UTF8.self) == "again"
        }
        XCTAssertTrue(helper!.isRunning)
    }

    // MARK: - Process behaviour

    func testBadArgumentsExit64() throws {
        let bad: [[String]] = [
            [],
            ["serve"],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket],
            ["listen", "http", "\(httpsPort)", httpSocket, httpsSocket],
            ["listen", "0", "\(httpsPort)", httpSocket, httpsSocket],
            ["listen", "70000", "\(httpsPort)", httpSocket, httpsSocket],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket, "extra"],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket, "0"],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket, "1", "0"],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket, "1", "513"],
            ["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket, "1", "4", "9"],
            ["launchd", httpSocket, httpsSocket, "1"],
            ["launchd", httpSocket],
        ]
        for arguments in bad {
            let result = try runToExit(arguments)
            XCTAssertEqual(result.status, 64, "arguments \(arguments)")
            XCTAssertTrue(result.stderr.contains("usage"), "arguments \(arguments): \(result.stderr)")
        }
    }

    func testLaunchdFormOutsideLaunchdExits78() throws {
        let result = try runToExit(["launchd", httpSocket, httpsSocket])
        XCTAssertEqual(result.status, 78)
        XCTAssertTrue(result.stderr.contains("launchd"), result.stderr)
    }

    func testSocketPathLengthBoundary() throws {
        // sun_path holds 104 bytes including the terminating NUL: 103 usable.
        let prefix = root.path + "/"
        let fits = prefix + String(repeating: "s", count: 103 - prefix.utf8.count)
        let tooLong = fits + "s"
        XCTAssertEqual(fits.utf8.count, 103)

        let rejected = try runToExit(["listen", "\(httpPort)", "\(httpsPort)", tooLong, httpsSocket])
        XCTAssertEqual(rejected.status, 1)
        XCTAssertTrue(rejected.stderr.contains("too long"), rejected.stderr)

        startServer(at: fits, handler: UnixServer.taggedEcho("long:"))
        try startHelper(httpSocketPath: fits)
        try assertExchange(port: httpPort, send: "edge", reply: "long:edge")
    }

    func testOverlongSocketPathExits1() throws {
        let long = "/tmp/" + String(repeating: "x", count: 100) + "/http.sock"
        let result = try runToExit(["listen", "\(httpPort)", "\(httpsPort)", long, httpsSocket])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("too long"), result.stderr)
    }

    func testBindFailureExits1() throws {
        let holder = try TestSupport.listen(port: httpsPort)
        defer { close(holder) }
        let result = try runToExit(["listen", "\(httpPort)", "\(httpsPort)", httpSocket, httpsSocket])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("\(httpsPort)"), result.stderr)
    }

    func testSIGTERMExitsZero() throws {
        try startHelper()
        let process = helper!
        kill(process.processIdentifier, SIGTERM)
        XCTAssertTrue(waitForExit(process, timeout: 5))
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Helpers

    private func helperBinary() throws -> URL {
        let products = Bundle(for: PortHelperTests.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("paddock-ports")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("paddock-ports not built at \(binary.path)")
            throw XCTSkip("paddock-ports missing")
        }
        return binary
    }

    private func startServer(at path: String, handler: @escaping @Sendable (Int32) -> Void) {
        do {
            servers.append(try UnixServer(path: path, handler: handler))
        } catch {
            XCTFail("unix server at \(path): \(error)")
        }
    }

    /// Starts `paddock-ports listen …` and waits for its start line.
    /// `tuning` are the listen form's hidden trailing arguments: idle seconds, connection cap.
    private func startHelper(tuning: [String] = [], httpSocketPath: String? = nil) throws {
        let process = Process()
        process.executableURL = try helperBinary()
        process.arguments = ["listen", "\(httpPort)", "\(httpsPort)", httpSocketPath ?? httpSocket, httpsSocket]
            + tuning
        process.environment = [:]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let collected = helperStderr
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.value.append(data) }
        }
        try process.run()
        helper = process
        try waitUntil("helper start line") { collected.value.contains(UInt8(ascii: "\n")) }
        XCTAssertTrue(process.isRunning, String(decoding: collected.value, as: UTF8.self))
    }

    /// Runs the helper with `arguments`; it must exit within 5 seconds.
    private func runToExit(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = try helperBinary()
        process.arguments = arguments
        process.environment = [:]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        if !waitForExit(process, timeout: 5) {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("helper did not exit for \(arguments)")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Sends `message` on a new connection and checks the reply, read by its expected length.
    private func assertExchange(host: String = "127.0.0.1", port: Int, send message: String, reply: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let fd = try Client.connect(host: host, port: port)
        defer { close(fd) }
        XCTAssertTrue(Client.writeAll(fd, Data(message.utf8)), "write failed", file: file, line: line)
        let received = Client.readExactly(fd, count: reply.utf8.count)
        XCTAssertEqual(String(decoding: received, as: UTF8.self), reply, file: file, line: line)
    }

    private func openFileCount(pid: Int32) throws -> Int {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-n", "-P", "-p", "\(pid)"]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return }
            if let helper, !helper.isRunning {
                XCTFail("helper exited (\(helper.terminationStatus)) while waiting for: \(what)\n"
                        + String(decoding: helperStderr.value, as: UTF8.self))
                throw XCTSkip("helper exited")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for: \(what)")
        throw XCTSkip("timeout")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }
}

// MARK: - Sockets for the tests

/// Blocking TCP client sockets with a 5 s receive timeout so a broken helper fails a test
/// instead of hanging it.
private enum Client {
    static func connect(host: String = "127.0.0.1", port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &info) == 0, let address = info else {
            throw POSIXError(.EINVAL)
        }
        defer { freeaddrinfo(info) }
        let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            let failure = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .ECONNREFUSED)
        }
        setReceiveTimeout(fd, seconds: 5)
        return fd
    }

    static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    /// For non-blocking sockets: writes what fits now and returns the byte count.
    static func sendAvailable(_ fd: Int32, _ data: Data) -> Int {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
    }

    static func readExactly(_ fd: Int32, count: Int) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count < count {
            let n = read(fd, &buffer, min(buffer.count, count - result.count))
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            result.append(buffer, count: n)
        }
        return result
    }

    static func readToEOF(_ fd: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            result.append(buffer, count: n)
        }
        return result
    }
}

/// A Unix-socket server standing in for Caddy: each connection runs `handler` on its own thread
/// and is closed when the handler returns.
private final class UnixServer: @unchecked Sendable {
    private let listener: Int32
    private let path: String
    private let handler: @Sendable (Int32) -> Void
    private let stopped = LockedBox(false)
    private let lock = NSLock()
    private var open = Set<Int32>()

    init(path: String, handler: @escaping @Sendable (Int32) -> Void) throws {
        self.path = path
        self.handler = handler
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 128) == 0 else {
            close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        stopped.value = true
        lock.lock()
        for fd in open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        unlink(path)
    }

    private func acceptLoop() {
        while !stopped.value {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) == 1 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            open.insert(fd)
            lock.unlock()
            let handler = self.handler
            Thread { [self] in
                handler(fd)
                lock.lock()
                open.remove(fd)
                close(fd)
                lock.unlock()
            }.start()
        }
        close(listener)
    }

    // MARK: Handlers

    static let echo: @Sendable (Int32) -> Void = { fd in
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            if !Client.writeAll(fd, Data(buffer[0..<n])) { return }
        }
    }

    static func taggedEcho(_ tag: String) -> @Sendable (Int32) -> Void {
        { fd in
            guard Client.writeAll(fd, Data(tag.utf8)) else { return }
            echo(fd)
        }
    }

    /// Replies at once and closes, whatever the client does.
    static let sayGoodbye: @Sendable (Int32) -> Void = { fd in
        _ = Client.writeAll(fd, Data("bye".utf8))
    }

    /// After the request's EOF, replies in five pieces 0.4 s apart (2 s in all).
    static let slowReplyAfterEOF: @Sendable (Int32) -> Void = { fd in
        _ = Client.readToEOF(fd)
        for word in ["one", "two", "three", "four", "five"] {
            Thread.sleep(forTimeInterval: 0.4)
            guard Client.writeAll(fd, Data("\(word) ".utf8)) else { return }
        }
    }

    static let replyAfterEOF: @Sendable (Int32) -> Void = { fd in
        let body = Client.readToEOF(fd)
        _ = Client.writeAll(fd, Data("got \(body.count) bytes: ".utf8) + body)
    }
}
