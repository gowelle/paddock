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

    /// A real directory for a link to point at (the registry serves only links to directories, and the
    /// router follows the same rule).
    private func target(_ name: String) throws -> String {
        let dir = home.appendingPathComponent("targets/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    func testLinksBecomeSymlinks() throws {
        let (blog, x) = (try target("some/blog"), try target("x"))
        let state = State(links: ["blog": blog, "My App": x, "gone": "/no/such/dir"])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/blog"), blog)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"), x)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: sitesDir + "/gone"), "not served, as in SiteRegistry")
    }

    func testRemovedLinkSymlinkIsDeletedAndChangedTargetUpdated() throws {
        var state = State(links: ["a": try target("a"), "b": try target("b")])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let a2 = try target("a2")
        state.links = ["a": a2]
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: sitesDir + "/a"), a2)
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
        let linked = try target("linked")
        let state = State(parked: [parked], links: ["my-app": linked])
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sitesDir + "/my-app"), linked)
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

    // MARK: - Same-name ties (one rule for the registry and the router)

    /// The folder (or link target) the registry serves as `name`, and the one the router would find.
    private func winners(_ state: State, name: String) throws -> (registry: String?, router: String?) {
        try RouterConfig.write(state: state, paths: paths, settings: Settings())
        let registry = SiteRegistry(state: state, defaultPHP: PHPVersion(major: 8, minor: 5)).site(named: name)?.path
        let fm = FileManager.default
        let link = sitesDir + "/" + name
        let router = (try? fm.destinationOfSymbolicLink(atPath: link))
            ?? state.parked.map { $0 + "/" + name }.first { fm.fileExists(atPath: $0) }
        return (registry.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                router.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private func folders(_ names: [String]) throws -> String {
        let parked = home.appendingPathComponent("parked-\(UUID().uuidString.prefix(6))").path
        for name in names {
            try FileManager.default.createDirectory(atPath: parked + "/" + name, withIntermediateDirectories: true)
        }
        return parked
    }

    func testWithoutAnExactlyNamedFolderTheFirstInCaseInsensitiveOrderWinsInBoth() throws {
        // Case-sensitively "B_x" sorts first; case-insensitively "b.x" does ("." < "_").
        let parked = try folders(["B_x", "b.x"])
        let result = try winners(State(parked: [parked]), name: "b-x")
        XCTAssertEqual(result.registry, parked + "/b.x")
        XCTAssertEqual(result.router, result.registry)
    }

    func testAnExactlyNamedFolderWinsInBoth() throws {
        let parked = try folders(["A App", "a-app", "a_app"])
        let result = try winners(State(parked: [parked]), name: "a-app")
        XCTAssertEqual(result.registry, parked + "/a-app")
        XCTAssertEqual(result.router, result.registry)
    }

    func testLinksWithTheSameNormalizedNameAgree() throws {
        for links in [["Blog!": "/tmp/one", "BLOG": "/tmp/two"], ["BLOG": "/tmp/two", "Blog!": "/tmp/one"],
                      ["Blog!": "/tmp/one", "blog": "/tmp/exact"]] {
            let targets = try Set(links.values.map { target -> String in
                try FileManager.default.createDirectory(atPath: home.path + target, withIntermediateDirectories: true)
                return target
            })
            XCTAssertEqual(targets.count, 2)
            let state = State(links: links.mapValues { home.path + $0 })
            let result = try winners(state, name: "blog")
            let expected = links["blog"] ?? "/tmp/two" // exact first, else "blog" < "blog!" case-insensitively
            XCTAssertEqual(result.registry, home.path + expected, "\(links)")
            XCTAssertEqual(result.router, result.registry, "\(links)")
        }
    }
}
