import Foundation
import XCTest
@testable import PaddockCore

final class DatabaseJSONTests: XCTestCase {
    func testAnObjectIsPrettyAndOneLineAsAPreview() {
        let document = DatabaseJSON.document(#"{"user":{"name":"Ada","tags":["a","b"]},"n":42}"#)
        XCTAssertEqual(document?.preview, #"{"n":42,"user":{"name":"Ada","tags":["a","b"]}}"#)
        XCTAssertEqual(document?.pretty, """
        {
          "n" : 42,
          "user" : {
            "name" : "Ada",
            "tags" : [
              "a",
              "b"
            ]
          }
        }
        """)
    }

    func testAnArrayIsADocumentToo() {
        let document = DatabaseJSON.document(#"[1,{"a":true}]"#)
        XCTAssertEqual(document?.preview, #"[1,{"a":true}]"#)
        XCTAssertEqual(document?.pretty, """
        [
          1,
          {
            "a" : true
          }
        ]
        """)
    }

    func testUnicodeAndSlashesStayReadable() {
        let document = DatabaseJSON.document(#"{"url":"https://a.test/b","text":"naïve 🐴"}"#)
        XCTAssertEqual(document?.preview, #"{"text":"naïve 🐴","url":"https://a.test/b"}"#)
    }

    func testWhitespaceAroundTheDocumentIsFine() {
        XCTAssertEqual(DatabaseJSON.document("\n  {\"a\": 1}\t\n")?.preview, #"{"a":1}"#)
    }

    func testEmptyContainersAreDocuments() {
        XCTAssertEqual(DatabaseJSON.document("{}")?.preview, "{}")
        XCTAssertEqual(DatabaseJSON.document("[]")?.preview, "[]")
    }

    func testScalarsAreNotDocuments() {
        for text in ["42", "-1.5", "\"hello\"", "true", "null", "\"{\"a\":1}\""] {
            XCTAssertNil(DatabaseJSON.document(text), text)
        }
    }

    func testBrokenOrCutJSONIsNotADocument() {
        for text in ["", "   ", "{\"a\":", "{\"a\": 1}…", "[1, 2", "not json"] {
            XCTAssertNil(DatabaseJSON.document(text), text)
        }
    }

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
}
