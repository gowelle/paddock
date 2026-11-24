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
