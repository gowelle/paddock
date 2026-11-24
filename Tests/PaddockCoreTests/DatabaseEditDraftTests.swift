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
