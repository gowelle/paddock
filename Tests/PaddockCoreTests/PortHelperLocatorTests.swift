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

    // MARK: - Only an app's helper may be installed as root

    func testTheAppsOwnHelperIsTheOnlyOneToInstall() throws {
        let helper = try placeholder("Paddock.app/Contents/MacOS/paddock-ports")
        let macOS = dir.appendingPathComponent("Paddock.app/Contents/MacOS")
        XCTAssertEqual(PortHelperLocator.bundledBinary(executableDirectories: [macOS])?.path, helper.path)
    }

    func testTheCopyInBinUsesTheHelperOfTheAppItsRecordNames() throws {
        let helper = try placeholder("Paddock.app/Contents/MacOS/paddock-ports")
        let bin = dir.appendingPathComponent("home/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data(dir.appendingPathComponent("Paddock.app/Contents/Resources").path.utf8)
            .write(to: bin.appendingPathComponent(".resources"))
        XCTAssertEqual(PortHelperLocator.bundledBinary(executableDirectories: [bin])?.path, helper.path)
    }

    func testARepositoryBuildHasNoHelperToInstallEvenWithOneBesideIt() throws {
        try placeholder("build/debug/paddock-ports")
        let build = dir.appendingPathComponent("build/debug")
        XCTAssertNil(PortHelperLocator.bundledBinary(executableDirectories: [build]))
        XCTAssertNotNil(PortHelperLocator.binary(executableDirectories: [build], resources: dir),
                        "a development home still runs it")
        // A record naming a Resources folder that isn't inside an app doesn't count.
        try placeholder("Vendor/MacOS/paddock-ports")
        try Data(dir.appendingPathComponent("Vendor/Resources").path.utf8)
            .write(to: build.appendingPathComponent(".resources"))
        XCTAssertNil(PortHelperLocator.bundledBinary(executableDirectories: [build]))
    }

    func testAnAppWithoutAHelperHasNone() throws {
        try placeholder("Paddock.app/Contents/MacOS/paddockd")
        XCTAssertNil(PortHelperLocator.bundledBinary(executableDirectories: [dir.appendingPathComponent("Paddock.app/Contents/MacOS")]))
    }
}
