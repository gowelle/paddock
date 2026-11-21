import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// The real Redis (Valkey) recipe (from the bundled catalog; Paddock's own build from Vendor/builds/, so no
/// network) in scratch homes on free high ports: Paddock's PHP (phpredis) over TCP and over the instance's
/// Unix socket, data kept across a stop and start and a remove and re-add, loopback only, TCP only in a long
/// home, readiness only once the dataset is loaded, and a daemon's orphan reclaimed.
final class RedisServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var daemon: Process?
    /// valkey-server processes these tests saw; any still alive at the end is killed (none should be).
    private var started: Set<Int32> = []

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        if let daemon {
            let client = PaddockClient(paths: home.paths)
            if daemon.isRunning, client.daemonIsRunning { _ = try? client.send(.shutdown, timeout: 60) }
            if !waitFor(30, { !daemon.isRunning }) { kill(daemon.processIdentifier, SIGKILL) }
        }
        for pid in started where kill(pid, 0) == 0 && isOurValkey(pid) {
            XCTFail("valkey-server \(pid) was left running")
            kill(pid, SIGKILL)
        }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private var php: URL { TestSupport.repoVendor.appendingPathComponent("php/8.5/default/php") }

    private func requirePHP() throws {
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored PHP missing; run Scripts/fetch-vendor.sh")
        }
    }

    /// The bundled recipe; its archive is Paddock's own build in Vendor/builds/.
    private func redis() throws -> ServiceRecipe {
        let recipe = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "redis", version: nil), "the catalog has Redis")
        for asset in recipe.assets where BuildSource.resolve(asset.artifact.url) == nil {
            throw XCTSkip("\(BuildSource.fileName(asset.artifact.url) ?? "?") is not in Vendor/builds/; build it with "
                          + "Scripts/build-valkey.sh (a few minutes)")
        }
        return recipe
    }

    private func makeManager(_ recipes: [ServiceRecipe], home: ServiceHome? = nil) -> ServiceManager {
        let home = home ?? self.home!
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager) -> ServiceStatus? {
        manager.statuses().first { $0.id == "redis" }
    }

    private func server(_ manager: ServiceManager) throws -> Int32 {
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName("redis")].flatMap(TestSupport.pid(from:)))
        started.insert(pid)
        return pid
    }

    /// A live process running valkey-server from a scratch home (never the Mac's own Redis).
    private func isOurValkey(_ pid: Int32) -> Bool {
        guard let program = PortCheck.executablePath(pid: pid) else { return false }
        return program.hasPrefix(home.paths.home.path) || program.hasPrefix("/private" + home.paths.home.path)
    }

    private func socketPath(_ home: ServiceHome? = nil) -> String {
        (home ?? self.home!).paths.serviceRun("redis").appendingPathComponent("redis.sock").path
    }

    private func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func configText(_ home: ServiceHome? = nil) throws -> String {
        try String(contentsOf: (home ?? self.home!).paths.serviceConfig("redis").appendingPathComponent("valkey.conf"),
                   encoding: .utf8)
    }

    /// Runs one phpredis operation with Paddock's PHP 8.5, connecting to `target` (`tcp:<port>` or a socket
    /// path); returns its output (fails the test on an error unless `quiet`).
    @discardableResult
    private func phpredis(_ target: String, _ operation: String, _ argument: String = "", quiet: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = home.root.appendingPathComponent("redis.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            [, $target, $op, $arg] = $argv + [3 => ''];
            try {
                $redis = new Redis();
                if (str_starts_with($target, 'tcp:')) {
                    $redis->connect('127.0.0.1', (int)substr($target, 4), 5);
                } else {
                    $redis->connect($target);
                }
                switch ($op) {
                    case 'set':
                        [$key, $value] = explode('=', $arg, 2);
                        echo $redis->set($key, $value) ? "ok\n" : "not set\n";
                        break;
                    case 'get':
                        $value = $redis->get($arg);
                        echo $value === false ? "(nil)\n" : "$value\n";
                        break;
                    case 'fill':
                        // One SET per key (the append-only file replays commands, not keys), pipelined.
                        for ($i = 0; $i < (int)$arg; $i += 1000) {
                            $pipe = $redis->multi(Redis::PIPELINE);
                            for ($j = $i; $j < min($i + 1000, (int)$arg); $j++) { $pipe->set("fill:$j", str_repeat('x', 100)); }
                            $pipe->exec();
                        }
                        echo $redis->dbSize(), "\n";
                        break;
                    case 'via':
                        // CLIENT INFO names the local address: the socket's path, or 127.0.0.1:<port>.
                        preg_match('/laddr=(\S+)/', $redis->rawCommand('CLIENT', 'INFO'), $m);
                        echo str_contains($m[1], '.sock') ? "socket\n" : explode(':', $m[1])[0] . "\n";
                        break;
                }
            } catch (Throwable $e) {
                fwrite(STDERR, $e->getMessage() . "\n");
                exit(1);
            }
            """#.utf8).write(to: script)
        }
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", script.path, target, operation, argument]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if !quiet {
            XCTAssertEqual(process.terminationStatus, 0, "\(operation) on \(target): \(problem)", file: file, line: line)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The installed valkey-cli asked `arguments` directly (to see what the readiness probe sees).
    private func valkeyCLI(_ manager: ServiceManager, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = home.paths.serviceBin(kind: "redis", version: "9.2.0").appendingPathComponent("valkey-cli")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    // MARK: - End to end

    /// Add, PHP over TCP and over the socket, loopback only, stop and start keep the key (append-only
    /// persistence), and a removed instance's data is used again when it is added back.
    func testRedisServesPHPOverTCPAndItsSocketAndKeepsData() async throws {
        try requirePHP()
        let manager = makeManager([try redis()])
        let added = try await manager.add(kind: "redis", version: nil)
        XCTAssertEqual(added.id, "redis")
        XCTAssertEqual(added.name, "Redis (Valkey)")
        XCTAssertEqual(added.version, "9.2.0")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertNotEqual(port, 6379, "never the Mac's own Redis port")
        XCTAssertGreaterThanOrEqual(port, home.portBase + 6379)
        let running = try XCTUnwrap(status(manager))
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.mainPort, port)
        XCTAssertNil(running.openURL)
        XCTAssertEqual(running.env, ["REDIS_CLIENT=phpredis", "REDIS_HOST=127.0.0.1", "REDIS_PORT=\(port)",
                                     "REDIS_PASSWORD=null"])
        XCTAssertEqual(running.notes, ["Valkey 9.2.0, a Redis-compatible server."])
        let config = try configText()
        XCTAssertTrue(config.contains("unixsocket \"\(socketPath())\"\n"), config)
        XCTAssertTrue(config.contains("dir \"\(home.paths.serviceData("redis").path)\"\n"), config)

        let pid = try server(manager)
        let listeners = Set(try assertListensOnThisMacOnly(processGroup: pid))
        XCTAssertTrue(listeners.contains("127.0.0.1:\(port)"), "\(listeners)")
        XCTAssertTrue(listeners.isSubset(of: ["127.0.0.1:\(port)", "[::1]:\(port)"]), "\(listeners)")
        XCTAssertTrue(isSocket(socketPath()), "its socket is in its own run folder")

        // SET and GET over TCP, then over the Unix socket.
        XCTAssertEqual(try phpredis("tcp:\(port)", "via"), "127.0.0.1")
        XCTAssertEqual(try phpredis("tcp:\(port)", "set", "greeting=over TCP"), "ok")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "greeting"), "over TCP")
        XCTAssertEqual(try phpredis(socketPath(), "via"), "socket")
        XCTAssertEqual(try phpredis(socketPath(), "set", "other=over the socket"), "ok")
        XCTAssertEqual(try phpredis(socketPath(), "get", "greeting"), "over TCP")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "other"), "over the socket")

        // Stop and start keep the data: append-only persistence is on, in the instance's data folder.
        manager.stop("redis")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertEqual(kill(pid, 0), -1, "stopped")
        let data = home.paths.serviceData("redis")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("appendonlydir").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("dump.rdb").path),
                      "a clean stop saves a snapshot too")
        try manager.start("redis")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "greeting"), "over TCP")
        XCTAssertEqual(try phpredis(socketPath(), "get", "other"), "over the socket")
        _ = try server(manager)

        // Removing keeps the data; adding again uses it.
        let kept = try manager.remove("redis", deleteData: false)
        XCTAssertEqual(kept, data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("appendonlydir").path))
        let again = try await manager.add(kind: "redis", version: nil)
        XCTAssertEqual(again.id, "redis")
        XCTAssertEqual(status(manager)?.notice, "Found existing data for Redis (Valkey); using it.")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try phpredis("tcp:\(portAgain)", "get", "greeting"), "over TCP")
        _ = try server(manager)
        manager.stopAll()
    }

    // MARK: - A long home

    /// Where the socket path would be longer than macOS allows, valkey.conf has no socket line, Valkey serves
    /// over TCP only, and the .env lines say so.
    func testALongHomeServesOverTCPWithoutASocket() async throws {
        try requirePHP()
        let long = try ServiceHome(longFolder: true)
        defer { long.cleanUp() }
        let manager = makeManager([try redis()], home: long)
        let added = try await manager.add(kind: "redis", version: nil)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertGreaterThan(socketPath(long).utf8.count, 103)
        XCTAssertEqual(manager.statuses().first?.state, .running)
        let config = try configText(long)
        XCTAssertFalse(config.contains("unixsocket \""), config)
        XCTAssertTrue(config.contains("port \(port)\n"), config)
        XCTAssertEqual(try manager.env("redis").last, "# Unix socket disabled: Paddock's folder path is too long")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: long.paths.serviceRun("redis").path)
            .filter { $0.hasSuffix(".sock") }, [])
        XCTAssertEqual(try phpredis("tcp:\(port)", "set", "long=home"), "ok")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "long"), "home")
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName("redis")].flatMap(TestSupport.pid(from:)))
        XCTAssertTrue(Set(try assertListensOnThisMacOnly(processGroup: pid)).isSubset(of: ["127.0.0.1:\(port)", "[::1]:\(port)"]))
        manager.stopAll()
        XCTAssertEqual(kill(pid, 0), -1)
    }

    // MARK: - Readiness

    /// While Valkey loads its dataset it answers PING with a LOADING error: the service is `starting`, not
    /// running, until it answers, and the start returns only then. (The recipe's own readiness probe, with a
    /// test copy of the recipe whose valkey.conf makes loading slow.)
    func testRedisIsStartingUntilItsDatasetIsLoaded() async throws {
        try requirePHP()
        let bundled = try redis()
        let slow = ServiceRecipe(
            kind: bundled.kind, displayName: bundled.displayName, version: bundled.version, series: bundled.series,
            seriesInID: bundled.seriesInID, licence: bundled.licence, minimumMacOS: bundled.minimumMacOS,
            assets: bundled.assets, initialise: bundled.initialise, start: bundled.start, ready: bundled.ready,
            stopSignal: bundled.stopSignal, stopGraceSeconds: bundled.stopGraceSeconds, ports: bundled.ports,
            socket: bundled.socket, env: bundled.env, openURL: bundled.openURL, needsPHP: bundled.needsPHP,
            configFiles: bundled.configFiles.map {
                // Valkey's hidden testing settings: microseconds per key loaded, and answering clients often.
                RecipeFile(path: $0.path, contents: $0.contents + "key-load-delay 100\nloading-process-events-interval-bytes 1024\n")
            },
            readyTimeoutSeconds: bundled.readyTimeoutSeconds, initialiseTimeoutSeconds: bundled.initialiseTimeoutSeconds,
            actions: bundled.actions, lockFiles: bundled.lockFiles, notes: bundled.notes)
        let manager = makeManager([slow])
        let added = try await manager.add(kind: "redis", version: nil)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try phpredis("tcp:\(port)", "fill", "40000"), "40000")
        manager.stop("redis")

        let finished = LockedBox<Bool>(false)
        let failure = LockedBox<String?>(nil)
        DispatchQueue.global().async {
            do { try manager.start("redis") } catch { failure.value = "\(error)" }
            finished.value = true
        }
        XCTAssertTrue(waitFor(10) {
            (try? self.valkeyCLI(manager, ["-h", "127.0.0.1", "-p", "\(port)", "ping"]))?.output.contains("LOADING") == true
        }, "Valkey is loading its dataset")
        // Loading takes seconds: a second on, the readiness probe has been asked several times.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(status(manager)?.state, .starting, "not running while it loads")
        XCTAssertFalse(finished.value, "the start waits")
        // What the readiness probe sees meanwhile: an error, so it keeps waiting.
        let probe = try valkeyCLI(manager, ["-h", "127.0.0.1", "-p", "\(port)", "-e", "ping"])
        XCTAssertTrue(probe.output.contains("LOADING"), probe.output)
        XCTAssertNotEqual(probe.status, 0, "the readiness probe fails on LOADING: \(probe.output)")
        XCTAssertTrue(waitFor(60) { finished.value }, "started once loaded")
        XCTAssertNil(failure.value)
        XCTAssertEqual(status(manager)?.state, .running)
        XCTAssertEqual(try valkeyCLI(manager, ["-h", "127.0.0.1", "-p", "\(port)", "-e", "ping"]).output, "PONG\n")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "fill:39999"), String(repeating: "x", count: 100))
        _ = try server(manager)
        manager.stopAll()
    }

    // MARK: - Orphans

    /// A daemon killed outright leaves valkey-server running; the next daemon stops it (its own signal, so
    /// it saves its data) and starts it again on the same data.
    func testADaemonsOrphanIsReclaimed() async throws {
        try requirePHP()
        try TestSupport.requireVendored()
        let recipe = try redis()
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [recipe])).write(to: catalog)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon(catalog: catalog)
        guard case .ok? = try? client.send(.serviceAdd(kind: "redis", version: nil), timeout: 120) else {
            return XCTFail("add through the daemon")
        }
        guard case .ok(let running) = try client.send(.status, timeout: 10) else { return XCTFail("status") }
        let orphan = try XCTUnwrap(running.processes["service-redis"].flatMap(TestSupport.pid(from:)))
        started.insert(orphan)
        let port = try XCTUnwrap(running.services.first?.ports["main"])
        XCTAssertEqual(try phpredis("tcp:\(port)", "set", "before=the crash"), "ok")
        _ = try client.send(.stop, timeout: 60) // Only the service should outlive the daemon.
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        self.daemon = nil
        XCTAssertTrue(waitFor(5) { ServiceProcessRecord.parent(of: orphan) == 1 }, "an orphan of launchd")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "before"), "the crash", "still serving without its daemon")

        try launchDaemon(catalog: catalog)
        var fresh: Int32 = 0
        XCTAssertTrue(waitFor(60) {
            guard case .ok(let status)? = try? client.send(.status, timeout: 5),
                  status.services.first?.state == .running,
                  let pid = status.processes["service-redis"].flatMap(TestSupport.pid(from:)) else { return false }
            fresh = pid
            return true
        }, "running again under the new daemon")
        started.insert(fresh)
        XCTAssertNotEqual(fresh, orphan)
        XCTAssertEqual(kill(orphan, 0), -1, "the orphaned valkey-server was stopped")
        XCTAssertEqual(try phpredis("tcp:\(port)", "get", "before"), "the crash")
        XCTAssertTrue(Set(try assertListensOnThisMacOnly(processGroup: fresh)).isSubset(of: ["127.0.0.1:\(port)", "[::1]:\(port)"]))
    }

    private func launchDaemon(catalog: URL) throws {
        let process = Process()
        process.executableURL = Bundle(for: ServiceHome.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("paddockd")
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        let http = TestSupport.freeTCPPort()
        env["PADDOCK_HTTP_PORT"] = "\(http)"
        env["PADDOCK_HTTPS_PORT"] = "\(TestSupport.freeTCPPort(excluding: [http]))"
        env["PADDOCK_DNS_PORT"] = "\(TestSupport.freeUDPPort(preferred: 53594))"
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env[ServiceCatalog.overrideVariable] = catalog.path
        env[ServicePorts.portBaseVariable] = "\(home.portBase)"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        daemon = process
        guard waitFor(40, { PaddockClient(paths: self.home.paths).daemonIsRunning }) else {
            XCTFail("daemon did not answer")
            throw XCTSkip("daemon did not answer")
        }
    }
}
