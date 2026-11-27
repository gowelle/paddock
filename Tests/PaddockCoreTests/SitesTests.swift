import XCTest
@testable import PaddockCore

final class SitesTests: XCTestCase {
    private var root: URL!
    private let php84 = PHPVersion(major: 8, minor: 4)
    private let php83 = PHPVersion(major: 8, minor: 3)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func mkdir(_ rel: String) throws -> String {
        let url = root.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func registry(_ state: State) -> SiteRegistry {
        SiteRegistry(state: state, defaultPHP: php84)
    }

    func testNormalize() {
        XCTAssertEqual(SiteName.normalize("My App"), "my-app")
        XCTAssertEqual(SiteName.normalize("shop_v2"), "shop-v2")
        XCTAssertEqual(SiteName.normalize("Blog.Old"), "blog-old")
        XCTAssertNil(SiteName.normalize("___"))
    }

    func testParkedFoldersBecomeSites() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/My App")
        try mkdir("Sites/blog")
        let sites = registry(State(parked: [parked])).sites()
        XCTAssertEqual(sites.map(\.name), ["blog", "my-app"])
        XCTAssertEqual(sites[1].kind, .parked)
        XCTAssertEqual(sites[1].host, "my-app.test")
        XCTAssertEqual(sites[1].url, "http://my-app.test")
        XCTAssertEqual(sites[1].php, php84)
        XCTAssertFalse(sites[1].pinned)
    }

    func testLinkOverridesParked() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/blog")
        let target = try mkdir("elsewhere/blog-src")
        let site = registry(State(parked: [parked], links: ["blog": target])).site(named: "blog")
        XCTAssertEqual(site?.kind, .linked)
        XCTAssertEqual(site?.path, target)
    }

    func testEarlierParkedPathWins() throws {
        let a = try mkdir("A")
        let b = try mkdir("B")
        try mkdir("A/blog")
        try mkdir("B/blog")
        let site = registry(State(parked: [a, b])).site(named: "blog")
        XCTAssertEqual(site?.path, a + "/blog")
    }

    func testHiddenAndFilesSkipped() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/.git")
        try mkdir("Sites/real")
        FileManager.default.createFile(atPath: parked + "/file.txt", contents: Data())
        XCTAssertEqual(registry(State(parked: [parked])).sites().map(\.name), ["real"])
    }

    func testMissingParkedPathAndLinkTargetSkipped() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/ok")
        let gone = try mkdir("gone")
        try FileManager.default.removeItem(atPath: gone)
        let state = State(parked: [root.path + "/nope", parked], links: ["dead": gone])
        XCTAssertEqual(registry(state).sites().map(\.name), ["ok"])
    }

    func testSiteContainingDirectory() throws {
        let parked = try mkdir("Sites")
        let app = try mkdir("Sites/app")
        let nested = try mkdir("Sites/app/app/Http")
        let r = registry(State(parked: [parked]))
        XCTAssertEqual(r.site(containing: nested)?.name, "app")
        XCTAssertEqual(r.site(containing: app)?.name, "app")
        XCTAssertNil(r.site(containing: parked))
        XCTAssertNil(r.site(containing: root.path))
    }

    func testSiteContainingResolvesSymlinksAndPrefersDeepest() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/outer/inner")
        let inner = try mkdir("Sites/outer/inner")
        let state = State(parked: [parked], links: ["inner": inner])
        let r = registry(state)
        let link = root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: inner)
        XCTAssertEqual(r.site(containing: link)?.name, "inner")
        XCTAssertEqual(r.site(containing: inner + "/x")?.name, "inner")
        // Sibling with a shared name prefix must not match.
        let prefixed = try mkdir("Sites/outer-two")
        XCTAssertEqual(r.site(containing: prefixed)?.name, "outer-two")
    }

    func testLanMembershipApplied() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/a")
        try mkdir("Sites/b")
        let r = registry(State(parked: [parked], lanEnabled: true, lanSites: ["a"]))
        XCTAssertTrue(r.site(named: "a")!.lan)
        XCTAssertFalse(r.site(named: "b")!.lan)
    }

    func testPinAndSecuredApplied() throws {
        let parked = try mkdir("Sites")
        try mkdir("Sites/a")
        try mkdir("Sites/b")
        let state = State(parked: [parked], secured: ["a"], phpPins: ["a": php83])
        let r = registry(state)
        let a = r.site(named: "a")!
        XCTAssertTrue(a.secured)
        XCTAssertEqual(a.url, "https://a.test")
        XCTAssertEqual(a.php, php83)
        XCTAssertTrue(a.pinned)
        let b = r.site(named: "b")!
        XCTAssertFalse(b.secured)
        XCTAssertEqual(b.php, php84)
        XCTAssertFalse(b.pinned)
    }
}
