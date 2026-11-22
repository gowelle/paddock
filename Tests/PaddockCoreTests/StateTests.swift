import XCTest
@testable import PaddockCore

final class StateTests: XCTestCase {
    private func makePaths() throws -> Paths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Paths(home: dir)
    }

    func testMissingFileGivesInitial() throws {
        let state = StateStore(paths: try makePaths()).load()
        XCTAssertEqual(state.parked.count, 1)
        XCTAssertTrue(state.parked[0].hasSuffix("/Paddock"))
        XCTAssertEqual(state, State.initial)
    }

    func testXdebugChoicesAreKeptAndAnOlderFileHasNone() throws {
        let paths = try makePaths()
        try StateStore(paths: paths).update { $0.xdebug = [PHPVersion("8.4")!] }
        XCTAssertEqual(StateStore(paths: paths).load().xdebug, [PHPVersion("8.4")!])

        // A file from before the switch existed, and one whose list holds something unreadable.
        let older = #"{"parked":[],"links":{},"secured":[],"phpPins":{}}"#
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: Data(older.utf8)).xdebug, [])
        let odd = #"{"parked":["/p"],"links":{},"secured":[],"phpPins":{},"xdebug":["8.5",7,"nonsense"]}"#
        let decoded = try JSONDecoder().decode(State.self, from: Data(odd.utf8))
        XCTAssertEqual(decoded.xdebug, [PHPVersion("8.5")!])
        XCTAssertEqual(decoded.parked, ["/p"], "the rest of the file is kept")
    }

    func testWhereDumpsGoIsKeptAndAnUnusablePortIsDropped() throws {
        let paths = try makePaths()
        try StateStore(paths: paths).update { $0.dumpsTo = 9912 }
        XCTAssertEqual(StateStore(paths: paths).load().dumpsTo, 9912)
        let older = #"{"parked":[],"links":{},"secured":[],"phpPins":{}}"#
        XCTAssertNil(try JSONDecoder().decode(State.self, from: Data(older.utf8)).dumpsTo)
        for bad in [#""dumpsTo":80"#, #""dumpsTo":"9912""#, #""dumpsTo":99999"#] {
            let json = #"{"parked":["/p"],"links":{},"secured":[],"phpPins":{},"# + bad + "}"
            let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))
            XCTAssertNil(state.dumpsTo, bad)
            XCTAssertEqual(state.parked, ["/p"], "the rest of the file is kept")
        }
    }

    func testRoundTrip() throws {
        let paths = try makePaths()
        let written = try StateStore(paths: paths).update {
            $0.links["blog"] = "/tmp/blog"
            $0.secured.insert("blog")
            $0.phpPins["blog"] = PHPVersion("8.3")!
            $0.defaultPHP = PHPVersion("8.4")!
        }
        let loaded = StateStore(paths: paths).load()
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.links["blog"], "/tmp/blog")
        XCTAssertEqual(loaded.phpPins["blog"], PHPVersion("8.3")!)
    }

    func testCorruptFileIsMovedAside() throws {
        let paths = try makePaths()
        try Data("{not json".utf8).write(to: paths.stateFile)
        let state = StateStore(paths: paths).load()
        XCTAssertEqual(state, State.initial)
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
        let corrupt = files.filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(corrupt.count, 1)
        XCTAssertFalse(files.contains("state.json"))
        let moved = try String(contentsOf: paths.home.appendingPathComponent(corrupt[0]), encoding: .utf8)
        XCTAssertEqual(moved, "{not json")
    }

    func testEmptyFileGivesInitial() throws {
        let paths = try makePaths()
        try Data().write(to: paths.stateFile)
        XCTAssertEqual(StateStore(paths: paths).load(), State.initial)
    }

    func testUnreadableFileReadsAsInitialButIsNeverOverwritten() throws {
        let paths = try makePaths()
        let saved = try StateStore(paths: paths).update {
            $0.links["blog"] = "/tmp/blog"
            $0.previousResolver = "nameserver 10.0.0.1\n"
        }
        let original = try Data(contentsOf: paths.stateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.stateFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.stateFile.path) }
        guard (try? Data(contentsOf: paths.stateFile)) == nil else { throw XCTSkip("running as root: file still readable") }

        let store = StateStore(paths: paths)
        XCTAssertEqual(store.load(), State.initial)
        XCTAssertThrowsError(try store.update { $0.parked = ["/somewhere"] })

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.stateFile.path)
        XCTAssertEqual(try Data(contentsOf: paths.stateFile), original)
        XCTAssertEqual(store.load(), saved)
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("state.json.corrupt-") }, "an unreadable file isn't corrupt")
    }

    func testMissingFileCanBeCreatedByUpdate() throws {
        let paths = try makePaths()
        let state = try StateStore(paths: paths).update { $0.parked = ["/x"] }
        XCTAssertEqual(StateStore(paths: paths).load(), state)
    }
}
