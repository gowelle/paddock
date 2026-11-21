import XCTest
@testable import PaddockCore

/// Finding `paddock-ports` the way the daemon does. Never runs it.
final class PortHelperLocatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func placeholder(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.resolvingSymlinksInPath()
    }

    func testTheHelperBesideTheExecutableComesFirst() throws {
        let beside = try placeholder("build/paddock-ports")
        try placeholder("Paddock.app/Contents/MacOS/paddock-ports")
        let found = PortHelperLocator.binary(
            executableDirectories: [dir.appendingPathComponent("build")],
            resources: dir.appendingPathComponent("Paddock.app/Contents/Resources"))
        XCTAssertEqual(found?.path, beside.path)
    }

    func testTheAppsMacOSFolderIsNext() throws {
        let inApp = try placeholder("Paddock.app/Contents/MacOS/paddock-ports")
        let found = PortHelperLocator.binary(
            executableDirectories: [dir.appendingPathComponent("home/bin")],
            resources: dir.appendingPathComponent("Paddock.app/Contents/Resources"))
        XCTAssertEqual(found?.path, inApp.path)
    }

    func testAResourcesFolderHoldingTheHelperIsLast() throws {
        let vendored = try placeholder("Vendor/paddock-ports")
        let found = PortHelperLocator.binary(executableDirectories: [],
                                             resources: dir.appendingPathComponent("Vendor"))
        XCTAssertEqual(found?.path, vendored.path)
    }

    func testNoHelperAnywhereIsNil() {
        XCTAssertNil(PortHelperLocator.binary(executableDirectories: [dir],
                                              resources: dir.appendingPathComponent("Vendor")))
    }
}
