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
}
