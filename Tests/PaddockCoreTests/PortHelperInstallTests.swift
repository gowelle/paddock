import CryptoKit
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The launchd entry for ports 80/443 and the privileged script fragments that install and remove it.
/// Everything runs against temp files: the generated scripts run as the current user under `/bin/sh`, with
/// `launchctl`, `chown` and `nc` replaced by stub scripts and the destinations in a temp directory.
final class PortHelperInstallTests: XCTestCase {
    private var dir: URL!
    private var paths: Paths!
    private var source: URL!
    private var stubs: URL!
    private var state: URL!
    private var helperDir: URL!
    private var daemonsDir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(home: dir.appendingPathComponent("Library/Application Support/Paddock", isDirectory: true))
        source = dir.appendingPathComponent("bundle/paddock-ports")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Arbitrary bytes, including every byte value, standing in for the bundled helper.
        try Data((0..<4096).map { UInt8($0 % 256) }).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        stubs = dir.appendingPathComponent("stubs", isDirectory: true)
        state = dir.appendingPathComponent("state", isDirectory: true)
        helperDir = dir.appendingPathComponent("Library/PrivilegedHelperTools", isDirectory: true)
        daemonsDir = dir.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        for d in [stubs!, state!, daemonsDir!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try writeStubs()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var installedBinary: URL { helperDir.appendingPathComponent("app.paddock.ports") }
    private var plist: URL { daemonsDir.appendingPathComponent("app.paddock.ports.plist") }

    private func helper(_ runner: CommandRunner = RecordingCommandRunner(), user: String = "someone",
                        binary: URL? = nil, plist: URL? = nil) -> PortHelper {
        PortHelper(source: source, user: user, paths: paths, runner: runner,
                   installedBinary: binary ?? installedBinary, plist: plist ?? self.plist,
                   tools: .init(launchctl: stubs.appendingPathComponent("launchctl").path,
                                chown: stubs.appendingPathComponent("chown").path,
                                nc: stubs.appendingPathComponent("nc").path,
                                unloadPolls: 5))
    }

    // MARK: - The launchd property list

    func testPlistHasExactlyTheExpectedKeysAndLoopbackSockets() throws {
        let data = try helper(user: "jo").plistData()
        let dict = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(Set(dict.keys), ["Label", "ProgramArguments", "UserName", "Sockets", "ProcessType"])
        XCTAssertEqual(dict["Label"] as? String, "app.paddock.ports")
        XCTAssertEqual(dict["ProgramArguments"] as? [String],
                       [installedBinary.path, "launchd", paths.httpSocket.path, paths.httpsSocket.path])
        XCTAssertEqual(dict["UserName"] as? String, "jo")
        XCTAssertEqual(dict["ProcessType"] as? String, "Interactive")
        XCTAssertNil(dict["RunAtLoad"])
        XCTAssertNil(dict["KeepAlive"])

        let sockets = try XCTUnwrap(dict["Sockets"] as? [String: [[String: String]]])
        XCTAssertEqual(Set(sockets.keys), ["http", "https"])
        XCTAssertEqual(sockets["http"], [["SockNodeName": "127.0.0.1", "SockServiceName": "80"],
                                         ["SockNodeName": "::1", "SockServiceName": "80"]])
        XCTAssertEqual(sockets["https"], [["SockNodeName": "127.0.0.1", "SockServiceName": "443"],
                                          ["SockNodeName": "::1", "SockServiceName": "443"]])
        let entries = sockets.values.flatMap { $0 }
        XCTAssertFalse(entries.contains { $0["SockNodeName"] == nil }, "no wildcard listener")
        XCTAssertTrue(entries.allSatisfy { ["127.0.0.1", "::1"].contains($0["SockNodeName"]!) })
    }

    func testPlistDataIsStable() throws {
        XCTAssertEqual(try helper().plistData(), try helper().plistData())
    }

    func testTheRealDefaultsAreTheSystemLocations() {
        XCTAssertEqual(PortHelper.defaultInstalledBinary.path, "/Library/PrivilegedHelperTools/app.paddock.ports")
        XCTAssertEqual(PortHelper.defaultPlist.path, "/Library/LaunchDaemons/app.paddock.ports.plist")
        let real = PortHelper(source: source, user: "someone", paths: paths, runner: RecordingCommandRunner())
        XCTAssertEqual(real.installedBinary, PortHelper.defaultInstalledBinary)
        XCTAssertEqual(real.plist, PortHelper.defaultPlist)
        let script = real.uninstallScriptFragment()
        XCTAssertTrue(script.hasPrefix("LAUNCHCTL='/bin/launchctl'; CHOWN='/usr/sbin/chown'; NC='/usr/bin/nc'; "
            + "SHASUM='/usr/bin/shasum'; MKTEMP='/usr/bin/mktemp'; BASE64='/usr/bin/base64'; "), script)
    }

    // MARK: - isInstalled

    private func placeInstalled(binary: Data? = nil, plist plistData: Data? = nil) throws {
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try (binary ?? Data(contentsOf: source)).write(to: installedBinary)
        try (plistData ?? helper().plistData()).write(to: plist)
    }

    func testIsInstalledWhenBinaryAndPlistMatch() throws {
        try placeInstalled()
        XCTAssertTrue(helper().isInstalled())
    }

    func testIsNotInstalledWithADifferentBinary() throws {
        try placeInstalled(binary: Data("older helper".utf8))
        XCTAssertFalse(helper().isInstalled())
    }

    func testIsNotInstalledWithADifferentPlist() throws {
        try placeInstalled(plist: try helper(user: "someone-else").plistData())
        XCTAssertFalse(helper().isInstalled())
    }

    func testIsNotInstalledWhenEitherFileIsMissing() throws {
        XCTAssertFalse(helper().isInstalled())
        try placeInstalled()
        try FileManager.default.removeItem(at: plist)
        XCTAssertFalse(helper().isInstalled())
        try placeInstalled()
        try FileManager.default.removeItem(at: installedBinary)
        XCTAssertFalse(helper().isInstalled())
    }

    func testIsLoadedAsksLaunchdReadOnly() {
        let runner = RecordingCommandRunner { _, _ in (0, "") }
        XCTAssertTrue(PortHelper(source: source, user: "x", paths: paths, runner: runner).isLoaded())
        XCTAssertEqual(runner.calls, [.init(executable: "/bin/launchctl", arguments: ["print", "system/app.paddock.ports"])])
        let notLoaded = RecordingCommandRunner { _, _ in (113, "Could not find service") }
        XCTAssertFalse(PortHelper(source: source, user: "x", paths: paths, runner: notLoaded).isLoaded())
    }

    // MARK: - Quoting

    func testInstallFragmentForHostilePathsIsQuotedForShellThenAppleScript() throws {
        let odd = dir.appendingPathComponent("it's a \"dir\" $(x) `y`", isDirectory: true)
        let h = helper(binary: odd.appendingPathComponent("helper\\bin"), plist: odd.appendingPathComponent("p.plist"))
        let shell = try h.installScriptFragment()
        XCTAssertTrue(shell.contains("HB=" + Resolver.shellQuote(odd.appendingPathComponent("helper\\bin").path) + ";"),
                      "single-quoted with ' written as '\\''")
        let apple = Resolver.appleScript(shell: shell)
        let literalStart = try XCTUnwrap(apple.range(of: "do shell script \""))
        let literalEnd = try XCTUnwrap(apple.range(of: "\" with prompt", options: .backwards))
        let literal = String(apple[literalStart.upperBound..<literalEnd.lowerBound])
        let unescaped = literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        XCTAssertEqual(unescaped, shell)
        XCTAssertFalse(shell.contains("\n"), "one line, like the resolver script")
    }

    func testFragmentsCarryNoEnvironmentLookups() throws {
        for script in [try helper().installScriptFragment(), helper().uninstallScriptFragment()] {
            XCTAssertFalse(script.contains("PATH"), script)
            XCTAssertFalse(script.contains("$HOME"), script)
        }
    }

    // MARK: - The generated scripts, run as the current user against temp directories

    private func writeStub(_ name: String, _ body: String) throws {
        let url = stubs.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A launchd that keeps whether the job is loaded in `state/loaded`; `state/bootstrap-fails` makes
    /// bootstrap fail and `state/sticky` keeps the job loaded through bootout. `nc` "connects" while
    /// `state/busy` exists. Every call is logged.
    private func writeStubs() throws {
        let s = Resolver.shellQuote(state.path)
        try writeStub("launchctl", """
            S=\(s)
            echo "launchctl $*" >> "$S/log"
            case "$1" in
              print) [ -f "$S/loaded" ] && exit 0; exit 113 ;;
              bootout) [ -f "$S/sticky" ] || rm -f "$S/loaded"; exit 0 ;;
              bootstrap) [ -f "$S/bootstrap-fails" ] && exit 5; touch "$S/loaded"; exit 0 ;;
            esac
            exit 1
            """)
        try writeStub("chown", "echo \"chown $*\" >> \(s)/log")
        try writeStub("nc", "echo \"nc $*\" >> \(s)/log\n[ -f \(s)/busy ]")
    }

    private func touch(_ name: String) throws {
        try Data().write(to: state.appendingPathComponent(name))
    }

    private var log: [String] {
        ((try? String(contentsOf: state.appendingPathComponent("log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func runShell(_ script: String) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = [:] // nothing from this process's environment reaches the script
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private func contents(_ d: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted()
    }

    func testInstallScriptPlacesBothFilesWithModesThenBootstraps() throws {
        let h = helper()
        let result = try runShell(try h.installScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertFalse(result.out.contains(PortHelper.busyMarker), result.out)

        XCTAssertEqual(try Data(contentsOf: installedBinary), try Data(contentsOf: source))
        XCTAssertEqual(try mode(installedBinary), 0o755)
        XCTAssertEqual(try Data(contentsOf: plist), try h.plistData())
        XCTAssertEqual(try mode(plist), 0o644)
        XCTAssertEqual(try mode(helperDir), 0o755, "created with mode 755")
        XCTAssertEqual(contents(helperDir), ["app.paddock.ports"], "no temp files left")
        XCTAssertEqual(contents(daemonsDir), ["app.paddock.ports.plist"])
        XCTAssertTrue(h.isInstalled())

        let calls = log
        XCTAssertTrue(calls.contains("chown root:wheel \(helperDir.path)"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("chown root:wheel \(helperDir.path)/.paddock.") }, "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("chown root:wheel \(daemonsDir.path)/.paddock.") }, "\(calls)")
        let launchctl = calls.filter { $0.hasPrefix("launchctl ") }
        XCTAssertEqual(launchctl.first, "launchctl print system/app.paddock.ports", "own job checked before the ports")
        XCTAssertTrue(launchctl.contains("launchctl bootout system/app.paddock.ports"), "\(launchctl)")
        XCTAssertEqual(launchctl.last, "launchctl bootstrap system \(plist.path)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("nc ") }, [
            "nc -z -G 1 127.0.0.1 80", "nc -z -G 1 ::1 80", "nc -z -G 1 127.0.0.1 443", "nc -z -G 1 ::1 443",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("loaded").path))
    }

    func testInstallScriptWorksWithHostilePaths() throws {
        let odd = dir.appendingPathComponent("it's a \"dir\" $(touch pwned) `x`", isDirectory: true)
        try FileManager.default.createDirectory(at: odd.appendingPathComponent("daemons"), withIntermediateDirectories: true)
        let binary = odd.appendingPathComponent("tools/helper bin")
        let plistURL = odd.appendingPathComponent("daemons/p.plist")
        let h = helper(binary: binary, plist: plistURL)
        let result = try runShell(try h.installScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertEqual(try Data(contentsOf: binary), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: plistURL), try h.plistData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
        let removed = try runShell(h.uninstallScriptFragment())
        XCTAssertEqual(removed.status, 0, removed.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: binary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testChecksumMismatchAbortsAndLeavesNothing() throws {
        let h = helper()
        let script = try h.installScriptFragment()
        let real = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(script.contains("'\(real)'"), "the expected hash is embedded")
        let tampered = script.replacingOccurrences(of: real, with: String(repeating: "0", count: 64))
        let result = try runShell(tampered)
        XCTAssertNotEqual(result.status, 0, result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(contents(helperDir), [], "temp file removed")
        XCTAssertEqual(contents(daemonsDir), [])
        XCTAssertFalse(log.contains { $0.hasPrefix("launchctl bootstrap") || $0.hasPrefix("launchctl bootout") }, "\(log)")
    }

    func testBusyPortPrintsTheMarkerAndChangesNothing() throws {
        try touch("busy")
        let result = try runShell(try helper().installScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertTrue(result.out.contains(PortHelper.busyMarker), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperDir.path), "not even the directory")
        XCTAssertEqual(contents(daemonsDir), [])
        XCTAssertEqual(log.filter { $0.hasPrefix("launchctl") }, ["launchctl print system/app.paddock.ports"])
        XCTAssertFalse(log.contains { $0.hasPrefix("chown") })
    }

    func testBusyMarkerStopsTheRestOfAComposedScript() throws {
        try touch("busy")
        let resolverFile = dir.appendingPathComponent("resolver/test")
        let script = try helper().installScriptFragment() + "; "
            + Resolver.guardedScript(destination: resolverFile, expected: nil, action: .write("nameserver 127.0.0.1\n"))
        let result = try runShell(script)
        XCTAssertTrue(result.out.contains(PortHelper.busyMarker), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolverFile.path), "the resolver is not touched")
    }

    func testPaddocksOwnLoadedJobHoldingThePortsIsReplaced() throws {
        try touch("busy")
        try touch("loaded")
        let h = helper()
        let result = try runShell(try h.installScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertFalse(result.out.contains(PortHelper.busyMarker), result.out)
        XCTAssertFalse(log.contains { $0.hasPrefix("nc ") }, "no port probe for Paddock's own job: \(log)")
        XCTAssertTrue(h.isInstalled())
        let launchctl = log.filter { $0.hasPrefix("launchctl ") }
        let bootout = try XCTUnwrap(launchctl.firstIndex(of: "launchctl bootout system/app.paddock.ports"))
        let bootstrap = try XCTUnwrap(launchctl.firstIndex(of: "launchctl bootstrap system \(plist.path)"))
        XCTAssertLessThan(bootout, bootstrap)
    }

    func testAJobThatWillNotUnloadAbortsAndLeavesNothingNew() throws {
        try touch("loaded")
        try touch("sticky")
        let result = try runShell(try helper().installScriptFragment())
        XCTAssertNotEqual(result.status, 0, result.out)
        XCTAssertEqual(contents(helperDir), [])
        XCTAssertEqual(contents(daemonsDir), [])
        XCTAssertFalse(log.contains { $0.hasPrefix("launchctl bootstrap") })
    }

    func testFailedBootstrapRemovesWhatThisRunCreated() throws {
        try touch("bootstrap-fails")
        let result = try runShell(try helper().installScriptFragment())
        XCTAssertNotEqual(result.status, 0, result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(contents(daemonsDir), [])
        XCTAssertEqual(log.filter { $0.hasPrefix("launchctl bootstrap") }.count, 2, "tried once more: \(log)")
    }

    func testFailedPortStepsNeverReachAComposedResolverStep() throws {
        try touch("bootstrap-fails")
        let resolverFile = dir.appendingPathComponent("resolver/test")
        let script = try helper().installScriptFragment() + "; "
            + Resolver.guardedScript(destination: resolverFile, expected: nil, action: .write("nameserver 127.0.0.1\n"))
        XCTAssertNotEqual(try runShell(script).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolverFile.path))
    }

    func testUninstallScriptBootsOutAndRemovesBothFiles() throws {
        let h = helper()
        XCTAssertEqual(try runShell(try h.installScriptFragment()).status, 0)
        let result = try runShell(h.uninstallScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("loaded").path))
        XCTAssertEqual(log.filter { $0.hasPrefix("launchctl") }.suffix(2),
                       ["launchctl bootout system/app.paddock.ports", "launchctl print system/app.paddock.ports"])
    }

    func testUninstallScriptWithNothingInstalledSucceeds() throws {
        let result = try runShell(helper().uninstallScriptFragment())
        XCTAssertEqual(result.status, 0, result.out)
    }

    func testUninstallScriptRunsAfterAResolverStepThatFoundTheFileChanged() throws {
        let h = helper()
        XCTAssertEqual(try runShell(try h.installScriptFragment()).status, 0)
        let resolverFile = dir.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "someone else's\n".write(to: resolverFile, atomically: true, encoding: .utf8)
        let script = Resolver.guardedScript(destination: resolverFile, expected: "nameserver 127.0.0.1\nport 53535\n",
                                            action: .write("nameserver 10.0.0.1\n"))
            + "; " + h.uninstallScriptFragment()
        let result = try runShell(script)
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertTrue(result.out.contains(Resolver.changedMarker), result.out)
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "someone else's\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }

    func testUninstallScriptRunsAfterAResolverRestore() throws {
        let h = helper()
        XCTAssertEqual(try runShell(try h.installScriptFragment()).status, 0)
        let resolverFile = dir.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nameserver 127.0.0.1\nport 53535\n".write(to: resolverFile, atomically: true, encoding: .utf8)
        let script = Resolver.guardedScript(destination: resolverFile, expected: "nameserver 127.0.0.1\nport 53535\n",
                                            action: .write("nameserver 10.0.0.1\n"))
            + "; " + h.uninstallScriptFragment()
        let result = try runShell(script)
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertEqual(try String(contentsOf: resolverFile, encoding: .utf8), "nameserver 10.0.0.1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
    }
}
