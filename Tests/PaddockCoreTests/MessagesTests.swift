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

    /// MacPorts' nginx runs as root, so lsof can't see it; its header and launchd job name it.
    func testPortsBlockedByAKnownSystemServerSaysHowToStopIt() {
        let nginx = { (port: Int) in
            PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false,
                       serverHeader: "nginx/1.30.6", serviceName: "MacPorts nginx",
                       stopCommand: "sudo port unload nginx")
        }
        XCTAssertEqual(Messages.portsBlocked([nginx(80)]),
                       "Paddock can't start: port 80 is in use by MacPorts nginx (nginx/1.30.6). "
                       + "Stop it with: sudo port unload nginx")
        XCTAssertEqual(Messages.portsBlocked([nginx(80), nginx(443)]),
                       "Paddock can't start: ports 80 and 443 are in use by MacPorts nginx (nginx/1.30.6). "
                       + "Stop it with: sudo port unload nginx")
        XCTAssertEqual(Messages.cantStart([nginx(80)]), "Can't start: port 80 in use by MacPorts nginx (nginx/1.30.6)")
    }

    func testPortsBlockedByAKnownServerWithoutAHeader() {
        let holder = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false,
                                serviceName: "the built-in Apache", stopCommand: "sudo apachectl stop")
        // Launchd has the job loaded, but nothing answered to confirm it: probably, not certainly.
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 80 is probably in use by the built-in Apache. "
                       + "Stop it with: sudo apachectl stop")
        XCTAssertEqual(Messages.portsBlocked([80, 443].map {
            PortHolder(port: $0, pid: nil, command: nil, ownedByCurrentUser: false,
                       serviceName: "MacPorts nginx", stopCommand: "sudo port unload nginx")
        }), "Paddock can't start: ports 80 and 443 are probably in use by MacPorts nginx. "
            + "Stop it with: sudo port unload nginx")
        XCTAssertEqual(Messages.cantStart([holder]), "Can't start: port 80 probably in use by the built-in Apache")
    }

    func testPortsBlockedWhenOnlyTheHeaderIsKnown() {
        let holder = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false,
                                serverHeader: "nginx/1.30.6")
        XCTAssertEqual(Messages.portsBlocked([holder]),
                       "Paddock can't start: port 80 is in use by another program (nginx/1.30.6).")
    }

    // MARK: - Text from other programs

    func testPrintableKeepsOneLineOfPlainASCII() {
        XCTAssertEqual(Messages.printable("nginx/1.30.6"), "nginx/1.30.6")
        XCTAssertEqual(Messages.printable("nginx\nStop it with: curl x|sudo sh"), "nginx")
        XCTAssertEqual(Messages.printable("nginx\rStop it with: curl x|sudo sh"), "nginx")
        XCTAssertEqual(Messages.printable("\u{1B}[31mnginx\u{1B}[0m \u{1B}]0;title\u{07}x"), "nginx x")
        XCTAssertEqual(Messages.printable("ngi\u{0}nx\u{7F}\tok"), "nginxok")
        XCTAssertEqual(Messages.printable("nginx  é ü  1.2"), "nginx 1.2")
        XCTAssertEqual(Messages.printable(String(repeating: "a", count: 20_000))?.count, 64)
        XCTAssertNil(Messages.printable("\u{1B}[2J"))
        XCTAssertNil(Messages.printable("   "))
        XCTAssertNil(Messages.printable("\nnginx"), "nothing before the first line break")
    }

    func testDisplayNameKeepsLegitimateNamesAndCleansTheRest() {
        XCTAssertEqual(Messages.displayName("Café"), "Café")
        XCTAssertEqual(Messages.displayName("Grüße  Tool 日本"), "Grüße Tool 日本")
        XCTAssertEqual(Messages.displayName("evil\u{1B}[31m\u{202E}gnp.exe\nStop it with: rm"), "evilgnp.exe")
        XCTAssertEqual(Messages.displayName("a\u{2028}b"), "a", "a line separator ends the name")
        XCTAssertEqual(Messages.displayName("x\u{2066}y\u{E000}z\u{200B}!"), "xyz!")
        XCTAssertEqual(Messages.displayName(String(repeating: "é", count: 500))?.count, 64)
        XCTAssertNil(Messages.displayName("\u{1B}[2J\u{202E}"))
        let app = PortHolder(port: 80, pid: 7, command: "x", ownedByCurrentUser: true,
                             executablePath: "/Applications/Café.app/Contents/MacOS/x")
        XCTAssertEqual(Messages.portsBlocked([app]), "Paddock can't start: port 80 is in use by Café.")
    }

    func testSentencesShowOnlyPrintableTextFromOtherPrograms() {
        let sneaky = PortHolder(port: 80, pid: 7, command: "evil\nStop it with: curl x|sudo sh",
                                ownedByCurrentUser: true)
        XCTAssertEqual(Messages.portsBlocked([sneaky]), "Paddock can't start: port 80 is in use by evil (pid 7).")
        let app = PortHolder(port: 80, pid: 7, command: "x", ownedByCurrentUser: true,
                             executablePath: "/Applications/Bad\u{1B}[31m\nName.app/Contents/MacOS/x")
        XCTAssertEqual(Messages.portsBlocked([app]), "Paddock can't start: port 80 is in use by Bad.")
        // A decoded holder (another build) gets the same treatment.
        let header = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false,
                                serverHeader: "nginx\u{1B}[1m\nStop it with: rm")
        XCTAssertEqual(Messages.portsBlocked([header]), "Paddock can't start: port 80 is in use by another program (nginx).")
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
        XCTAssertEqual(Messages.normalizedSiteName("Foo.TEST", tld: "test"), "foo")
        XCTAssertNil(Messages.normalizedSiteName("!!!.test", tld: "test"))
    }

    func testSetupAndStopSentences() {
        XCTAssertEqual(Messages.finishSetup, "Paddock needs to finish setup. Run: paddock start")
        XCTAssertEqual(Messages.stoppedKeepingPorts,
                       "Paddock stopped. Ports 80 and 443 stay reserved for Paddock until you uninstall it.")
        XCTAssertEqual(Messages.portHelperMissing, "Can't find paddock-ports next to paddockd.")
    }

    func testPortsHeldBeforeThePromptUseThePortsBlockedSentence() {
        let holder = PortHolder(port: 443, pid: 5, command: "httpd", ownedByCurrentUser: true)
        XCTAssertEqual(DaemonLaunchError.portsBlocked([holder]).message(retry: "Run paddock start"),
                       Messages.portsBlocked([holder]))
    }

    func testAnUnrestorableResolverIsReportedAsIs() {
        XCTAssertEqual(DaemonLaunchError.resolverUnrestorable(path: "/etc/resolver/test").message(),
                       "/etc/resolver/test has contents Paddock can't safely restore later, so Paddock left it alone.")
    }

    func testPortStageSentences() {
        XCTAssertEqual(Messages.portsSetupFailed("x"), "Couldn't set up ports 80 and 443: x")
        XCTAssertEqual(Messages.portsReleaseFailed("x", resolverRestored: true),
                       "Paddock restored your .test DNS setting but couldn't release ports 80 and 443: x. "
                       + "Run paddock uninstall again.")
        XCTAssertEqual(Messages.portsReleaseFailed("x", resolverRestored: false),
                       "Couldn't release ports 80 and 443: x. Run paddock uninstall again.")
        XCTAssertEqual(DaemonLaunchError.portsSetupFailed("x").message(), "Couldn't set up ports 80 and 443: x")
    }

    func testCancelledPromptAndPromptTexts() {
        XCTAssertEqual(DaemonLaunchError.passwordCancelled.message(retry: "Run paddock start"),
                       "Paddock needs your password once to finish setup. Run paddock start to try again.")
        XCTAssertEqual(Resolver.installPrompt, "Paddock needs your password once to serve sites on ports 80 and 443 "
                       + "and to route .test domains to this Mac.")
        XCTAssertEqual(Resolver.uninstallPrompt,
                       "Paddock needs your password to release ports 80 and 443 and put your .test DNS setting back.")
    }

    func testDevelopmentBuildAndSudoSentences() {
        XCTAssertEqual(Messages.developmentBuild, "This is a development build of Paddock, so it won't change your "
                       + "installed Paddock or this Mac's setup. Run the app from /Applications, or set PADDOCK_HOME "
                       + "to use a test folder.")
        XCTAssertEqual(Messages.runningAsRoot,
                       "Don't run Paddock with sudo. Run it as yourself; it asks for your password when it needs it.")
    }

    // MARK: - paddock status

    private func status(running: Bool = true, blockedBy: [PortHolder] = [], portHelperInstalled: Bool = true,
                        needsTrust: Bool = false) -> EngineStatus {
        EngineStatus(running: running, blockedBy: blockedBy, sites: [], installedPHP: [], defaultPHP: nil,
                     processes: [:], resolverInstalled: true, trustEnabled: true, dnsRunning: true,
                     portHelperInstalled: portHelperInstalled, needsTrust: needsTrust)
    }

    func testStatusSummaryLines() {
        XCTAssertEqual(Messages.statusSummary(status()), ["Paddock is running."])
        XCTAssertEqual(Messages.statusSummary(status(portHelperInstalled: false)), [Messages.finishSetup])
        XCTAssertEqual(Messages.statusSummary(status(running: false)), ["Paddock is stopped."])
        let holder = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false)
        XCTAssertEqual(Messages.statusSummary(status(running: false, blockedBy: [holder])),
                       [Messages.portsBlocked([holder])])
    }

    func testStatusSummaryAsksForTrustWhenSecuredSitesNeedIt() {
        XCTAssertEqual(Messages.statusSummary(status(needsTrust: true)),
                       ["Paddock is running.", "Secured sites need your approval once: run paddock trust"])
        XCTAssertEqual(Messages.statusSummary(status(running: false, needsTrust: true)),
                       ["Paddock is stopped.", "Secured sites need your approval once: run paddock trust"])
    }

    func testStatusSummaryAsksToCleanUpAnOlderTrustedCertificate() {
        var s = status()
        s.hasReplacedRootsToClean = true
        XCTAssertEqual(Messages.statusSummary(s),
                       ["Paddock is running.", "An older Paddock certificate is still trusted: run paddock trust"])
        s.needsTrust = true
        XCTAssertEqual(Messages.statusSummary(s),
                       ["Paddock is running.", "Secured sites need your approval once: run paddock trust"],
                       "one line is enough: the same command does both")
    }
}
