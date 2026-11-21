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

    /// Herd's nginx: 4 worker pids on each of 80 and 443, all inside Herd.app.
    private func herdWorkers(owned: Bool = true) -> [PortHolder] {
        [80, 443].flatMap { port in
            (101...104).map { pid in
                PortHolder(port: port, pid: Int32(pid), command: "nginx-x86", ownedByCurrentUser: owned,
                           executablePath: "/Applications/Herd.app/Contents/Resources/nginx-x86")
            }
        }
    }

    func testOneAppHoldingBothPortsThroughEightPidsIsOneClause() {
        XCTAssertEqual(Messages.portsBlocked(herdWorkers()),
                       "Paddock can't start: ports 80 and 443 are in use by Herd.")
        // A known app gets no kill hint, even when its processes are someone else's.
        XCTAssertEqual(Messages.portsBlocked(herdWorkers(owned: false)),
                       "Paddock can't start: ports 80 and 443 are in use by Herd.")
    }

    func testOneCommandWithSeveralPidsIsOneClauseWithOneHintPerPid() {
        let holders = [80, 443].flatMap { port in
            [7, 8].map { PortHolder(port: port, pid: $0, command: "httpd", ownedByCurrentUser: false) }
        }
        XCTAssertEqual(Messages.portsBlocked(holders),
                       "Paddock can't start: ports 80 and 443 are in use by httpd.\nStop it with: sudo kill 7\nStop it with: sudo kill 8")
    }

    func testUnknownHoldersOfBothPortsAreOneClause() {
        let holders = [80, 443].map { PortHolder(port: $0, pid: nil, command: nil, ownedByCurrentUser: false) }
        XCTAssertEqual(Messages.portsBlocked(holders),
                       "Paddock can't start: ports 80 and 443 are in use by another program.")
    }

    func testCantStartLineNamesTheAppAndItsPorts() {
        XCTAssertEqual(Messages.cantStart(herdWorkers()), "Can't start: ports 80 and 443 in use by Herd")
        XCTAssertEqual(Messages.cantStart([PortHolder(port: 80, pid: 1, command: "nginx", ownedByCurrentUser: true)]),
                       "Can't start: port 80 in use by nginx")
    }

    func testPortsNotPermittedSentence() {
        XCTAssertEqual(Messages.portsNotPermitted([80]),
                       "Paddock can't listen on port 80 yet on this Mac. This is a known limitation being worked on.")
        XCTAssertEqual(Messages.portsNotPermitted([80, 443]),
                       "Paddock can't listen on ports 80 and 443 yet on this Mac. This is a known limitation being worked on.")
    }

    func testEnclosingAppIsTheOutermostAppFolder() {
        let herd = PortHolder.enclosingApp(ofExecutable: "/Applications/Herd.app/Contents/Resources/nginx-x86")
        XCTAssertEqual(herd?.path, "/Applications/Herd.app")
        XCTAssertEqual(herd?.name, "Herd")
        let nested = PortHolder.enclosingApp(
            ofExecutable: "/Applications/My Tool.app/Contents/Frameworks/Helper.app/Contents/MacOS/helper")
        XCTAssertEqual(nested?.path, "/Applications/My Tool.app")
        XCTAssertEqual(nested?.name, "My Tool")
        XCTAssertNil(PortHolder.enclosingApp(ofExecutable: "/usr/sbin/httpd"))
        XCTAssertNil(PortHolder.enclosingApp(ofExecutable: "/opt/thing.app"), "the program itself is not an app folder")

        let holder = PortHolder(port: 80, pid: 1, command: "nginx", ownedByCurrentUser: true,
                                executablePath: "/Applications/Herd.app/Contents/Resources/nginx-x86")
        XCTAssertEqual(holder.appBundlePath, "/Applications/Herd.app")
        XCTAssertEqual(holder.appName, "Herd")
        XCTAssertNil(PortHolder(port: 80, pid: 1, command: "nginx", ownedByCurrentUser: true).appName)
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
