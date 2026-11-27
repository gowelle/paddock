import XCTest
@testable import PaddockCore

final class LANAddressTests: XCTestCase {
    private func candidate(_ name: String, _ address: String, down: Bool = false,
                           loopback: Bool = false, linkLocal: Bool = false) -> LANAddress.Candidate {
        LANAddress.Candidate(name: name, address: address, isDown: down,
                             isLoopback: loopback, isLinkLocal: linkLocal)
    }

    func testChoosesAWiFiAddressOverAWiredOneAndIgnoresUnusableOnes() {
        let chosen = LANAddress.choose(from: [
            candidate("lo0", "127.0.0.1", loopback: true),
            candidate("en5", "169.254.3.4", linkLocal: true),
            candidate("en2", "10.0.0.4"),
            candidate("en0", "192.168.1.23"),
            candidate("en1", "192.168.1.24", down: true),
        ])
        XCTAssertEqual(chosen, "192.168.1.23")
    }

    func testFallsBackToAnyUsableInterfaceWhenWiFiIsNotFirst() {
        XCTAssertEqual(LANAddress.choose(from: [candidate("bridge100", "172.20.0.1")]), "172.20.0.1")
        XCTAssertEqual(LANAddress.choose(from: [candidate("en7", "203.0.113.9")]), "203.0.113.9")
    }

    func testNoUsableInterfaceIsNil() {
        XCTAssertNil(LANAddress.choose(from: []))
        XCTAssertNil(LANAddress.choose(from: [
            candidate("lo0", "127.0.0.1", loopback: true),
            candidate("en0", "192.168.1.2", down: true),
            candidate("en0", "169.254.1.1", linkLocal: true),
        ]))
    }
}
