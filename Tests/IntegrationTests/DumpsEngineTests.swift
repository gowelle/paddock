import Darwin
import XCTest
@testable import PaddockCore

/// Dumps from a site to a listener, through a real engine: Paddock's web server and PHP-FPM in a scratch home on
/// free high ports. The site sends what Symfony VarDumper's dump server client sends (a real payload from
/// `Tests/Fixtures/var-dumper`), to wherever its `$_SERVER` says, exactly as VarDumper decides it.
final class DumpsEngineTests: XCTestCase {
    private var home: TestHome!
    private var engine: Engine!

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TestHome()
        let site = home.parked.appendingPathComponent("dumper", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data(#"""
        <?php
        // What VarDumper does with these two: format "server" sends to the address; anything else shows in the page.
        $format = $_SERVER['VAR_DUMPER_FORMAT'] ?? 'none';
        $server = $_SERVER['VAR_DUMPER_SERVER'] ?? 'none';
        if ($format === 'server' && ($socket = @stream_socket_client('tcp://' . $server, $errno, $error, 3))) {
            fwrite($socket, trim(file_get_contents(__DIR__ . '/payload.txt')) . "\n");
            fclose($socket);
            echo "sent:$server";
        } else {
            echo "page:$format";
        }
        """#.utf8).write(to: site.appendingPathComponent("index.php"))
        struct Case: Decodable { let name: String; let payload: String }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/var-dumper/v8.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixtures))
        let payload = try XCTUnwrap(cases.first { $0.name == "object with visibilities" }).payload
        try Data(payload.utf8).write(to: site.appendingPathComponent("payload.txt"))
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

    private func get() throws -> String {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "15", "-H", "Host: dumper.test", "http://127.0.0.1:\(home.settings.httpPort)/"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testASitesDumpReachesTheListenerOnlyWhileTheDaemonIsToldThereIsOne() async throws {
        try engine.start()
        XCTAssertEqual(try get(), "page:none", "nothing listening: dumps show in the page")
        XCTAssertNil(engine.status().dumpsTo)

        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort])
        let received = Locked<[Data]>([])
        let listener = DumpListener(port: port) { line in received.value = received.value + [line] }
        try listener.start()
        defer { listener.stop() }

        let on = try await status(.dumps(port: port))
        XCTAssertEqual(on.dumpsTo, port)
        XCTAssertEqual(engine.store.load().dumpsTo, port)
        XCTAssertEqual(try get(), "sent:127.0.0.1:\(port)")
        XCTAssertTrue(waitUntil(10) { received.value.count == 1 }, "the dump arrived")

        // What arrived reads as the object that was dumped.
        let dump = try DumpDecoder.decode(line: try XCTUnwrap(received.value.first), id: 1)
        XCTAssertEqual(dump.source, "OrderController.php:42")
        XCTAssertEqual(dump.root.children.map(\.head),
                       ["+id: 1042", "+note: null", "#lines: array:2 [", "-total: 59.0", "+parent: null"])

        // Told again what is already so: nothing changes. Then nowhere: the page again.
        _ = try await status(.dumps(port: port))
        let off = try await status(.dumps(port: nil))
        XCTAssertNil(off.dumpsTo)
        XCTAssertEqual(try get(), "page:none")
        XCTAssertEqual(received.value.count, 1)

        // The listener gone while PHP is still told to send (the app quit): VarDumper's own fallback is the page.
        _ = try await status(.dumps(port: port))
        listener.stop()
        XCTAssertEqual(try get(), "page:server", "nothing answers, so it is shown where it always was")
    }

    func testAPortThatIsNotOneForDumpsIsRefused() async throws {
        for port in [0, 80, 70_000] {
            let response = await engine.handle(.dumps(port: port))
            guard case .error(let code, _) = response else { return XCTFail("\(port): \(response)") }
            XCTAssertEqual(code, ErrorCode.invalidArgument)
        }
        XCTAssertNil(engine.store.load().dumpsTo)
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
