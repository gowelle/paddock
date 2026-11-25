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

    func testEditingARowLoadsItsWholeValues() async throws {
        await model.beginEdit(row: 0)
        XCTAssertEqual(model.editingRow, 0)
        XCTAssertEqual(model.draft?.text(for: "name"), "Ada Lovelace")
        XCTAssertEqual(browser.rowKeys, [["id": "1"]])
        XCTAssertFalse(model.canSaveDraft, "nothing has changed yet")
    }

    func testSavingSendsOnlyWhatChangedAndKeepsTheNotice() async throws {
        await model.beginEdit(row: 0)
        model.setDraftText("Ada L.", column: "name")
        XCTAssertTrue(model.canSaveDraft)
        await model.saveDraft()

        XCTAssertEqual(browser.updated?.key, ["id": "1"])
        XCTAssertEqual(browser.updated?.changes, ["name": "Ada L."])
        XCTAssertEqual(browser.updated?.expected["id"] ?? nil, "1")
        XCTAssertNil(model.draft)
        XCTAssertNil(model.editingRow)
        XCTAssertEqual(model.notice, "Saved.")
        XCTAssertEqual(model.rows?.rows.count, 5, "the table reloaded")
    }

    func testAConflictKeepsTheDraftAndItsText() async throws {
        browser.conflict = .failed("This row changed since it was read. Reload and try again.")
        await model.beginEdit(row: 0)
        model.setDraftText("Ada L.", column: "name")
        await model.saveDraft()

        XCTAssertNotNil(model.draft)
        XCTAssertEqual(model.draft?.text(for: "name"), "Ada L.")
        XCTAssertEqual(model.lastError, "This row changed since it was read. Reload and try again.")
        XCTAssertNil(model.notice)
    }

    func testInsertingSendsOnlyTheTouchedFields() async throws {
        model.beginInsert()
        XCTAssertNil(model.editingRow)
        XCTAssertTrue(model.canSaveDraft, "a fully defaulted row can be added")
        model.setDraftText("Grace", column: "name")
        await model.saveDraft()

        XCTAssertEqual(browser.inserted, ["name": "Grace"])
        XCTAssertEqual(model.notice, "Added.")
        XCTAssertNil(model.draft)
    }

    func testDeletingReadsTheRowFirstAndReloads() async throws {
        model.requestDelete(row: 1)
        let key = try XCTUnwrap(model.pendingDelete)
        XCTAssertEqual(key.description, "id = 2")
        await model.confirmDelete(key)

        XCTAssertEqual(browser.deleted, ["id": "2"])
        XCTAssertEqual(model.notice, "Deleted.")
        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(model.rows?.rows.count, 5)
    }

    /// The alert clears the pending row as it dismisses, before the task its Delete button starts can read it.
    func testDeletingHoldsTheRowTheDialogNamedPastItsDismissal() async throws {
        model.requestDelete(row: 1)
        let key = try XCTUnwrap(model.pendingDelete)
        model.cancelDelete()
        await model.confirmDelete(key)

        XCTAssertEqual(browser.deleted, ["id": "2"])
        XCTAssertEqual(model.notice, "Deleted.")
    }

    func testATableWithoutAPrimaryKeyCannotBeEdited() async throws {
        await model.select(table: FakeBrowser.keyless)
        XCTAssertFalse(model.isEditableTable)
        XCTAssertEqual(model.readOnlyNote, "Read-only: no primary key")
        model.beginInsert()
        XCTAssertNil(model.draft)
    }

    func testTheConsoleWaitsWhileARowIsOpen() async throws {
        model.setQuery("SELECT 1")
        XCTAssertTrue(model.canRunQuery)
        await model.beginEdit(row: 0)
        XCTAssertFalse(model.canRunQuery, "⌘⏎ saves the row")
        model.cancelDraft()
        XCTAssertTrue(model.canRunQuery)
    }

    func testWhoeverHasAnUnsavedRowIsAskedBeforeLeaving() async throws {
        await model.beginEdit(row: 0)
        model.setDraftText("Ada L.", column: "name")
        await model.go(to: .table(FakeBrowser.logs))

        XCTAssertEqual(model.pendingDiscard, .table(FakeBrowser.logs))
        XCTAssertEqual(model.table?.id, FakeBrowser.users.id, "still here until the answer")
        let destination = try XCTUnwrap(model.pendingDiscard)
        model.cancelDiscard()
        await model.discardAndGo(destination)

        XCTAssertNil(model.pendingDiscard)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.table?.id, FakeBrowser.logs.id)
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

/// Records the searches it is asked for, narrows its sample rows as the real browser does, and writes one row.
private final class FakeBrowser: DatabaseBrowsing, DatabaseWriting, @unchecked Sendable {
    static let users = DatabaseTable(schema: "public", name: "users", kind: "table")
    static let logs = DatabaseTable(schema: "public", name: "logs", kind: "table")
    static let keyless = DatabaseTable(schema: "public", name: "keyless", kind: "table")

    private static let userColumns = ["id", "name"]
    private static let userRows: [[String?]] = [
        ["1", "Ada Lovelace"], ["2", "Grace Hopper"], ["3", "Alan Turing"],
        ["4", "Katherine Johnson"], ["5", "Edsger Dijkstra"],
    ]

    private let lock = NSLock()
    private var recorded: [String?] = []

    /// When set, every write refuses with it, as a database that moved on does.
    var conflict: DatabaseError?
    private(set) var rowKeys: [[String: String?]] = []
    private(set) var inserted: [String: String?]?
    private(set) var updated: (key: [String: String?], changes: [String: String?],
                               expected: [String: String?])?
    private(set) var deleted: [String: String?]?

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
        [Self.users, Self.logs, Self.keyless]
    }

    func columns(for service: DatabaseService, database: String, table: DatabaseTable) throws -> [DatabaseColumn] {
        switch table.id {
        case Self.users.id:
            return [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil,
                                   primary: true, identity: true),
                    DatabaseColumn(name: "name", type: "text", nullable: false, defaultValue: nil, primary: false)]
        case Self.keyless.id:
            return [DatabaseColumn(name: "body", type: "text", nullable: true, defaultValue: nil, primary: false)]
        default:
            return [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil, primary: true),
                    DatabaseColumn(name: "line", type: "text", nullable: false, defaultValue: nil, primary: false)]
        }
    }

    func rows(for service: DatabaseService, database: String, table: DatabaseTable,
              search: String?, limit: Int) throws -> DatabaseRows {
        if table.id == Self.keyless.id {
            return DatabaseRows(columns: ["body"], rows: [["hello"]], truncated: false)
        }
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

    func row(for service: DatabaseService, database: String, table: DatabaseTable,
             key: [String: String?]) throws -> [String: String?] {
        rowKeys.append(key)
        return ["id": key["id"] ?? nil, "name": "Ada Lovelace"]
    }

    func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                values: [String: String?]) throws {
        if let conflict { throw conflict }
        inserted = values
    }

    func update(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], changes: [String: String?],
                expected: [String: String?]) throws {
        if let conflict { throw conflict }
        updated = (key, changes, expected)
    }

    func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], expected: [String: String?]) throws {
        if let conflict { throw conflict }
        deleted = key
    }
}
