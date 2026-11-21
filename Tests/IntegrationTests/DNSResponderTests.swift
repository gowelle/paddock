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
        for candidate in [53599] + (0..<20).map({ _ in Int.random(in: 20000...40000) }) {
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
        var first: DNSResponder?
        for _ in 0..<20 {
            let r = DNSResponder(port: Int.random(in: 20000...40000), tld: "test")
            if (try? r.start()) != nil { first = r; break }
        }
        let a = try XCTUnwrap(first, "no free port")
        defer { a.stop() }
        XCTAssertThrowsError(try DNSResponder(port: a.port, tld: "test").start())
    }

    func testRapidStopStartCyclesStillAnswer() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dig") else {
            throw XCTSkip("dig not available")
        }
        var port = 0
        var current: DNSResponder?
        for _ in 0..<20 {
            let p = Int.random(in: 20000...40000)
            let r = DNSResponder(port: p, tld: "test")
            if (try? r.start()) != nil { port = p; current = r; break }
        }
        var responder = try XCTUnwrap(current, "no free port")
        for _ in 0..<10 {
            responder.stop()
            responder = DNSResponder(port: port, tld: "test")
            try responder.start()
        }
        defer { responder.stop() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        p.arguments = ["+short", "+time=2", "+tries=1", "-p", "\(port)", "@127.0.0.1", "x.test", "A"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "127.0.0.1")
    }
}
