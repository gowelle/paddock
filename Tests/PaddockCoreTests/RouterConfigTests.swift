import XCTest
@testable import PaddockCore

final class RouterConfigTests: XCTestCase {
    private var home: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdk-rc-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: home)
        try paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func config() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.routerHome.appendingPathComponent("config.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var sitesDir: String { paths.routerHome.appendingPathComponent("Sites").path }

    func testConfigHasTldLoopbackAndParkedPathsPlusSites() throws {
        let state = State(parked: ["/a/b", "/c d"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let json = try config()
        XCTAssertEqual(json["tld"] as? String, "test")
        XCTAssertEqual(json["loopback"] as? String, "127.0.0.1")
        XCTAssertEqual(json["paths"] as? [String], ["/a/b", "/c d", sitesDir])
    }

    func testLinksBecomeSymlinks() throws {
        let state = State(links: ["blog": "/tmp/some/blog", "My App": "/tmp/x"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/blog"), "/tmp/some/blog")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"), "/tmp/x")
    }

    func testRemovedLinkSymlinkIsDeletedAndChangedTargetUpdated() throws {
        var state = State(links: ["a": "/tmp/a", "b": "/tmp/b"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        state.links = ["a": "/tmp/a2"]
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/a"), "/tmp/a2")
        XCTAssertFalse(fm.fileExists(atPath: sitesDir + "/b"))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: sitesDir + "/b"))
    }
}
