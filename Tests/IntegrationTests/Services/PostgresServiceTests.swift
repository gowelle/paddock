import Darwin
import XCTest
@testable import PaddockCore

/// The real PostgreSQL recipes (from the bundled catalog; archives cached in Vendor/services/), in scratch
/// homes on free high ports. Series 18 and 17 run end to end with Paddock's own PHP talking PDO over TCP and
/// over the instance's Unix socket; 16 is installed and version-checked only, to keep the suite quick.
final class PostgresServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var daemon: Process?
    /// Postgres processes these tests saw; any still alive at the end is killed (none should be).
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
        for pid in started where isAlive(pid) && isOurPostgres(pid) {
            XCTFail("postgres \(pid) was left running")
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

    /// The bundled recipe of a series, its archive served from the cache (downloaded and verified once).
    private func postgres(_ series: String) async throws -> ServiceRecipe {
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "postgres", series: series),
                                    "the catalog has PostgreSQL \(series)")
        return try await ServiceDownloadCache.localRecipe(bundled)
    }

    private func makeManager(_ recipes: [ServiceRecipe], home: ServiceHome? = nil,
                             macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> ServiceManager {
        let home = home ?? self.home!
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase, macOSVersion: macOS)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String) -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func postmaster(_ manager: ServiceManager, _ id: String) throws -> Int32 {
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName(id)].flatMap(TestSupport.pid(from:)))
        started.insert(pid)
        for child in children(of: pid) { started.insert(child) }
        return pid
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// A live process running a postgres program from a scratch home (never the Mac's own PostgreSQL).
    private func isOurPostgres(_ pid: Int32) -> Bool {
        guard let program = PortCheck.executablePath(pid: pid) else { return false }
        return program.hasPrefix(home.paths.home.path) || program.hasPrefix("/private" + home.paths.home.path)
    }

    /// The postmaster's children (each leads its own process group, so `pgrep -g` doesn't find them).
    private func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    private func socketPath(_ id: String, port: Int, home: ServiceHome? = nil) -> String {
        (home ?? self.home!).paths.serviceRun(id).appendingPathComponent(".s.PGSQL.\(port)").path
    }

    private func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func tcp(_ port: Int, _ database: String = "laravel") -> String {
        "pgsql:host=127.0.0.1;port=\(port);dbname=\(database)"
    }

    private func unixSocket(_ id: String, _ port: Int, _ database: String = "laravel") -> String {
        "pgsql:host=\(home.paths.serviceRun(id).path);port=\(port);dbname=\(database)"
    }

    /// Runs one PDO operation with Paddock's PHP 8.5; returns its output (fails the test on an error).
    @discardableResult
    private func pdo(_ dsn: String, _ operation: String, _ argument: String = "",
                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = home.root.appendingPathComponent("pdo.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            [, $dsn, $op, $arg] = $argv + [3 => ''];
            try {
                $pdo = new PDO($dsn, 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                switch ($op) {
                    case 'setup':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS notes (id serial PRIMARY KEY, body text NOT NULL)');
                        echo "ok\n";
                        break;
                    case 'insert':
                        $pdo->prepare('INSERT INTO notes (body) VALUES (?)')->execute([$arg]);
                        echo "ok\n";
                        break;
                    case 'read':
                        echo implode(',', $pdo->query('SELECT body FROM notes ORDER BY id')->fetchAll(PDO::FETCH_COLUMN)), "\n";
                        break;
                    case 'databases':
                        $rows = $pdo->query('SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname');
                        echo implode(',', $rows->fetchAll(PDO::FETCH_COLUMN)), "\n";
                        break;
                    case 'via':
                        $address = $pdo->query('SELECT inet_server_addr()')->fetchColumn();
                        echo ($address === null ? 'socket' : $address), "\n";
                        break;
                    case 'server':
                        echo $pdo->query("SELECT current_user || ' ' || current_setting('server_version') || ' '"
                            . " || current_setting('server_encoding')")->fetchColumn(), "\n";
                        break;
                    case 'json':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS documents (id serial PRIMARY KEY,'
                            . ' meta jsonb NOT NULL, pretty json NOT NULL)');
                        $pdo->prepare('INSERT INTO documents (meta, pretty) VALUES (?::jsonb, ?::json)')
                            ->execute([$arg, "{\n  \"name\": \"Ada\",\n  \"tags\": [\"a\", \"b\"]\n}"]);
                        echo "ok\n";
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
        process.arguments = ["-n", script.path, dsn, operation, argument]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(operation) on \(dsn): \(problem)", file: file, line: line)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 18 and 17

    /// PostgreSQL 18 from add to re-add: its preferred port taken, PDO over TCP and over its socket, databases
    /// created (and an existing or invalid one handled), data kept across a stop and start, 17 beside it on
    /// another port with its own data, loopback only, and a removed instance's data reused without initdb.
    func testPostgreSQL18And17EndToEnd() async throws {
        try requirePHP()
        let recipes = [try await postgres("18"), try await postgres("17")]
        let manager = makeManager(recipes)

        let preferred = home.portBase + 5432
        // The preferred (shifted) port is taken: the next free one is chosen. Never skipped silently.
        let holder = try listenReusingAddress(port: preferred)
        let added = try await manager.add(kind: "postgres", version: "18")
        close(holder)
        XCTAssertEqual(added.id, "postgres-18")
        XCTAssertEqual(added.name, "PostgreSQL 18")
        XCTAssertEqual(added.version, "18.7.0")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertNotEqual(port, 5432, "never the Mac's own PostgreSQL port")
        XCTAssertTrue((preferred + 1...preferred + ServicePorts.searchLimit).contains(port), "the next free port: \(port)")
        let running = try XCTUnwrap(status(manager, "postgres-18"))
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.mainPort, port)
        XCTAssertNil(running.openURL)
        XCTAssertEqual(running.env, ["DB_CONNECTION=pgsql", "DB_HOST=127.0.0.1", "DB_PORT=\(port)", "DB_DATABASE=laravel",
                                    "DB_USERNAME=root", "DB_PASSWORD="])

        let pid18 = try postmaster(manager, "postgres-18")
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid18), ["127.0.0.1:\(port)"])
        XCTAssertTrue(isSocket(socketPath("postgres-18", port: port)), "its socket is in its own run folder")
        XCTAssertFalse(manager.logTail("postgres-18").contains("/tmp/.s.PGSQL"), "never a socket in /tmp")

        // Databases.
        XCTAssertEqual(try manager.createDatabase("postgres-18", database: "laravel"), .done)
        XCTAssertEqual(try manager.createDatabase("PostgreSQL 18", database: "laravel"), .alreadyDone)
        XCTAssertThrowsError(try manager.createDatabase("postgres-18", database: "my-db")) { error in
            XCTAssertEqual(error as? ServiceError, .invalidParameter(parameter: "database", value: "my-db"))
        }
        XCTAssertEqual(try pdo(tcp(port, "postgres"), "databases"), "laravel,postgres", "my-db was never created")
        XCTAssertEqual(try pdo(tcp(port), "server").components(separatedBy: " ").first, "root")
        XCTAssertTrue(try pdo(tcp(port), "server").hasSuffix(" UTF8"))

        // PDO over TCP, then over the Unix socket.
        XCTAssertEqual(try pdo(tcp(port), "via"), "127.0.0.1")
        try pdo(tcp(port), "setup")
        try pdo(tcp(port), "insert", "over TCP")
        XCTAssertEqual(try pdo(unixSocket("postgres-18", port), "via"), "socket")
        try pdo(unixSocket("postgres-18", port), "insert", "over the socket")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")

        // A database created on request is one an app can use.
        XCTAssertEqual(try manager.createDatabase("postgres-18", database: "Shop_2"), .done)
        try pdo(tcp(port, "Shop_2"), "setup")

        // Stop and start keep the data; a clean stop leaves no lock behind.
        manager.stop("postgres-18")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertFalse(isAlive(pid18))
        let data18 = home.paths.serviceData("postgres-18")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data18.appendingPathComponent("postmaster.pid").path))
        try manager.start("postgres-18")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")

        // After an unclean shutdown the pids in postmaster.pid and the socket lock may belong to other
        // processes by now: PostgreSQL would refuse to start ("lock file already exists"); Paddock removes
        // them, and never signals the process they name.
        manager.stop("postgres-18")
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["60"]
        try stranger.run()
        defer { if stranger.isRunning { stranger.terminate() } }
        let postmasterPid = data18.appendingPathComponent("postmaster.pid")
        try Data("\(stranger.processIdentifier)\n\(data18.path)\n".utf8).write(to: postmasterPid)
        let socketLock = home.paths.serviceRun("postgres-18").appendingPathComponent(".s.PGSQL.\(port).lock")
        try Data("\(stranger.processIdentifier)\n".utf8).write(to: socketLock)
        try manager.start("postgres-18")
        XCTAssertTrue(stranger.isRunning, "never signalled")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")
        let restarted = try postmaster(manager, "postgres-18")
        XCTAssertEqual(try String(contentsOf: postmasterPid, encoding: .utf8).components(separatedBy: "\n").first,
                       "\(restarted)")

        // 17 beside it: another port, its own data.
        let added17 = try await manager.add(kind: "postgres", version: "17")
        XCTAssertEqual(added17.id, "postgres-17")
        XCTAssertEqual(added17.name, "PostgreSQL 17")
        let port17 = try XCTUnwrap(added17.ports["main"])
        XCTAssertNotEqual(port17, port)
        XCTAssertEqual(manager.statuses().map(\.state), [.running, .running])
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: try postmaster(manager, "postgres-17")),
                       ["127.0.0.1:\(port17)"])
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: try postmaster(manager, "postgres-18")),
                       ["127.0.0.1:\(port)"])
        XCTAssertTrue(try pdo(tcp(port17, "postgres"), "server").hasPrefix("root 17.12 "))
        XCTAssertTrue(try pdo(tcp(port, "postgres"), "server").hasPrefix("root 18.7 "))
        XCTAssertEqual(try pdo(tcp(port17, "postgres"), "databases"), "postgres", "17 has its own data")
        XCTAssertTrue(isSocket(socketPath("postgres-17", port: port17)))

        // The postmaster and its children run in their data folder: that is how Paddock tells this instance's
        // server from another instance's of the same binaries.
        let pid17 = try postmaster(manager, "postgres-17")
        let data17 = try XCTUnwrap(ServiceManager.realPath(home.paths.serviceData("postgres-17").path))
        XCTAssertEqual(ServiceProcessInspector.live.workingDirectory(pid17), data17)
        for child in children(of: pid17) {
            XCTAssertEqual(ServiceProcessInspector.live.workingDirectory(child), data17, "child \(child)")
        }

        // 18's lock files naming 17's postmaster (a pid reused by another instance of the same kind): removed,
        // 18 starts, and 17 is untouched and still serving.
        manager.stop("postgres-18")
        try Data("\(pid17)\n\(data18.path)\n".utf8).write(to: postmasterPid)
        try Data("\(pid17)\n".utf8).write(to: socketLock)
        try manager.start("postgres-18")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")
        XCTAssertEqual(try postmaster(manager, "postgres-17"), pid17, "17 was not restarted")
        XCTAssertTrue(try pdo(tcp(port17, "postgres"), "server").hasPrefix("root 17.12 "))

        // Lock files naming a dead pid are left to PostgreSQL, which removes them itself.
        manager.stop("postgres-18")
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try Data("\(gone.processIdentifier)\n\(data18.path)\n".utf8).write(to: postmasterPid)
        try Data("\(gone.processIdentifier)\n".utf8).write(to: socketLock)
        try manager.start("postgres-18")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")
        XCTAssertEqual(try String(contentsOf: postmasterPid, encoding: .utf8).components(separatedBy: "\n").first,
                       "\(try postmaster(manager, "postgres-18"))")

        // Removing keeps the data; adding again reuses it without initdb.
        let initdbRuns = { manager.logTail("postgres-18").components(separatedBy: "creating subdirectories").count - 1 }
        XCTAssertEqual(initdbRuns(), 1)
        let kept = try manager.remove("postgres-18", deleteData: false)
        XCTAssertEqual(kept, data18)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data18.appendingPathComponent("PG_VERSION").path))
        let again = try await manager.add(kind: "postgres", version: "18")
        XCTAssertEqual(again.id, "postgres-18")
        XCTAssertEqual(status(manager, "postgres-18")?.notice, "Found existing data for PostgreSQL 18; using it.")
        XCTAssertEqual(initdbRuns(), 1, "initdb did not run again")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try pdo(tcp(portAgain), "read"), "over TCP,over the socket")
        _ = try postmaster(manager, "postgres-18")
        _ = try postmaster(manager, "postgres-17")
        manager.stopAll()
    }

    // MARK: - Browsing

    /// The read-only browser over a real PostgreSQL: the databases, a table's columns and rows, a query, and
    /// a write refused before PHP runs.
    func testDatabaseBrowserReadsPostgreSQL() async throws {
        try requirePHP()
        let manager = makeManager([try await postgres("18")])
        let added = try await manager.add(kind: "postgres", version: "18")
        _ = try postmaster(manager, added.id)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try manager.createDatabase(added.id, database: "laravel"), .done)
        try pdo(tcp(port), "setup")
        try pdo(tcp(port), "insert", "read only, please")

        let service = try XCTUnwrap(status(manager, added.id).flatMap(DatabaseService.init))
        let browser = DatabaseBrowser(php: php)
        XCTAssertEqual(try browser.databases(for: service), ["laravel", "postgres"])

        let tables = try browser.tables(for: service, database: "laravel")
        let notes = try XCTUnwrap(tables.first { $0.name == "notes" })
        XCTAssertEqual(notes.schema, "public")
        XCTAssertFalse(notes.isView)

        let columns = try browser.columns(for: service, database: "laravel", table: notes)
        XCTAssertEqual(columns.map(\.name), ["id", "body"])
        XCTAssertEqual(columns.first { $0.name == "id" }?.primary, true)
        XCTAssertEqual(columns.first { $0.name == "body" }?.nullable, false)

        let rows = try browser.rows(for: service, database: "laravel", table: notes, limit: 20)
        XCTAssertEqual(rows.columns, ["id", "body"])
        XCTAssertEqual(rows.rows.count, 1)
        XCTAssertEqual(rows.value(row: 0, column: 1), "read only, please")

        let count = try browser.query(for: service, database: "laravel", sql: "SELECT count(*) FROM notes", limit: 20)
        XCTAssertEqual(count.value(row: 0, column: 0), "1")
        XCTAssertThrowsError(try browser.query(for: service, database: "laravel", sql: "DELETE FROM notes", limit: 20)) {
            XCTAssertEqual($0 as? DatabaseError, .notReadOnly)
        }
        XCTAssertEqual(try pdo(tcp(port), "read"), "read only, please", "the write never reached PostgreSQL")

        // A search looks through the whole table, in the database, and LIKE's own marks stay literal.
        try pdo(tcp(port), "insert", "second note")
        let second = try browser.rows(for: service, database: "laravel", table: notes, search: "SECOND", limit: 20)
        XCTAssertEqual(second.rows.count, 1, "case-insensitive, across the rows that aren't on show")
        XCTAssertEqual(second.value(row: 0, column: 1), "second note")
        try pdo(tcp(port), "insert", "100% sure")
        let percent = try browser.rows(for: service, database: "laravel", table: notes, search: "%", limit: 20)
        XCTAssertEqual(percent.rows.count, 1, "a % in the search is a %, not a wildcard")
        XCTAssertEqual(percent.value(row: 0, column: 1), "100% sure")
        let nobody = try browser.rows(for: service, database: "laravel", table: notes, search: "no such note", limit: 20)
        XCTAssertTrue(nobody.rows.isEmpty)
        XCTAssertFalse(nobody.truncated)

        // A json column comes back as its text, which the window reads as a document.
        try pdo(tcp(port), "json", #"{"theme":"dark","fields":["orders","stock"]}"#)
        let documents = try XCTUnwrap(browser.tables(for: service, database: "laravel").first { $0.name == "documents" })
        let documentRows = try browser.rows(for: service, database: "laravel", table: documents, limit: 20)
        let meta = try XCTUnwrap(documentRows.value(row: 0, column: 1))
        XCTAssertEqual(DatabaseJSON.document(meta)?.preview, #"{"fields":["orders","stock"],"theme":"dark"}"#)
        let pretty = try XCTUnwrap(documentRows.value(row: 0, column: 2))
        XCTAssertEqual(DatabaseJSON.document(pretty)?.pretty, """
        {
          "name" : "Ada",
          "tags" : [
            "a",
            "b"
          ]
        }
        """)
        manager.stopAll()
    }

    // MARK: - A long home

    /// Where the socket path would be longer than macOS allows, PostgreSQL is told to make no socket at all
    /// and serves over TCP; the .env lines say so.
    func testALongHomeServesOverTCPWithoutASocket() async throws {
        try requirePHP()
        let long = try ServiceHome(longFolder: true)
        defer { long.cleanUp() }
        let manager = makeManager([try await postgres("18")], home: long)
        let added = try await manager.add(kind: "postgres", version: "18")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertGreaterThan(socketPath("postgres-18", port: port, home: long).utf8.count, 103)
        XCTAssertEqual(status(manager, "postgres-18")?.state, .running)
        XCTAssertEqual(try manager.env("postgres-18").last, "# Unix socket disabled: Paddock's folder path is too long")
        let run = long.paths.serviceRun("postgres-18")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.path).filter { $0.hasPrefix(".s.PGSQL") }, [])
        XCTAssertEqual(try manager.createDatabase("postgres-18", database: "laravel"), .done)
        XCTAssertEqual(try pdo(tcp(port), "via"), "127.0.0.1")
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: try postmaster(manager, "postgres-18")),
                       ["127.0.0.1:\(port)"])
        manager.stopAll()
    }

    // MARK: - Crashes and orphans

    /// A postmaster killed outright is restarted by the supervisor despite its stale postmaster.pid; a daemon
    /// killed outright leaves postgres running, and the next daemon stops that whole postmaster (its children
    /// with it) and starts it again on the same data, which isn't left locked.
    func testACrashedPostmasterAndADaemonsOrphanAreRecovered() async throws {
        try requirePHP()
        try TestSupport.requireVendored()
        let recipe = try await postgres("18")
        let manager = makeManager([recipe])
        let added = try await manager.add(kind: "postgres", version: "18")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try manager.createDatabase("postgres-18", database: "laravel"), .done)
        try pdo(tcp(port), "setup")
        try pdo(tcp(port), "insert", "before the crash")

        // The supervisor's restart.
        let crashed = try postmaster(manager, "postgres-18")
        let crashedChildren = children(of: crashed)
        XCTAssertFalse(crashedChildren.isEmpty)
        kill(crashed, SIGKILL)
        let pidFile = home.paths.serviceData("postgres-18").appendingPathComponent("postmaster.pid")
        var restarted: Int32 = 0
        XCTAssertTrue(waitFor(30) {
            guard let pid = manager.processes["service-postgres-18"].flatMap(TestSupport.pid(from:)), pid != crashed else {
                return false
            }
            restarted = pid
            return PortCheck.acceptsIPv4(port: port)
        }, "restarted")
        started.insert(restarted)
        XCTAssertTrue(waitFor(30) { (try? self.quietRead(port)) == "before the crash" }, "serving the same data again")
        XCTAssertTrue(waitFor(10) { crashedChildren.allSatisfy { !self.isAlive($0) || !self.isOurPostgres($0) } },
                      "the crashed postmaster's children went with it")
        manager.stopAll()

        // A daemon killed outright.
        let catalog = home.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(ServiceCatalog(recipes: [recipe])).write(to: catalog)
        let client = PaddockClient(paths: home.paths)
        try launchDaemon(catalog: catalog)
        guard case .ok(let running) = try client.send(.serviceStart(name: "postgres-18"), timeout: 120) else {
            return XCTFail("start through the daemon")
        }
        _ = try client.send(.stop, timeout: 60) // Only the service should outlive the daemon.
        let orphan = try XCTUnwrap(running.processes["service-postgres-18"].flatMap(TestSupport.pid(from:)))
        started.insert(orphan)
        let orphanChildren = children(of: orphan)
        XCTAssertFalse(orphanChildren.isEmpty, "a postmaster has children (checkpointer, walwriter…)")
        for child in orphanChildren { started.insert(child) }
        let daemon = try XCTUnwrap(self.daemon)
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        self.daemon = nil
        XCTAssertTrue(waitFor(5) { ServiceProcessRecord.parent(of: orphan) == 1 }, "an orphan of launchd")
        XCTAssertEqual(try quietRead(port), "before the crash", "still serving without its daemon")

        try launchDaemon(catalog: catalog)
        var fresh: Int32 = 0
        XCTAssertTrue(waitFor(90) {
            guard case .ok(let status)? = try? client.send(.status, timeout: 5),
                  status.services.first?.state == .running,
                  let pid = status.processes["service-postgres-18"].flatMap(TestSupport.pid(from:)) else { return false }
            fresh = pid
            return true
        }, "running again under the new daemon")
        started.insert(fresh)
        XCTAssertNotEqual(fresh, orphan)
        XCTAssertFalse(isAlive(orphan), "the orphaned postmaster was stopped")
        for child in orphanChildren { XCTAssertFalse(isAlive(child) && isOurPostgres(child), "child \(child) was stopped") }
        let pidFileText = try String(contentsOf: pidFile, encoding: .utf8)
        XCTAssertEqual(pidFileText.components(separatedBy: "\n").first, "\(fresh)", "the data folder is the new postmaster's")
        XCTAssertEqual(try pdo(tcp(port), "read"), "before the crash")
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: fresh), ["127.0.0.1:\(port)"])
        for child in children(of: fresh) { started.insert(child) }
    }

    /// `read` without failing the test (while waiting for a restart).
    private func quietRead(_ port: Int) throws -> String {
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", "-r", "echo implode(',', (new PDO($argv[1], 'root', ''))->query('SELECT body FROM notes "
                             + "ORDER BY id')->fetchAll(PDO::FETCH_COLUMN));", tcp(port)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }

    // MARK: - 16, and too old a macOS

    /// 16 is installed from its verified archive and its programs run from wherever they are unpacked; the
    /// archive Paddock downloaded carries no quarantine mark, and nor does anything installed.
    func testPostgreSQL16InstallsAndRuns() async throws {
        let recipe = try await postgres("16")
        XCTAssertEqual(recipe.version, "16.16.0")
        let cached = try XCTUnwrap(recipe.assets.first?.artifact.url)
        XCTAssertEqual(getxattr(cached.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "not quarantined")
        let installer = ServiceInstaller(paths: home.paths)
        let bin = try await installer.install(recipe)
        for program in ["postgres", "initdb", "createdb", "pg_ctl"] {
            let output = try run(bin.appendingPathComponent("bin/\(program)"), ["--version"])
            XCTAssertTrue(output.hasSuffix("(PostgreSQL) 16.16\n"), "\(program): \(output)")
        }
        let quarantined = (FileManager.default.enumerator(atPath: bin.path)?.allObjects as? [String] ?? []).filter {
            getxattr(bin.appendingPathComponent($0).path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
        XCTAssertEqual(quarantined, [])
    }

    private func run(_ program: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }

    /// PostgreSQL's binaries need macOS 15: on an older Mac, adding it is refused before any download.
    func testAnOlderMacOSIsRefused() async throws {
        let recipe = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "postgres", series: "18"))
        XCTAssertEqual(recipe.minimumMacOS, "15.0")
        let manager = makeManager([recipe], macOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1))
        do {
            _ = try await manager.add(kind: "postgres", version: nil)
            XCTFail("added")
        } catch let error as ServiceError {
            XCTAssertEqual(Engine.response(for: error), .error(code: ErrorCode.serviceUnavailable,
                                                               message: "PostgreSQL 18 needs macOS 15 or later."))
        }
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "postgres", version: "18.7.0").path))
    }

    // MARK: - Daemon

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
