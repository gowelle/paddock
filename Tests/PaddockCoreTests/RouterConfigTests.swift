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

    func testConfigHasTldLoopbackAndSitesThenParkedPaths() throws {
        let state = State(parked: ["/a/b", "/c d"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let json = try config()
        XCTAssertEqual(json["tld"] as? String, "test")
        XCTAssertEqual(json["loopback"] as? String, "127.0.0.1")
        // Sites first: links (and normalized-name links) win over parked folders.
        XCTAssertEqual(json["paths"] as? [String], [sitesDir, "/a/b", "/c d"])
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

    private func makeParked(_ folders: [String], in name: String = "parked") throws -> String {
        let dir = home.appendingPathComponent(name, isDirectory: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        return dir.path
    }

    func testParkedFolderWithNonNormalizedNameGetsNormalizedSymlink() throws {
        let parked = try makeParked(["My App", "blog", ".hidden dir"])
        try Data().write(to: URL(fileURLWithPath: parked + "/Some File"))
        try RouterConfig.write(state: State(parked: [parked]), paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"), parked + "/My App")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: sitesDir).sorted(), ["my-app"],
                       "only folders whose name differs from the site name get a link")
    }

    func testLinkWinsOverParkedFolderWithSameNormalizedName() throws {
        let parked = try makeParked(["My App"])
        let state = State(parked: [parked], links: ["my-app": "/tmp/linked"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"),
                       "/tmp/linked")
    }

    func testEarlierParkedPathWinsAndExactlyNamedFolderNeedsNoLink() throws {
        let first = try makeParked(["Shop", "news"], in: "first")
        let second = try makeParked(["shop", "News"], in: "second")
        try RouterConfig.write(state: State(parked: [first, second]), paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/shop"), first + "/Shop")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: sitesDir + "/news"),
                     "the earlier exactly named folder is found by the router without a link")
    }

    func testRemovedFolderLinkIsDeletedButRealDirectoryKept() throws {
        let parked = try makeParked(["My App"])
        try RouterConfig.write(state: State(parked: [parked]), paths: paths, settings: Settings())
        try FileManager.default.removeItem(atPath: parked + "/My App")
        try FileManager.default.createDirectory(atPath: sitesDir + "/real", withIntermediateDirectories: true)
        try RouterConfig.write(state: State(parked: [parked]), paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"))
        XCTAssertTrue(fm.fileExists(atPath: sitesDir + "/real"))
    }
}
