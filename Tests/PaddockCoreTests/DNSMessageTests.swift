import XCTest
@testable import PaddockCore

final class DNSMessageTests: XCTestCase {
    private func query(_ name: String, type: UInt16, id: UInt16 = 0x1234,
                       flags: UInt16 = 0x0100, qdcount: UInt16 = 1,
                       withOPT: Bool = false) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xff)) }
        u16(id); u16(flags); u16(qdcount); u16(0); u16(0); u16(withOPT ? 1 : 0)
        for label in name.split(separator: ".") {
            d.append(UInt8(label.utf8.count)); d.append(contentsOf: Array(label.utf8))
        }
        d.append(0)
        u16(type); u16(1)
        if withOPT { d.append(0); u16(41); u16(4096); u16(0); u16(0); u16(0) }
        return d
    }

    private func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) << 8 | UInt16(d[d.startIndex + i + 1])
    }

    func testAQuery() throws {
        let q = query("foo.test", type: 1)
        let r = try XCTUnwrap(DNSMessage.response(to: q, tld: "test"))
        XCTAssertEqual(u16(r, 0), 0x1234)
        XCTAssertEqual(u16(r, 2) & 0x8000, 0x8000, "QR")
        XCTAssertEqual(u16(r, 2) & 0x0400, 0x0400, "AA")
        XCTAssertEqual(u16(r, 2) & 0x0100, 0x0100, "RD copied")
        XCTAssertEqual(u16(r, 2) & 0x000F, 0, "NOERROR")
        XCTAssertEqual(u16(r, 4), 1)
        XCTAssertEqual(u16(r, 6), 1)
        XCTAssertEqual(Array(r.suffix(4)), [0x7F, 0, 0, 0x01])
        // TTL 60 sits before RDLENGTH(2)+RDATA(4)
        XCTAssertEqual(Array(r[(r.count - 10)..<(r.count - 6)]), [0, 0, 0, 60])
        XCTAssertEqual(Array(r[12..<q.count]), Array(q[12...]), "question copied")
    }

    func testAAAAQuery() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("foo.test", type: 28), tld: "test"))
        XCTAssertEqual(u16(r, 6), 1)
        XCTAssertEqual(Array(r.suffix(16)), [UInt8](repeating: 0, count: 15) + [1])
    }

    func testBareTLDIsAnswered() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("test", type: 1), tld: "test"))
        XCTAssertEqual(u16(r, 6), 1)
    }

    func testMXQueryHasNoAnswers() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("foo.test", type: 15), tld: "test"))
        XCTAssertEqual(u16(r, 2) & 0x000F, 0)
        XCTAssertEqual(u16(r, 6), 0)
    }

    func testOtherTLDIsNXDOMAIN() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("foo.example", type: 1), tld: "test"))
        XCTAssertEqual(u16(r, 2) & 0x000F, 3)
        XCTAssertEqual(u16(r, 6), 0)
    }

    func testSuffixWithoutDotBoundaryIsNXDOMAIN() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("footest", type: 1), tld: "test"))
        XCTAssertEqual(u16(r, 2) & 0x000F, 3)
    }

    func testTruncatedPacketIsDropped() {
        let q = query("foo.test", type: 1)
        XCTAssertNil(DNSMessage.response(to: q.prefix(5), tld: "test"))
        XCTAssertNil(DNSMessage.response(to: q.prefix(q.count - 3), tld: "test"))
    }

    func testMultiQuestionIsDropped() {
        XCTAssertNil(DNSMessage.response(to: query("foo.test", type: 1, qdcount: 2), tld: "test"))
    }

    func testCompressedNameIsDropped() {
        var q = query("foo.test", type: 1)
        q[12] = 0xC0
        XCTAssertNil(DNSMessage.response(to: q, tld: "test"))
    }

    func testNameIsCaseInsensitive() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("MyApp.TEST", type: 1), tld: "test"))
        XCTAssertEqual(u16(r, 6), 1)
        XCTAssertEqual(u16(r, 2) & 0x000F, 0)
    }

    func testEDNSQueryIsAnsweredWithoutAdditional() throws {
        let r = try XCTUnwrap(DNSMessage.response(to: query("foo.test", type: 1, withOPT: true), tld: "test"))
        XCTAssertEqual(u16(r, 10), 0)
        XCTAssertEqual(u16(r, 6), 1)
        XCTAssertEqual(Array(r.suffix(4)), [0x7F, 0, 0, 0x01])
    }

    func testResponsesAreDropped() {
        XCTAssertNil(DNSMessage.response(to: query("foo.test", type: 1, flags: 0x8100), tld: "test"))
    }
}
