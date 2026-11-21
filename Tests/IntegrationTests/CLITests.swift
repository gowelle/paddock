import Darwin
import XCTest
@testable import PaddockCore

/// Runs the built `paddock` CLI against a `paddockd` on a throwaway home and high ports.
/// Never run either without the port variables: the owner's Herd holds 80/443.
final class CLITests: XCTestCase {
    private var home: TestHome!
    private var daemon: Process?

    override func setUpWithError() throws {
        home = try TestHome()
    }

    override func tearDown() {
        // Stops the daemon this test started (directly or through `paddock start`), and nothing else.
        let client = PaddockClient(paths: home.paths)
        if client.daemonIsRunning { _ = try? client.send(.shutdown, timeout: 30) }
        if let daemon, daemon.isRunning {
            for _ in 0..<150 where daemon.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL) }
        }
        home?.cleanUp()
    }

    // MARK: - No daemon

    func testCommandWithoutDaemonSaysNotRunning() throws {
        let result = try run(["parked"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("Paddock isn't running. Start it with: paddock start"), result.err)
    }

    func testStatusWithoutDaemonIsNotAFailure() throws {
        let result = try run(["status"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("Paddock isn't running. Start it with: paddock start"), result.out)
    }

    func testStopWithoutDaemon() throws {
        let result = try run(["stop"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("Paddock isn't running."), result.out)
    }

    func testIsolateOldVersionNamesMinimum() throws {
        let result = try run(["isolate", "7.4"], cwd: home.parked.appendingPathComponent("plain-php"))
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("8.1"), result.err)
        let use = try run(["use", "7.4"])
        XCTAssertEqual(use.status, 1)
        XCTAssertTrue(use.err.contains("Paddock supports PHP 8.1 and later."), use.err)
    }

    // MARK: - With a daemon

    func testParkAndParkedListsPath() throws {
        try launchDaemon()
        let more = try home.makeDirectory("more")
        try FileManager.default.createDirectory(at: more.appendingPathComponent("extra"),
                                                withIntermediateDirectories: true)
        let parked = try run(["park", more.path])
        XCTAssertEqual(parked.status, 0, parked.err)
        let listed = try run(["parked"])
        XCTAssertEqual(listed.status, 0, listed.err)
        XCTAssertTrue(listed.out.contains(more.standardizedFileURL.path), listed.out)
        XCTAssertTrue(try run(["status"]).out.contains("extra.test"))
        XCTAssertEqual(try run(["forget", more.path]).status, 0)
        XCTAssertFalse(try run(["parked"]).out.contains(more.standardizedFileURL.path))
    }

    func testLinkInFixtureDirThenLinksShowsArrow() throws {
        try launchDaemon()
        let app = try home.makeDirectory("My App")
        let link = try run(["link"], cwd: app)
        XCTAssertEqual(link.status, 0, link.err)
        XCTAssertTrue(link.out.contains("my-app.test"), link.out)
        let links = try run(["links"])
        let real = app.resolvingSymlinksInPath().path
        XCTAssertTrue(links.out.contains("my-app → \(real)"), links.out)
        XCTAssertEqual(try run(["unlink"], cwd: app).status, 0)
        XCTAssertFalse(try run(["links"]).out.contains("my-app"))
    }

    func testLinkWithTheTLDTypedNamesTheSiteWithoutIt() throws {
        try launchDaemon()
        let app = try home.makeDirectory("somewhere")
        let link = try run(["link", "Foo.test"], cwd: app)
        XCTAssertEqual(link.status, 0, link.err)
        XCTAssertTrue(link.out.hasPrefix("foo.test now serves "), link.out)
        XCTAssertTrue(link.out.hasSuffix("/somewhere.\n"), link.out)
        XCTAssertTrue(try run(["links"]).out.contains("foo → "))
        XCTAssertEqual(try run(["unlink", "foo.test"]).status, 0)
        XCTAssertFalse(try run(["links"]).out.contains("foo → "))
    }

    func testStatusShowsSiteURLAndSecureChangesIt() throws {
        try launchDaemon()
        let status = try run(["status"])
        XCTAssertEqual(status.status, 0, status.err)
        XCTAssertTrue(status.out.contains("http://plain-php.test"), status.out)
        XCTAssertTrue(status.out.contains("Default PHP"), status.out)

        let cwd = home.parked.appendingPathComponent("plain-php")
        let secure = try run(["secure"], cwd: cwd)
        XCTAssertEqual(secure.status, 0, secure.err)
        XCTAssertEqual(secure.out, "plain-php.test is now served over HTTPS. "
            + "Certificate trust is turned off for this Paddock home, so browsers will warn.\n")
        let trust = try run(["trust"])
        XCTAssertEqual(trust.status, 1)
        XCTAssertTrue(trust.err.contains("Certificate trust is turned off for this Paddock home."), trust.err)
        XCTAssertTrue(try run(["status"]).out.contains("https://plain-php.test"))
        XCTAssertEqual(try run(["unsecure", "plain-php"]).out, "plain-php.test is now served over HTTP.\n")
    }

    func testOpenUsesConfiguredCommandAndFolderOutsideSiteFails() throws {
        try launchDaemon()
        let open = try run(["open"], cwd: home.parked.appendingPathComponent("plain-php"),
                           extraEnv: ["PADDOCK_OPEN_COMMAND": "/bin/echo"])
        XCTAssertEqual(open.status, 0, open.err)
        XCTAssertTrue(open.out.contains("http://plain-php.test"), open.out)

        let outside = try home.makeDirectory("outside")
        let result = try run(["secure"], cwd: outside)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("This folder isn't a Paddock site."), result.err)
        XCTAssertEqual(try run(["unisolate"], cwd: outside).status, 1)
    }

    func testUnknownSiteIsAnErrorOnStderr() throws {
        try launchDaemon()
        let result = try run(["secure", "nope"])
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.err.isEmpty)
        XCTAssertEqual(result.out, "")
    }

    func testStartLaunchesDaemonThenStopShutsItDown() throws {
        let start = try run(["start"], timeout: 90)
        XCTAssertEqual(start.status, 0, start.err)
        XCTAssertEqual(start.out, "Paddock is running.\n")
        XCTAssertTrue(PaddockClient(paths: home.paths).daemonIsRunning)
        XCTAssertTrue(try run(["status"]).out.contains("Paddock is running."))
        XCTAssertTrue(try run(["logs"]).out.contains("paddockd.log"))

        let stop = try run(["stop"], timeout: 60)
        XCTAssertEqual(stop.out, "Paddock stopped.\n")
        XCTAssertFalse(PaddockClient(paths: home.paths).daemonIsRunning)
    }

    func testStartReportsBlockedPort() throws {
        let fd = try TestSupport.listen(port: home.settings.httpPort)
        defer { close(fd) }
        let start = try run(["start"], timeout: 90)
        XCTAssertEqual(start.status, 1)
        XCTAssertTrue(start.err.contains("Paddock can't start: port \(home.settings.httpPort) is in use by"), start.err)
        let status = try run(["status"])
        XCTAssertTrue(status.out.contains("Paddock can't start: port \(home.settings.httpPort)"), status.out)
    }

    /// A repository-built `paddock` on the real system (no PADDOCK_HOME; home directory a scratch folder)
    /// reads, but changes nothing: a mutating request and `stop` are refused with the one sentence.
    func testADevelopmentBuildOnTheRealSystemOnlyReads() throws {
        let scratch = try home.makeDirectory("scratch-home")
        let env = TestSupport.realSystemEnvironment(scratchHome: scratch, settings: home.settings)
        for args in [["park", home.parked.path], ["forget", home.parked.path], ["stop"], ["restart"], ["trust"]] {
            let result = try run(args, environment: env)
            XCTAssertEqual(result.status, 1, "\(args): \(result.out)")
            XCTAssertTrue(result.err.contains(Messages.developmentBuild), "\(args): \(result.err)")
        }
        let status = try run(["status"], environment: env)
        XCTAssertEqual(status.out, Messages.daemonNotRunning + "\n", "reads still work")
        XCTAssertEqual(TestSupport.contents(of: scratch), [])
    }

    // MARK: - Helpers

    private struct Result { let status: Int32; let out: String; let err: String }

    private var products: URL { Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent() }

    private func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        env["PADDOCK_HTTP_PORT"] = "\(home.settings.httpPort)"
        env["PADDOCK_HTTPS_PORT"] = "\(home.settings.httpsPort)"
        env["PADDOCK_DNS_PORT"] = "\(home.settings.dnsPort)"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env.merge(extra) { $1 }
        return env
    }

    private func run(_ args: [String], cwd: URL? = nil, extraEnv: [String: String] = [:],
                     environment fullEnvironment: [String: String]? = nil,
                     timeout: TimeInterval = 60) throws -> Result {
        let binary = products.appendingPathComponent("paddock")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("paddock not built at \(binary.path)")
            throw XCTSkip("paddock missing")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = fullEnvironment ?? environment(extra: extraEnv)
        process.currentDirectoryURL = cwd ?? home.root
        let outFile = home.root.appendingPathComponent("out-\(TestSupport.token())")
        let errFile = home.root.appendingPathComponent("err-\(TestSupport.token())")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("paddock \(args) timed out")
        }
        process.waitUntilExit()
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return Result(status: process.terminationStatus, out: read(outFile), err: read(errFile))
    }

    private func launchDaemon() throws {
        try TestSupport.requireVendored()
        let binary = products.appendingPathComponent("paddockd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("paddockd not built at \(binary.path)")
            throw XCTSkip("paddockd missing")
        }
        let process = Process()
        process.executableURL = binary
        process.environment = environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        let client = PaddockClient(paths: home.paths)
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if client.daemonIsRunning,
               case .ok(let s)? = try? client.send(.status), s.running { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("daemon did not come up")
        throw XCTSkip("daemon did not come up")
    }
}
