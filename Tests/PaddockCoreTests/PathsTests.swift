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
        XCTAssertEqual(p.httpSocket.path, "/tmp/px/run/http.sock")
        XCTAssertEqual(p.httpsSocket.path, "/tmp/px/run/https.sock")
    }

    /// sun_path holds 104 bytes including the terminating NUL, so 103 is the longest usable path.
    func testSocketPathTooLongIsReported() {
        func home(httpSocketLength: Int) -> Paths {
            let suffix = "/run/http.sock"
            let name = String(repeating: "h", count: httpSocketLength - "/tmp/".utf8.count - suffix.utf8.count)
            return Paths(home: URL(fileURLWithPath: "/tmp/" + name, isDirectory: true))
        }
        let short = Paths(home: URL(fileURLWithPath: "/tmp/px", isDirectory: true))
        XCTAssertNil(short.tooLongSocket)

        // The web sockets are checked first, so the one named is the HTTP socket itself.
        let long = home(httpSocketLength: 104)
        XCTAssertEqual(long.httpSocket.path.utf8.count, 104)
        XCTAssertEqual(long.tooLongSocket, long.httpSocket.path)

        // Every socket the web stack uses counts, the HTTPS socket and Caddy's admin socket included.
        let edge = home(httpSocketLength: 103)
        XCTAssertEqual(edge.tooLongSocket, edge.httpsSocket.path)

        XCTAssertEqual(Messages.socketPathTooLong(long.httpSocket.path),
                       "Paddock's folder path is too long for macOS sockets: \(long.httpSocket.path)")
    }

    func testSettingsDefaults() {
        XCTAssertEqual(Settings().httpPort, 80)
        XCTAssertEqual(Settings().dnsPort, 53535)
    }
}
