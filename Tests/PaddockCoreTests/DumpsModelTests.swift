import Darwin
import XCTest
@testable import PaddockCore

/// A stand-in listener: starts or fails as told, and lets the test send lines as PHP would.
private final class FakeListener: DumpListening, @unchecked Sendable {
    var failure: Error?
    private(set) var started = false
    private(set) var stopped = false
    let receive: @Sendable (Data) -> Void

    init(receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }

    func start() throws {
        if let failure { throw failure }
        started = true
    }

    func stop() { stopped = true }
}

@MainActor
final class DumpsModelTests: XCTestCase {
    private var listeners: [FakeListener] = []
    private var routed: [Int?] = []
    private var copied: [String] = []
    private var startFailure: Error?

    private func makeModel(port: Int = 9912) -> DumpsModel {
        DumpsModel(port: port, listener: { [unowned self] _, receive in
            let listener = FakeListener(receive: receive)
            listener.failure = self.startFailure
            self.listeners.append(listener)
            return listener
        }, route: { [unowned self] port in self.routed.append(port) }, copy: { [unowned self] in self.copied.append($0) })
    }

    private func payload(_ name: String) throws -> Data {
        struct Case: Decodable { let name: String; let payload: String }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/var-dumper/v8.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        return Data(try XCTUnwrap(cases.first { $0.name == name }).payload.utf8)
    }

    private func dump(_ name: String) throws -> Result<Dump, Error> {
        .success(try DumpDecoder.decode(line: try payload(name), id: 0))
    }

    func testOpeningListensAndHasPHPSendDumpsHereClosingUndoesBoth() async throws {
        let model = makeModel()
        XCTAssertEqual(model.emptyText, "Not listening.")
        await model.open()
        XCTAssertTrue(model.isListening)
        XCTAssertEqual(listeners.count, 1)
        XCTAssertTrue(listeners[0].started)
        XCTAssertEqual(routed, [9912])
        XCTAssertEqual(model.statusLine, "Listening on port 9912")
        XCTAssertEqual(model.emptyText, "Listening. Call dump() or dd() in a site and it shows here instead of in the page.")
        await model.open()
        XCTAssertEqual(listeners.count, 1, "already open: not started twice")

        await model.close()
        XCTAssertFalse(model.isListening)
        XCTAssertTrue(listeners[0].stopped)
        XCTAssertEqual(routed, [9912, nil])
    }

    func testAPortInUseSaysSoAndPHPIsNotToldToSendAnything() async {
        startFailure = DumpListenerError.portInUse(9912)
        let model = makeModel()
        await model.open()
        XCTAssertFalse(model.isListening)
        XCTAssertEqual(routed, [], "dumps keep showing in the page")
        XCTAssertEqual(model.problem, "Paddock can't listen for dumps: port 9912 is in use. Quit the other dump server "
                       + "(php artisan dump-server), then open this window again.")
        XCTAssertEqual(model.statusLine, "Not listening")
        // Closing a window that never listened changes nothing at the daemon; opening again tries again.
        await model.close()
        XCTAssertEqual(routed, [])
        startFailure = nil
        await model.open()
        XCTAssertTrue(model.isListening)
        XCTAssertNil(model.problem)
    }

    func testALineSentToTheListenerShowsAsADumpNewestFirst() async throws {
        let model = makeModel()
        await model.open()
        // As PHP sends it: through the listener, decoded off the main thread, shown on it.
        listeners[0].receive(try payload("assoc"))
        let arrived = expectation(description: "the dump shows")
        Task { @MainActor in
            while model.dumps.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            arrived.fulfill()
        }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(model.dumps.first?.source, "OrderController.php:42")
        XCTAssertNil(model.emptyText)

        model.received(try dump("from the command line"))
        XCTAssertEqual(model.dumps.map(\.origin), ["artisan queue:work --tries=3", "GET https://shop.test/orders/1042?tab=items"])
        XCTAssertEqual(Set(model.dumps.map(\.id)).count, 2, "each has its own id")

        model.copy(model.dumps[0])
        XCTAssertEqual(copied, ["array:1 [\n  \"queued\" => 3\n]\n"])

        model.clear()
        XCTAssertEqual(model.dumps, [])
    }

    func testWhatIsNotADumpIsNotedAndNothingArrivesAfterClosing() async throws {
        let model = makeModel()
        await model.open()
        model.received(.failure(DumpError.notADump))
        XCTAssertEqual(model.dumps, [])
        XCTAssertEqual(model.notice, "Something that isn't a dump was sent to port 9912.")
        model.received(.failure(DumpError.tooLarge))
        XCTAssertEqual(model.notice, "A dump was too large to show here.")
        await model.close()
        model.received(try dump("assoc"))
        XCTAssertEqual(model.dumps, [], "a line still on its way when the window closed is dropped")
    }

    func testOnlySoManyDumpsAreKept() async throws {
        let model = makeModel()
        await model.open()
        let one = try dump("int")
        for _ in 0..<(DumpsModel.limit + 5) { model.received(one) }
        XCTAssertEqual(model.dumps.count, DumpsModel.limit)
        XCTAssertEqual(model.dumps.first?.id, DumpsModel.limit + 5, "the newest is first")
    }

    func testLinesStartUnfoldedNearTheTopAndCanBeFoldedByHand() async throws {
        let model = makeModel()
        await model.open()
        model.received(try dump("nested object"))
        let dump = try XCTUnwrap(model.dumps.first)
        let root = dump.root
        XCTAssertTrue(model.isUnfolded(root, in: dump, depth: 0))
        let inner = try XCTUnwrap(root.children.first { $0.isFoldable })
        XCTAssertTrue(model.isUnfolded(inner, in: dump, depth: 1))
        XCTAssertFalse(model.isUnfolded(inner, in: dump, depth: DumpsModel.unfoldedDepth), "deeper lines start folded")
        model.toggle(root, in: dump, depth: 0)
        XCTAssertFalse(model.isUnfolded(root, in: dump, depth: 0))
        model.toggle(root, in: dump, depth: 0)
        XCTAssertTrue(model.isUnfolded(root, in: dump, depth: 0))
        let leaf = try XCTUnwrap(root.children.first { !$0.isFoldable })
        model.toggle(leaf, in: dump, depth: 1)
        XCTAssertEqual(model.folds.count, 1, "a line with nothing in it has nothing to fold")
    }

    /// The app quit with the window open, or the daemon restarted while it was: the two are brought back in step.
    func testTheDaemonsSettingIsBroughtBackInStep() async {
        let model = makeModel()
        await model.reconcile(daemonSendsTo: nil)
        XCTAssertEqual(routed, [], "nothing to fix")
        await model.reconcile(daemonSendsTo: 9912)
        XCTAssertEqual(routed, [nil], "PHP was sending dumps to nobody")
        await model.open()
        routed = []
        await model.reconcile(daemonSendsTo: 9912)
        XCTAssertEqual(routed, [], "in step")
        await model.reconcile(daemonSendsTo: nil)
        XCTAssertEqual(routed, [9912], "the daemon forgot; told again")
    }
}

final class DumpListenerTests: XCTestCase {
    private func freePort() -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Connects to 127.0.0.1:port and writes `text`, as VarDumper's client does.
    private func send(_ text: String, to port: Int) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0, "connected to the listener")
        let bytes = Array(text.utf8)
        XCTAssertEqual(Darwin.write(fd, bytes, bytes.count), bytes.count)
    }

    func testLinesSentOverTCPArriveOneByOneAndStoppingClosesThePort() throws {
        let port = freePort()
        let lines = LockedLines()
        let listener = DumpListener(port: port) { lines.append($0) }
        try listener.start()
        defer { listener.stop() }

        // Two dumps on one connection, the second split across writes; then another connection.
        try send("first\nsec", to: port)
        try send("third\n\n", to: port)
        let deadline = Date().addingTimeInterval(5)
        while lines.all.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(Set(lines.all), ["first", "third"], "whole lines only: the unfinished one is not a dump")

        // A second listener on the same port is refused, and says which port.
        XCTAssertThrowsError(try DumpListener(port: port) { _ in }.start()) {
            XCTAssertEqual($0 as? DumpListenerError, .portInUse(port))
        }

        listener.stop()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let refused = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(refused, -1, "nothing listens after stop, so PHP falls back to the page")
    }

    func testOnlyPortsAUserProgramMayUseAreListenedOn() {
        XCTAssertThrowsError(try DumpListener(port: 80) { _ in }.start())
        XCTAssertEqual(DumpDestination.environment(port: nil), [:])
        XCTAssertEqual(DumpDestination.environment(port: 80), [:])
        XCTAssertEqual(DumpDestination.environment(port: 9912),
                       ["VAR_DUMPER_FORMAT": "server", "VAR_DUMPER_SERVER": "127.0.0.1:9912"])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ data: Data) {
        lock.lock()
        stored.append(String(decoding: data, as: UTF8.self))
        lock.unlock()
    }
}
