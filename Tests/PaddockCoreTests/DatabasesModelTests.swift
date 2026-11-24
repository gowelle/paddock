import Foundation
import XCTest
@testable import PaddockCore

/// The Databases window's logic against a fake browser: a table's rows, search narrowing them in the database,
/// and what the window says while they don't match.
@MainActor
final class DatabasesModelTests: XCTestCase {
    private var browser: FakeBrowser!
    private var model: DatabasesModel!

    override func setUp() async throws {
        browser = FakeBrowser()
        let service = ServiceStatus(id: "postgres-18", name: "PostgreSQL 18", kind: "postgres", version: "18",
                                    displayName: "PostgreSQL 18", state: .running, ports: ["main": 5432],
                                    env: [], openURL: nil, dataPath: "/tmp/postgres-18", autostart: true,
                                    mainPort: 5432)
        model = DatabasesModel(browser: browser, services: { [service] })
        await model.refresh()
        await model.select(table: FakeBrowser.users)
    }

    func testTheFirstRowsComeWithoutASearch() {
        XCTAssertEqual(model.rows?.rows.count, 5)
        XCTAssertEqual(model.rowCountText, "First 50 rows.")
        XCTAssertTrue(browser.searches.allSatisfy { $0 == nil })
        XCTAssertNil(model.noRowsText)
    }

    func testSearchNarrowsTheRowsAndClearingBringsThemBack() async throws {
        model.setRowSearch("ADA")
        XCTAssertTrue(model.isSearching)
        await waitUntil("the search's rows") { self.model.rows?.rows.count == 1 }

        XCTAssertEqual(model.rows?.value(row: 0, column: 1), "Ada Lovelace")
        XCTAssertEqual(model.rowCountText, "1 match")
        XCTAssertEqual(browser.lastSearch, "ADA")

        model.setRowSearch("nobody")
        await waitUntil("no matches") { self.model.rows?.rows.isEmpty == true }
        XCTAssertEqual(model.rowCountText, "No matches")
        XCTAssertEqual(model.noRowsText, "No rows match \u{201C}nobody\u{201D}.")

        model.setRowSearch("")
        XCTAssertFalse(model.isSearching)
        await waitUntil("the rows again") { self.model.rows?.rows.count == 5 }
        XCTAssertNil(model.noRowsText)
        XCTAssertEqual(model.rowCountText, "First 50 rows.")
    }

    func testChoosingAnotherTableClearsTheSearch() async throws {
        model.setRowSearch("ada")
        await waitUntil("the search's rows") { self.model.rows?.rows.count == 1 }

        await model.select(table: FakeBrowser.logs)

        XCTAssertEqual(model.rowSearch, "")
        XCTAssertEqual(model.rows?.columns, ["id", "line"])
        XCTAssertEqual(browser.lastSearch, nil)
    }

    /// Waits (briefly) for the model's own work, which runs a moment after the last keystroke.
    private func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }
}

/// Records the searches it is asked for and narrows its sample rows as the real browser does.
private final class FakeBrowser: DatabaseBrowsing, @unchecked Sendable {
    static let users = DatabaseTable(schema: "public", name: "users", kind: "table")
    static let logs = DatabaseTable(schema: "public", name: "logs", kind: "table")

    private static let userColumns = ["id", "name"]
    private static let userRows: [[String?]] = [
        ["1", "Ada Lovelace"], ["2", "Grace Hopper"], ["3", "Alan Turing"],
        ["4", "Katherine Johnson"], ["5", "Edsger Dijkstra"],
    ]

    private let lock = NSLock()
    private var recorded: [String?] = []

    var searches: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var lastSearch: String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last ?? nil
    }

    func databases(for service: DatabaseService) throws -> [String] { ["postgres", "shop"] }

    func tables(for service: DatabaseService, database: String) throws -> [DatabaseTable] {
        [Self.users, Self.logs]
    }

    func columns(for service: DatabaseService, database: String, table: DatabaseTable) throws -> [DatabaseColumn] {
        table.id == Self.users.id
            ? [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil, primary: true),
               DatabaseColumn(name: "name", type: "text", nullable: false, defaultValue: nil, primary: false)]
            : [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil, primary: true),
               DatabaseColumn(name: "line", type: "text", nullable: false, defaultValue: nil, primary: false)]
    }

    func rows(for service: DatabaseService, database: String, table: DatabaseTable,
              search: String?, limit: Int) throws -> DatabaseRows {
        lock.lock()
        recorded.append(search)
        lock.unlock()
        if table.id == Self.logs.id {
            return DatabaseRows(columns: ["id", "line"], rows: [["1", "started"]], truncated: false)
        }
        guard let search, !search.isEmpty else {
            return DatabaseRows(columns: Self.userColumns, rows: Self.userRows, truncated: true)
        }
        let matched = Self.userRows.filter { row in
            row.contains { value in (value ?? "").localizedCaseInsensitiveContains(search) }
        }
        return DatabaseRows(columns: Self.userColumns, rows: matched, truncated: false)
    }

    func query(for service: DatabaseService, database: String, sql: String, limit: Int) throws -> DatabaseRows {
        DatabaseRows(columns: [], rows: [], truncated: false)
    }
}
