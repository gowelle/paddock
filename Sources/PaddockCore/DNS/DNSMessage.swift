import Foundation

/// Pure DNS packet handling for the `*.test` responder.
public enum DNSMessage {
    private static let ttl: UInt32 = 60

    /// Builds the response for a single-question query, or nil if the packet
    /// should be dropped (malformed, multi-question, compressed name, or a response).
    public static func response(to query: Data, tld: String) -> Data? {
        let q = [UInt8](query)
        guard q.count >= 12 else { return nil }
        let flags = UInt16(q[2]) << 8 | UInt16(q[3])
        guard flags & 0x8000 == 0 else { return nil }               // not a query
        guard (flags >> 11) & 0xF == 0 else { return nil }          // opcode QUERY only
        guard q[4] == 0, q[5] == 1 else { return nil }              // exactly one question

        // Parse the question name (no compression allowed).
        var labels: [String] = []
        var i = 12
        while true {
            guard i < q.count else { return nil }
            let len = Int(q[i])
            if len == 0 { i += 1; break }
            guard len & 0xC0 == 0, i + 1 + len <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        guard i + 4 <= q.count else { return nil }
        let qtype = UInt16(q[i]) << 8 | UInt16(q[i + 1])
        let questionEnd = i + 4

        let name = labels.joined(separator: ".").lowercased()
        let zone = tld.lowercased()
        let inZone = name == zone || name.hasSuffix("." + zone)

        var rdata: [UInt8] = []
        if inZone {
            if qtype == 1 { rdata = [127, 0, 0, 1] }
            else if qtype == 28 { rdata = [UInt8](repeating: 0, count: 15) + [1] }
        }
        let rcode: UInt16 = inZone ? 0 : 3
        let respFlags: UInt16 = 0x8000 | 0x0400 | (flags & 0x0100) | rcode

        var out = [UInt8]()
        out.append(q[0]); out.append(q[1])
        out.append(UInt8(respFlags >> 8)); out.append(UInt8(respFlags & 0xFF))
        out += [0, 1, 0, rdata.isEmpty ? 0 : 1, 0, 0, 0, 0]
        out += q[12..<questionEnd]
        if !rdata.isEmpty {
            out += [0xC0, 0x0C]                                     // pointer to question name
            out += [UInt8(qtype >> 8), UInt8(qtype & 0xFF), 0, 1]   // TYPE, CLASS IN
            out += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
            out += [0, UInt8(rdata.count)]
            out += rdata
        }
        return Data(out)
    }
}
