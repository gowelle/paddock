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

        let sockets = try XCTUnwrap(dict["Sockets"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(sockets.keys), ["http", "https"])
        for (name, port) in [("http", "80"), ("https", "443")] {
            let entries = try XCTUnwrap(sockets[name])
            XCTAssertEqual(entries.count, 2)
            for (entry, (node, family)) in zip(entries, [("127.0.0.1", "IPv4"), ("::1", "IPv6")]) {
                XCTAssertEqual(Set(entry.keys), ["SockNodeName", "SockServiceName", "SockFamily", "SockType",
                                                 "SockProtocol", "SockPassive"])
                XCTAssertEqual(entry["SockNodeName"] as? String, node)
                XCTAssertEqual(entry["SockServiceName"] as? String, port)
                XCTAssertEqual(entry["SockFamily"] as? String, family)
                XCTAssertEqual(entry["SockType"] as? String, "stream")
                XCTAssertEqual(entry["SockProtocol"] as? String, "TCP")
                XCTAssertEqual(entry["SockPassive"] as? Bool, true)
            }
        }
        let entries = sockets.values.flatMap { $0 }
        XCTAssertFalse(entries.contains { $0["SockNodeName"] == nil }, "no wildcard listener")
        XCTAssertTrue(entries.allSatisfy { ["127.0.0.1", "::1"].contains($0["SockNodeName"] as? String ?? "") })
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
        XCTAssertTrue(script.hasPrefix(Resolver.trapLine + "; LAUNCHCTL='/bin/launchctl'; CHOWN='/usr/sbin/chown'; "
            + "NC='/usr/bin/nc'; SHA256='/sbin/sha256'; MKTEMP='/usr/bin/mktemp'; BASE64='/usr/bin/base64'; "), script)
    }

    // MARK: - isInstalled

    private func placeInstalled(binary: Data? = nil, plist plistData: Data? = nil) throws {
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try (binary ?? Data(contentsOf: source)).write(to: installedBinary)
        try (plistData ?? helper().plistData()).write(to: plist)
    }

    func testFilesAreCurrentWhenBinaryAndPlistMatch() throws {
        try placeInstalled()
        XCTAssertTrue(helper().filesCurrent())
    }

    func testFilesAreNotCurrentWithADifferentBinary() throws {
        try placeInstalled(binary: Data("older helper".utf8))
        XCTAssertFalse(helper().filesCurrent())
    }

    func testFilesAreNotCurrentWithADifferentPlist() throws {
        try placeInstalled(plist: try helper(user: "someone-else").plistData())
        XCTAssertFalse(helper().filesCurrent())
    }

    func testFilesAreNotCurrentWhenEitherFileIsMissing() throws {
        XCTAssertFalse(helper().filesCurrent())
        try placeInstalled()
        try FileManager.default.removeItem(at: plist)
        XCTAssertFalse(helper().filesCurrent())
        try placeInstalled()
        try FileManager.default.removeItem(at: installedBinary)
        XCTAssertFalse(helper().filesCurrent())
    }

    private func launchd(loaded: Bool) -> RecordingCommandRunner {
        RecordingCommandRunner { _, _ in (loaded ? 0 : 113, "") }
    }

    func testInstalledNeedsCurrentFilesAndTheJobLoaded() throws {
        XCTAssertFalse(helper(launchd(loaded: true)).isInstalled(), "no files")
        XCTAssertFalse(helper(launchd(loaded: false)).isInstalled(), "no files, not loaded")
        try placeInstalled()
        XCTAssertTrue(helper(launchd(loaded: true)).isInstalled())
        XCTAssertFalse(helper(launchd(loaded: false)).isInstalled(), "a dead job: switched off or booted out")
        try placeInstalled(binary: Data("older helper".utf8))
        XCTAssertFalse(helper(launchd(loaded: true)).isInstalled(), "outdated binary")
    }

    func testServingNeedsInstalledAndAnAnswerOnTheHTTPPort() throws {
        try placeInstalled()
        let asked = LockedBox<[Int]>([])
        func answers(_ yes: Bool) -> (Int) -> Bool { { port in asked.value.append(port); return yes } }
        XCTAssertTrue(helper(launchd(loaded: true)).isServing(port: 80, accepts: answers(true)))
        XCTAssertEqual(asked.value, [80])
        XCTAssertFalse(helper(launchd(loaded: true)).isServing(port: 80, accepts: answers(false)),
                       "loaded but nothing answers (failed bind)")
        XCTAssertFalse(helper(launchd(loaded: false)).isServing(port: 80, accepts: answers(true)),
                       "something answers, but not Paddock's job")
        try FileManager.default.removeItem(at: plist)
        XCTAssertFalse(helper(launchd(loaded: true)).isServing(port: 80, accepts: answers(true)))
    }

    func testCachedCheckAnswersFromTheCacheAndRefreshesInTheBackground() throws {
        let calls = LockedBox(0)
        let answer = LockedBox(true)
        let check = CachedCheck(ttl: 0.2) { calls.value += 1; return answer.value }
        XCTAssertEqual(calls.value, 1, "worked out once when made")
        XCTAssertTrue(check.value)
        XCTAssertTrue(check.value)
        XCTAssertEqual(calls.value, 1, "no work within the ttl")
        answer.value = false
        Thread.sleep(forTimeInterval: 0.3)
        let began = Date()
        XCTAssertTrue(check.value, "a stale answer is returned at once")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.05)
        let deadline = Date().addingTimeInterval(2)
        while check.value && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(check.value, "refreshed in the background")
    }

    func testCachedCheckWithAnInitialAnswerDoesNoWorkUntilReadAndRefreshesOnRequest() throws {
        let calls = LockedBox(0)
        let answer = LockedBox(false)
        let check = CachedCheck(ttl: 60, initial: true) { calls.value += 1; return answer.value }
        XCTAssertEqual(calls.value, 0, "nothing worked out when made")
        XCTAssertTrue(check.value, "the initial answer stands until the real one is in")
        let deadline = Date().addingTimeInterval(2)
        while check.value && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(check.value, "the first read started working out the real answer")
        answer.value = true
        check.refresh()
        XCTAssertTrue(check.value, "refresh() replaces the answer at once, ttl or not")
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
        XCTAssertEqual(try Self.innerScript(ofAppleScript: Resolver.appleScript(shell: shell)), shell)
        XCTAssertFalse(shell.contains("\n"), "one line, like the resolver script")
    }

    func testFragmentsCarryNoEnvironmentLookups() throws {
        for script in [try helper().installScriptFragment(), helper().uninstallScriptFragment()] {
            XCTAssertFalse(script.contains("PATH"), script)
            XCTAssertFalse(script.contains("$HOME"), script)
        }
    }

    /// Undoes both quoting layers of `Resolver.appleScript(shell:)`: the AppleScript string literal, then
    /// the `env -i … /bin/sh -c '<script>'` single quotes. Fails unless the command has exactly that form.
    static func innerScript(ofAppleScript apple: String) throws -> String {
        let literalStart = try XCTUnwrap(apple.range(of: "do shell script \""))
        let literalEnd = try XCTUnwrap(apple.range(of: "\" with prompt", options: .backwards))
        let literal = String(apple[literalStart.upperBound..<literalEnd.lowerBound])
        // AppleScript: \\ -> \ and \" -> ", left to right.
        var command = ""
        var escaped = false
        for c in literal {
            if escaped { command.append(c); escaped = false } else if c == "\\" { escaped = true } else { command.append(c) }
        }
        let prefix = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '"
        XCTAssertTrue(command.hasPrefix(prefix), command)
        XCTAssertTrue(command.hasSuffix("'"), command)
        let quoted = String(command.dropFirst(prefix.count - 1))
        // Single-quoted shell word with ' written as '\'': the only other quote characters are in that form.
        let body = String(quoted.dropFirst().dropLast())
        XCTAssertEqual(Resolver.shellQuote(body.replacingOccurrences(of: "'\\''", with: "'")), quoted)
        return body.replacingOccurrences(of: "'\\''", with: "'")
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

    private func runShell(_ script: String, environment: [String: String] = [:]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = environment // by default nothing from this process's environment reaches the script
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
        XCTAssertTrue(result.out.contains("PADDOCK_FAILED_PORTS_INSTALL paddock-ports did not match its checksum"),
                      result.out)
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

    func testAJobThatWillNotUnloadOnUninstallReportsThePortRemovalStage() throws {
        try touch("loaded")
        try touch("sticky")
        let result = try runShell(helper().uninstallScriptFragment())
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("PADDOCK_FAILED_PORTS_REMOVAL app.paddock.ports is still loaded"), result.out)
    }

    // MARK: - A hostile environment never reaches the root shell

    /// Exported shell functions replacing `echo` and `printf`, and a Perl switch that kills any Perl script.
    private let hostile = [
        "BASH_FUNC_echo%%": "() {  /usr/bin/true; }",
        "BASH_FUNC_printf%%": "() {  /usr/bin/true; }",
        "PERL5OPT": "-e die",
        "PATH": "/usr/bin:/bin",
    ]

    func testTheHostileEnvironmentWouldHijackABareShell() throws {
        // Control: without the env -i layer the busy marker never gets printed.
        try touch("busy")
        let bare = try runShell(try helper().installScriptFragment(), environment: hostile)
        XCTAssertFalse(bare.out.contains(PortHelper.busyMarker), bare.out)
    }

    func testTheRootShellCommandIgnoresAHostileEnvironment() throws {
        try touch("busy")
        let busy = try runShell(Resolver.rootShellCommand(try helper().installScriptFragment()), environment: hostile)
        XCTAssertTrue(busy.out.contains(PortHelper.busyMarker), busy.out)
        try FileManager.default.removeItem(at: state.appendingPathComponent("busy"))

        let h = helper()
        let result = try runShell(Resolver.rootShellCommand(try h.installScriptFragment()), environment: hostile)
        XCTAssertEqual(result.status, 0, result.out)
        XCTAssertTrue(h.filesCurrent(), "helper written and verified, plist written")
        XCTAssertEqual(contents(helperDir), ["app.paddock.ports"])
    }

    // MARK: - An interrupted run leaves no temp files

    func testAnInterruptedInstallRemovesItsTempFiles() throws {
        // launchd takes its time to boot the old job out; the root shell is killed meanwhile.
        try touch("loaded")
        let s = Resolver.shellQuote(state.path)
        try writeStub("launchctl", """
            S=\(s)
            echo "launchctl $*" >> "$S/log"
            case "$1" in
              print) [ -f "$S/loaded" ] && exit 0; exit 113 ;;
              bootout) touch "$S/in-bootout"; /bin/sleep 1; rm -f "$S/loaded"; exit 0 ;;
            esac
            exit 0
            """)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try helper().installScriptFragment()]
        p.environment = [:]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: state.appendingPathComponent("in-bootout").path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(contents(helperDir).filter { $0.hasPrefix(".paddock.") }.count, 1, "staged helper")
        XCTAssertEqual(contents(daemonsDir).filter { $0.hasPrefix(".paddock.") }.count, 1, "staged plist")
        kill(p.processIdentifier, SIGTERM)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 130)
        XCTAssertEqual(contents(helperDir), [], "no temp file left")
        XCTAssertEqual(contents(daemonsDir), [])
    }
}
