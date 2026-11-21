import XCTest
@testable import PaddockCore

final class BundledResourcesTests: XCTestCase {
    private var dir: URL!
    private let fallback = URL(fileURLWithPath: "/repo/Vendor", isDirectory: true)

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdk-res-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeRecord(_ path: String) throws {
        try Data((path + "\n").utf8).write(to: dir.appendingPathComponent(".resources"))
    }

    private func resolve(env: [String: String] = [:], bundle: String = "/x/xctest",
                         executableDirectory: URL? = nil) -> String {
        Bundled.resolveResources(environment: env, bundleURL: URL(fileURLWithPath: bundle),
                                 executableDirectory: executableDirectory ?? dir, fallback: fallback).path
    }

    func testEnvironmentOverrideWinsOverEverything() throws {
        try writeRecord("/recorded")
        XCTAssertEqual(resolve(env: ["PADDOCK_RESOURCES": "/override"], bundle: "/Apps/Paddock.app"), "/override")
    }

    func testAppBundleBeatsRecordedFile() throws {
        try writeRecord("/recorded")
        XCTAssertEqual(resolve(bundle: "/Apps/Paddock.app"), "/Apps/Paddock.app/Contents/Resources")
    }

    func testRecordedFileBeatsFallback() throws {
        try writeRecord("/recorded")
        XCTAssertEqual(resolve(), "/recorded")
    }

    func testFallbackWhenNoRecordOrEmptyRecord() throws {
        XCTAssertEqual(resolve(), "/repo/Vendor")
        try writeRecord("   ")
        XCTAssertEqual(resolve(env: ["PADDOCK_RESOURCES": ""]), "/repo/Vendor")
        XCTAssertEqual(resolve(executableDirectory: nil), "/repo/Vendor")
    }

    func testHelperExecutableInsideAnAppFindsTheAppsResources() throws {
        // paddockd and paddock run from Paddock.app/Contents/MacOS as plain executables, whose main
        // bundle may be their own directory rather than the .app.
        let macOS = URL(fileURLWithPath: "/Applications/Paddock.app/Contents/MacOS", isDirectory: true)
        XCTAssertEqual(resolve(bundle: macOS.path, executableDirectory: macOS),
                       "/Applications/Paddock.app/Contents/Resources")
        XCTAssertEqual(resolve(env: ["PADDOCK_RESOURCES": "/override"], bundle: macOS.path, executableDirectory: macOS),
                       "/override")
    }

    func testOnlyAnAppsContentsMacOSCountsAsAnApp() throws {
        XCTAssertNil(Bundled.enclosingApp(ofExecutableIn: URL(fileURLWithPath: "/x/Paddock/Contents/MacOS")))
        XCTAssertNil(Bundled.enclosingApp(ofExecutableIn: URL(fileURLWithPath: "/x/Paddock.app/Contents/bin")))
        XCTAssertNil(Bundled.enclosingApp(ofExecutableIn: URL(fileURLWithPath: "/x/Paddock.app/MacOS")))
        XCTAssertEqual(Bundled.enclosingApp(ofExecutableIn: URL(fileURLWithPath: "/x/P.app/Contents/MacOS/"))?.path,
                       "/x/P.app")
        // The copy in bin/ still uses its recorded path.
        try writeRecord("/recorded")
        XCTAssertEqual(resolve(), "/recorded")
    }
}
