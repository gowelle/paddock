import Darwin
import XCTest
@testable import PaddockCore

/// Launches the built `paddockd` binary with a throwaway PADDOCK_HOME and high ports.
/// Never launch it without the port variables: the owner's Herd holds 80/443.
final class DaemonTests: XCTestCase {
    private var home: TestHome!
    private var client: PaddockClient!
    private var daemon: Process?
    private var observedGroups: Set<Int32> = []
    private var holder: Int32?

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TestHome()
        client = PaddockClient(paths: home.paths)
    }

    override func tearDown() {
        // Remember the children's process groups while the daemon still answers.
        recordGroups()
        if let daemon, daemon.isRunning {
            kill(daemon.processIdentifier, SIGTERM)
            if !waitForExit(daemon, timeout: 15) {
                kill(daemon.processIdentifier, SIGKILL)
                daemon.waitUntilExit()
            }
        }
        // Only groups this test's daemon created: sweep any survivors, then check.
        for group in observedGroups where ((try? TestSupport.pgrep(group: group)) ?? []).isEmpty == false {
            kill(-group, SIGKILL)
            XCTFail("process group \(group) outlived the daemon")
        }
        if let holder { close(holder) }
        home?.cleanUp()
    }

    // MARK: - Tests

    func testParkLinkIsolateSecureAndSiteList() throws {
        try launchDaemon()
        try waitUntilRunning()
        XCTAssertEqual(try ok(.status).sites.map(\.name), ["laravel-like", "plain-php"])

        let more = try home.makeDirectory("more")
        try FileManager.default.createDirectory(at: more.appendingPathComponent("extra-site"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(try ok(.park(path: more.path)).sites.map(\.name),
                       ["extra-site", "laravel-like", "plain-php"])

        let app = try home.makeDirectory("wherever")
        let linked = try ok(.link(name: "Pretty App", path: app.path))
        XCTAssertEqual(linked.sites.map(\.name), ["extra-site", "laravel-like", "plain-php", "pretty-app"])

        XCTAssertEqual(errorCode(try client.send(.isolate(site: "plain-php", version: PHPVersion("8.4")!))),
                       "php_not_installed")
        XCTAssertEqual(try ok(.status).sites.first { $0.name == "plain-php" }?.pinned, false)

        XCTAssertEqual(errorCode(try client.send(.secure(site: "nope"))), "unknown_site")
        XCTAssertEqual(try ok(.status).sites.map(\.name),
                       ["extra-site", "laravel-like", "plain-php", "pretty-app"])

        let secured = try ok(.secure(site: "plain-php"))
        XCTAssertEqual(secured.sites.first { $0.name == "plain-php" }?.secured, true)
        XCTAssertTrue(secured.running)

        XCTAssertEqual(try ok(.unlink(name: "pretty-app")).sites.map(\.name),
                       ["extra-site", "laravel-like", "plain-php"])
        XCTAssertEqual(try ok(.forget(path: more.path)).sites.map(\.name), ["laravel-like", "plain-php"])
        XCTAssertEqual(errorCode(try client.send(.park(path: "/no/such/dir"))), "not_a_directory")
    }

    func testStatusNamesPortHolder() throws {
        holder = try TestSupport.listen(port: home.settings.httpPort)
        try launchDaemon()
        try waitUntil("daemon reports the blocked port") {
            guard case .ok(let s) = try client.send(.status) else { return false }
            return !s.blockedBy.isEmpty
        }
        let status = try ok(.status)
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.blockedBy.first?.port, home.settings.httpPort)
        XCTAssertEqual(status.blockedBy.first?.pid, getpid())
        XCTAssertTrue(status.dnsRunning, "the daemon answers .test while the web ports are blocked")
        XCTAssertEqual(try TestSupport.dig("blocked.test", port: home.settings.dnsPort), "127.0.0.1")

        // State changes still work, and an explicit start explains the problem.
        let more = try home.makeDirectory("more")
        let parked = try ok(.park(path: more.path))
        XCTAssertFalse(parked.running)
        XCTAssertEqual(parked.blockedBy.first?.pid, getpid())
        guard case .error(let code, _) = try client.send(.start) else { return XCTFail("expected ports_blocked") }
        XCTAssertEqual(code, "ports_blocked")
    }

    func testStopKeepsDaemonAnsweringAndStartResumes() throws {
        try launchDaemon()
        try waitUntilRunning()
        recordGroups()
        XCTAssertFalse(try ok(.stop).running)
        XCTAssertTrue(try XCTUnwrap(daemon).isRunning)
        XCTAssertFalse(try ok(.status).running)
        for group in observedGroups {
            XCTAssertEqual(try TestSupport.pgrep(group: group), [], "group \(group) survived stop")
        }
        XCTAssertTrue(try ok(.start).running)
        XCTAssertTrue(try ok(.restart).running)
    }

    func testShutdownRepliesThenDaemonExitsCleanly() throws {
        try launchDaemon()
        try waitUntilRunning()
        recordGroups()
        XCTAssertFalse(try ok(.shutdown).running)
        let daemon = try XCTUnwrap(self.daemon)
        XCTAssertTrue(waitForExit(daemon, timeout: 15), "daemon did not exit after shutdown")
        XCTAssertEqual(daemon.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.daemonSocket.path))
        XCTAssertFalse(client.daemonIsRunning)
        for group in observedGroups {
            XCTAssertEqual(try TestSupport.pgrep(group: group), [], "group \(group) survived shutdown")
        }
    }

    func testSigtermStopsEngineAndRemovesSocket() throws {
        try launchDaemon()
        try waitUntilRunning()
        recordGroups()
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGTERM)
        XCTAssertTrue(waitForExit(daemon, timeout: 15), "daemon ignored SIGTERM")
        XCTAssertEqual(daemon.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.daemonSocket.path))
        for group in observedGroups {
            XCTAssertEqual(try TestSupport.pgrep(group: group), [], "group \(group) survived SIGTERM")
        }
    }

    func testSecondInstanceExitsZeroWhileFirstAnswers() throws {
        try launchDaemon()
        try waitUntilRunning()
        let second = try makeDaemonProcess(log: "second.log")
        try second.run()
        XCTAssertTrue(waitForExit(second, timeout: 15), "second daemon kept running")
        XCTAssertEqual(second.terminationStatus, 0)
        // The first daemon is untouched.
        XCTAssertTrue(try ok(.status).running)
        XCTAssertTrue(try XCTUnwrap(daemon).isRunning)
    }

    func testStaleSocketFromDeadDaemonIsReplaced() throws {
        try home.paths.ensureDirectories()
        // A dead daemon's socket file: bound, never listening.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = home.paths.daemonSocket.path
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertFalse(client.daemonIsRunning)

        try launchDaemon()
        try waitUntilRunning()
    }

    // MARK: - Helpers

    private func ok(_ request: Request, file: StaticString = #filePath, line: UInt = #line) throws -> EngineStatus {
        let response = try client.send(request, timeout: 60)
        guard case .ok(let status) = response else {
            XCTFail("\(request) -> \(response)", file: file, line: line)
            throw XCTSkip("unexpected error response")
        }
        return status
    }

    private func errorCode(_ response: Response) -> String? {
        if case .error(let code, _) = response { return code }
        return nil
    }

    private func daemonBinary() throws -> URL {
        // The test bundle sits in the build products directory, next to the executables.
        let products = Bundle(for: DaemonTests.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("paddockd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("paddockd not built at \(binary.path)")
            throw XCTSkip("paddockd missing")
        }
        return binary
    }

    /// A repository-built paddockd on the real system (no PADDOCK_HOME) refuses to run before it opens or
    /// creates anything. Its home directory is a scratch folder, so even a bug can't reach the real home.
    func testADevelopmentBuildDaemonRefusesTheRealSystem() throws {
        let scratch = try home.makeDirectory("scratch-home")
        let process = Process()
        process.executableURL = try daemonBinary()
        process.environment = TestSupport.realSystemEnvironment(scratchHome: scratch, settings: home.settings)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        if !waitForExit(process, timeout: 10) {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("paddockd kept running")
        }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 78, text)
        XCTAssertEqual(text, "paddockd: \(Messages.developmentBuild)\n")
        XCTAssertEqual(TestSupport.contents(of: scratch), [], "nothing created under the home directory")
    }

    private func makeDaemonProcess(log: String) throws -> Process {
        let process = Process()
        process.executableURL = try daemonBinary()
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        env["PADDOCK_HTTP_PORT"] = "\(home.settings.httpPort)"
        env["PADDOCK_HTTPS_PORT"] = "\(home.settings.httpsPort)"
        env["PADDOCK_DNS_PORT"] = "\(home.settings.dnsPort)"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        process.environment = env
        let logURL = home.root.appendingPathComponent(log)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func launchDaemon() throws {
        let process = try makeDaemonProcess(log: "daemon.log")
        try process.run()
        daemon = process
        try waitUntil("daemon socket answers") { client.daemonIsRunning }
    }

    private func waitUntilRunning() throws {
        try waitUntil("engine running") {
            guard case .ok(let s) = try client.send(.status) else { return false }
            XCTAssertTrue(s.blockedBy.isEmpty, "blocked by \(s.blockedBy)")
            return s.running
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 40, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return }
            if let daemon, !daemon.isRunning {
                XCTFail("daemon exited (\(daemon.terminationStatus)) while waiting for: \(what)\n\(daemonLog())")
                throw XCTSkip("daemon exited")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("timed out waiting for: \(what)\n\(daemonLog())")
        throw XCTSkip("timeout")
    }

    private func daemonLog() -> String {
        (try? String(contentsOf: home.root.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? ""
    }

    private func recordGroups() {
        guard let daemon, daemon.isRunning, case .ok(let status)? = try? client.send(.status, timeout: 5) else { return }
        for description in status.processes.values {
            if let pid = TestSupport.pid(from: description) { observedGroups.insert(pid) }
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }
}
