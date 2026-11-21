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
}
