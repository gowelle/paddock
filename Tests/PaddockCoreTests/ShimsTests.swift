import XCTest
@testable import PaddockCore

final class ShimsTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdk-shims-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home dir", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(_ contents: String) throws -> URL {
        let source = root.appendingPathComponent("paddock-src")
        try Data(contents.utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return source
    }

    private let resources = URL(fileURLWithPath: "/somewhere/Resources", isDirectory: true)

    func testMissingSourceIsANoOp() throws {
        try Shims.install(paths: paths, source: root.appendingPathComponent("nope"), resources: resources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bin.path))
        try Shims.install(paths: paths, source: nil, resources: resources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bin.path))
    }

    func testCopiesBinaryAndMakesRelativeSymlinks() throws {
        try Shims.install(paths: paths, source: try makeSource("one"), resources: resources)
        let bin = paths.bin
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("paddock")), "one")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("paddock").path))
        for name in ["php", "composer"] {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: bin.appendingPathComponent(name).path), "paddock")
        }
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent(".resources")), resources.path)
    }

    func testReplacesOlderCopyAndIsIdempotent() throws {
        try Shims.install(paths: paths, source: try makeSource("one"), resources: resources)
        try Shims.install(paths: paths, source: try makeSource("two"), resources: resources)
        try Shims.install(paths: paths, source: try makeSource("two"), resources: resources)
        let bin = paths.bin
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("paddock")), "two")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: bin.appendingPathComponent("php").path), "paddock")
        // No temporary files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted()
        XCTAssertEqual(names, [".resources", "composer", "paddock", "php"])
    }

    func testReplacesAStrayFileOrWrongSymlink() throws {
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: paths.bin.appendingPathComponent("php"))
        try FileManager.default.createSymbolicLink(
            atPath: paths.bin.appendingPathComponent("composer").path, withDestinationPath: "/usr/bin/true")
        try Shims.install(paths: paths, source: try makeSource("one"), resources: resources)
        for name in ["php", "composer"] {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: paths.bin.appendingPathComponent(name).path), "paddock")
        }
    }
}
