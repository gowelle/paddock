import XCTest
@testable import PaddockCore

final class PathsTests: XCTestCase {
    func testPathsHonourHome() throws {
        let p = Paths(home: URL(fileURLWithPath: "/tmp/px"))
        XCTAssertEqual(p.stateFile.path, "/tmp/px/state.json")
        XCTAssertEqual(p.fpmSocket(PHPVersion("8.4")!).path, "/tmp/px/run/php-8.4.sock")
        XCTAssertEqual(p.phpDir(PHPVersion("8.4")!).path, "/tmp/px/bin/php-versions/8.4/default")
        XCTAssertEqual(p.daemonSocket.path, "/tmp/px/run/paddockd.sock")
        XCTAssertEqual(p.phpIni(PHPVersion("8.4")!).path, "/tmp/px/php/8.4/php.ini")
    }

    func testSettingsDefaults() {
        XCTAssertEqual(Settings().httpPort, 80)
        XCTAssertEqual(Settings().dnsPort, 53535)
    }
}
