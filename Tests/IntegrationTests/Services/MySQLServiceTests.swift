import Darwin
import XCTest
@testable import PaddockCore

/// The real MySQL recipes (from the bundled catalog; archives cached in Vendor/services/), in scratch homes on
/// free high ports. 8.4 runs end to end with Paddock's own PHP talking PDO over TCP and over the instance's Unix
/// socket; 9.7 runs beside it on its own port and data.
final class MySQLServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    /// mysqld processes these tests saw; any still alive at the end is killed (none should be).
    private var started: Set<Int32> = []

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        for pid in started where isAlive(pid) && isOurs(pid) {
            XCTFail("mysqld \(pid) was left running")
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
    private func mysql(_ series: String) async throws -> ServiceRecipe {
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "mysql", series: series),
                                    "the catalog has MySQL \(series)")
        return try await ServiceDownloadCache.localRecipe(bundled)
    }

    private func makeManager(_ recipes: [ServiceRecipe], home: ServiceHome? = nil) -> ServiceManager {
        let home = home ?? self.home!
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    private func status(_ manager: ServiceManager, _ id: String) -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func server(_ manager: ServiceManager, _ id: String) throws -> Int32 {
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName(id)].flatMap(TestSupport.pid(from:)))
        started.insert(pid)
        return pid
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// A live process running a program from a scratch home (never the Mac's own MySQL).
    private func isOurs(_ pid: Int32) -> Bool {
        guard let program = PortCheck.executablePath(pid: pid) else { return false }
        return program.hasPrefix(home.paths.home.path) || program.hasPrefix("/private" + home.paths.home.path)
    }

    private func socketPath(_ id: String, home: ServiceHome? = nil) -> String {
        (home ?? self.home!).paths.serviceRun(id).appendingPathComponent("mysql.sock").path
    }

    private func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func tcp(_ port: Int, _ database: String = "laravel") -> String {
        "mysql:host=127.0.0.1;port=\(port);dbname=\(database)"
    }

    private func unixSocket(_ id: String, _ database: String = "laravel") -> String {
        "mysql:unix_socket=\(socketPath(id));dbname=\(database)"
    }

    /// Runs one PDO operation with Paddock's PHP 8.5; returns its output (fails the test on an error).
    @discardableResult
    private func pdo(_ dsn: String, _ operation: String, _ argument: String = "",
                     file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = home.root.appendingPathComponent("pdo-mysql.php")
        if !FileManager.default.fileExists(atPath: script.path) {
            try Data(#"""
            <?php
            [, $dsn, $op, $arg] = $argv + [3 => ''];
            try {
                $pdo = new PDO($dsn, 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                switch ($op) {
                    case 'setup':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS notes (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT NOT NULL)');
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
                        $rows = $pdo->query("SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN"
                            . " ('mysql', 'sys', 'information_schema', 'performance_schema') ORDER BY schema_name");
                        echo implode(',', $rows->fetchAll(PDO::FETCH_COLUMN)), "\n";
                        break;
                    case 'via':
                        // The connection's own description: "127.0.0.1 via TCP/IP" or "Localhost via UNIX socket".
                        echo $pdo->getAttribute(PDO::ATTR_CONNECTION_STATUS), "\n";
                        break;
                    case 'server':
                        // Who, which version, the default character set, and how many X plugins are active.
                        echo $pdo->query("SELECT CONCAT(SUBSTRING_INDEX(CURRENT_USER(), '@', 1), ' ', @@version, ' ',"
                            . " @@character_set_server, ' ', (SELECT COUNT(*) FROM information_schema.plugins"
                            . " WHERE plugin_name = 'mysqlx' AND plugin_status = 'ACTIVE'))")->fetchColumn(), "\n";
                        break;
                    case 'accounts':
                        $rows = $pdo->query("SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user = 'root' ORDER BY host");
                        echo implode(',', $rows->fetchAll(PDO::FETCH_COLUMN)), "\n";
                        break;
                    case 'json':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS documents (id INT AUTO_INCREMENT PRIMARY KEY,'
                            . ' meta JSON NOT NULL)');
                        $pdo->prepare('INSERT INTO documents (meta) VALUES (?)')->execute([$arg]);
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

    // MARK: - 8.4 and 9.7

    /// MySQL 8.4 from add to re-add: its preferred port taken, PDO over TCP and over its socket, databases created
    /// (and an existing or invalid one handled), data kept across a stop and start, 9.7 beside it on another port
    /// with its own data, loopback only, and a removed instance's data reused without initialising again.
    func testMySQL84And97EndToEnd() async throws {
        try requirePHP()
        let recipes = [try await mysql("8.4"), try await mysql("9.7")]
        let manager = makeManager(recipes)

        let preferred = home.portBase + 3306
        // The preferred (shifted) port is taken: the next free one is chosen.
        let holder = try listenReusingAddress(port: preferred)
        let added = try await manager.add(kind: "mysql", version: "8.4")
        close(holder)
        XCTAssertEqual(added.id, "mysql-8-4")
        XCTAssertEqual(added.name, "MySQL 8.4")
        XCTAssertEqual(added.version, "8.4.11")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertNotEqual(port, 3306, "never the Mac's own MySQL port")
        XCTAssertTrue((preferred + 1...preferred + ServicePorts.searchLimit).contains(port), "the next free port: \(port)")
        let running = try XCTUnwrap(status(manager, "mysql-8-4"))
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.mainPort, port)
        XCTAssertNil(running.openURL)
        XCTAssertEqual(running.env, ["DB_CONNECTION=mysql", "DB_HOST=127.0.0.1", "DB_PORT=\(port)", "DB_DATABASE=laravel",
                                    "DB_USERNAME=root", "DB_PASSWORD="])
        XCTAssertEqual(running.notes, ["MySQL 8.4.11 is the last 8.4 release Oracle built for Intel Macs."])

        // Loopback only: its one TCP listener, with the X plugin's port never opened.
        let pid84 = try server(manager, "mysql-8-4")
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid84), ["127.0.0.1:\(port)"])
        XCTAssertTrue(isSocket(socketPath("mysql-8-4")), "its socket is in its own run folder")
        XCTAssertFalse(manager.logTail("mysql-8-4").contains("/tmp/mysql.sock"), "never a socket in /tmp")

        // Databases.
        XCTAssertEqual(try manager.createDatabase("mysql-8-4", database: "laravel"), .done)
        XCTAssertEqual(try manager.createDatabase("MySQL 8.4", database: "laravel"), .alreadyDone)
        XCTAssertThrowsError(try manager.createDatabase("mysql-8-4", database: "my-db")) { error in
            XCTAssertEqual(error as? ServiceError, .invalidParameter(parameter: "database", value: "my-db"))
        }
        XCTAssertEqual(try pdo(tcp(port, "mysql"), "databases"), "laravel", "my-db was never created")
        XCTAssertEqual(try pdo(tcp(port), "server"), "root 8.4.11 utf8mb4 0", "the X plugin is off")
        XCTAssertEqual(try pdo(tcp(port), "accounts"), "root@localhost", "no account reachable from another Mac")

        // PDO over TCP, then over the Unix socket.
        XCTAssertEqual(try pdo(tcp(port), "via"), "127.0.0.1 via TCP/IP")
        try pdo(tcp(port), "setup")
        try pdo(tcp(port), "insert", "over TCP")
        XCTAssertEqual(try pdo(unixSocket("mysql-8-4"), "via"), "Localhost via UNIX socket")
        try pdo(unixSocket("mysql-8-4"), "insert", "over the socket")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")

        // A database created on request is one an app can use.
        XCTAssertEqual(try manager.createDatabase("mysql-8-4", database: "Shop_2"), .done)
        try pdo(tcp(port, "Shop_2"), "setup")

        // Stop and start keep the data; a clean stop leaves no socket or lock behind.
        manager.stop("mysql-8-4")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: port))
        XCTAssertFalse(isAlive(pid84))
        let run84 = home.paths.serviceRun("mysql-8-4")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run84.path).filter { $0.hasPrefix("mysql.sock") }, [])
        try manager.start("mysql-8-4")
        XCTAssertEqual(try pdo(tcp(port), "read"), "over TCP,over the socket")

        // After an unclean shutdown the pid in the socket's lock file may belong to another process by now:
        // MySQL would refuse to start; Paddock removes the lock, and never signals the process it names.
        manager.stop("mysql-8-4")
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["120"]
        try stranger.run()
        defer { if stranger.isRunning { stranger.terminate() } }
        try Data("\(stranger.processIdentifier)\n".utf8).write(to: run84.appendingPathComponent("mysql.sock.lock"))
        try manager.start("mysql-8-4")
        XCTAssertTrue(stranger.isRunning, "never signalled")
        XCTAssertEqual(try pdo(unixSocket("mysql-8-4"), "read"), "over TCP,over the socket")
        _ = try server(manager, "mysql-8-4")

        // 9.7 beside it: another port, its own data.
        let added97 = try await manager.add(kind: "mysql", version: "9.7")
        XCTAssertEqual(added97.id, "mysql-9-7")
        XCTAssertEqual(added97.name, "MySQL 9.7")
        let port97 = try XCTUnwrap(added97.ports["main"])
        XCTAssertNotEqual(port97, port)
        XCTAssertEqual(manager.statuses().map(\.state), [.running, .running])
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: try server(manager, "mysql-9-7")),
                       ["127.0.0.1:\(port97)"])
        XCTAssertEqual(try pdo(tcp(port97, "mysql"), "server"), "root 9.7.2 utf8mb4 0")
        XCTAssertEqual(try pdo(tcp(port97, "mysql"), "databases"), "", "9.7 has its own data")
        XCTAssertEqual(try pdo(tcp(port, "mysql"), "databases"), "laravel,Shop_2")
        XCTAssertEqual(status(manager, "mysql-9-7")?.notes, [])

        // Each server runs in its own data folder: that is how Paddock tells one instance's server from another's.
        let data97 = try XCTUnwrap(ServiceManager.realPath(home.paths.serviceData("mysql-9-7").path))
        XCTAssertEqual(ServiceProcessInspector.live.workingDirectory(try server(manager, "mysql-9-7")), data97)

        // Removing keeps the data; adding again reuses it without initialising.
        let data84 = home.paths.serviceData("mysql-8-4")
        let initialisations = { manager.logTail("mysql-8-4").components(separatedBy: "initializing of server in progress").count - 1 }
        XCTAssertEqual(initialisations(), 1)
        let kept = try manager.remove("mysql-8-4", deleteData: false)
        XCTAssertEqual(kept, data84)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data84.appendingPathComponent("mysql.ibd").path))
        let again = try await manager.add(kind: "mysql", version: "8.4")
        XCTAssertEqual(again.id, "mysql-8-4")
        XCTAssertEqual(status(manager, "mysql-8-4")?.notice, "Found existing data for MySQL 8.4; using it.")
        XCTAssertEqual(initialisations(), 1, "MySQL was not initialised again")
        let portAgain = try XCTUnwrap(again.ports["main"])
        XCTAssertEqual(try pdo(tcp(portAgain), "read"), "over TCP,over the socket")
        _ = try server(manager, "mysql-8-4")
        _ = try server(manager, "mysql-9-7")
        manager.stopAll()
    }

    // MARK: - Browsing

    /// The read-only browser over a real MySQL: the databases, a table's columns and rows, a query, and a
    /// write refused before PHP runs.
    func testDatabaseBrowserReadsMySQL() async throws {
        try requirePHP()
        let manager = makeManager([try await mysql("8.4")])
        let added = try await manager.add(kind: "mysql", version: "8.4")
        _ = try server(manager, added.id)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try manager.createDatabase(added.id, database: "laravel"), .done)
        try pdo(tcp(port), "setup")
        try pdo(tcp(port), "insert", "read only, please")

        let service = try XCTUnwrap(status(manager, added.id).flatMap(DatabaseService.init))
        let browser = DatabaseBrowser(php: php)
        XCTAssertEqual(try browser.databases(for: service), ["laravel"])

        let tables = try browser.tables(for: service, database: "laravel")
        let notes = try XCTUnwrap(tables.first { $0.name == "notes" }, "tables: \(tables.map(\.displayName))")
        XCTAssertNil(notes.schema)
        XCTAssertFalse(notes.isView)

        let columns = try browser.columns(for: service, database: "laravel", table: notes)
        XCTAssertEqual(columns.map(\.name), ["id", "body"])
        XCTAssertEqual(columns.first { $0.name == "id" }?.primary, true)
        XCTAssertEqual(columns.first { $0.name == "body" }?.nullable, false)

        let rows = try browser.rows(for: service, database: "laravel", table: notes, limit: 20)
        XCTAssertEqual(rows.columns, ["id", "body"])
        XCTAssertEqual(rows.value(row: 0, column: 1), "read only, please")

        let count = try browser.query(for: service, database: "laravel", sql: "SELECT count(*) FROM notes", limit: 20)
        XCTAssertEqual(count.value(row: 0, column: 0), "1")
        XCTAssertThrowsError(try browser.query(for: service, database: "laravel", sql: "DELETE FROM notes", limit: 20)) {
            XCTAssertEqual($0 as? DatabaseError, .notReadOnly)
        }
        XCTAssertEqual(try pdo(tcp(port), "read"), "read only, please", "the write never reached MySQL")

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

        // A JSON column comes back as its text, which the window reads as a document.
        try pdo(tcp(port), "json", #"{"theme":"dark","fields":["orders","stock"]}"#)
        let documents = try XCTUnwrap(browser.tables(for: service, database: "laravel").first { $0.name == "documents" })
        let documentRows = try browser.rows(for: service, database: "laravel", table: documents, limit: 20)
        let meta = try XCTUnwrap(documentRows.value(row: 0, column: 1))
        XCTAssertEqual(DatabaseJSON.document(meta)?.preview, #"{"fields":["orders","stock"],"theme":"dark"}"#)
        manager.stopAll()
    }

    // MARK: - A long home

    /// Where the socket path would be longer than macOS allows, MySQL serves over TCP, the `.env` lines say so,
    /// and its socket (MySQL always makes one) stays inside its own data folder, never in /tmp.
    func testALongHomeServesOverTCPAndKeepsItsSocketInItsDataFolder() async throws {
        try requirePHP()
        let long = try ServiceHome(longFolder: true)
        defer { long.cleanUp() }
        let manager = makeManager([try await mysql("8.4")], home: long)
        let added = try await manager.add(kind: "mysql", version: "8.4")
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertGreaterThan(socketPath("mysql-8-4", home: long).utf8.count, 103)
        XCTAssertEqual(status(manager, "mysql-8-4")?.state, .running)
        XCTAssertEqual(try manager.env("mysql-8-4").last, "# Unix socket disabled: Paddock's folder path is too long")
        let run = long.paths.serviceRun("mysql-8-4")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.path).filter { $0.hasPrefix("mysql.sock") }, [])
        XCTAssertTrue(isSocket(long.paths.serviceData("mysql-8-4").appendingPathComponent("mysql.sock").path))
        XCTAssertFalse(manager.logTail("mysql-8-4").contains("/tmp/mysql.sock"), "never a socket in /tmp")
        XCTAssertEqual(try manager.createDatabase("mysql-8-4", database: "laravel"), .done)
        XCTAssertEqual(try pdo(tcp(port), "via"), "127.0.0.1 via TCP/IP")
        let pid = try XCTUnwrap(manager.processes[ServiceManager.processName("mysql-8-4")].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(try assertListensOnThisMacOnly(processGroup: pid), ["127.0.0.1:\(port)"])
        manager.stopAll()
        XCTAssertFalse(kill(pid, 0) == 0, "stopped")
    }
}
