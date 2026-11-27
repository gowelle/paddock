import Darwin
import XCTest
@testable import PaddockCore

final class LANPortTests: XCTestCase {
    func testPreferredIsTheEnvironmentChoiceThenTheSavedOneThenTheDefault() {
        XCTAssertEqual(LANPort.preferred(saved: 8090, environment: ["PADDOCK_LAN_PORT": "9000"]), 9000)
        XCTAssertEqual(LANPort.preferred(saved: 8090, environment: [:]), 8090)
        XCTAssertEqual(LANPort.preferred(saved: nil, environment: [:]), LAN.defaultPort)
        // A value a normal user can't bind is ignored, not obeyed.
        for bad in ["80", "443", "not a port", "70000"] {
            XCTAssertEqual(LANPort.preferred(saved: nil, environment: ["PADDOCK_LAN_PORT": bad]), LAN.defaultPort)
        }
        XCTAssertEqual(LANPort.preferred(saved: 80, environment: [:]), LAN.defaultPort)
    }

    func testChooseTakesTheFirstFreePortInTheRange() {
        XCTAssertEqual(LANPort.choose(saved: nil, environment: [:], isFree: { _ in true }), 8080)
        XCTAssertEqual(LANPort.choose(saved: 8080, environment: [:], isFree: { $0 != 8080 }), 8081)
        XCTAssertEqual(LANPort.choose(saved: nil, environment: [:], isFree: { $0 >= 8095 }), 8095)
        XCTAssertEqual(LANPort.choose(saved: 8099, environment: [:], isFree: { $0 < 8099 }), 8080,
                       "an unavailable saved port falls back into the range")
        XCTAssertNil(LANPort.choose(saved: 8099, environment: [:], isFree: { _ in false }))
    }

    func testChooseTriesACustomPortFirstThenTheRange() {
        let environment = ["PADDOCK_LAN_PORT": "9000"]
        let taken: Set<Int> = [9000, 8080]
        XCTAssertEqual(LANPort.choose(saved: nil, environment: environment, isFree: { !taken.contains($0) }), 8081)
        XCTAssertEqual(LANPort.choose(saved: nil, environment: environment, isFree: { $0 == 9000 }), 9000)
        XCTAssertNil(LANPort.choose(saved: nil, environment: environment, isFree: { _ in false }))
    }

    func testIsFreeSeesAWildcardListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        XCTAssertEqual(named, 0)
        let port = Int(UInt16(bigEndian: actual.sin_port))
        XCTAssertFalse(LANPort.isFree(port))
        close(fd)
        XCTAssertTrue(LANPort.isFree(port), "the port is free once the listener is closed")
    }
}
