import Darwin
import XCTest
@testable import PaddockCore

/// The Xdebug switch against a real engine: Paddock's own PHP-FPM and Xdebug build (from Vendor/builds/, by the
/// bundled manifest), a scratch home and free high ports.
final class XdebugEngineTests: XCTestCase {
    private var home: TestHome!
    private var engine: Engine!
    private let v85 = PHPVersion("8.5")!

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        guard let asset = try PHPManifest.bundled().build(for: v85)?.xdebug,
              BuildSource.resolve(asset.url) != nil else {
            throw XCTSkip("Paddock's Xdebug for PHP 8.5 is not in Vendor/builds/; build it with Scripts/build-xdebug.sh")
        }
        home = try TestHome()
        // A page that says whether Xdebug is loaded and how it is set.
        let site = home.parked.appendingPathComponent("debugme", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data(#"""
        <?php
        echo extension_loaded('xdebug')
            ? 'xdebug:' . phpversion('xdebug') . ' mode=' . ini_get('xdebug.mode') . ' start=' . ini_get('xdebug.start_with_request')
            : 'plain';
        """#.utf8).write(to: site.appendingPathComponent("index.php"))
        engine = Engine.development(paths: home.paths, settings: home.settings)
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        home?.cleanUp()
    }

    private func status(_ request: Request, file: StaticString = #filePath, line: UInt = #line) async throws -> EngineStatus {
        let response = await engine.handle(request)
        guard case .ok(let status) = response else {
            XCTFail("expected ok for \(request), got \(response)", file: file, line: line)
            throw XCTSkip("unexpected error response")
        }
        return status
    }

    private func fpm() throws -> Int32 {
        try XCTUnwrap(engine.status().processes["php-fpm-8.5"].flatMap(TestSupport.pid(from:)), "PHP-FPM 8.5 runs")
    }

    /// GET on the scratch site through Paddock's web server; `timeout` bounds the whole request.
    private func get(_ path: String = "/", timeout: Int = 15) throws -> String {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "\(timeout)", "-H", "Host: debugme.test",
                          "http://127.0.0.1:\(home.settings.httpPort)\(path)"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Switching on installs Paddock's Xdebug, restarts that version's PHP-FPM and loads it for step debugging
    /// that starts only when asked; switching off restarts again without it. Asking for what is already so
    /// restarts nothing. The user's php.ini is never changed.
    func testTheSwitchLoadsXdebugIntoTheVersionsSitesAndTakesItOutAgain() async throws {
        try engine.start()
        XCTAssertEqual(try get(), "plain")
        let before = engine.status()
        XCTAssertEqual(before.xdebug, [])
        XCTAssertTrue(before.xdebugAvailable.contains(v85))
        let ini = home.paths.phpIni(v85)
        let iniBefore = try String(contentsOf: ini, encoding: .utf8)
        let plainFPM = try fpm()

        let on = try await status(.xdebug(version: v85, enabled: true))
        XCTAssertEqual(on.xdebug, [v85])
        XCTAssertEqual(engine.store.load().xdebug, [v85])
        XCTAssertTrue(engine.xdebug.isInstalled(v85))
        XCTAssertEqual(try get(), "xdebug:3.5.3 mode=debug start=trigger")
        let debugFPM = try fpm()
        XCTAssertNotEqual(debugFPM, plainFPM, "PHP-FPM was restarted to load it")
        XCTAssertEqual(try String(contentsOf: ini, encoding: .utf8), iniBefore, "php.ini is the user's")

        // Already on: nothing restarts.
        _ = try await status(.xdebug(version: v85, enabled: true))
        XCTAssertEqual(try fpm(), debugFPM)

        // It survives a restart of Paddock's web stack: the choice is saved.
        _ = try await status(.restart)
        XCTAssertEqual(try get(), "xdebug:3.5.3 mode=debug start=trigger")

        let off = try await status(.xdebug(version: v85, enabled: false))
        XCTAssertEqual(off.xdebug, [])
        XCTAssertEqual(try get(), "plain")
        let offFPM = try fpm()
        _ = try await status(.xdebug(version: v85, enabled: false))
        XCTAssertEqual(try fpm(), offFPM, "already off: nothing restarts")
    }

    /// With Xdebug on, a request that asks for a session connects to the debugger where php.ini says it listens
    /// and announces itself; a request that doesn't ask connects to nothing and is served as usual.
    func testASessionStartsOnlyWhenTheRequestAsks() async throws {
        try engine.installer.installBundled()
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort])
        let ini = home.paths.phpIni(v85)
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((FPMConfig.defaultIni(version: v85, paths: home.paths) + "xdebug.client_port = \(port)\n").utf8).write(to: ini)
        try engine.start()
        _ = try await status(.xdebug(version: v85, enabled: true))

        let listener = try TestSupport.listen(port: port)
        defer { close(listener) }
        XCTAssertEqual(fcntl(listener, F_SETFL, O_NONBLOCK), 0)

        // No trigger: served at once, and nothing connects to the debugger.
        XCTAssertEqual(try get(), "xdebug:3.5.3 mode=debug start=trigger")
        XCTAssertEqual(accept(listener, nil, nil), -1, "no session without being asked")

        // With the trigger, Xdebug connects and waits for the debugger; the request goes on once it hangs up.
        let page = Locked<String?>(nil)
        let done = expectation(description: "the triggered request finishes")
        Thread.detachNewThread {
            page.value = try? self.get("/?XDEBUG_TRIGGER=1", timeout: 40)
            done.fulfill()
        }
        var connection: Int32 = -1
        XCTAssertTrue(waitUntil(20) {
            connection = accept(listener, nil, nil)
            return connection >= 0
        }, "Xdebug connected to the debugger's port")
        guard connection >= 0 else { return }
        XCTAssertEqual(fcntl(connection, F_SETFL, 0), 0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = ""
        // The DBGp greeting: a length, a NUL, then an <init> packet naming the engine.
        XCTAssertTrue(waitUntil(10) {
            let count = read(connection, &buffer, buffer.count)
            if count > 0 { received += String(decoding: buffer[..<count], as: UTF8.self) }
            return received.contains("<init") && received.contains("Xdebug")
        }, "the DBGp greeting: \(received)")
        // Every request enters through Paddock's router, so that is the script the session opens on.
        XCTAssertTrue(received.contains("router/server.php"), "it names the entry script: \(received)")
        close(connection)
        await fulfillment(of: [done], timeout: 45)
        XCTAssertEqual(page.value, "xdebug:3.5.3 mode=debug start=trigger", "served once the debugger let go")
    }

    func testAVersionThatIsNotInstalledIsRefused() async throws {
        try engine.installer.installBundled()
        let response = await engine.handle(.xdebug(version: PHPVersion("8.1")!, enabled: true))
        guard case .error(let code, _) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(code, ErrorCode.phpNotInstalled)
        XCTAssertEqual(engine.store.load().xdebug, [])
    }

    /// Switched on while Paddock is stopped: saved, and loaded when it next starts.
    func testSwitchingWhileStoppedTakesEffectAtTheNextStart() async throws {
        try engine.installer.installBundled()
        let on = try await status(.xdebug(version: v85, enabled: true))
        XCTAssertEqual(on.xdebug, [v85])
        XCTAssertFalse(on.running)
        try engine.start()
        XCTAssertEqual(try get(), "xdebug:3.5.3 mode=debug start=trigger")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
