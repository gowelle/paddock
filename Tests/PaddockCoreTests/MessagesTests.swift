import XCTest
@testable import PaddockCore

final class MessagesTests: XCTestCase {
    func testPortsBlockedNamesCommandAndPid() {
        let holder = PortHolder(port: 80, pid: 123, command: "nginx", ownedByCurrentUser: true)
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 80 is in use by nginx (pid 123).")
    }

    func testPortsBlockedAddsKillHintOnlyForOthersProcesses() {
        let holder = PortHolder(port: 80, pid: 123, command: "nginx", ownedByCurrentUser: false)
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 80 is in use by nginx (pid 123).\nStop it with: sudo kill 123")
    }

    func testPortsBlockedWithUnknownHolder() {
        let holder = PortHolder(port: 443, pid: nil, command: nil, ownedByCurrentUser: false)
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 443 is in use by another program.")
    }

    func testPortsBlockedWithPidButNoCommand() {
        let holder = PortHolder(port: 80, pid: 9, command: nil, ownedByCurrentUser: true)
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 80 is in use by another program (pid 9).")
    }

    func testPortsBlockedWithTwoHolders() {
        let a = PortHolder(port: 80, pid: 1, command: "a", ownedByCurrentUser: true)
        let b = PortHolder(port: 443, pid: nil, command: nil, ownedByCurrentUser: false)
        XCTAssertEqual(Messages.portsBlocked([a, b]),
                       "Paddock can't start: port 80 is in use by a (pid 1); port 443 is in use by another program.")
    }

    func testSiteTableAlignsColumns() {
        let v = PHPVersion(major: 8, minor: 4)
        let sites = [
            Site(name: "a", path: "/a", kind: .parked, secured: false, php: v, pinned: false),
            Site(name: "longer", path: "/l", kind: .linked, secured: true, php: v, pinned: true),
        ]
        let lines = Messages.siteTable(sites).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "SITE    URL                  PHP  SECURED")
        XCTAssertEqual(lines[1], "a       http://a.test        8.4  no")
        XCTAssertEqual(lines[2], "longer  https://longer.test  8.4  yes")
    }

    func testHostStripsTLDAndNormalizes() {
        XCTAssertEqual(Messages.siteName("My App.test", tld: "test"), "my-app")
        XCTAssertEqual(Messages.siteName("myapp", tld: "test"), "myapp")
    }
}
