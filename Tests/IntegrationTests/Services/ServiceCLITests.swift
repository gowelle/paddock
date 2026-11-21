import Darwin
import XCTest
@testable import PaddockCore

/// `paddock service …` and the services in `paddock status`, run as the built CLI against a scratch
/// daemon whose catalog is the fake service, on free high ports.
final class ServiceCLITests: XCTestCase {
    private var home: ServiceHome!
    private var daemon: Process?
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        try TestSupport.requireVendored()
        home = try ServiceHome()
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [
            FakeService.recipe(actions: [RecipeAction.createDatabase: FakeService.createDatabase]),
        ])).write(to: catalog)
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        let http = TestSupport.freeTCPPort()
        env["PADDOCK_HTTP_PORT"] = "\(http)"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort(excluding: [http]))"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53596))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServiceCatalog.overrideVariable] = catalog.path
        env[ServicePorts.portBaseVariable] = "\(home.portBase)"
        // `paddock service open` prints the URL instead of opening a browser.
        env["PADDOCK_OPEN_COMMAND"] = "/bin/echo"
        environment = env
    }

    override func tearDown() {
        let client = PaddockClient(paths: home.paths)
        if client.daemonIsRunning { _ = try? client.send(.shutdown, timeout: 30) }
        if let daemon {
            if !waitFor(15, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        home?.cleanUp()
    }

    func testServiceCommands() throws {
        try launchDaemon()
        let port = home.fakePort
        let socket = home.paths.serviceRun("fake").appendingPathComponent("fake.sock").path
        let env = "FAKE_HOST=127.0.0.1\nFAKE_PORT=\(port)\nFAKE_SOCKET=\(socket)\n"

        let empty = try run(["service"])
        XCTAssertEqual(empty.status, 0, empty.err)
        XCTAssertEqual(empty.out, "No services yet. See what you can add with: paddock service available\n",
                       "`paddock service` alone lists the services")

        let available = try run(["service", "available"])
        XCTAssertEqual(available.status, 0, available.err)
        // The fake is a file on this Mac: adding it downloads nothing.
        XCTAssertEqual(available.out, "KIND  SERVICE  SERIES  LICENCE  DOWNLOAD\nfake  Fake     1       MIT      none\n")

        let unknown = try run(["service", "add", "nope"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertEqual(unknown.out, "")
        XCTAssertEqual(unknown.err, "Paddock has no service called \"nope\". Available: fake.\n")

        let added = try run(["service", "add", "fake"])
        XCTAssertEqual(added.status, 0, added.err)
        XCTAssertEqual(added.out, "Starting Fake…\nFake is running on port \(port).\n\n" + env)

        let list = try run(["service", "list"])
        XCTAssertEqual(list.out, "SERVICE  STATE    PORTS\nFake     running  \(port) (main)\n")
        let status = try run(["status"])
        XCTAssertTrue(status.out.hasSuffix("\n\nSERVICE  STATE    PORTS\nFake     running  \(port) (main)\n"), status.out)

        XCTAssertEqual(try run(["service", "env", "FAKE"]).out, env)
        XCTAssertEqual(try run(["service", "update", "fake"]).out, "Fake is up to date (1.0).\n")
        XCTAssertEqual(try run(["service", "stop", "fake"]).out, "Fake stopped.\n")
        XCTAssertTrue(try run(["service", "list"]).out.contains("Fake     stopped"))
        XCTAssertEqual(try run(["service", "start", "Fake"]).out, "Fake is running on port \(port).\n")
        XCTAssertEqual(try run(["service", "restart", "fake"]).out, "Fake is running on port \(port).\n")
        let logs = try run(["service", "logs", "fake"])
        XCTAssertTrue(logs.out.hasPrefix(home.paths.serviceLog("fake").path + "\n"), logs.out)
        XCTAssertTrue(logs.out.contains("fake-service: ready"), logs.out)
        XCTAssertEqual(try run(["service", "open", "fake"]).out, "http://127.0.0.1:\(port)\n")

        XCTAssertEqual(try run(["service", "create-db", "fake", "shop"]).out, "Created database shop in Fake.\n")
        let existing = try run(["service", "create-db", "Fake", "shop"])
        XCTAssertEqual(existing.status, 0, existing.err)
        XCTAssertEqual(existing.out, "shop already exists in Fake.\n")
        let invalid = try run(["service", "create-db", "fake", "my-shop"])
        XCTAssertEqual(invalid.status, 1)
        XCTAssertEqual(invalid.err, "Database names can use letters, numbers and underscores.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceData("fake").appendingPathComponent("made-my-shop").path))

        let missing = try run(["service", "stop", "nope"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.err, "No service named \"nope\". See: paddock service list\n")

        // Held port at a later start: the daemon's sentence, on stderr.
        _ = try run(["service", "stop", "fake"])
        let holder = try listenReusingAddress(port: port)
        let blocked = try run(["service", "start", "fake"])
        close(holder)
        XCTAssertEqual(blocked.status, 1)
        XCTAssertTrue(blocked.err.hasPrefix("Fake can't start: port \(port) is in use by "), blocked.err)
        XCTAssertTrue(try run(["service", "list"]).out.contains("port in use by"))
        XCTAssertEqual(try run(["service", "start", "fake"]).status, 0)

        let removed = try run(["service", "remove", "fake"])
        XCTAssertEqual(removed.out, "Removed Fake. Its data is still at \(home.paths.serviceData("fake").path).\n")
        let again = try run(["service", "add", "fake"])
        XCTAssertEqual(again.out, "Starting Fake…\nFound existing data for Fake; using it.\n"
                       + "Fake is running on port \(port).\n\n" + env)
        let deleted = try run(["service", "remove", "fake", "--delete-data"])
        XCTAssertEqual(deleted.out, "Removed Fake and deleted its data.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake").path))
        XCTAssertEqual(try run(["service", "list"]).out,
                       "No services yet. See what you can add with: paddock service available\n")
    }

    /// A secret is never printed by `service add` (a comment says how to get it, safe to paste into `.env`);
    /// `service env` fetches and prints it.
    func testAddLeavesSecretsOutAndEnvPrintsThem() throws {
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [FakeService.keyedRecipe()])).write(to: catalog)
        try launchDaemon()
        let port = home.fakePort
        let socket = home.paths.serviceRun("fake").appendingPathComponent("fake.sock").path
        let plain = "FAKE_HOST=127.0.0.1\nFAKE_PORT=\(port)\nFAKE_SOCKET=\(socket)\n"

        let added = try run(["service", "add", "fake"])
        XCTAssertEqual(added.status, 0, added.err)
        let key = try XCTUnwrap(try ServiceSecrets.load(from: home.paths.serviceConfig("fake"))["master_key"])
        XCTAssertEqual(added.out, "Starting Fake…\nFake is running on port \(port).\n\n" + plain
                       + "# FAKE_SECRET: run \"paddock service env fake\"\n")
        XCTAssertFalse(added.out.contains(key))
        XCTAssertFalse(try run(["service", "list"]).out.contains(key))
        XCTAssertFalse(try run(["status"]).out.contains(key))

        let env = try run(["service", "env", "Fake"])
        XCTAssertEqual(env.status, 0, env.err)
        XCTAssertEqual(env.out, plain + "FAKE_SECRET=\(key)\n")
    }

    /// A daemon whose services take a while to stop (here one that ignores SIGTERM, with five seconds'
    /// grace): `paddock stop` says what it is waiting for.
    func testStopSaysWhenItIsWaitingForServices() throws {
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [
            FakeService.recipe(extraArguments: ["--ignore-term"], stopGraceSeconds: 5),
        ])).write(to: catalog)
        try launchDaemon()
        let added = try run(["service", "add", "fake"])
        XCTAssertEqual(added.status, 0, added.err)
        let stopped = try run(["stop"], timeout: 120)
        XCTAssertEqual(stopped.status, 0, stopped.err)
        XCTAssertEqual(stopped.out, "Waiting for services to stop…\nPaddock stopped.\n")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: home.fakePort))
    }

    // MARK: - Helpers

    private struct Result { let status: Int32; let out: String; let err: String }

    private var products: URL { Bundle(for: ServiceCLITests.self).bundleURL.deletingLastPathComponent() }

    private func run(_ args: [String], timeout: TimeInterval = 60) throws -> Result {
        let process = Process()
        process.executableURL = products.appendingPathComponent("paddock")
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = home.root
        let outFile = home.root.appendingPathComponent("out-\(TestSupport.token())")
        let errFile = home.root.appendingPathComponent("err-\(TestSupport.token())")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        if !waitFor(timeout, { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("paddock \(args) timed out")
        }
        process.waitUntilExit()
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return Result(status: process.terminationStatus, out: read(outFile), err: read(errFile))
    }

    private func launchDaemon() throws {
        let process = Process()
        process.executableURL = products.appendingPathComponent("paddockd")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        guard waitFor(40, { PaddockClient(paths: self.home.paths).daemonIsRunning }) else {
            XCTFail("daemon did not come up")
            throw XCTSkip("daemon did not come up")
        }
    }
}
