import Darwin
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
}

/// How a failed bind is read: only "address in use" means someone holds the port.
final class PortBindClassificationTests: XCTestCase {
    func testAddressInUseIsAHolder() {
        XCTAssertEqual(PortCheck.classify([EADDRINUSE, 0]), .inUse)
        XCTAssertEqual(PortCheck.classify([0, EADDRINUSE]), .inUse)
        XCTAssertEqual(PortCheck.classify([EACCES, EADDRINUSE]), .inUse)
    }

    func testPermissionDeniedIsNotAHolder() {
        XCTAssertEqual(PortCheck.classify([EACCES, EACCES]), .notPermitted)
        XCTAssertEqual(PortCheck.classify([EACCES, EADDRNOTAVAIL]), .notPermitted)
    }

    func testFreeOnBothAddressesIsNoProblem() {
        XCTAssertNil(PortCheck.classify([0, 0]))
        // No IPv6 loopback on this Mac: nothing can hold ::1 either.
        XCTAssertNil(PortCheck.classify([0, EADDRNOTAVAIL]))
        XCTAssertNil(PortCheck.classify([0, EAFNOSUPPORT]))
    }

    func testReportTurnsProblemsIntoHoldersOrNotPermittedPorts() {
        let report = PortCheck.report(ports: [80, 443, 8080, 9090],
                                      listeners: { $0 == 9090 ? [PortHolder(port: 9090, pid: 5, command: "x",
                                                                                ownedByCurrentUser: true)] : [] },
                                      bindProblem: { port in
                                          switch port {
                                          case 80, 443: return .notPermitted
                                          case 8080: return .inUse
                                          default: return nil
                                          }
                                      })
        XCTAssertEqual(report.notPermitted, [80, 443])
        XCTAssertEqual(report.holders.map(\.port), [8080, 9090])
        XCTAssertNil(report.holders.first?.pid, "a failed bind shows a holder of unknown pid")
    }

    /// Port 81 on 127.0.0.1 needs root for a normal user, so binding it (never listening) gives EACCES.
    func testBindingALowLoopbackPortIsNotPermittedForANormalUser() throws {
        let result = PortCheck.bindErrno(port: 81, ipv6: false, listen: false)
        if result == 0 { throw XCTSkip("binding 127.0.0.1:81 unexpectedly succeeded (running as root?)") }
        if result == EADDRINUSE { throw XCTSkip("something is listening on port 81") }
        XCTAssertEqual(result, EACCES)
    }
}
