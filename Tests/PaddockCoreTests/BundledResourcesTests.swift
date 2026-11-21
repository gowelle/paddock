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
}
