import XCTest
@testable import PaddockCore

final class CaddyfileTests: XCTestCase {
    private let v84 = PHPVersion("8.4")!
    private let v83 = PHPVersion("8.3")!
    private let paths = Paths(home: URL(fileURLWithPath: "/h/Paddock", isDirectory: true))

    private func site(_ name: String, secured: Bool = false, pinned: Bool = false,
                      php: PHPVersion? = nil) -> Site {
        Site(name: name, path: "/s/\(name)", kind: .parked, secured: secured,
             php: php ?? v84, pinned: pinned)
    }

    private func render(_ sites: [Site], paths: Paths? = nil) -> String {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        return Caddyfile.render(sites: sites, defaultPHP: v84, paths: paths ?? self.paths,
                                settings: settings)
    }

    func testGlobalBlock() {
        let out = render([])
        XCTAssertTrue(out.contains("admin \"unix//h/Paddock/run/caddy-admin.sock\""))
        XCTAssertTrue(out.contains("http_port 18080"))
        XCTAssertTrue(out.contains("https_port 18443"))
        // Caddy listens only on Unix sockets; the global ports stay for URLs and redirects.
        XCTAssertFalse(out.contains("default_bind"))
        XCTAssertFalse(out.contains("127.0.0.1"))
        XCTAssertTrue(out.contains("local_certs"))
        XCTAssertTrue(out.contains("skip_install_trust"))
        XCTAssertTrue(out.contains("auto_https disable_redirects"))
        XCTAssertTrue(out.contains("storage file_system \"/h/Paddock/caddy\""))
    }

    func testSnippetCarriesRouterEnvAndStaticPrefix() {
        let out = render([])
        XCTAssertTrue(out.contains("env PADDOCK_ROUTER_HOME \"/h/Paddock/config/valet\""))
        XCTAssertTrue(out.contains("router/server.php\""))
        XCTAssertTrue(out.contains("uri strip_prefix /41c270e4-5535-4daa-b23e-c269744c2f45"))
    }

    func testCatchAllServesEveryOtherHostWithTheDefaultVersion() {
        let out = render([])
        // Every host on the HTTP port, so subdomains (api.myapp.test) reach the router too.
        XCTAssertTrue(out.contains("http:// {\n    bind \"unix//h/Paddock/run/http.sock\"\n"
            + "    import paddock_php \"/h/Paddock/run/php-8.4.sock\"\n}"))
        XCTAssertFalse(out.contains("*.test"))
    }

    func testPinnedSiteGetsOwnBlock() {
        let out = render([site("blog", pinned: true, php: v83)])
        XCTAssertTrue(out.contains(
            "http://blog.test, http://*.blog.test {\n    bind \"unix//h/Paddock/run/http.sock\"\n"
            + "    import paddock_php \"/h/Paddock/run/php-8.3.sock\"\n}"))
    }

    func testSecuredSiteGetsHttpsAndRedirect() {
        let out = render([site("shop", secured: true, pinned: true, php: v83)])
        XCTAssertTrue(out.contains("https://shop.test, https://*.shop.test {\n"
            + "    bind \"unix//h/Paddock/run/https.sock\"\n    tls internal\n"
            + "    import paddock_php \"/h/Paddock/run/php-8.3.sock\"\n}"))
        XCTAssertTrue(out.contains("http://shop.test, http://*.shop.test {\n    bind \"unix//h/Paddock/run/http.sock\"\n"
            + "    redir https://{host}:18443{uri}\n}"))
    }

    func testRedirectOmitsPortOnDefaultHttpsPort() {
        var settings = Settings()
        settings.httpsPort = 443
        let out = Caddyfile.render(sites: [site("shop", secured: true)], defaultPHP: v84, paths: paths,
                                   settings: settings)
        XCTAssertTrue(out.contains("http://shop.test, http://*.shop.test {\n    bind \"unix//h/Paddock/run/http.sock\"\n"
            + "    redir https://{host}{uri}\n}"))
    }

    func testPlainSiteHasNoBlock() {
        let out = render([site("plain")])
        XCTAssertFalse(out.contains("plain.test"))
    }

    func testOutputIndependentOfInputOrder() {
        let a = site("a", pinned: true, php: v83)
        let b = site("b", secured: true)
        let c = site("c", pinned: true)
        XCTAssertEqual(render([a, b, c]), render([c, a, b]))
        XCTAssertEqual(render([a, b, c]), render([b, c, a]))
    }

    func testPathsWithSpacesAndQuotesAreQuoted() {
        let spaced = Paths(home: URL(fileURLWithPath: "/Users/x/Library/Application Support/Paddock",
                                     isDirectory: true))
        let out = render([site("s", secured: true)], paths: spaced)
        XCTAssertTrue(out.contains("admin \"unix//Users/x/Library/Application Support/Paddock/run/caddy-admin.sock\""))
        XCTAssertTrue(out.contains("storage file_system \"/Users/x/Library/Application Support/Paddock/caddy\""))
        XCTAssertTrue(out.contains("env PADDOCK_ROUTER_HOME \"/Users/x/Library/Application Support/Paddock/config/valet\""))
        XCTAssertTrue(out.contains("import paddock_php \"/Users/x/Library/Application Support/Paddock/run/php-8.4.sock\""))
        XCTAssertTrue(out.contains("bind \"unix//Users/x/Library/Application Support/Paddock/run/http.sock\""))
        XCTAssertTrue(out.contains("bind \"unix//Users/x/Library/Application Support/Paddock/run/https.sock\""))
        XCTAssertEqual(Caddyfile.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testEverySiteBlockBindsItsUnixSocket() {
        let out = render([site("plain"), site("blog", pinned: true, php: v83), site("shop", secured: true)])
        // Catch-all, pinned blog, and shop's HTTP redirect on the HTTP socket; shop's HTTPS on the HTTPS socket.
        XCTAssertEqual(out.components(separatedBy: "bind \"unix//h/Paddock/run/http.sock\"").count - 1, 3)
        XCTAssertEqual(out.components(separatedBy: "bind \"unix//h/Paddock/run/https.sock\"").count - 1, 1)
        XCTAssertEqual(out.components(separatedBy: "bind ").count - 1, 4, out)
    }
}
