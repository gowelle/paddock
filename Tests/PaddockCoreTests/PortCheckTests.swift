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
    }

    func testFreePortHasNoHolder() throws {
        let (fd, port) = try listen()
        close(fd)
        XCTAssertEqual(PortCheck.holders(of: [port]), [])
    }
}
