import Foundation
import XCTest
import PaddockTestSupport
@testable import PaddockCore

/// The LAN listener serves chosen PHP sites as plain HTTP, and answers everything else with a landing page.
final class LANEngineTests: XCTestCase {
    private var home: TestHome!
    private var engine: Engine?

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TestHome()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        home?.cleanUp()
    }

    func testSharedSitesAnswerAsPlainHttpAndOthersGetTheLandingPage() throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                       home.settings.dnsPort])
        try StateStore(paths: home.paths).update { state in
            state.lanEnabled = true
            state.lanSites = ["plain-php"]
            state.secured = ["plain-php"]
            state.lanPort = port
        }
        let engine = Engine.development(paths: home.paths, settings: home.settings,
                                        lanPortChooser: { _ in port })
        self.engine = engine
        try engine.start()
        XCTAssertTrue(engine.status().running, "blocked by \(String(describing: engine.status().blockedBy))")

        let shared = try get("plain-php.paddock.local:\(port)", "/", port: port)
        XCTAssertEqual(shared.status, 200, shared.body)
        XCTAssertTrue(shared.body.hasPrefix("plain:8.5"), "plain HTTP, not a redirect to HTTPS: \(shared.body)")

        let unshared = try get("laravel-like.paddock.local:\(port)", "/", port: port)
        XCTAssertEqual(unshared.status, 200)
        XCTAssertFalse(unshared.body.contains("laravel:"), "only chosen sites are shared")

        let byAddress = try get("127.0.0.1:\(port)", "/", port: port)
        XCTAssertTrue(byAddress.body.contains("Sites on this network"), byAddress.body)
        XCTAssertTrue(byAddress.body.contains("http://plain-php.paddock.local:\(port)"), byAddress.body)
        XCTAssertFalse(byAddress.body.contains("laravel-like"), byAddress.body)
    }

    func testSharedNamesAreAnnouncedAndWithdrawnAsSharingChanges() throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                       home.settings.dnsPort])
        try StateStore(paths: home.paths).update { state in
            state.lanEnabled = true
            state.lanSites = ["plain-php"]
            state.lanPort = port
        }
        let advertiser = RecordingLANAdvertiser()
        let engine = Engine.development(paths: home.paths, settings: home.settings,
                                        lanPortChooser: { _ in port },
                                        lanAdvertiser: { advertiser })
        self.engine = engine
        try engine.start()

        XCTAssertEqual(engine.status().lan?.address, "192.168.1.50")
        XCTAssertTrue(waitFor {
            advertiser.last == .init(hosts: ["plain-php.paddock.local"], address: "192.168.1.50")
        }, "announced \(String(describing: advertiser.last))")

        try StateStore(paths: home.paths).update { $0.lanSites = [] }
        try engine.reload()
        XCTAssertTrue(waitFor { advertiser.last?.hosts == [] },
                      "stopped sharing withdraws the names: \(String(describing: advertiser.last))")

        engine.shutdown()
        XCTAssertTrue(advertiser.stopped)
    }

    func testALoadKeepsTheRunningLanPort() throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                       home.settings.dnsPort])
        let other = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                        home.settings.dnsPort, port])
        try StateStore(paths: home.paths).update { state in
            state.lanEnabled = true
            state.lanSites = ["plain-php"]
            state.lanPort = port
        }
        let chooser = RecordingLANPortChooser(first: port, later: other)
        let engine = Engine.development(paths: home.paths, settings: home.settings,
                                        lanPortChooser: { chooser.choose(saved: $0) })
        self.engine = engine
        try engine.start()
        XCTAssertEqual(engine.status().lan?.port, port)

        try engine.reload()
        XCTAssertTrue(engine.status().lan?.running == true)
        XCTAssertEqual(engine.status().lan?.port, port, "a reload must not move a running listener")
        XCTAssertEqual(chooser.calls, 1)
    }

    func testKillingTheLanListenerWithdrawsNamesAndStartRecovers() throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort,
                                                       home.settings.dnsPort])
        try StateStore(paths: home.paths).update { state in
            state.lanEnabled = true
            state.lanSites = ["plain-php"]
            state.lanPort = port
        }
        let advertiser = RecordingLANAdvertiser()
        let engine = Engine.development(paths: home.paths, settings: home.settings,
                                        lanPortChooser: { _ in port },
                                        lanAdvertiser: { advertiser })
        self.engine = engine
        try engine.start()
        XCTAssertTrue(waitFor { advertiser.last?.hosts == ["plain-php.paddock.local"] })

        let reported = try XCTUnwrap(engine.status().processes["lan"])
        let pid = try XCTUnwrap(Int32(reported.filter(\.isNumber)))
        XCTAssertEqual(kill(pid, SIGKILL), 0)

        XCTAssertTrue(waitFor { advertiser.stopped },
                      "a listener that died must stop announcing names at a dead port")
        XCTAssertTrue(waitFor { engine.status().lan?.running == false })
        XCTAssertTrue(engine.status().running, "the rest of Paddock keeps serving")

        try engine.start()
        XCTAssertTrue(engine.status().lan?.running == true)
        XCTAssertEqual(engine.status().lan?.port, port)
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private struct Response { let status: Int; let body: String }

    /// Returns `first` the first time, then `later`: shows whether a reload asks again.
    private final class RecordingLANPortChooser: @unchecked Sendable {
        private let lock = NSLock()
        private let first: Int
        private let later: Int
        private var count = 0

        init(first: Int, later: Int) {
            self.first = first
            self.later = later
        }

        func choose(saved: Int?) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count == 1 ? first : later
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
    private func get(_ host: String, _ path: String, port: Int) throws -> Response {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "10", "-H", "Host: \(host)",
                          "-w", "\n%{http_code}", "http://127.0.0.1:\(port)\(path)"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        var text = String(decoding: data, as: UTF8.self)
        let newline = try XCTUnwrap(text.lastIndex(of: "\n"), "curl output: \(text)")
        let status = Int(text[text.index(after: newline)...]) ?? -1
        text = String(text[..<newline])
        return Response(status: status, body: text)
    }
}
