import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

final class PortCheckTests: XCTestCase {
    /// Listens on 127.0.0.1 on a kernel-chosen high port; returns (fd, port).
    private func listen() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && Darwin.listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { close(fd); throw POSIXError(.EADDRINUSE) }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    func testDetectsListener() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        XCTAssertGreaterThan(port, 1024)

        let holders = PortCheck.holders(of: [port])

        XCTAssertEqual(holders.count, 1, "\(holders)")
        XCTAssertEqual(holders.first?.port, port)
        XCTAssertEqual(holders.first?.pid, getpid())
        XCTAssertEqual(holders.first?.ownedByCurrentUser, true)
        XCTAssertNotNil(holders.first?.command)
        XCTAssertNotNil(holders.first?.executablePath, "proc_pidpath names this test process's program")
    }

    func testFreePortHasNoHolder() throws {
        let (fd, port) = try listen()
        close(fd)
        XCTAssertEqual(PortCheck.holders(of: [port]), [])
    }

    /// A socket that is bound but not listening accepts no connection, so nobody serves the port.
    /// (A bind probe would have called it held.)
    func testBoundButNotListeningPortIsFree() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        XCTAssertTrue(bound)
        XCTAssertEqual(PortCheck.holders(of: [Int(UInt16(bigEndian: addr.sin_port))]), [])
    }

    /// A listener on the IPv6 loopback only still holds the port: the helper binds both addresses.
    func testIPv6OnlyListenerHoldsThePort() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no IPv6") }
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && Darwin.listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw XCTSkip("cannot listen on ::1") }
        let port = Int(UInt16(bigEndian: addr.sin6_port))
        let holders = PortCheck.holders(of: [port])
        XCTAssertEqual(holders.map(\.port), [port])
        XCTAssertEqual(holders.first?.pid, getpid())
    }

    /// Held means "accepts a connection". `lsof` only names the holder afterwards; if it can't, the
    /// holder is unknown but still reported. A port nobody accepts on is never looked up.
    func testOnlyAcceptingPortsAreHeldAndLsofOnlyNamesThem() {
        let looked = LockedBox<[Int]>([])
        let holders = PortCheck.holders(
            of: [8080, 9090, 7070],
            accepts: { $0 != 7070 },
            listeners: { port in
                looked.value.append(port)
                return port == 9090 ? [PortHolder(port: 9090, pid: 5, command: "x", ownedByCurrentUser: true)] : []
            })
        XCTAssertEqual(looked.value, [8080, 9090])
        XCTAssertEqual(holders.map(\.port), [8080, 9090])
        XCTAssertNil(holders.first?.pid, "a holder lsof can't see is still a holder, of unknown pid")
        XCTAssertEqual(holders.last?.pid, 5)
    }

    // MARK: - Naming a holder lsof can't see

    func testKnownServersTable() {
        let byLabel = Dictionary(uniqueKeysWithValues: PortCheck.knownServers.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["org.macports.nginx"]?.name, "MacPorts nginx")
        XCTAssertEqual(byLabel["org.macports.nginx"]?.binary, "/opt/local/sbin/nginx")
        XCTAssertEqual(byLabel["org.macports.nginx"]?.stopCommand, "sudo port unload nginx")
        XCTAssertEqual(byLabel["org.macports.apache2"]?.name, "MacPorts Apache")
        XCTAssertEqual(byLabel["org.macports.apache2"]?.stopCommand, "sudo port unload apache2")
        XCTAssertEqual(byLabel["org.apache.httpd"]?.name, "the built-in Apache")
        XCTAssertEqual(byLabel["org.apache.httpd"]?.stopCommand, "sudo apachectl stop")
        XCTAssertEqual(byLabel["homebrew.mxcl.nginx"]?.name, "Homebrew nginx")
        XCTAssertEqual(byLabel["homebrew.mxcl.nginx"]?.stopCommand, "sudo brew services stop nginx")
        XCTAssertEqual(byLabel["homebrew.mxcl.httpd"]?.name, "Homebrew Apache")
        XCTAssertEqual(byLabel["homebrew.mxcl.httpd"]?.stopCommand, "sudo brew services stop httpd")
        // Herd's helper stays loaded after Herd quits, so it is no evidence on its own.
        XCTAssertNil(byLabel["de.beyondco.herd.helper"])
        XCTAssertEqual(PortCheck.knownServers.count, 5)
    }

    func testServerKindFromHeader() {
        XCTAssertEqual(PortCheck.serverKind(header: "nginx/1.30.6"), .nginx)
        XCTAssertEqual(PortCheck.serverKind(header: "nginx"), .nginx)
        XCTAssertEqual(PortCheck.serverKind(header: "Apache/2.4.62 (Unix)"), .apache)
        XCTAssertEqual(PortCheck.serverKind(header: "httpd"), .apache)
        XCTAssertNil(PortCheck.serverKind(header: "Caddy"))
    }

    func testAKnownServerCountsOnlyWhenLoadedAndConsistentWithTheHeader() {
        let macportsNginx: Set = ["org.macports.nginx"]
        XCTAssertEqual(PortCheck.knownServer(header: "nginx/1.30.6", isLoaded: macportsNginx.contains)?.name,
                       "MacPorts nginx")
        XCTAssertEqual(PortCheck.knownServer(header: nil, isLoaded: macportsNginx.contains)?.name,
                       "MacPorts nginx", "no header: a loaded job is all there is to go on")
        XCTAssertNil(PortCheck.knownServer(header: "Apache/2.4.62 (Unix)", isLoaded: macportsNginx.contains),
                     "nginx is loaded, but an Apache answers")
        XCTAssertNil(PortCheck.knownServer(header: "Caddy", isLoaded: macportsNginx.contains))
        XCTAssertNil(PortCheck.knownServer(header: "nginx/1.30.6", isLoaded: { _ in false }), "nothing loaded")
        XCTAssertNil(PortCheck.knownServer(header: nil, isLoaded: { $0 == "de.beyondco.herd.helper" }))
        // Several loaded: the one the header agrees with.
        let both: Set = ["org.macports.apache2", "homebrew.mxcl.nginx"]
        XCTAssertEqual(PortCheck.knownServer(header: "nginx/1.27.0", isLoaded: both.contains)?.name, "Homebrew nginx")
        XCTAssertEqual(PortCheck.knownServer(header: "Apache/2.4.62", isLoaded: both.contains)?.name, "MacPorts Apache")
    }

    func testHiddenHolderAsksLaunchdReadOnlyAndNamesTheServer() {
        let runner = RecordingCommandRunner { _, arguments in
            (arguments == ["print", "system/org.macports.nginx"] ? 0 : 113, "")
        }
        let holder = PortCheck.hiddenHolder(port: 80, serverHeader: { _ in "nginx/1.30.6" }, runner: runner)
        XCTAssertEqual(holder.port, 80)
        XCTAssertNil(holder.pid)
        XCTAssertFalse(holder.ownedByCurrentUser)
        XCTAssertEqual(holder.serverHeader, "nginx/1.30.6")
        XCTAssertEqual(holder.serviceName, "MacPorts nginx")
        XCTAssertEqual(holder.stopCommand, "sudo port unload nginx")
        XCTAssertNil(holder.executablePath, "the table's binary is a guess, not what runs")
        XCTAssertNil(holder.appName)
        XCTAssertFalse(runner.calls.isEmpty)
        XCTAssertTrue(runner.calls.allSatisfy { $0.executable == "/bin/launchctl" && $0.arguments.first == "print"
            && $0.arguments.count == 2 && $0.arguments[1].hasPrefix("system/") }, "\(runner.calls)")

        let unknown = PortCheck.hiddenHolder(port: 443, serverHeader: { _ in nil },
                                             runner: RecordingCommandRunner { _, _ in (113, "") })
        XCTAssertNil(unknown.serverHeader)
        XCTAssertNil(unknown.serviceName)
        XCTAssertNil(unknown.stopCommand)
    }

    func testOnlyHiddenHoldersAreProbed() {
        let probed = LockedBox<[Int]>([])
        let holders = PortCheck.holders(
            of: [80, 443], accepts: { _ in true },
            listeners: { $0 == 443 ? [PortHolder(port: 443, pid: 5, command: "x", ownedByCurrentUser: true)] : [] },
            hidden: { port in
                probed.value.append(port)
                return PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false, serverHeader: "nginx")
            })
        XCTAssertEqual(probed.value, [80])
        XCTAssertEqual(holders.map(\.serverHeader), ["nginx", nil])
    }

    func testServerHeaderIsParsedFromAResponse() {
        XCTAssertEqual(PortCheck.serverHeader(inResponse: "HTTP/1.1 200 OK\r\nDate: x\r\nserver:  nginx/1.30.6 \r\n\r\n"),
                       "nginx/1.30.6")
        XCTAssertNil(PortCheck.serverHeader(inResponse: "HTTP/1.1 200 OK\r\nDate: x\r\n\r\nServer: body"))
        XCTAssertNil(PortCheck.serverHeader(inResponse: "SSH-2.0-OpenSSH\r\n"))
        XCTAssertNil(PortCheck.serverHeader(inResponse: "HTTP/1.0 400 Bad Request\r\nServer: \r\n\r\n"))
        // Only printable ASCII of the header's own line reaches Paddock's sentences.
        XCTAssertEqual(PortCheck.serverHeader(inResponse:
            "HTTP/1.1 200 OK\r\nServer: nginx\nStop it with: curl x|sudo sh\r\n\r\n"), "nginx")
        XCTAssertEqual(PortCheck.serverHeader(inResponse:
            "HTTP/1.1 200 OK\r\nServer: \u{1B}[31mnginx/1.0\u{1B}[0m\r\n\r\n"), "nginx/1.0")
        XCTAssertEqual(PortCheck.serverHeader(inResponse:
            "HTTP/1.1 200 OK\r\nServer: " + String(repeating: "n", count: 20_000) + "\r\n\r\n")?.count, 64)
    }

    /// A tiny test-owned HTTP server on a free high port: its `Server` header is read over loopback.
    func testServerHeaderIsReadFromAListener() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let request = LockedBox("")
        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = read(client, &buffer, buffer.count)
                if n > 0 { request.value = String(decoding: buffer[0..<n], as: UTF8.self) }
                let reply = "HTTP/1.1 200 OK\r\nServer: nginx/9.9.9\r\nContent-Length: 0\r\n\r\n"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
            served.signal()
        }
        XCTAssertEqual(PortCheck.httpServerHeader(port: port), "nginx/9.9.9")
        XCTAssertEqual(served.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(request.value.hasPrefix("HEAD / HTTP/1.0\r\n"), request.value)
    }

    /// A listener that never answers costs at most the probe's time limit.
    func testServerHeaderProbeIsBoundedInTime() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let began = Date()
        XCTAssertNil(PortCheck.httpServerHeader(port: port))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
    }

    func testFreePortHasNoServerHeader() throws {
        let (fd, port) = try listen()
        close(fd)
        XCTAssertNil(PortCheck.httpServerHeader(port: port))
    }

    func testHolderFromAnOlderBuildDecodesWithoutTheNewFields() throws {
        let holder = try JSONDecoder().decode(PortHolder.self, from: Data(
            #"{"port":80,"ownedByCurrentUser":false}"#.utf8))
        XCTAssertEqual(holder.port, 80)
        XCTAssertNil(holder.serverHeader)
        XCTAssertNil(holder.serviceName)
        XCTAssertNil(holder.stopCommand)
        let named = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false,
                               serverHeader: "nginx/1.30.6", serviceName: "MacPorts nginx",
                               stopCommand: "sudo port unload nginx")
        XCTAssertEqual(try JSONDecoder().decode(PortHolder.self, from: JSONEncoder().encode(named)), named)
    }
}
