import XCTest
@testable import PaddockCore

/// Paddock's reading of a dump against Symfony VarDumper's own. `Tests/Fixtures/var-dumper/*.json` holds real
/// payloads, exactly as VarDumper's dump server client sends them, each with the text VarDumper's own
/// `CliDumper` prints for it (made by the generator the roadmap describes, from VarDumper 8 and 6.4).
final class DumpDecoderTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let payload: String
        let text: String
    }

    private func cases(_ version: String) throws -> [Case] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/var-dumper/\(version).json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
    }

    private func assertReadsAsVarDumperDoes(_ version: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let cases = try cases(version)
        XCTAssertGreaterThan(cases.count, 40, file: file, line: line)
        for (index, item) in cases.enumerated() {
            do {
                let dump = try DumpDecoder.decode(line: Data(item.payload.utf8), id: index)
                XCTAssertEqual(dump.text, item.text, "\(version): \(item.name)", file: file, line: line)
            } catch {
                XCTFail("\(version): \(item.name) could not be read: \(error)", file: file, line: line)
            }
        }
    }

    func testEveryDumpReadsAsVarDumper8PrintsIt() throws { try assertReadsAsVarDumperDoes("v8") }

    func testEveryDumpReadsAsVarDumper6PrintsIt() throws { try assertReadsAsVarDumperDoes("v6") }

    func testWhereAndDuringWhatADumpWasMadeIsRead() throws {
        let cases = try cases("v8")
        let web = try DumpDecoder.decode(line: Data(try XCTUnwrap(cases.first { $0.name == "assoc" }).payload.utf8), id: 7)
        XCTAssertEqual(web.id, 7)
        XCTAssertEqual(web.origin, "GET https://shop.test/orders/1042?tab=items")
        XCTAssertEqual(web.file, "/Users/you/Paddock/shop/app/Http/Controllers/OrderController.php")
        XCTAssertEqual(web.line, 42)
        XCTAssertEqual(web.source, "OrderController.php:42")
        XCTAssertEqual(try XCTUnwrap(web.time).timeIntervalSince1970, 1_795_310_050.25, accuracy: 0.001)

        let cli = try DumpDecoder.decode(line: Data(try XCTUnwrap(cases.first { $0.name == "from the command line" }).payload.utf8), id: 8)
        XCTAssertEqual(cli.origin, "artisan queue:work --tries=3")
        XCTAssertEqual(cli.source, "Worker.php:9")
    }

    func testTheTreeHasAMemberPerLineAndFoldsWhatIsNested() throws {
        let cases = try cases("v8")
        let dump = try DumpDecoder.decode(line: Data(try XCTUnwrap(cases.first { $0.name == "object with visibilities" }).payload.utf8), id: 1)
        XCTAssertEqual(dump.root.kind, .hash)
        XCTAssertTrue(dump.root.head.hasPrefix("Order {#"))
        XCTAssertEqual(dump.root.tail, "}")
        XCTAssertEqual(dump.root.children.map(\.head),
                       ["+id: 1042", "+note: null", "#lines: array:2 [", "-total: 59.0", "+parent: null"])
        let lines = dump.root.children[2]
        XCTAssertTrue(lines.isFoldable)
        XCTAssertEqual(lines.children.map(\.head), ["\"widget\" => 2", "\"gadget\" => 1"])
        XCTAssertEqual(lines.tail, "]")
        XCTAssertFalse(dump.root.children[0].isFoldable)
        // Every line has its own id.
        var ids: [Int] = []
        func collect(_ node: DumpNode) { ids.append(node.id); node.children.forEach(collect) }
        collect(dump.root)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testWhatIsNotADumpIsRefusedAndNothingInItIsRun() {
        for junk in ["", "not base64 at all!", Data("hello".utf8).base64EncodedString(),
                     Data("a:2:{i:0;i:1;i:1;i:2;}".utf8).base64EncodedString(),
                     Data(#"a:2:{i:0;O:8:"stdClass":0:{}i:1;a:0:{}}"#.utf8).base64EncodedString(),
                     Data(#"O:8:"Evil\Run":1:{s:3:"cmd";s:2:"id";}"#.utf8).base64EncodedString()] {
            XCTAssertThrowsError(try DumpDecoder.decode(line: Data(junk.utf8), id: 0), junk) {
                XCTAssertEqual($0 as? DumpError, .notADump)
            }
        }
    }

    func testFloatsAreWrittenAsPHPWritesThem() {
        XCTAssertEqual(DumpDecoder.float(1.5), "1.5")
        XCTAssertEqual(DumpDecoder.float(2), "2.0")
        XCTAssertEqual(DumpDecoder.float(0.1 + 0.2), "0.3")
        XCTAssertEqual(DumpDecoder.float(1e100), "1.0E+100")
        XCTAssertEqual(DumpDecoder.float(1.5e-7), "1.5E-7")
        XCTAssertEqual(DumpDecoder.float(-0.0), "-0.0")
        XCTAssertEqual(DumpDecoder.float(.infinity), "INF")
        XCTAssertEqual(DumpDecoder.float(.nan), "NAN")
    }
}

final class PHPSerializedTests: XCTestCase {
    private func parse(_ text: String) throws -> PHPValue { try PHPSerialized.parse(Data(text.utf8)) }

    func testScalarsArraysAndObjects() throws {
        guard case .array(let entries) = try parse(#"a:5:{i:0;N;i:1;b:1;s:1:"k";i:-7;i:3;d:0.5;i:4;s:5:"h"i"!";}"#) else {
            return XCTFail("not an array")
        }
        XCTAssertEqual(entries.map(\.key), [.int(0), .int(1), .string(Data("k".utf8)), .int(3), .int(4)])
        XCTAssertEqual(entries[2].value.intValue, -7)
        XCTAssertEqual(entries[4].value.stringValue, #"h"i"!"#, "a string is its length in bytes, whatever it holds")
        guard case .object(let name, let properties) = try parse(#"O:3:"A\B":1:{s:1:"p";s:1:"v";}"#) else {
            return XCTFail("not an object")
        }
        XCTAssertEqual(name, #"A\B"#)
        XCTAssertEqual(properties.first?.value.stringValue, "v")
    }

    /// `r:` names an earlier value by its number and takes a number itself; `R:` names one and does not.
    func testRepeatedValuesAreNumberedAsPHPNumbersThem() throws {
        // 1: the array, 2: the object, 3: r:2 (takes a number), 4: the string; R:4 takes none, so 5 is "z".
        let value = try parse(#"a:5:{i:0;O:1:"A":0:{}i:1;r:2;i:2;s:1:"x";i:3;R:4;i:4;s:1:"z";}"#)
        guard case .array(let entries) = value else { return XCTFail("not an array") }
        if case .object(let name, _) = entries[1].value { XCTAssertEqual(name, "A") } else { XCTFail("r: is the object again") }
        XCTAssertEqual(entries[3].value.stringValue, "x")
        XCTAssertEqual(entries[4].value.stringValue, "z")
    }

    func testMalformedAndOversizedInputIsRefused() {
        for bad in ["", "x", "i:1", "s:5:\"ab\";", "a:2:{i:0;i:1;}", "a:1:{i:0;i:1;}trailing", "r:9;", "s:-1:\"\";",
                    "a:99999999:{", "O:1:\"A\":1:{b:1;i:1;}"] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
        let deep = String(repeating: "a:1:{i:0;", count: PHPSerialized.depthLimit + 5) + "N;"
            + String(repeating: "}", count: PHPSerialized.depthLimit + 5)
        XCTAssertThrowsError(try parse(deep)) { XCTAssertEqual($0 as? PHPSerializedError, .tooLarge) }
    }
}
