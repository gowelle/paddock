# Editing Records in the Databases Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner create, edit and delete individual records in the Databases window, safely, while the SQL console and `paddock db` stay read-only.

**Architecture:** Writes join the existing bundled PHP/PDO bridge as three prepared actions (`insert`, `update`, `delete`) plus one read (`row`), with values in a private request file. A pure-Swift draft computes what changed and what the row looked like; `DatabasesModel` runs the draft; the grid edits in place. Each write locks and re-reads its row in the transaction and refuses if it moved.

**Tech Stack:** Swift 6 package, macOS 13+, SwiftUI + AppKit, ArgumentParser (untouched), PHP 8 PDO via the bundled runtime, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-24-database-writes-design.md`

## Global Constraints

- The SQL console stays read-only at all three layers (`ReadOnlySQL`, PHP's keyword check, read-only transaction). Do not change `query`.
- `paddock db` stays read-only: `DatabaseBrowsing` must not gain write methods.
- Only tables with a primary key are editable; views and keyless tables are refused.
- `nil` in a value map means SQL NULL; empty text is not NULL.
- An update with no changes is never sent; an identity, generated or binary column is never written.
- Server errors are shown verbatim; the two conflict messages are exactly:
  - `This row changed since it was read. Reload and try again.`
  - `That row is no longer there. It may have been deleted.`
- No SQL text crosses the boundary; PHP builds every statement and binds every value.
- Swift 6 strict concurrency; `PaddockCore.State` shadows `SwiftUI.State`, so use `@SwiftUI.State` in views.
- Commit messages are one plain sentence (the repo's style), no conventional-commit prefixes.
- Do not publish any release without the owner asking.

---

### Task 1: Commit the verified 0.3.1 fixes

The working tree holds the JSON-cell, column-width and clipping work (VERSION 0.3.1, build 23). It is tested but uncommitted; the write feature builds on it.

**Files:**
- Modify (already modified in the working tree): `README.md`, `Sources/PaddockApp/Databases/DatabasesView.swift`, `Sources/PaddockApp/Snapshots.swift`, `Sources/PaddockCore/Engine.swift`, `Tests/IntegrationTests/Services/MySQLServiceTests.swift`, `Tests/IntegrationTests/Services/PostgresServiceTests.swift`, `VERSION`, `docs/images/databases-light.png`
- Create (already in the working tree): `Sources/PaddockCore/Database/DatabaseGridWidths.swift`, `Sources/PaddockCore/Database/DatabaseJSON.swift`, `Tests/PaddockCoreTests/DatabaseGridWidthsTests.swift`, `Tests/PaddockCoreTests/DatabaseJSONTests.swift`, `docs/releases/0.3.1.md`
- Modify (the spec's one post-commit correction): `docs/superpowers/specs/2026-11-24-database-writes-design.md`
- Modify: `.gitignore` (ignore Qoder's generated `.qoder/` state, so it cannot dirty the tree a release is built from)

**Interfaces:**
- Consumes: nothing.
- Produces: a clean tree containing `DatabaseJSON` and `DatabaseGridWidths`, which Task 3 and Task 6 use.

- [ ] **Step 1: Ignore Qoder's state, then confirm the tree is exactly these changes**

Append `.qoder/` to `.gitignore` (it holds generated repository knowledge, not source, and must not dirty the tree a release is built from). Then:

Run: `git status --short`
Expected: the paths above plus this plan file — the plan being executed, which this task does not commit.

- [ ] **Step 2: Run the unit suite**

Run: `swift test --filter 'PaddockCoreTests'`
Expected: `Executed 809 tests, with 0 failures` (plus the Swift Testing summary line).

- [ ] **Step 3: Commit**

```bash
git add .gitignore README.md Sources/PaddockApp/Databases/DatabasesView.swift Sources/PaddockApp/Snapshots.swift \
  Sources/PaddockCore/Engine.swift Tests/IntegrationTests/Services/MySQLServiceTests.swift \
  Tests/IntegrationTests/Services/PostgresServiceTests.swift VERSION docs/images/databases-light.png \
  Sources/PaddockCore/Database/DatabaseGridWidths.swift Sources/PaddockCore/Database/DatabaseJSON.swift \
  Tests/PaddockCoreTests/DatabaseGridWidthsTests.swift Tests/PaddockCoreTests/DatabaseJSONTests.swift \
  docs/releases/0.3.1.md
git commit -m "JSON cells, column widths and clipped cells in the Databases window"
```

Publishing 0.3.1 later is `Scripts/release.sh 0.3.1 --publish` from a clean `main` — only when the owner asks. VERSION already says 0.3.1 and the build is already 23, so the script will not bump again.

- [ ] **Step 4: Commit the spec correction**

```bash
git add docs/superpowers/specs/2026-11-24-database-writes-design.md
git commit -m "Say a draft survives closing the window"
```

---

### Task 2: Column flags and JSON validity

**Files:**
- Modify: `Sources/PaddockCore/Database/DatabaseBrowser.swift` (`DatabaseColumn`, around lines 111-132)
- Modify: `Sources/PaddockCore/Database/DatabaseJSON.swift`
- Test: `Tests/PaddockCoreTests/DatabaseColumnFlagsTests.swift` (create)
- Test: `Tests/PaddockCoreTests/DatabaseJSONTests.swift` (append)

**Interfaces:**
- Consumes: `DatabaseJSON` (existing).
- Produces:
  - `DatabaseColumn.binary: Bool`, `.generated: Bool`, `.identity: Bool`
  - `DatabaseColumn.isEditable: Bool`
  - `DatabaseColumn.insertPlaceholder: String`
  - `DatabaseJSON.isValid(_ text: String) -> Bool`

- [ ] **Step 1: Write the failing column-flag tests**

Create `Tests/PaddockCoreTests/DatabaseColumnFlagsTests.swift`:

```swift
import XCTest
@testable import PaddockCore

final class DatabaseColumnFlagsTests: XCTestCase {
    func testColumnsKnowWhatTheDatabaseOwns() throws {
        let json = #"""
        [{"name":"id","type":"bigint","nullable":false,"default":null,"primary":true,
          "binary":false,"generated":false,"identity":true},
         {"name":"avatar","type":"bytea","nullable":true,"default":null,"primary":false,
          "binary":true,"generated":false,"identity":false},
         {"name":"total","type":"numeric","nullable":false,"default":"0","primary":false,
          "binary":false,"generated":true,"identity":false}]
        """#.data(using: .utf8)!
        let columns = try JSONDecoder().decode([DatabaseColumn].self, from: json)

        XCTAssertTrue(columns[0].identity)
        XCTAssertFalse(columns[0].isEditable, "the database assigns the key")
        XCTAssertTrue(columns[1].binary)
        XCTAssertFalse(columns[1].isEditable, "binary values are never typed")
        XCTAssertTrue(columns[2].generated)
        XCTAssertFalse(columns[2].isEditable, "the database computes it")
    }

    func testAFlagMissingFromAnOlderReplyReadsAsFalse() throws {
        let json = #"[{"name":"name","type":"text","nullable":false,"default":null,"primary":false}]"#
            .data(using: .utf8)!
        let column = try JSONDecoder().decode([DatabaseColumn].self, from: json)[0]
        XCTAssertFalse(column.binary)
        XCTAssertFalse(column.generated)
        XCTAssertFalse(column.identity)
        XCTAssertTrue(column.isEditable)
    }

    func testInsertPlaceholdersFollowDefaultsAndNullability() {
        let withDefault = DatabaseColumn(name: "seen", type: "boolean", nullable: false,
                                         defaultValue: "false", primary: false)
        let nullable = DatabaseColumn(name: "note", type: "text", nullable: true,
                                      defaultValue: nil, primary: false)
        let required = DatabaseColumn(name: "name", type: "text", nullable: false,
                                      defaultValue: nil, primary: false)
        XCTAssertEqual(withDefault.insertPlaceholder, "default")
        XCTAssertEqual(nullable.insertPlaceholder, "NULL")
        XCTAssertEqual(required.insertPlaceholder, "required")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter 'DatabaseColumnFlagsTests'`
Expected: compile error — `DatabaseColumn` has no member `binary`/`isEditable`.

- [ ] **Step 3: Add the flags**

In `DatabaseBrowser.swift`, replace `DatabaseColumn` with:

```swift
public struct DatabaseColumn: Identifiable, Equatable, Sendable, Decodable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let defaultValue: String?
    public let primary: Bool
    /// A value Paddock never reads as text or writes: bytea, binary, the BLOB family, geometry.
    public let binary: Bool
    /// Computed by the database (a generated or identity expression).
    public let generated: Bool
    /// Assigned by the database on insert; shown, but never typed.
    public let identity: Bool

    public init(name: String, type: String, nullable: Bool, defaultValue: String?,
                primary: Bool, binary: Bool = false, generated: Bool = false, identity: Bool = false) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.primary = primary
        self.binary = binary
        self.generated = generated
        self.identity = identity
    }

    public var id: String { name }

    /// A field the owner may type into.
    public var isEditable: Bool { !binary && !generated && !identity }

    /// What an untouched field of a new row shows, and therefore leaves to the database.
    public var insertPlaceholder: String {
        if defaultValue != nil { return "default" }
        return nullable ? "NULL" : "required"
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, nullable, primary, binary, generated, identity
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        nullable = try values.decode(Bool.self, forKey: .nullable)
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue)
        primary = try values.decode(Bool.self, forKey: .primary)
        binary = try values.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        generated = try values.decodeIfPresent(Bool.self, forKey: .generated) ?? false
        identity = try values.decodeIfPresent(Bool.self, forKey: .identity) ?? false
    }
}
```

- [ ] **Step 4: Write the failing JSON-validity tests**

Append to `Tests/PaddockCoreTests/DatabaseJSONTests.swift`:

```swift
func testEveryJSONValueIsValidIncludingScalars() {
    for text in [#"{"a":1}"#, "[1,2]", "42", #""hello""#, "true", "null", "  { } "] {
        XCTAssertTrue(DatabaseJSON.isValid(text), text)
    }
}

func testBrokenJSONIsNotValid() {
    for text in ["", "{", #"{"a":1}…"#, "[1, 2"] {
        XCTAssertFalse(DatabaseJSON.isValid(text), text)
    }
}
```

- [ ] **Step 5: Run it to see it fail**

Run: `swift test --filter 'DatabaseJSONTests'`
Expected: compile error — no `isValid`.

- [ ] **Step 6: Add `isValid`**

In `DatabaseJSON.swift`, before `document`:

```swift
    /// Whether `text` is any valid JSON value: an object, an array, a string, a number, true, false or null.
    /// `document` is narrower — the grid only marks objects and arrays — but a JSON column accepts all of them.
    public static func isValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
```

- [ ] **Step 7: Run both suites**

Run: `swift test --filter 'DatabaseColumnFlagsTests|DatabaseJSONTests'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/PaddockCore/Database/DatabaseBrowser.swift Sources/PaddockCore/Database/DatabaseJSON.swift \
  Tests/PaddockCoreTests/DatabaseColumnFlagsTests.swift Tests/PaddockCoreTests/DatabaseJSONTests.swift
git commit -m "Database columns know what the database owns"
```

---

### Task 3: The draft, the key and the write protocol

**Files:**
- Create: `Sources/PaddockCore/Database/DatabaseEditing.swift`
- Create: `Tests/PaddockCoreTests/DatabaseEditDraftTests.swift`

**Interfaces:**
- Consumes: `DatabaseColumn`, `DatabaseService`, `DatabaseTable`, `DatabaseError`, `DatabaseJSON`.
- Produces:
  - `protocol DatabaseWriting` with `row(for:database:table:key:)`, `insert(for:database:table:values:)`, `update(for:database:table:key:changes:expected:)`, `delete(for:database:table:key:expected:)`
  - `struct DatabaseRowKey` (`columns`, `values`, `description`)
  - `struct DatabaseEditDraft` (`Mode`, `columns`, `key`, `text(for:)`, `isNull(_:)`, `isTouched(_:)`, `type(_:into:)`, `setNull(_:column:)`, `shownValue(_:)`, `hasChanges`, `changes`, `values`, `expected`, `placeholder(for:)`, `invalidJSONColumns()`)
  - `struct DatabaseWriteResult: Decodable` (`affected`)

- [ ] **Step 1: Write the failing draft tests**

Create `Tests/PaddockCoreTests/DatabaseEditDraftTests.swift`:

```swift
import XCTest
@testable import PaddockCore

final class DatabaseEditDraftTests: XCTestCase {
    private let columns = [
        DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil,
                       primary: true, identity: true),
        DatabaseColumn(name: "name", type: "text", nullable: false, defaultValue: nil, primary: false),
        DatabaseColumn(name: "note", type: "text", nullable: true, defaultValue: nil, primary: false),
        DatabaseColumn(name: "meta", type: "jsonb", nullable: true, defaultValue: nil, primary: false),
        DatabaseColumn(name: "avatar", type: "bytea", nullable: true, defaultValue: nil,
                       primary: false, binary: true),
        DatabaseColumn(name: "total", type: "numeric", nullable: false, defaultValue: "0",
                       primary: false, generated: true),
    ]
    private let original: [String: String?] = [
        "id": "1", "name": "Ada", "note": "first", "meta": nil, "avatar": "\\x00ff", "total": "0",
    ]

    private func draft() -> DatabaseEditDraft {
        let key = DatabaseRowKey(columns: columns, names: ["id", "name"], row: ["1", "Ada"])!
        return .update(columns: columns, key: key, original: original)
    }

    func testATypedFieldBecomesTheOnlyChange() {
        var draft = draft()
        XCTAssertFalse(draft.hasChanges)
        draft.type("Grace", into: "name")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.changes, ["name": "Grace"])
        XCTAssertEqual(draft.expected, ["id": "1", "name": "Ada", "note": "first", "meta": nil, "total": "0"],
                       "binary values never join the check")
        XCTAssertEqual(draft.key?.values, ["id": "1"])
    }

    func testNullAndEmptyTextAreDistinct() {
        var draft = draft()
        draft.setNull(true, column: "note")
        XCTAssertEqual(draft.changes, ["note": nil])
        draft.setNull(false, column: "note")
        XCTAssertEqual(draft.changes, ["note": ""])
        XCTAssertEqual(draft.text(for: "note"), "")
    }

    func testSettingNullOnANullFieldChangesNothing() {
        var draft = draft()
        draft.setNull(true, column: "meta")
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(draft.changes.isEmpty)
    }

    func testTheDatabaseOwnedColumnsTakeNoTyping() {
        var draft = draft()
        draft.type("99", into: "id")
        draft.type("99", into: "total")
        draft.setNull(true, column: "avatar")
        XCTAssertEqual(draft.text(for: "id"), "1")
        XCTAssertEqual(draft.text(for: "total"), "0")
        XCTAssertEqual(draft.changes, [:])
    }

    func testANewRowSendsOnlyItsTouchedFields() {
        var draft = DatabaseEditDraft.insert(columns: columns)
        XCTAssertEqual(draft.values, [:])
        draft.type("Ada", into: "name")
        draft.setNull(true, column: "note")
        XCTAssertEqual(draft.values, ["name": "Ada", "note": nil])
        XCTAssertTrue(draft.hasChanges, "a fully defaulted row may still be inserted")
    }

    func testNewRowPlaceholders() {
        let draft = DatabaseEditDraft.insert(columns: columns)
        XCTAssertEqual(draft.placeholder(for: columns[1]), "required")
        XCTAssertEqual(draft.placeholder(for: columns[2]), "NULL")
        XCTAssertEqual(draft.placeholder(for: columns[5]), "default")
    }

    func testTheKeyIsEveryPrimaryColumn() {
        let composite = [
            DatabaseColumn(name: "country", type: "text", nullable: false, defaultValue: nil, primary: true),
            DatabaseColumn(name: "code", type: "text", nullable: false, defaultValue: nil, primary: true),
            DatabaseColumn(name: "label", type: "text", nullable: false, defaultValue: nil, primary: false),
        ]
        let key = DatabaseRowKey(columns: composite, names: ["country", "code", "label"],
                                 row: ["France", "fr", "France"])
        XCTAssertEqual(key?.columns, ["country", "code"])
        XCTAssertEqual(key?.values, ["country": "France", "code": "fr"])
        XCTAssertEqual(key?.description, "country = France, code = fr")
    }

    func testAKeyNeedsEveryPrimaryColumnAndAValue() {
        let keyless = [DatabaseColumn(name: "body", type: "text", nullable: true,
                                      defaultValue: nil, primary: false)]
        XCTAssertNil(DatabaseRowKey(columns: keyless, names: ["body"], row: ["hello"]),
                     "no primary key in these columns")
        let composite = [
            DatabaseColumn(name: "country", type: "text", nullable: false, defaultValue: nil, primary: true),
            DatabaseColumn(name: "code", type: "text", nullable: true, defaultValue: nil, primary: true),
        ]
        XCTAssertNil(DatabaseRowKey(columns: composite, names: ["country", "code"], row: ["France", nil]),
                     "a NULL key value names no row")
    }

    func testEditingANonIdentityKeyKeepsTheOriginalKey() {
        let keyed = [
            DatabaseColumn(name: "code", type: "text", nullable: false, defaultValue: nil, primary: true),
            DatabaseColumn(name: "label", type: "text", nullable: true, defaultValue: nil, primary: false),
        ]
        let key = DatabaseRowKey(columns: keyed, names: ["code", "label"], row: ["fr", "France"])!
        var draft = DatabaseEditDraft.update(columns: keyed, key: key, original: ["code": "fr", "label": "France"])
        draft.type("FR", into: "code")
        XCTAssertEqual(draft.key?.values, ["code": "fr"], "the row is found by what it was")
        XCTAssertEqual(draft.changes, ["code": "FR"])
    }

    func testInvalidJSONIsNamedAndScalarsAreFine() {
        var draft = draft()
        draft.type("{bad", into: "meta")
        XCTAssertEqual(draft.invalidJSONColumns(), ["meta"])
        draft.type("42", into: "meta")
        XCTAssertEqual(draft.invalidJSONColumns(), [])
        draft.setNull(true, column: "meta")
        XCTAssertEqual(draft.invalidJSONColumns(), [], "NULL is not text to check")
    }

    func testShownValuesServeTheReadOnlyFields() {
        let draft = draft()
        XCTAssertEqual(draft.shownValue("avatar"), "\\x00ff")
        XCTAssertNil(draft.shownValue("meta"))
        XCTAssertEqual(draft.shownValue("name"), "Ada")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter 'DatabaseEditDraftTests'`
Expected: compile error — `DatabaseEditDraft` is not defined.

- [ ] **Step 3: Write `DatabaseEditing.swift`**

Create `Sources/PaddockCore/Database/DatabaseEditing.swift`:

```swift
import Foundation

/// Writes to a database service, one row at a time. Values are column → text maps; nil is SQL NULL.
/// Separate from `DatabaseBrowsing` so the CLI's reader cannot grow writes by accident.
public protocol DatabaseWriting: Sendable {
    /// The row as the database holds it now, whole (not clipped to the grid's 4096 characters), binary
    /// columns left out.
    func row(for service: DatabaseService, database: String, table: DatabaseTable,
             key: [String: String?]) throws -> [String: String?]

    /// One row; columns absent from `values` take their database default.
    func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                values: [String: String?]) throws

    /// The changed columns of one row. `expected` holds the row as it was read; the database refuses the
    /// write if the row moved since.
    func update(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], changes: [String: String?],
                expected: [String: String?]) throws

    /// One row, refused when it changed since `expected` was read.
    func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], expected: [String: String?]) throws
}

/// What a write answered: rows touched. One is the only acceptable count for a single-row write.
public struct DatabaseWriteResult: Decodable, Equatable, Sendable {
    public let affected: Int
}

/// The columns that name one row: every primary key column, in table order.
public struct DatabaseRowKey: Equatable, Sendable {
    public let columns: [String]
    public let values: [String: String?]

    /// Nil when the table has no primary key, a key column is missing from the result, or a key value is NULL.
    public init?(columns: [DatabaseColumn], names: [String], row: [String?]) {
        let primary = columns.filter(\.primary)
        guard !primary.isEmpty else { return nil }
        var values: [String: String?] = [:]
        for column in primary {
            guard let index = names.firstIndex(of: column.name),
                  row.indices.contains(index), let value = row[index] else { return nil }
            values[column.name] = value
        }
        self.columns = primary.map(\.name)
        self.values = values
    }

    /// `id = 42, country = France`, for the delete dialog.
    public var description: String {
        columns.map { "\($0) = \(values[$0] ?? "NULL")" }.joined(separator: ", ")
    }
}

/// One row on its way into the database: the values it opened with, what has been typed, and which fields
/// stand for NULL. The model owns one; the views only read it.
public struct DatabaseEditDraft: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case update, insert }

    public let mode: Mode
    public let columns: [DatabaseColumn]
    /// Nil when adding a row.
    public let key: DatabaseRowKey?
    private var original: [String: String?]
    private var text: [String: String]
    private var nulls: Set<String>
    private var touched: Set<String>

    private init(mode: Mode, columns: [DatabaseColumn], key: DatabaseRowKey?,
                 original: [String: String?], text: [String: String], nulls: Set<String>, touched: Set<String>) {
        self.mode = mode
        self.columns = columns
        self.key = key
        self.original = original
        self.text = text
        self.nulls = nulls
        self.touched = touched
    }

    /// An existing row: `original` is what the database returned, whole, plus the display text of any column
    /// the row read leaves out (binary columns).
    public static func update(columns: [DatabaseColumn], key: DatabaseRowKey,
                              original: [String: String?]) -> DatabaseEditDraft {
        var text: [String: String] = [:]
        var nulls = Set<String>()
        for column in columns {
            if let value = original[column.name] ?? nil {
                text[column.name] = value
            } else if column.isEditable && column.nullable {
                nulls.insert(column.name)
            }
        }
        return DatabaseEditDraft(mode: .update, columns: columns, key: key, original: original,
                                 text: text, nulls: nulls, touched: [])
    }

    public static func insert(columns: [DatabaseColumn]) -> DatabaseEditDraft {
        DatabaseEditDraft(mode: .insert, columns: columns, key: nil, original: [:],
                          text: [:], nulls: [], touched: [])
    }

    // MARK: - Reading

    public func text(for column: String) -> String { text[column] ?? "" }
    public func isNull(_ column: String) -> Bool { nulls.contains(column) }
    public func isTouched(_ column: String) -> Bool { touched.contains(column) }

    /// What an untouched or read-only field shows: the typed text, NULL, or the original value.
    public func shownValue(_ column: String) -> String? {
        if nulls.contains(column) { return nil }
        if let value = text[column] { return value }
        return original[column] ?? nil
    }

    public func placeholder(for column: DatabaseColumn) -> String {
        mode == .insert ? column.insertPlaceholder : ""
    }

    /// What the database's row held for a column, nil for a value that was NULL or absent.
    private func originalValue(_ column: String) -> String? { original[column] ?? nil }

    // MARK: - Writing

    public mutating func type(_ value: String, into column: String) {
        guard columns.contains(where: { $0.name == column && $0.isEditable }) else { return }
        text[column] = value
        touched.insert(column)
    }

    public mutating func setNull(_ isNull: Bool, column: String) {
        guard columns.contains(where: { $0.name == column && $0.isEditable && $0.nullable }) else { return }
        if isNull {
            nulls.insert(column)
            text[column] = ""
        } else {
            nulls.remove(column)
        }
        touched.insert(column)
    }

    /// Whether saving would change the database: any change on update; the row itself on insert.
    public var hasChanges: Bool {
        switch mode {
        case .insert:
            return true
        case .update:
            return columns.contains { column in
                guard column.isEditable, touched.contains(column.name) else { return false }
                if nulls.contains(column.name) { return originalValue(column.name) != nil }
                return text[column.name] != originalValue(column.name)
            }
        }
    }

    /// What an UPDATE sends: only the fields that differ from the row as it was read.
    public var changes: [String: String?] {
        guard mode == .update else { return [:] }
        var changes: [String: String?] = [:]
        for column in columns where column.isEditable && touched.contains(column.name) {
            let new: String? = nulls.contains(column.name) ? nil : (text[column.name] ?? "")
            if new != originalValue(column.name) { changes[column.name] = new }
        }
        return changes
    }

    /// What an INSERT sends: only the fields the owner touched; every other column takes its default.
    public var values: [String: String?] {
        guard mode == .insert else { return [:] }
        var values: [String: String?] = [:]
        for column in columns where column.isEditable && touched.contains(column.name) {
            values[column.name] = nulls.contains(column.name) ? nil : (text[column.name] ?? "")
        }
        return values
    }

    /// The row as it was read, for the write's own "has it moved?" check. Binary columns stay out.
    public var expected: [String: String?] {
        original.filter { name, _ in columns.contains { $0.name == name && !$0.binary } }
    }

    /// JSON and JSONB fields, touched, whose text is not valid JSON. Names them for the message.
    public func invalidJSONColumns() -> [String] {
        columns.filter { column in
            let type = column.type.lowercased()
            guard type == "json" || type == "jsonb",
                  column.isEditable, touched.contains(column.name), !nulls.contains(column.name) else {
                return false
            }
            return !DatabaseJSON.isValid(text[column.name] ?? "")
        }.map(\.name)
    }
}
```

- [ ] **Step 4: Run the draft tests**

Run: `swift test --filter 'DatabaseEditDraftTests'`
Expected: PASS. If the module fails to build because another file conforms to `DatabaseBrowsing`, nothing has changed there yet — this task adds a new protocol only.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaddockCore/Database/DatabaseEditing.swift Tests/PaddockCoreTests/DatabaseEditDraftTests.swift
git commit -m "A draft of one database row, and the write protocol"
```

---

### Task 4: The bridge writes, and the browser obeys

**Files:**
- Modify: `Sources/PaddockCore/Database/PHPDatabaseBridge.swift` (whole script and `run`)
- Modify: `Sources/PaddockCore/Database/DatabaseBrowser.swift` (columns SQL is in PHP; add `DatabaseWriting` conformance and the extended `ask`)
- Test: `Tests/PaddockCoreTests/DatabaseBrowserTests.swift` (append the request-file test)
- Test: `Tests/IntegrationTests/Services/PostgresServiceTests.swift` (append `testDatabaseBrowserWritesPostgreSQL` and pdo cases)
- Test: `Tests/IntegrationTests/Services/MySQLServiceTests.swift` (append `testDatabaseBrowserWritesMySQL` and pdo cases)

**Interfaces:**
- Consumes: `DatabaseWriting`, `DatabaseRowKey`, `DatabaseWriteResult`, `DatabaseColumn` flags from Tasks 2-3.
- Produces: `DatabaseBrowser: DatabaseWriting`; `DatabaseRequest` gains `key`, `changes`, `expected`, `values`; `PHPDatabaseBridge.run(_:as:inFile:)`; PHP actions `row`, `insert`, `update`, `delete`; PHP columns replies include `binary`, `generated`, `identity`.

- [ ] **Step 1: Write the failing request-file test**

Append to `Tests/PaddockCoreTests/DatabaseBrowserTests.swift`:

```swift
func testAWriteRequestTravelsInAPrivateFile() throws {
    let runner = CapturingRunner(reply: #"{"ok":true,"result":{"affected":1}}"#)
    let bridge = PHPDatabaseBridge(php: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
    let request = DatabaseRequest(action: "update", driver: "pgsql", host: "127.0.0.1", port: 5432,
                                  user: "root", password: "", database: "shop", schema: "public",
                                  table: "users", sql: nil, limit: nil, search: nil,
                                  key: ["id": "1"], changes: ["note": nil],
                                  expected: ["id": "1", "note": "first"], values: nil)
    let result = try bridge.run(request, as: DatabaseWriteResult.self, inFile: true)

    XCTAssertEqual(result.affected, 1)
    let path = try XCTUnwrap(runner.filePath)
    XCTAssertEqual(runner.permissions, 0o600)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the request file is gone afterwards")
    XCTAssertNil(runner.environment["PADDOCK_DB_REQUEST"], "a write does not also sit in the environment")

    let data = try XCTUnwrap(runner.fileContents)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: data)))
        as? [String: Any])
    XCTAssertEqual(json["action"] as? String, "update")
    XCTAssertEqual((json["key"] as? [String: Any])?["id"] as? String, "1")
    XCTAssertTrue((json["changes"] as? [String: Any])?["note"] is NSNull, "NULL travels as null")
}
```

At the bottom of the same file, add:

```swift
/// Reads the request file while it exists, then answers as PHP would.
private final class CapturingRunner: CommandRunner, @unchecked Sendable {
    let reply: String
    private(set) var environment: [String: String] = [:]
    private(set) var filePath: String?
    private(set) var fileContents: Data?
    private(set) var permissions: Int?

    init(reply: String) { self.reply = reply }

    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String) {
        self.environment = environment ?? [:]
        if let path = environment?["PADDOCK_DB_REQUEST_FILE"] {
            filePath = path
            fileContents = try Data(contentsOf: URL(fileURLWithPath: path))
            permissions = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                as? NSNumber)?.intValue
        }
        return (0, reply)
    }
}
```

`CommandRunner`'s extension already routes the bridge's `timeout:` call to this method, so the fake needs only the one requirement.

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter 'testAWriteRequestTravelsInAPrivateFile'`
Expected: compile error — `DatabaseRequest` has no `key`/`changes`/`expected`/`values`, `run` has no `inFile`, `DatabaseWriteResult` missing (Task 3 must be committed first).

- [ ] **Step 3: Add the request fields and the file transport**

In `PHPDatabaseBridge.swift`, extend `DatabaseRequest`:

```swift
struct DatabaseRequest: Encodable, Sendable {
    let action: String
    let driver: String
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String
    var schema: String?
    var table: String?
    var sql: String?
    var limit: Int?
    var search: String?
    var key: [String: String?]? = nil
    var changes: [String: String?]? = nil
    var expected: [String: String?]? = nil
    var values: [String: String?]? = nil
}
```

Replace the start of `run` (everything from `var environment` through the `environment[...]` line):

```swift
        var environment = ProcessInfo.processInfo.environment
        var requestFile: URL?
        if inFile {
            // A write can hold a long value; the environment has a size limit on macOS. 0600 at creation.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paddock-db-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw DatabaseError.failed("Paddock couldn't prepare the write request.")
            }
            requestFile = url
            environment[Self.fileKey] = url.path
        } else {
            environment[Self.requestKey] = data.base64EncodedString()
        }
        // The function's scope, not the `if`'s: a defer inside that block runs as the block exits, deleting
        // the file before PHP is started.
        defer { if let requestFile { try? FileManager.default.removeItem(at: requestFile) } }
```

and change the signature to:

```swift
    func run<Answer: Decodable>(_ request: DatabaseRequest, as: Answer.Type,
                                inFile: Bool = false) throws -> Answer {
```

Add beside `arguments`:

```swift
    static let requestKey = "PADDOCK_DB_REQUEST"
    static let fileKey = "PADDOCK_DB_REQUEST_FILE"
```

- [ ] **Step 4: Teach the PHP program to read a file, and add the actions**

In the script string, replace the first two lines:

```php
    $raw = getenv('PADDOCK_DB_REQUEST');
    $request = is_string($raw) ? json_decode(base64_decode($raw), true) : null;
```

with:

```php
    $raw = getenv('PADDOCK_DB_REQUEST');
    $file = getenv('PADDOCK_DB_REQUEST_FILE');
    if (!is_string($raw) && is_string($file) && $file !== '') {
        $raw = @file_get_contents($file);
        @unlink($file);
        if (!is_string($raw)) fail('Paddock could not read its write request.');
    }
    $request = is_string($raw) ? json_decode(base64_decode($raw), true) : null;
```

Keep `cell()` but factor out the untruncated conversion and add helpers after it:

```php
    function text($value) {
        if ($value === null) return null;
        if (is_bool($value)) return $value ? 'true' : 'false';
        if (!is_scalar($value)) {
            return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
        }
        return (string)$value;
    }
    function cell($value) {
        $text = text($value);
        if ($text !== null && strlen($text) > 4096) $text = substr($text, 0, 4096) . '…';
        return $text;
    }
    function binaryTypes() {
        return ['binary', 'varbinary', 'tinyblob', 'blob', 'mediumblob', 'longblob', 'geometry', 'point',
                'linestring', 'polygon', 'multipoint', 'multilinestring', 'multipolygon', 'geometrycollection'];
    }
    // The binary columns of a table: left out of a row read, never compared or written.
    function binaryColumns($pdo, $driver, $schema, $table) {
        if ($driver === 'mysql') {
            $types = binaryTypes();
            $marks = implode(', ', array_fill(0, count($types), '?'));
            $statement = $pdo->prepare('SELECT column_name FROM information_schema.columns WHERE table_schema = ?'
                . ' AND table_name = ? AND data_type IN (' . $marks . ')');
            $statement->execute(array_merge([$schema, $table], $types));
        } else {
            $statement = $pdo->prepare("SELECT column_name FROM information_schema.columns WHERE table_schema = ?"
                . " AND table_name = ? AND data_type = 'bytea'");
            $statement->execute([$schema, $table]);
        }
        $set = [];
        foreach ($statement->fetchAll(PDO::FETCH_COLUMN) as $name) $set[(string)$name] = true;
        return $set;
    }
    function qualified($driver, $schema, $table) {
        return ($schema ? ident($driver, (string)$schema) . '.' : '') . ident($driver, $table);
    }
    // The row lock's condition: the key's columns, NULL-safe even though a key is never NULL.
    function keyCondition($driver, $key) {
        $conditions = [];
        $parameters = [];
        foreach ($key as $column => $value) {
            $conditions[] = ident($driver, (string)$column) . ($driver === 'mysql' ? ' <=> ?' : ' IS NOT DISTINCT FROM ?');
            $parameters[] = $value;
        }
        return [implode(' AND ', $conditions), $parameters];
    }
    function writeKey($request) {
        return isset($request['key']) && is_array($request['key']) ? $request['key'] : [];
    }
    // The row as the database holds it now, locked until the transaction ends.
    function lockedRow($pdo, $driver, $name, $key) {
        [$where, $parameters] = keyCondition($driver, $key);
        $statement = $pdo->prepare('SELECT * FROM ' . $name . ' WHERE ' . $where . ' FOR UPDATE');
        $statement->execute($parameters);
        $row = $statement->fetch(PDO::FETCH_ASSOC);
        return is_array($row) ? $row : null;
    }
    // Whether the locked row differs from the row the editor opened, past the 4096-character clip.
    function differs($row, $expected) {
        foreach ($expected as $column => $value) {
            if (!array_key_exists($column, $row)) return true;
            $actual = text($row[$column]);
            if ($value === null ? $actual !== null : (string)$value !== $actual) return true;
        }
        return false;
    }
    function beginWrite($pdo, $driver) {
        if ($driver === 'mysql') $pdo->exec('SET SESSION innodb_lock_wait_timeout = 5');
        $pdo->beginTransaction();
        if ($driver === 'pgsql') $pdo->exec("SET LOCAL statement_timeout = '5s'");
    }
```

Replace the existing `cell()` function with the two above (there must be exactly one definition of each).

Add `PDO::MYSQL_ATTR_FOUND_ROWS` to the options:

```php
        if ($driver === 'mysql') {
            $options[PDO::ATTR_EMULATE_PREPARES] = false;
            $options[PDO::MYSQL_ATTR_FOUND_ROWS] = true; // an unchanged save still counts the row as matched
        }
```

Add the three flags to the `columns` action. Replace its two `information_schema.columns` queries with:

```php
                $statement = $pdo->prepare('SELECT column_name AS name, data_type AS type, is_nullable AS nullable, column_default AS default_value, is_generated AS generated, is_identity AS identity FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position');
```

MySQL query:

```php
                $statement = $pdo->prepare('SELECT column_name AS name, column_type AS type, is_nullable AS nullable, column_default AS default_value, extra AS extra, data_type AS data_type FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position');
```

and replace its `$columns[] = [...]` block with:

```php
            foreach ($statement as $row) {
                $binary = false;
                $generated = false;
                $identity = false;
                $default = $row['default_value'] === null ? null : (string)$row['default_value'];
                if ($driver === 'mysql') {
                    $binary = in_array(strtolower((string)$row['data_type']), binaryTypes(), true);
                    $generated = stripos((string)$row['extra'], 'VIRTUAL GENERATED') !== false
                        || stripos((string)$row['extra'], 'STORED GENERATED') !== false;
                    $identity = stripos((string)$row['extra'], 'auto_increment') !== false;
                } else {
                    $binary = strtolower((string)$row['type']) === 'bytea';
                    $generated = strtoupper((string)$row['generated']) !== 'NEVER';
                    $identity = strtoupper((string)$row['identity']) === 'YES'
                        || ($default !== null && stripos($default, 'nextval(') === 0);
                }
                $columns[] = [
                    'name' => (string)$row['name'],
                    'type' => (string)$row['type'],
                    'nullable' => strtoupper((string)$row['nullable']) === 'YES',
                    'default' => $default,
                    'primary' => isset($keys[(string)$row['name']]),
                    'binary' => $binary,
                    'generated' => $generated,
                    'identity' => $identity,
                ];
            }
```

Add the four cases before `default:`. `row` is a read and uses a read-only transaction:

```php
        case 'row':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            $binary = binaryColumns($pdo, $driver, $schema ?: $database, $table);
            [$where, $parameters] = keyCondition($driver, $key);
            if ($driver === 'pgsql') {
                $pdo->exec('BEGIN TRANSACTION READ ONLY');
                $pdo->exec("SET LOCAL statement_timeout = '5s'");
            } else {
                $pdo->exec('SET SESSION MAX_EXECUTION_TIME = 5000');
                $pdo->exec('START TRANSACTION READ ONLY');
            }
            $statement = $pdo->prepare('SELECT * FROM ' . $name . ' WHERE ' . $where . ' LIMIT 1');
            $statement->execute($parameters);
            $found = $statement->fetch(PDO::FETCH_ASSOC);
            if (!is_array($found)) fail('That row is no longer there. It may have been deleted.');
            $out = [];
            foreach ($found as $column => $value) {
                if (!isset($binary[(string)$column])) $out[$column] = text($value);
            }
            try { $pdo->rollBack(); } catch (Throwable $ignored) {}
            reply(['ok' => true, 'result' => $out]);
        case 'insert':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $values = isset($request['values']) && is_array($request['values']) ? $request['values'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            if (empty($values)) {
                if ($driver === 'pgsql') {
                    $pdo->exec('INSERT INTO ' . $name . ' DEFAULT VALUES');
                } else {
                    $pdo->exec('INSERT INTO ' . $name . ' () VALUES ()');
                }
            } else {
                $names = [];
                $marks = [];
                $parameters = [];
                foreach ($values as $column => $value) {
                    $names[] = ident($driver, (string)$column);
                    $marks[] = '?';
                    $parameters[] = $value;
                }
                $statement = $pdo->prepare('INSERT INTO ' . $name . ' (' . implode(', ', $names) . ') VALUES ('
                    . implode(', ', $marks) . ')');
                $statement->execute($parameters);
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
        case 'update':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $changes = isset($request['changes']) && is_array($request['changes']) ? $request['changes'] : [];
            if (empty($changes)) fail('Nothing was changed.');
            $expected = isset($request['expected']) && is_array($request['expected']) ? $request['expected'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            $found = lockedRow($pdo, $driver, $name, $key);
            if ($found === null) fail('That row is no longer there. It may have been deleted.');
            if (differs($found, $expected)) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $sets = [];
            $parameters = [];
            foreach ($changes as $column => $value) {
                $sets[] = ident($driver, (string)$column) . ' = ?';
                $parameters[] = $value;
            }
            [$where, $keyParameters] = keyCondition($driver, $key);
            $statement = $pdo->prepare('UPDATE ' . $name . ' SET ' . implode(', ', $sets) . ' WHERE ' . $where);
            $statement->execute(array_merge($parameters, $keyParameters));
            if ($statement->rowCount() < 1) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
        case 'delete':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $expected = isset($request['expected']) && is_array($request['expected']) ? $request['expected'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            $found = lockedRow($pdo, $driver, $name, $key);
            if ($found === null) fail('That row is no longer there. It may have been deleted.');
            if (differs($found, $expected)) {
                fail('This row changed since it was read. Reload and try again.');
            }
            [$where, $keyParameters] = keyCondition($driver, $key);
            $statement = $pdo->prepare('DELETE FROM ' . $name . ' WHERE ' . $where);
            $statement->execute($keyParameters);
            if ($statement->rowCount() < 1) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
```

Finally, roll back on any error. Replace the catch:

```php
    } catch (Throwable $error) {
        try { if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack(); } catch (Throwable $ignored) {}
        fail($error->getMessage());
    }
```

- [ ] **Step 5: Add `DatabaseWriting` to `DatabaseBrowser`**

In `DatabaseBrowser.swift`, change the private `ask` to carry write payloads:

```swift
    private func ask<Answer: Decodable>(_ action: String, service: DatabaseService, database: String,
                                        schema: String? = nil, table: String? = nil, sql: String? = nil,
                                        search: String? = nil, limit: Int? = nil,
                                        key: [String: String?]? = nil, changes: [String: String?]? = nil,
                                        expected: [String: String?]? = nil, values: [String: String?]? = nil,
                                        as: Answer.Type, inFile: Bool = false) throws -> Answer {
        guard service.isRunning else { throw DatabaseError.notRunning(service.name) }
        try Self.validate(database: database)
        let request = DatabaseRequest(action: action, driver: service.engine.driver, host: "127.0.0.1",
                                      port: service.port, user: "root", password: "", database: database,
                                      schema: schema, table: table, sql: sql, limit: limit, search: search,
                                      key: key, changes: changes, expected: expected, values: values)
        return try bridge.run(request, as: Answer.self, inFile: inFile)
    }
```

Add after the `DatabaseBrowser` type (same file, bottom):

```swift
/// Writes go through the same bundled PHP, one row at a time; the SQL console's read-only rule is untouched.
extension DatabaseBrowser: DatabaseWriting {
    public func row(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?]) throws -> [String: String?] {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        return try ask("row", service: service, database: database, schema: table.schema, table: table.name,
                       key: key, as: [String: String?].self)
    }

    public func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                       values: [String: String?]) throws {
        _ = try ask("insert", service: service, database: database, schema: table.schema, table: table.name,
                    values: values, as: DatabaseWriteResult.self, inFile: true)
    }

    public func update(for service: DatabaseService, database: String, table: DatabaseTable,
                       key: [String: String?], changes: [String: String?],
                       expected: [String: String?]) throws {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        guard !changes.isEmpty else { throw DatabaseError.failed("Nothing was changed.") }
        _ = try ask("update", service: service, database: database, schema: table.schema, table: table.name,
                    key: key, changes: changes, expected: expected,
                    as: DatabaseWriteResult.self, inFile: true)
    }

    public func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                       key: [String: String?], expected: [String: String?]) throws {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        _ = try ask("delete", service: service, database: database, schema: table.schema, table: table.name,
                    key: key, expected: expected, as: DatabaseWriteResult.self, inFile: true)
    }
}
```

- [ ] **Step 6: Run the request-file test**

Run: `swift test --filter 'testAWriteRequestTravelsInAPrivateFile'`
Expected: PASS.

- [ ] **Step 7: Add the integration fixtures**

In `PostgresServiceTests.swift`, add to the embedded `pdo.php` script inside the `pdo` helper, before the `switch`'s closing brace (after its `case 'json':`):

```php
                    case 'writable':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS editable (id serial PRIMARY KEY, name text NOT NULL,'
                            . ' note text, meta jsonb, seen boolean NOT NULL DEFAULT false)');
                        $pdo->exec('TRUNCATE editable RESTART IDENTITY');
                        $pdo->prepare('INSERT INTO editable (name, note) VALUES (?, ?)')->execute(['Ada', 'first']);
                        $pdo->prepare('INSERT INTO editable (name, note) VALUES (?, ?)')->execute(['Grace', 'second']);
                        $pdo->exec('CREATE TABLE IF NOT EXISTS keyless (body text)');
                        $pdo->exec('CREATE OR REPLACE VIEW editable_view AS SELECT id, name FROM editable');
                        echo "ok\n";
                        break;
                    case 'count':
                        echo $pdo->query('SELECT count(*) FROM editable')->fetchColumn(), "\n";
                        break;
                    case 'cell':
                        [$table, $id, $column] = explode('|', $arg);
                        $statement = $pdo->prepare("SELECT $column::text FROM $table WHERE id = ?");
                        $statement->execute([$id]);
                        $value = $statement->fetchColumn();
                        echo $value === null ? 'NULL' : (string)$value, "\n";
                        break;
                    case 'set':
                        [$id, $name] = explode('|', $arg);
                        $pdo->prepare('UPDATE editable SET name = ? WHERE id = ?')->execute([$name, $id]);
                        echo "ok\n";
                        break;
```

In `MySQLServiceTests.swift`, add the same cases to the embedded `pdo-mysql.php` script inside that file's `pdo` helper, before its `switch`'s closing brace:

```php
                    case 'writable':
                        $pdo->exec('CREATE TABLE IF NOT EXISTS editable (id INT AUTO_INCREMENT PRIMARY KEY,'
                            . ' name VARCHAR(255) NOT NULL, note TEXT NULL, meta JSON NULL,'
                            . ' seen TINYINT(1) NOT NULL DEFAULT 0)');
                        $pdo->exec('TRUNCATE editable');
                        $pdo->prepare('INSERT INTO editable (name, note) VALUES (?, ?)')->execute(['Ada', 'first']);
                        $pdo->prepare('INSERT INTO editable (name, note) VALUES (?, ?)')->execute(['Grace', 'second']);
                        $pdo->exec('CREATE TABLE IF NOT EXISTS keyless (body text)');
                        $pdo->exec('DROP VIEW IF EXISTS editable_view');
                        $pdo->exec('CREATE VIEW editable_view AS SELECT id, name FROM editable');
                        echo "ok\n";
                        break;
                    case 'count':
                        echo $pdo->query('SELECT count(*) FROM editable')->fetchColumn(), "\n";
                        break;
                    case 'cell':
                        [$table, $id, $column] = explode('|', $arg);
                        $statement = $pdo->prepare("SELECT $column FROM $table WHERE id = ?");
                        $statement->execute([$id]);
                        $value = $statement->fetchColumn();
                        echo $value === null ? 'NULL' : (string)$value, "\n";
                        break;
                    case 'set':
                        [$id, $name] = explode('|', $arg);
                        $pdo->prepare('UPDATE editable SET name = ? WHERE id = ?')->execute([$name, $id]);
                        echo "ok\n";
                        break;
```

- [ ] **Step 8: Write the PostgreSQL write test**

Add to `PostgresServiceTests.swift` (after `testDatabaseBrowserReadsPostgreSQL`):

```swift
    /// The browser's writes over a real PostgreSQL: the flags, a row read whole, insert with defaults and an
    /// explicit NULL, one change, a conflicting save, a delete, and the refusals.
    func testDatabaseBrowserWritesPostgreSQL() async throws {
        try requirePHP()
        let manager = makeManager([try await postgres("18")])
        let added = try await manager.add(kind: "postgres", version: "18")
        _ = try postmaster(manager, added.id)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try manager.createDatabase(added.id, database: "laravel"), .done)
        try pdo(tcp(port), "writable")

        let service = try XCTUnwrap(status(manager, added.id).flatMap(DatabaseService.init))
        let browser = DatabaseBrowser(php: php)
        let tables = try browser.tables(for: service, database: "laravel")
        let editable = try XCTUnwrap(tables.first { $0.name == "editable" })
        let columns = try browser.columns(for: service, database: "laravel", table: editable)
        let id = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(id.primary)
        XCTAssertTrue(id.identity)
        XCTAssertFalse(id.isEditable)
        let meta = try XCTUnwrap(columns.first { $0.name == "meta" })
        XCTAssertTrue(meta.isEditable)
        XCTAssertTrue(meta.nullable)

        let row = try browser.row(for: service, database: "laravel", table: editable, key: ["id": "1"])
        XCTAssertEqual(row["name"], "Ada")
        XCTAssertEqual(row["note"], "first")
        XCTAssertEqual(row["seen"], "false")
        XCTAssertNil(row["meta"])

        // A new row: name typed, note NULL, everything else defaulted.
        try browser.insert(for: service, database: "laravel", table: editable,
                           values: ["name": "Katherine", "note": nil])
        XCTAssertEqual(try pdo(tcp(port), "count"), "3")
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|3|seen"), "false")
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|3|note"), "NULL")

        // One change; the rest of the row stays.
        let expected = try browser.row(for: service, database: "laravel", table: editable, key: ["id": "1"])
        try browser.update(for: service, database: "laravel", table: editable, key: ["id": "1"],
                           changes: ["note": nil], expected: expected)
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|note"), "NULL")
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|name"), "Ada")

        // Someone else changes the row: the save refuses and writes nothing.
        try pdo(tcp(port), "set", "1|Someone else")
        XCTAssertThrowsError(try browser.update(for: service, database: "laravel", table: editable,
                                                key: ["id": "1"], changes: ["note": "mine"], expected: expected)) {
            XCTAssertEqual($0 as? DatabaseError,
                           .failed("This row changed since it was read. Reload and try again."))
        }
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|name"), "Someone else")
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|note"), "NULL", "nothing was written")

        // Delete, then a second delete finds it gone.
        let fresh = try browser.row(for: service, database: "laravel", table: editable, key: ["id": "1"])
        try browser.delete(for: service, database: "laravel", table: editable, key: ["id": "1"], expected: fresh)
        XCTAssertEqual(try pdo(tcp(port), "count"), "2")
        XCTAssertThrowsError(try browser.delete(for: service, database: "laravel", table: editable,
                                                key: ["id": "1"], expected: fresh)) {
            XCTAssertEqual($0 as? DatabaseError,
                           .failed("That row is no longer there. It may have been deleted."))
        }

        // A table with no key names no row; a view cannot be locked.
        let keyless = try XCTUnwrap(tables.first { $0.name == "keyless" })
        XCTAssertThrowsError(try browser.update(for: service, database: "laravel", table: keyless,
                                                key: [:], changes: ["body": "x"], expected: [:])) {
            XCTAssertEqual($0 as? DatabaseError, .failed("No row was named."))
        }
        manager.stopAll()
    }
```

Remove the odd line `XCTAssertFalse(... isEditable.self == true, "meta is editable")` — assert instead `XCTAssertTrue(try XCTUnwrap(columns.first { $0.name == "meta" }).isEditable)`.

- [ ] **Step 9: Write the MySQL write test**

Add to `MySQLServiceTests.swift`:

```swift
    /// The browser's writes over a real MySQL: defaults, an explicit NULL, an unchanged save (found rows),
    /// a conflicting save, and a delete.
    func testDatabaseBrowserWritesMySQL() async throws {
        try requirePHP()
        let manager = makeManager([try await mysql("8.4")])
        let added = try await manager.add(kind: "mysql", version: "8.4")
        _ = try server(manager, added.id)
        let port = try XCTUnwrap(added.ports["main"])
        XCTAssertEqual(try manager.createDatabase(added.id, database: "laravel"), .done)
        try pdo(tcp(port), "writable")

        let service = try XCTUnwrap(status(manager, added.id).flatMap(DatabaseService.init))
        let browser = DatabaseBrowser(php: php)
        let tables = try browser.tables(for: service, database: "laravel")
        let editable = try XCTUnwrap(tables.first { $0.name == "editable" })
        let columns = try browser.columns(for: service, database: "laravel", table: editable)
        let id = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(id.identity)
        XCTAssertFalse(id.isEditable)

        try browser.insert(for: service, database: "laravel", table: editable,
                           values: ["name": "Katherine", "note": nil])
        XCTAssertEqual(try pdo(tcp(port), "count"), "3")
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|3|seen"), "0")

        // Setting a field to the value it already holds still counts the row (MySQL found rows).
        var expected = try browser.row(for: service, database: "laravel", table: editable, key: ["id": "1"])
        try browser.update(for: service, database: "laravel", table: editable, key: ["id": "1"],
                           changes: ["name": "Ada"], expected: expected)
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|name"), "Ada")

        try pdo(tcp(port), "set", "1|Someone else")
        XCTAssertThrowsError(try browser.update(for: service, database: "laravel", table: editable,
                                                key: ["id": "1"], changes: ["note": "mine"], expected: expected)) {
            XCTAssertEqual($0 as? DatabaseError,
                           .failed("This row changed since it was read. Reload and try again."))
        }
        XCTAssertEqual(try pdo(tcp(port), "cell", "editable|1|note"), "NULL")

        expected = try browser.row(for: service, database: "laravel", table: editable, key: ["id": "1"])
        try browser.delete(for: service, database: "laravel", table: editable, key: ["id": "1"], expected: expected)
        XCTAssertEqual(try pdo(tcp(port), "count"), "2")
        manager.stopAll()
    }
```

- [ ] **Step 10: Run the integration writes**

Run: `swift test --filter 'DatabaseBrowserWrites(PostgreSQL|MySQL)'`
Expected: `Executed 2 tests, with 0 failures`. If the vendored PHP or the cached PostgreSQL/MySQL archives are missing, the test skips with its existing message — fetch them with `Scripts/fetch-vendor.sh` and rerun.

- [ ] **Step 11: Run the reader tests to prove nothing changed**

Run: `swift test --filter 'DatabaseBrowserReads(PostgreSQL|MySQL)'`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 12: Commit**

```bash
git add Sources/PaddockCore/Database/PHPDatabaseBridge.swift Sources/PaddockCore/Database/DatabaseBrowser.swift \
  Tests/PaddockCoreTests/DatabaseBrowserTests.swift Tests/IntegrationTests/Services/PostgresServiceTests.swift \
  Tests/IntegrationTests/Services/MySQLServiceTests.swift
git commit -m "The database bridge writes one row at a time"
```

---

### Task 5: The model holds the draft

**Files:**
- Modify: `Sources/PaddockCore/App/DatabasesModel.swift`
- Modify: `Tests/PaddockCoreTests/DatabasesModelTests.swift`

**Interfaces:**
- Consumes: `DatabaseWriting`, `DatabaseEditDraft`, `DatabaseRowKey` (Tasks 3-4).
- Produces:
  - `DatabasesModel.browser` becomes `(any DatabaseBrowsing & DatabaseWriting)?`
  - `enum DatabaseDestination: Equatable, Sendable { case service(String), database(String), table(DatabaseTable) }`
  - Published: `draft`, `editingRow`, `isSaving`, `notice`, `pendingDelete: DatabaseRowKey?`, `pendingDiscard: DatabaseDestination?`
  - `isEditableTable`, `readOnlyNote`, `hasUnsavedDraft`, `canSaveDraft`, `pendingDeleteText`
  - `beginEdit(row:) async`, `beginInsert()`, `setDraftText(_:column:)`, `setDraftNull(_:column:)`, `cancelDraft()`, `saveDraft() async`, `requestDelete(row:)`, `cancelDelete()`, `confirmDelete() async`, `go(to:) async`, `discardAndGo() async`, `cancelDiscard()`

- [ ] **Step 1: Extend the fake and write the failing tests**

In `Tests/PaddockCoreTests/DatabasesModelTests.swift`, make `FakeBrowser` conform to both protocols and record writes. Replace the class declaration line and add fields and methods:

```swift
private final class FakeBrowser: DatabaseBrowsing, DatabaseWriting, @unchecked Sendable {
    static let users = DatabaseTable(schema: "public", name: "users", kind: "table")
    static let logs = DatabaseTable(schema: "public", name: "logs", kind: "table")
    static let keyless = DatabaseTable(schema: "public", name: "keyless", kind: "table")

    var conflict: DatabaseError?
    private(set) var rowKeys: [[String: String?]] = []
    private(set) var inserted: [String: String?]?
    private(set) var updated: (key: [String: String?], changes: [String: String?],
                               expected: [String: String?])?
    private(set) var deleted: [String: String?]?

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
```

Change the existing `tables(for:)` to include the keyless table, and `columns(for:)` to give it a column with no primary key:

```swift
    func tables(for service: DatabaseService, database: String) throws -> [DatabaseTable] {
        [Self.users, Self.logs, Self.keyless]
    }
```

At the top of the existing `rows(for:)`, before its `lock.lock()` line, add:

```swift
        if table.id == Self.keyless.id {
            return DatabaseRows(columns: ["body"], rows: [["hello"]], truncated: false)
        }
```

Then replace the existing `columns(for:)` with:

```swift
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
```

Add these tests to `DatabasesModelTests`:

```swift
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
        XCTAssertEqual(model.pendingDeleteText, "id = 2")
        await model.confirmDelete()

        XCTAssertEqual(browser.deleted, ["id": "2"])
        XCTAssertEqual(model.notice, "Deleted.")
        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(model.rows?.rows.count, 5)
    }

    func testATableWithoutAPrimaryKeyCannotBeEdited() async throws {
        await model.select(table: FakeBrowser.keyless)
        XCTAssertFalse(model.isEditableTable)
        XCTAssertEqual(model.readOnlyNote, "Read-only: no primary key")
        model.beginInsert()
        XCTAssertNil(model.draft)
    }

    func testWhoeverHasAnUnsavedRowIsAskedBeforeLeaving() async throws {
        await model.beginEdit(row: 0)
        model.setDraftText("Ada L.", column: "name")
        await model.go(to: .table(FakeBrowser.logs))

        XCTAssertEqual(model.pendingDiscard, .table(FakeBrowser.logs))
        XCTAssertEqual(model.table?.id, FakeBrowser.users.id, "still here until the answer")
        await model.discardAndGo()

        XCTAssertNil(model.pendingDiscard)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.table?.id, FakeBrowser.logs.id)
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter 'DatabasesModelTests'`
Expected: compile errors — no `beginEdit`, `go(to:)`, `draft`, and `DatabasesModel` wants a `DatabaseWriting`.

- [ ] **Step 3: Implement the model additions**

In `DatabasesModel.swift`, change the stored browser and initializer:

```swift
    private let browser: (any DatabaseBrowsing & DatabaseWriting)?

    public init(browser: (any DatabaseBrowsing & DatabaseWriting)?,
                services: @escaping @MainActor () -> [ServiceStatus]) {
        self.browser = browser
        availableServices = services
    }
```

Add the destination type above the class:

```swift
/// Where the window may go; a row being edited asks first.
public enum DatabaseDestination: Equatable, Sendable {
    case service(String)
    case database(String)
    case table(DatabaseTable)
}
```

Add state below `lastError`:

```swift
    /// The row being edited, or the new row being filled in.
    @Published public private(set) var draft: DatabaseEditDraft?
    /// The row the draft belongs to; nil while the draft is a new row.
    @Published public private(set) var editingRow: Int?
    @Published public private(set) var isSaving = false
    /// Saved / Added / Deleted, kept across the reload that follows a write.
    @Published public private(set) var notice: String?
    /// The row the delete dialog is about.
    @Published public private(set) var pendingDelete: DatabaseRowKey?
    /// Where a navigation wants to go while an unsaved draft asks first.
    @Published public private(set) var pendingDiscard: DatabaseDestination?
```

Add the derived values after `canRunQuery`:

```swift
    /// Whether this table can be written at all: a real table with a primary key.
    public var isEditableTable: Bool {
        guard let table, !table.isView, !columns.isEmpty else { return false }
        return columns.contains(where: \.primary)
    }

    public var readOnlyNote: String? {
        guard table != nil, !columns.isEmpty, !isEditableTable else { return nil }
        return "Read-only: no primary key"
    }

    public var hasUnsavedDraft: Bool {
        guard let draft else { return false }
        return draft.mode == .insert || draft.hasChanges
    }

    public var canSaveDraft: Bool {
        guard let draft, !isSaving else { return false }
        return draft.mode == .insert || draft.hasChanges
    }

    public var pendingDeleteText: String? { pendingDelete?.description }
```

Tighten `canReload`:

```swift
    public var canReload: Bool { isRunning && !isBusy && draft == nil && !isSaving }
```

Add the actions before `// MARK: - Watching`:

```swift
    // MARK: - Editing

    /// Opens one row for editing, whole: the grid's clipped text never feeds a write.
    public func beginEdit(row index: Int) async {
        guard draft == nil, !isSaving, isEditableTable,
              let table, let service = selectedService, let database, service.isRunning,
              let browser, let rows, rows.rows.indices.contains(index),
              let key = rowKey(at: index) else { return }
        beginLoad()
        defer { endLoad() }
        do {
            let full = try await Task.detached(priority: .userInitiated) {
                try browser.row(for: service, database: database, table: table, key: key.values)
            }.value
            guard self.table?.id == table.id, self.rows?.rows.indices.contains(index) == true else { return }
            var original = full
            for (name, value) in zip(rows.columns, rows.rows[index]) where !original.keys.contains(name) {
                original[name] = value
            }
            draft = .update(columns: columns, key: key, original: original)
            editingRow = index
            notice = nil
            lastError = nil
        } catch {
            show(error)
        }
    }

    public func beginInsert() {
        guard draft == nil, !isSaving, isEditableTable else { return }
        draft = .insert(columns: columns)
        editingRow = nil
        notice = nil
        lastError = nil
    }

    public func setDraftText(_ text: String, column: String) {
        guard var copy = draft else { return }
        copy.type(text, into: column)
        draft = copy
    }

    public func setDraftNull(_ isNull: Bool, column: String) {
        guard var copy = draft else { return }
        copy.setNull(isNull, column: column)
        draft = copy
    }

    public func cancelDraft() {
        draft = nil
        editingRow = nil
    }

    /// Saves the open row. On a refusal the draft stays exactly as it was.
    public func saveDraft() async {
        guard let draft, !isSaving, let service = selectedService, let database, let table,
              service.isRunning, let browser else { return }
        if let bad = draft.invalidJSONColumns().first {
            lastError = "The \(bad) value isn't valid JSON."
            return
        }
        if draft.mode == .update, !draft.hasChanges { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch draft.mode {
            case .insert:
                let values = draft.values
                try await Task.detached(priority: .userInitiated) {
                    try browser.insert(for: service, database: database, table: table, values: values)
                }.value
                notice = "Added."
            case .update:
                guard let key = draft.key else { return }
                let keyValues = key.values
                let changes = draft.changes
                let expected = draft.expected
                try await Task.detached(priority: .userInitiated) {
                    try browser.update(for: service, database: database, table: table, key: keyValues,
                                       changes: changes, expected: expected)
                }.value
                notice = "Saved."
            }
            self.draft = nil
            editingRow = nil
            lastError = nil
            if let table = self.table, let database = self.database {
                await loadRows(table, service: service, database: database)
            }
        } catch {
            show(error)
        }
    }

    public func requestDelete(row index: Int) {
        guard draft == nil, !isSaving, isEditableTable else { return }
        pendingDelete = rowKey(at: index)
    }

    public func cancelDelete() { pendingDelete = nil }

    /// Deletes the confirmed row, after reading it whole so the check does not run on clipped text.
    public func confirmDelete() async {
        guard let key = pendingDelete, let service = selectedService, let database, let table,
              service.isRunning, let browser, !isSaving else { return }
        pendingDelete = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let keyValues = key.values
            let fresh = try await Task.detached(priority: .userInitiated) {
                try browser.row(for: service, database: database, table: table, key: keyValues)
            }.value
            let expected = fresh.filter { name, _ in
                columns.contains { $0.name == name && !$0.binary }
            }
            try await Task.detached(priority: .userInitiated) {
                try browser.delete(for: service, database: database, table: table,
                                   key: keyValues, expected: expected)
            }.value
            notice = "Deleted."
            lastError = nil
            if let table = self.table, let database = self.database {
                await loadRows(table, service: service, database: database)
            }
        } catch {
            show(error)
        }
    }

    /// A navigation that asks before discarding an unsaved row.
    public func go(to destination: DatabaseDestination) async {
        if hasUnsavedDraft {
            pendingDiscard = destination
            return
        }
        await perform(destination)
    }

    public func discardAndGo() async {
        guard let destination = pendingDiscard else { return }
        pendingDiscard = nil
        cancelDraft()
        await perform(destination)
    }

    public func cancelDiscard() { pendingDiscard = nil }

    private func perform(_ destination: DatabaseDestination) async {
        switch destination {
        case .service(let id): await select(service: id)
        case .database(let name): await select(database: name)
        case .table(let table): await select(table: table)
        }
    }

    private func rowKey(at index: Int) -> DatabaseRowKey? {
        guard let rows, rows.rows.indices.contains(index) else { return nil }
        return DatabaseRowKey(columns: columns, names: rows.columns, row: rows.rows[index])
    }
```

Then make the snapshot sample satisfy the composition, or the app target stops compiling. In
`Sources/PaddockApp/Snapshots.swift`, change `private struct SampleDatabase: DatabaseBrowsing {` to
`private struct SampleDatabase: DatabaseBrowsing, DatabaseWriting {` and add, before its closing brace:

```swift
        func row(for service: DatabaseService, database: String, table: DatabaseTable,
                 key: [String: String?]) throws -> [String: String?] {
            let id = key["id"] ?? nil
            guard let row = Self.userRows.first(where: { ($0.first ?? nil) == id }) else { return key }
            return ["id": row[0], "name": row[1], "meta": row[2], "email": row[3], "created_at": row[4]]
        }

        func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                    values: [String: String?]) throws {}

        func update(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?], changes: [String: String?],
                    expected: [String: String?]) throws {}

        func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?], expected: [String: String?]) throws {}
```

Task 8 gives the snapshots their editing states; these stubs only keep the package building until then.

Clear the draft and notice on navigation. In `select(database:)`, after `clearSearch()`, add:

```swift
        draft = nil
        editingRow = nil
        pendingDelete = nil
        pendingDiscard = nil
        notice = nil
```

Do the same at the start of `select(table:)` and `select(service:)`, and in `clearBelowService()`:

```swift
        if draft != nil { draft = nil }
        if editingRow != nil { editingRow = nil }
        if pendingDelete != nil { pendingDelete = nil }
        if pendingDiscard != nil { pendingDiscard = nil }
        if notice != nil { notice = nil }
```

Leave `loadRows` and `loadTable` alone: a reload after saving must keep `notice`, and it must not touch a draft (navigation clears instead).

- [ ] **Step 4: Run the model tests**

Run: `swift test --filter 'DatabasesModelTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaddockCore/App/DatabasesModel.swift Tests/PaddockCoreTests/DatabasesModelTests.swift
git commit -m "The Databases model edits, adds and deletes one row at a time"
```

---

### Task 6: The grid edits in place

**Files:**
- Modify: `Sources/PaddockApp/Databases/DatabasesView.swift` (`DatabaseRowsGrid`, new `GridActions`, `GridEditor`, `JSONEditor`)

**Interfaces:**
- Consumes: `DatabaseEditDraft`, `DatabaseColumn`, `DatabaseJSON.isValid`.
- Produces: `DatabaseRowsGrid(columns:rows:modelColumns:actions:editor:)`; `GridActions`; `GridEditor`; `JSONEditor(text:onCancel:onApply:)`.

- [ ] **Step 1: Add the two value types and the editable JSON box**

Add above `DatabaseRowsGrid` in `DatabasesView.swift`:

```swift
/// What a row's pencil and trash do. Passed only where the table can be written.
private struct GridActions {
    let onEdit: (Int) -> Void
    let onDelete: (Int) -> Void
}

/// The open row: its draft, the row it belongs to (nil for a new row), and how to change it.
private struct GridEditor {
    let draft: DatabaseEditDraft
    let row: Int?
    let saving: Bool
    let onText: (String, String) -> Void
    let onNull: (Bool, String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
}

/// A JSON value being edited: the whole document in a box, checked before it is applied. The read-only
/// twin of the cells' `JSONInspector`.
private struct JSONEditor: View {
    @SwiftUI.State private var text: String
    let onCancel: () -> Void
    let onApply: (String) -> Void

    init(text: String, onCancel: @escaping () -> Void, onApply: @escaping (String) -> Void) {
        _text = SwiftUI.State(initialValue: text)
        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JSON")
                .font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(DatabaseJSON.isValid(text) ? Theme.line : Color.red))
                .frame(width: 480, height: 250)
            HStack(spacing: 8) {
                if !DatabaseJSON.isValid(text) {
                    Text("Not valid JSON.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply") { onApply(text) }
                    .disabled(!DatabaseJSON.isValid(text))
            }
        }
        .padding(12)
        .frame(width: 504, height: 340)
        .background(Theme.surface)
    }
}
```

- [ ] **Step 2: Replace `DatabaseRowsGrid`**

Replace the whole current struct (from `private struct DatabaseRowsGrid` to just before `/// A JSON value in the grid`) with:

```swift
/// A result set as a grid: a row number gutter, then one column per result column, each as wide as its header
/// divider has been dragged, then, where the table can be written, an actions column. A row open for editing
/// replaces its cells with fields. Scrolls both ways.
private struct DatabaseRowsGrid: View {
    let columns: [DatabaseGridColumn]
    let rows: [[String?]]
    var modelColumns: [DatabaseColumn] = []
    var actions: GridActions?
    var editor: GridEditor?

    @SwiftUI.State private var widths = DatabaseGridWidths(columns: 0)
    /// The column whose edge is being dragged, and the width it had when the drag began.
    @SwiftUI.State private var resizing: Int?
    @SwiftUI.State private var resizeFrom: CGFloat = 0
    @SwiftUI.State private var hovered: Int?
    @SwiftUI.State private var jsonColumn: String?
    @FocusState private var focus: String?

    private static let gutter: CGFloat = 42
    /// How wide a column's edge is to the pointer, and how wide the line looks.
    private static let handle: CGFloat = 9
    private static let actionsWidth: CGFloat = 58
    private static let controlsWidth: CGFloat = 176

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        Group {
                            if let editor, editor.row == index {
                                editRow(index: index, editor: editor)
                            } else {
                                plainRow(index: index, row: row)
                            }
                            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
                        }
                    }
                    if let editor, editor.row == nil {
                        editRow(index: nil, editor: editor)
                        Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
                    }
                }
                // Small results stay at the top leading corner instead of drifting to the middle.
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        .background(Theme.surface)
        .onChange(of: columns.count) { _ in
            widths = DatabaseGridWidths(columns: columns.count)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell(Text(verbatim: "#"), width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if columns[index].isKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.honeyText)
                        }
                        Text(columns[index].name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    if let detail = columns[index].detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: widths[index], alignment: .leading)
                .clipped()
                .overlay(alignment: .trailing) { resizeHandle(index) }
            }
            if actions != nil {
                Color.clear.frame(width: Self.actionsWidth)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.ground)
    }

    private func plainRow(index: Int, row: [String?]) -> some View {
        HStack(spacing: 0) {
            cell(Text(verbatim: "\(index + 1)"), width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { column in
                valueCell(row: index, column: column, row[safe: column] ?? nil)
            }
            if let actions {
                actionButtons(actions, row: index)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions?.onEdit(index) }
        .contextMenu {
            if let actions {
                Button("Edit Row\u{2026}") { actions.onEdit(index) }
                Button("Delete Row\u{2026}", role: .destructive) { actions.onDelete(index) }
            }
        }
        .onHover { inside in
            if inside {
                hovered = index
            } else if hovered == index {
                hovered = nil
            }
        }
    }

    private func actionButtons(_ actions: GridActions, row: Int) -> some View {
        HStack(spacing: 2) {
            if hovered == row, editor == nil {
                Button { actions.onEdit(row) } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit this row")
                Button { actions.onDelete(row) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this row")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(Theme.inkMuted)
        .frame(width: Self.actionsWidth)
    }

    private func editRow(index: Int?, editor: GridEditor) -> some View {
        HStack(spacing: 0) {
            cell(index.map { Text(verbatim: "\($0 + 1)") } ?? Text(verbatim: "new"),
                 width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { column in
                if let model = modelColumn(at: column) {
                    editCell(model, index: column, editor: editor)
                } else {
                    cell(Text(verbatim: ""), width: widths[column])
                }
            }
            editorControls(editor)
        }
        .padding(.vertical, 3)
        .background(Theme.ground.opacity(0.6))
        .onAppear { focus = firstEditableColumn(editor.draft) }
    }

    private func modelColumn(at index: Int) -> DatabaseColumn? {
        guard columns.indices.contains(index) else { return nil }
        return modelColumns.first { $0.name == columns[index].name }
    }

    @ViewBuilder
    private func editCell(_ column: DatabaseColumn, index: Int, editor: GridEditor) -> some View {
        HStack(spacing: 4) {
            if column.isEditable {
                field(column, editor: editor)
                if column.nullable {
                    Button {
                        editor.onNull(!editor.draft.isNull(column.name), column.name)
                    } label: {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(editor.draft.isNull(column.name) ? Theme.honeyText : Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help(editor.draft.isNull(column.name) ? "Give this field a value" : "Set this field to NULL")
                }
            } else if let shown = editor.draft.shownValue(column.name) {
                Text(verbatim: Self.oneLine(shown))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(nonEditableHelp(column))
            } else {
                Text("NULL")
                    .font(.system(.caption, design: .monospaced))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
                    .help(nonEditableHelp(column))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: widths[index], alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
        }
        .disabled(editor.saving)
    }

    @ViewBuilder
    private func field(_ column: DatabaseColumn, editor: GridEditor) -> some View {
        if editor.draft.isNull(column.name) {
            Text("NULL")
                .font(.system(.caption, design: .monospaced))
                .italic()
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if column.type.lowercased() == "json" || column.type.lowercased() == "jsonb" {
            Button {
                jsonColumn = column.name
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: Self.oneLine(editor.draft.isTouched(column.name)
                        ? editor.draft.text(for: column.name)
                        : editor.draft.placeholder(for: column)))
                        .foregroundStyle(editor.draft.isTouched(column.name) ? Theme.ink : Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "curlybraces")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.honeyText)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(editor.draft.invalidJSONColumns().contains(column.name) ? Color.red : Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this JSON document")
            .popover(isPresented: Binding(
                get: { jsonColumn == column.name },
                set: { if !$0, jsonColumn == column.name { jsonColumn = nil } })) {
                JSONEditor(text: editor.draft.text(for: column.name),
                           onCancel: { jsonColumn = nil },
                           onApply: { text in
                               editor.onText(text, column.name)
                               jsonColumn = nil
                           })
            }
        } else {
            TextField(editor.draft.placeholder(for: column), text: Binding(
                get: { editor.draft.text(for: column.name) },
                set: { editor.onText($0, column.name) }))
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                .focused($focus, equals: column.name)
                .onSubmit { focus = nextEditable(after: column.name, in: editor.draft) }
        }
    }

    private func editorControls(_ editor: GridEditor) -> some View {
        HStack(spacing: 6) {
            if editor.saving {
                ProgressView().controlSize(.small)
            }
            Button("Save") { editor.onSave() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor.saving || !(editor.draft.mode == .insert || editor.draft.hasChanges))
            Button("Cancel") { editor.onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .disabled(editor.saving)
        }
        .padding(.horizontal, 8)
        .frame(width: Self.controlsWidth, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
        }
    }

    private func firstEditableColumn(_ draft: DatabaseEditDraft) -> String? {
        draft.columns.first { $0.isEditable }?.name
    }

    private func nextEditable(after name: String, in draft: DatabaseEditDraft) -> String? {
        guard let index = draft.columns.firstIndex(where: { $0.name == name }) else { return nil }
        return draft.columns[(index + 1)...].first { $0.isEditable }?.name
    }

    private func nonEditableHelp(_ column: DatabaseColumn) -> String {
        if column.binary { return "Binary values can't be edited here" }
        if column.generated { return "The database computes this column" }
        if column.identity { return "The database assigns this column" }
        return "Read-only here"
    }
```

Leave `resizeHandle`, `valueCell`, `cell`, and `oneLine` exactly as they are (they follow the replaced parts).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success. The console's `DatabaseRowsGrid` call still compiles because the new parameters default.

- [ ] **Step 4: Commit**

```bash
git add Sources/PaddockApp/Databases/DatabasesView.swift
git commit -m "The row grid edits in place"
```

---

### Task 7: The window's chrome: toolbar, dialogs, navigation

**Files:**
- Modify: `Sources/PaddockApp/Databases/DatabasesView.swift` (`DatabasesView` root, `DatabaseSidebar`, `DatabaseTablePane`, `DatabaseConsole` call)

**Interfaces:**
- Consumes: everything Task 5 produced, and the grid from Task 6.
- Produces: nothing new; the window now exposes the writes.

- [ ] **Step 1: Wire the sidebar through the prompt**

In `DatabaseSidebar`, replace the three selection calls:

```swift
Task { await databases.go(to: .service(service.id)) }
Task { await databases.go(to: .database(name)) }
Task { await databases.go(to: .table(table)) }
```

- [ ] **Step 2: Add the root discard alert**

In `DatabasesView.body`, after `.background(Theme.ground)`, add:

```swift
        .alert("Discard the unsaved row?", isPresented: Binding(
            get: { databases.pendingDiscard != nil },
            set: { if !$0 { databases.cancelDiscard() } })) {
            Button("Cancel", role: .cancel) { databases.cancelDiscard() }
            Button("Discard", role: .destructive) { Task { await databases.discardAndGo() } }
        } message: {
            Text("The row you were editing hasn't been saved yet.")
        }
```

- [ ] **Step 3: Replace the table pane's toolbar and grid call**

In `DatabaseTablePane.body`, replace the toolbar `HStack` with:

```swift
            HStack(spacing: 8) {
                Text(databases.title)
                    .font(Theme.heading(16))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if databases.table != nil {
                    TextField("Search rows", text: Binding(
                        get: { databases.rowSearch },
                        set: { text in databases.setRowSearch(text) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .disabled(databases.draft != nil)
                        .help("Find rows with this text in any column, searched across the whole table")
                }
                if let count = databases.rowCountText, databases.table != nil {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                if let notice = databases.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                if databases.isBusy || databases.isSaving {
                    ProgressView().controlSize(.small)
                }
                if databases.table != nil {
                    if databases.isEditableTable {
                        Button {
                            databases.beginInsert()
                        } label: {
                            Label("New row", systemImage: "plus")
                        }
                        .disabled(databases.draft != nil || databases.isSaving)
                        .help("Add a row at the end of this table")
                    } else if let note = databases.readOnlyNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .help("Only tables with a primary key can be edited here")
                    }
                }
                Button("Reload") { Task { await databases.reload() } }
                    .disabled(!databases.canReload)
                    .help("Read the databases and tables again")
            }
```

and in `content` change the `noRowsText` branch to `if let text = databases.noRowsText, databases.draft == nil {` (an empty table must still show its new row), and replace `DatabaseRowsGrid(columns: gridColumns(rows), rows: rows.rows)` with:

```swift
                DatabaseRowsGrid(columns: gridColumns(rows), rows: rows.rows,
                                 modelColumns: databases.columns,
                                 actions: databases.isEditableTable
                                     ? GridActions(
                                         onEdit: { index in Task { await databases.beginEdit(row: index) } },
                                         onDelete: { databases.requestDelete(row: $0) })
                                     : nil,
                                 editor: databases.draft.map { draft in
                                     GridEditor(
                                         draft: draft,
                                         row: databases.editingRow,
                                         saving: databases.isSaving,
                                         onText: { databases.setDraftText($0, column: $1) },
                                         onNull: { databases.setDraftNull($0, column: $1) },
                                         onSave: { Task { await databases.saveDraft() } },
                                         onCancel: { databases.cancelDraft() })
                                 })
```

- [ ] **Step 4: Add the delete dialog**

Attach to `DatabaseTablePane.body`, after the outer `VStack`'s `.background(Theme.surface)`: 

```swift
        .alert("Delete this row?", isPresented: Binding(
            get: { databases.pendingDelete != nil },
            set: { if !$0 { databases.cancelDelete() } })) {
            Button("Cancel", role: .cancel) { databases.cancelDelete() }
            Button("Delete", role: .destructive) { Task { await databases.confirmDelete() } }
        } message: {
            Text("Delete the row where \(databases.pendingDeleteText ?? "")? This can't be undone.")
        }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add Sources/PaddockApp/Databases/DatabasesView.swift
git commit -m "New rows, saves and deletes in the Databases window"
```

---

### Task 8: Snapshots and the sample database

**Files:**
- Modify: `Sources/PaddockApp/Snapshots.swift`

**Interfaces:**
- Consumes: `DatabaseWriting` (Task 3) and the window (Tasks 6-7).
- Produces: snapshots `databases-edit`, `databases-new`, `databases-readonly` in light and dark.

- [ ] **Step 1: Give the sample its view and its identity key**

The sample already conforms to both protocols (Task 5). In `Snapshots.swift`, replace its `columns(for:)` with one that gives the view its own columns and marks `id` identity (so the editor shows it as assigned):

```swift
        func columns(for service: DatabaseService, database: String, table: DatabaseTable) throws -> [DatabaseColumn] {
            if table.name == "recent_orders" {
                return [DatabaseColumn(name: "order_id", type: "bigint", nullable: false,
                                       defaultValue: nil, primary: false),
                        DatabaseColumn(name: "total", type: "numeric", nullable: true,
                                       defaultValue: nil, primary: false)]
            }
            return [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil,
                                   primary: true, identity: true),
                    DatabaseColumn(name: "name", type: "varchar(255)", nullable: false,
                                   defaultValue: nil, primary: false),
                    DatabaseColumn(name: "meta", type: "jsonb", nullable: true, defaultValue: nil, primary: false),
                    DatabaseColumn(name: "email", type: "varchar(255)", nullable: false,
                                   defaultValue: nil, primary: false),
                    DatabaseColumn(name: "created_at", type: "timestamptz", nullable: true,
                                   defaultValue: nil, primary: false)]
        }
```

Then add a branch at the top of the sample's existing `rows(for:)`, before its `guard let search`, so the view shows its own two columns:

```swift
            if table.name == "recent_orders" {
                return DatabaseRows(columns: ["order_id", "total"],
                                    rows: [["1042", "129.00"], ["1043", "54.50"]], truncated: false)
            }
```

- [ ] **Step 2: Add the sample states**

Replace `databasesModel(searching:querying:)` with:

```swift
    private static func databasesModel(searching: String? = nil, querying: Bool = false,
                                       editing: Int? = nil, inserting: Bool = false,
                                       readOnly: Bool = false) -> DatabasesModel {
        let postgres = service("postgres-18", "PostgreSQL 18", kind: "postgres", state: .running, ports: ["main": 5432])
        let model = DatabasesModel(browser: SampleDatabase(), services: { [postgres] })
        settle {
            await model.refresh()
            if readOnly {
                await model.select(table: DatabaseTable(schema: "public", name: "recent_orders", kind: "view"))
            } else {
                await model.select(table: DatabaseTable(schema: "public", name: "users", kind: "table"))
                if let searching {
                    model.setRowSearch(searching)
                    // The model collects typing for a moment before reading; let that moment pass.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if querying {
                    model.setQuery("SELECT count(*) FROM users")
                    await model.runQuery()
                }
                if let editing {
                    await model.beginEdit(row: editing)
                }
                if inserting {
                    model.beginInsert()
                }
            }
        }
        return model
    }
```

- [ ] **Step 3: Add the three shots**

After `("databases-no-match", ...)`, add:

```swift
            ("databases-edit", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(editing: 1))), DatabasesView.size),
            ("databases-new", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(inserting: true))), DatabasesView.size),
            ("databases-readonly", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(readOnly: true))), DatabasesView.size),
```

- [ ] **Step 4: Render and look**

Run: `swift run PaddockApp --snapshots /tmp/paddock-snapshots-writes`
Expected: prints a path per image. Read `/tmp/paddock-snapshots-writes/databases-edit-light.png`,
`databases-new-light.png`, `databases-readonly-light.png` and `databases-edit-dark.png`.

Check: the edit row shows fields with Save/Cancel; the identity `id` is grey; `meta` shows the braces box; the new row shows `required`/`NULL`/`default` placeholders; the view's toolbar says `Read-only: no primary key` and has no actions column; light and dark both legible. Then run the app by hand (`swift run PaddockApp`), hover a row for the pencil and trash, and open the trash: the dialog must name the key (`id = 2`) and Cancel must leave the row alone.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaddockApp/Snapshots.swift
git commit -m "Snapshots for editing, new rows and read-only tables"
```

---

### Task 9: Docs, release notes, version and the full gate

**Files:**
- Modify: `README.md` (Databases section)
- Create: `docs/releases/0.4.0.md`
- Modify: `VERSION` (`0.4.0`)
- Modify: `Sources/PaddockCore/Engine.swift` (`number = 24`)
- Modify: `docs/images/databases-light.png` (from `databases-edit-light.png` if the action column reads better; otherwise keep the plain one)

**Interfaces:**
- Consumes: all previous tasks.
- Produces: the shippable 0.4.0.

- [ ] **Step 1: Rewrite the README's Databases bullets**

In `### The Databases window`, replace everything from the `**The first 50 rows**` bullet through the `Nothing here changes a database. Creating one is ... the window only reads.` bullet with:

```markdown
- **The first 50 rows** of a chosen table, with each column's type and a key
  for the primary key. Values are one line and stay inside their column;
  hover one to see it whole. A JSON or JSONB value shows its one line with a
  `{ }` mark: click it to read the whole document, indented.
- **Column widths** are yours: drag the divider at the right edge of a column
  in the header.
- **Editing** works on tables with a primary key: double-click a row (or use
  its pencil), change its fields, and ⌘⏎ saves; Esc cancels. Only what you
  changed is written, NULL and empty text stay distinct, and JSON opens in an
  editable box. Views and tables without a primary key say they are read-only.
- **+ New row** adds a blank row at the end; fields you leave alone keep the
  database's default. The trash asks first, naming the row's key.
- **Search** finds rows holding a text in any column. The database does the
  looking, so it sees the whole table, not just the rows on show; the first 50
  matches appear. **Filter tables** narrows the table list as you type.
- **Reload** reads the databases, tables and rows again.
- **SQL** runs one read-only statement (`SELECT`, `WITH`, `SHOW`, `DESCRIBE`,
  `EXPLAIN`, `TABLE` or `VALUES`) with ⌘↩, and shows its result. A statement
  that could write is refused before PHP starts, and the statement runs inside
  a read-only transaction with a five-second limit.
- Reads still run in read-only transactions and the SQL console can't write.
  Row edits are individual, confirmed writes: each save checks that the row
  hasn't changed since it was read, and refuses rather than overwrite it.
  Creating a database is still `paddock service create-db`.
```

Then two smaller corrections elsewhere in the file:

1. The feature table's Databases row (line ~100): `Browse the PostgreSQL and MySQL services you added: their databases, tables and columns, the first rows, and one read-only SQL statement. Nothing in it can write.` becomes `Browse and edit the PostgreSQL and MySQL services you added: their databases, tables, columns and rows, with one read-only SQL statement beside them.`
2. In `### Databases` under the CLI: `The same read-only browser as the Databases window, for the terminal.` becomes `A read-only browser of the same databases, for the terminal; edits are in the window.`

Update the image alt text:

```markdown
  <img src="docs/images/databases-light.png" width="760" alt="The Databases window: a table filter and the services, databases and tables on the left; the users table's columns (with a JSON meta column) and rows on the right, with a row search and row actions, above a read-only SQL console">
```

- [ ] **Step 2: Write the release notes**

Create `docs/releases/0.4.0.md`:

```markdown
Records can be edited, added and deleted in the Databases window.

- Double-click a row of a table with a primary key to change it in place; ⌘⏎ saves and Esc cancels. Only the fields you changed are written.
- + adds a blank row at the end; untouched fields keep the database's default, and a NULL toggle keeps NULL apart from empty text. JSON columns open in an editable box.
- The trash asks first, naming the row's key.
- Every save locks and re-reads its row inside the transaction and refuses if it changed since you opened it, rather than overwriting someone's work.
- Views and tables without a primary key say they are read-only. The SQL console and `paddock db` stay read-only.
```

- [ ] **Step 3: Bump the version**

```bash
printf '0.4.0\n' > VERSION
```

and in `Sources/PaddockCore/Engine.swift`, `public static let number = 24`.

- [ ] **Step 4: Update the documentation image**

If the edit-state image shows the feature better, copy it:

```bash
cp /tmp/paddock-snapshots-writes/databases-edit-light.png docs/images/databases-light.png
```

Otherwise copy the plain `databases-light.png` from the new render (the shot named `databases`, light).

- [ ] **Step 5: Run the full unit suite**

Run: `swift test --filter 'PaddockCoreTests'`
Expected: `0 failures`.

- [ ] **Step 6: Run both integration pairs**

Run: `swift test --filter 'DatabaseBrowser(Reads|Writes)(PostgreSQL|MySQL)'`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 7: Build the app**

Run: `swift build`
Expected: success.

- [ ] **Step 8: Commit**

```bash
git add README.md docs/releases/0.4.0.md VERSION Sources/PaddockCore/Engine.swift docs/images/databases-light.png
git commit -m "Release notes and version for 0.4.0"
```

Publishing is `Scripts/release.sh 0.4.0 --publish` from a clean `main`, only when the owner asks. Note that VERSION already equals 0.4.0, so the script will not bump the build again; it stays 24.
