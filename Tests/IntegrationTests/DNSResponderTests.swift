import XCTest
@testable import PaddockCore

final class DNSResponderTests: XCTestCase {
    func testDigResolvesTestDomainToLoopback() throws {
        let dig = "/usr/bin/dig"
        guard FileManager.default.isExecutableFile(atPath: dig) else {
            throw XCTSkip("dig not available")
        }
        var responder: DNSResponder?
        var port = 53599
        for candidate in [53599] + (0..<20).map({ _ in Int.random(in: 40000...60000) }) {
            let r = DNSResponder(port: candidate, tld: "test")
            if (try? r.start()) != nil { responder = r; port = candidate; break }
        }
        let started = try XCTUnwrap(responder, "no free port")
        defer { started.stop() }

        for (type, expected) in [("A", "127.0.0.1"), ("AAAA", "::1")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dig)
            p.arguments = ["+short", "+time=2", "+tries=1", "-p", "\(port)", "@127.0.0.1", "anything.test", type]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func testStartThrowsWhenPortBusy() throws {
        let a = DNSResponder(port: Int.random(in: 40000...60000), tld: "test")
        try a.start()
        defer { a.stop() }
        // Reuse a's port via a second responder
        let b = DNSResponder(port: a.port, tld: "test")
        XCTAssertThrowsError(try b.start())
    }
}
