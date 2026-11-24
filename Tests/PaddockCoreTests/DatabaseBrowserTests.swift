import Foundation
import XCTest
@testable import PaddockCore

final class DatabaseBrowserTests: XCTestCase {
    // MARK: - Read-only rule

    func testReadOnlySQLAllowsReads() {
        for sql in [
            "SELECT 1", "select * from users", "  SELECT 1;  ",
            "-- a comment\nSELECT 1", "/* note */ SHOW TABLES", "WITH x AS (SELECT 1) SELECT * FROM x",
            "(SELECT 1)", "EXPLAIN SELECT 1", "TABLE users", "VALUES (1)",
            "WITH x AS (SELECT 'delete' AS note) SELECT * FROM x",
            "SELECT * FROM users WHERE note = 'UPDATE'", "SELECT * FROM users -- DELETE is a word here",
        ] {
            XCTAssertTrue(ReadOnlySQL.allows(sql), sql)
        }
    }

    func testReadOnlySQLRefusesWritesAndMultipleStatements() {
        for sql in [
            "", "   ", "INSERT INTO users VALUES (1)", "UPDATE users SET x = 1", "DELETE FROM users",
            "DROP TABLE users", "ALTER TABLE users ADD x int", "SELECT 1; DROP TABLE users",
            "SELECT 1; SELECT 2", "WITH x AS (SELECT 1) DELETE FROM users", "PRAGMA foreign_keys = off",
            "WITH x AS (SELECT 1) UPDATE users SET x = 1", "SELECT * FROM users FOR UPDATE",
        ] {
            XCTAssertFalse(ReadOnlySQL.allows(sql), sql)
        }
    }

    // MARK: - Service mapping

    func testDatabaseServiceMapsPostgresAndMySQLOnly() {
        let postgres = service("postgres-18", kind: "postgres", state: .running, port: 5432)
        let mapped = DatabaseService(postgres)
        XCTAssertEqual(mapped?.engine, .postgres)
        XCTAssertEqual(mapped?.port, 5432)
        XCTAssertEqual(mapped?.isRunning, true)

        let mysql = service("mysql-8-4", kind: "mysql", state: .stopped, port: 3306)
        XCTAssertEqual(DatabaseService(mysql)?.engine, .mysql)
        XCTAssertEqual(DatabaseService(mysql)?.isRunning, false)

        XCTAssertNil(DatabaseService(service("mail", kind: "mail", state: .running, port: nil)))
        XCTAssertNil(DatabaseService(service("postgres-18", kind: "postgres", state: .running, port: nil)))
    }

    func testDatabaseNamesAreSafeForADSN() {
        for name in ["laravel", "app_db", "my-db", "my.db", "A1"] {
            XCTAssertNoThrow(try DatabaseBrowser.validate(database: name), name)
        }
        for name in ["", " space", "with space", "x;y", "x'y", ";drop", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try DatabaseBrowser.validate(database: name), name)
        }
    }

    // MARK: - The PHP bridge

    func testDatabasesSendsTheMaintenanceDatabaseAndReadsTheList() throws {
        let runner = FakeRunner(answer: #"{"ok":true,"result":["laravel","postgres"]}"#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        let names = try browser.databases(for: databaseService())

        XCTAssertEqual(names, ["laravel", "postgres"])
        let request = try XCTUnwrap(runner.request)
        XCTAssertEqual(request["action"] as? String, "databases")
        XCTAssertEqual(request["driver"] as? String, "pgsql")
        XCTAssertEqual(request["database"] as? String, "postgres")
        XCTAssertEqual(request["host"] as? String, "127.0.0.1")
        XCTAssertEqual(request["port"] as? Int, 5432)
        XCTAssertEqual(request["user"] as? String, "root")
        XCTAssertEqual(request["password"] as? String, "")
        XCTAssertEqual(runner.arguments.first, "-d")
        XCTAssertTrue(runner.arguments.contains("display_errors=0"))
    }

    func testTablesDecodesSchemasAndViews() throws {
        let runner = FakeRunner(answer: #"""
        {"ok":true,"result":[{"schema":"public","name":"users","kind":"table"},{"schema":null,"name":"v","kind":"view"}]}
        """#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        let tables = try browser.tables(for: databaseService(), database: "laravel")

        XCTAssertEqual(tables.map(\.displayName), ["public.users", "v"])
        XCTAssertEqual(tables.map(\.isView), [false, true])
        XCTAssertEqual(try XCTUnwrap(runner.request)["table"] as? String, nil)
        XCTAssertEqual(try XCTUnwrap(runner.request)["database"] as? String, "laravel")
    }

    func testColumnsDecodeDefaultsAndPrimaryKeys() throws {
        let runner = FakeRunner(answer: #"""
        {"ok":true,"result":[{"name":"id","type":"bigint","nullable":false,"default":null,"primary":true},
                             {"name":"name","type":"text","nullable":true,"default":"'x'","primary":false}]}
        """#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)
        let table = DatabaseTable(schema: "public", name: "users", kind: "table")

        let columns = try browser.columns(for: databaseService(), database: "laravel", table: table)

        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertTrue(columns[0].primary)
        XCTAssertNil(columns[0].defaultValue)
        XCTAssertTrue(columns[1].nullable)
        XCTAssertEqual(columns[1].defaultValue, "'x'")
        let request = try XCTUnwrap(runner.request)
        XCTAssertEqual(request["schema"] as? String, "public")
        XCTAssertEqual(request["table"] as? String, "users")
    }

    func testRowsDecodeNullsAndClampTheLimit() throws {
        let runner = FakeRunner(answer: #"""
        {"ok":true,"result":{"columns":["id","name"],"rows":[["1","Ada"],["2",null]],"truncated":false}}
        """#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)
        let table = DatabaseTable(schema: nil, name: "users", kind: "table")

        let rows = try browser.rows(for: databaseService(engine: .mysql), database: "laravel", table: table,
                                     limit: 5000)

        XCTAssertEqual(rows.columns, ["id", "name"])
        XCTAssertEqual(rows.value(row: 0, column: 1), "Ada")
        XCTAssertNil(rows.value(row: 1, column: 1))
        XCTAssertEqual(try XCTUnwrap(runner.request)["limit"] as? Int, 1000)
        XCTAssertEqual(try XCTUnwrap(runner.request)["driver"] as? String, "mysql")
    }

    func testSearchRowsSendsTheTrimmedTerm() throws {
        let runner = FakeRunner(answer: #"""
        {"ok":true,"result":{"columns":["id","name"],"rows":[["1","Ada"]],"truncated":false}}
        """#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)
        let table = DatabaseTable(schema: "public", name: "users", kind: "table")

        let rows = try browser.rows(for: databaseService(), database: "laravel", table: table,
                                     search: "  Ada  ", limit: 20)

        XCTAssertEqual(rows.rows.count, 1)
        let request = try XCTUnwrap(runner.request)
        XCTAssertEqual(request["action"] as? String, "rows")
        XCTAssertEqual(request["search"] as? String, "Ada")
        XCTAssertEqual(request["schema"] as? String, "public")
        XCTAssertEqual(request["table"] as? String, "users")
    }

    func testABlankSearchIsNoSearch() throws {
        let runner = FakeRunner(answer: #"{"ok":true,"result":{"columns":[],"rows":[],"truncated":false}}"#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)
        let table = DatabaseTable(schema: nil, name: "users", kind: "table")

        _ = try browser.rows(for: databaseService(), database: "laravel", table: table, search: "   ", limit: 20)

        XCTAssertNil(try XCTUnwrap(runner.request)["search"], "whitespace is not a search")
    }

    func testQueryRefusesWritesBeforePhpRuns() {
        let runner = FakeRunner(answer: #"{"ok":true,"result":{"columns":[],"rows":[],"truncated":false}}"#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        XCTAssertThrowsError(try browser.query(for: databaseService(), database: "laravel", sql: "DELETE FROM users")) {
            XCTAssertEqual($0 as? DatabaseError, .notReadOnly)
        }
        XCTAssertNil(runner.request, "PHP must not be started for a write")
    }

    func testQuerySendsOneReadOnlyStatement() throws {
        let runner = FakeRunner(answer: #"""
        {"ok":true,"result":{"columns":["count"],"rows":[["2"]],"truncated":false}}
        """#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        let rows = try browser.query(for: databaseService(), database: "laravel", sql: "SELECT count(*) FROM users")

        XCTAssertEqual(rows.value(row: 0, column: 0), "2")
        XCTAssertEqual(try XCTUnwrap(runner.request)["sql"] as? String, "SELECT count(*) FROM users")
    }

    func testAPHPFailureBecomesTheOwnersSentence() {
        let runner = FakeRunner(answer: #"{"ok":false,"error":"database \"x\" does not exist"}"#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        XCTAssertThrowsError(try browser.databases(for: databaseService())) {
            XCTAssertEqual($0 as? DatabaseError, .failed("database \"x\" does not exist"))
        }
    }

    func testAnUnreadableAnswerIsAFailure() {
        let runner = FakeRunner(answer: "not json")
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)

        XCTAssertThrowsError(try browser.databases(for: databaseService())) {
            guard case .failed = $0 as? DatabaseError else { return XCTFail("\($0)") }
        }
    }

    func testARefusedServiceNeverStartsPHP() {
        let runner = FakeRunner(answer: #"{"ok":true,"result":[]}"#)
        let browser = DatabaseBrowser(php: URL(fileURLWithPath: "/php"), runner: runner)
        let stopped = DatabaseService(id: "postgres-18", name: "PostgreSQL 18", engine: .postgres,
                                      port: 5432, isRunning: false)

        XCTAssertThrowsError(try browser.databases(for: stopped)) {
            XCTAssertEqual($0 as? DatabaseError, .notRunning("PostgreSQL 18"))
        }
        XCTAssertNil(runner.request)
    }

    // MARK: - Helpers

    private func databaseService(engine: DatabaseEngine = .postgres) -> DatabaseService {
        DatabaseService(id: engine == .postgres ? "postgres-18" : "mysql-9-7",
                        name: engine == .postgres ? "PostgreSQL 18" : "MySQL 9.7",
                        engine: engine, port: engine == .postgres ? 5432 : 3306, isRunning: true)
    }

    private func service(_ id: String, kind: String, state: ServiceState, port: Int?) -> ServiceStatus {
        ServiceStatus(id: id, name: id, kind: kind, version: "1", displayName: kind, state: state,
                      ports: port.map { ["main": $0] } ?? [:], env: [], openURL: nil,
                      dataPath: "/tmp/\(id)", autostart: true, mainPort: port)
    }
}

/// Answers with one canned string and records what it was asked.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    let answer: String
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    private(set) var request: [String: Any]?

    init(answer: String) { self.answer = answer }

    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String) {
        self.arguments = arguments
        self.environment = environment ?? [:]
        if let encoded = environment?["PADDOCK_DB_REQUEST"], let data = Data(base64Encoded: encoded) {
            request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return (0, answer)
    }
}
