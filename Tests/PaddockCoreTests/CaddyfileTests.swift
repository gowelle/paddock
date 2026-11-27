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

    /// With a listener for dumps, every PHP request carries the two variables VarDumper reads; without one,
    /// neither appears, so `dump()` shows in the page as it always did.
    func testPHPIsToldWhereDumpsGoOnlyWhileSomethingListens() {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        let none = Caddyfile.render(sites: [site("blog", secured: true)], defaultPHP: v84, paths: paths, settings: settings)
        XCTAssertFalse(none.contains("VAR_DUMPER"))
        let listening = Caddyfile.render(sites: [site("blog", secured: true)], defaultPHP: v84, paths: paths,
                                         settings: settings, dumpsTo: 9912)
        XCTAssertTrue(listening.contains("env VAR_DUMPER_FORMAT \"server\""))
        XCTAssertTrue(listening.contains("env VAR_DUMPER_SERVER \"127.0.0.1:9912\""))
        // Once, in the snippet every site's PHP goes through.
        XCTAssertEqual(listening.components(separatedBy: "VAR_DUMPER_SERVER").count, 2)
        let unusable = Caddyfile.render(sites: [], defaultPHP: v84, paths: paths, settings: settings, dumpsTo: 80)
        XCTAssertFalse(unusable.contains("VAR_DUMPER"), "not a port dumps are sent to")
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

    /// Caddy's default CA names collide with other Caddy-based tools' roots in the keychain, so
    /// Paddock names its own.
    func testGlobalBlockNamesPaddocksCertificateAuthority() {
        let out = render([])
        XCTAssertTrue(out.contains("""
                pki {
                    ca local {
                        name "Paddock Local Authority"
                        root_cn "Paddock Local Authority - Root"
                        intermediate_cn "Paddock Local Authority - Intermediate"
                    }
                }
            """), out)
        // Inside the global options block, before the first snippet.
        let pki = try! XCTUnwrap(out.range(of: "pki {"))
        XCTAssertLessThan(pki.lowerBound, try! XCTUnwrap(out.range(of: "(paddock_php)")).lowerBound)
        XCTAssertEqual(Caddyfile.authorityName, "Paddock Local Authority")
    }

    func testTestHookRendersCaddysDefaultAuthority() {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        let out = Caddyfile.render(sites: [], defaultPHP: v84, paths: paths, settings: settings,
                                   namesAuthority: false)
        XCTAssertFalse(out.contains("pki"))
        XCTAssertTrue(out.contains("local_certs"))
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

    // MARK: - LAN

    private func render(_ sites: [Site], lan: Caddyfile.LANSharing?) -> String {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        return Caddyfile.render(sites: sites, defaultPHP: v84, paths: paths, settings: settings, lan: lan)
    }

    /// Shared sites answer on the LAN socket as plain HTTP, whatever their loopback block looks like;
    /// a secured site is not redirected to HTTPS there, and its proxy routes stay off the LAN.
    func testSharedSitesGetPlainHttpLanBlocks() {
        let out = render([site("blog", pinned: true, php: v83), site("shop", secured: true), site("plain")],
                         lan: Caddyfile.LANSharing(sites: ["blog", "shop"], port: 8090))
        XCTAssertTrue(out.contains("""
        http://blog.paddock.local, http://*.blog.paddock.local {
            bind "unix//h/Paddock/run/lan.sock"
            import paddock_php "/h/Paddock/run/php-8.3.sock"
        }
        """), out)
        XCTAssertTrue(out.contains("""
        http://shop.paddock.local, http://*.shop.paddock.local {
            bind "unix//h/Paddock/run/lan.sock"
            import paddock_php "/h/Paddock/run/php-8.4.sock"
        }
        """), out)
        XCTAssertFalse(out.contains("http://plain.paddock.local"), "only chosen sites are shared")
    }

    /// Proxy routes are loopback dev servers; sharing a site on the LAN must not expose them.
    func testLanBlocksNeverIncludeProxyRoutes() {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        let out = Caddyfile.render(sites: [site("blog")], defaultPHP: v84, paths: paths, settings: settings,
                                   proxies: ["blog": ["/app": 9000]],
                                   lan: Caddyfile.LANSharing(sites: ["blog"], port: 8090))
        guard let start = out.range(of: "http://blog.paddock.local") else { return XCTFail(out) }
        let block = out[start.lowerBound...]
        XCTAssertFalse(block.contains("reverse_proxy"), String(block))
    }

    func testLanLandingPageListsSharedSitesAndTheirPort() {
        let out = render([site("blog"), site("shop")], lan: Caddyfile.LANSharing(sites: ["blog", "shop"], port: 8090))
        XCTAssertTrue(out.contains("Sites on this network"))
        XCTAssertTrue(out.contains("http://blog.paddock.local:8090"))
        XCTAssertTrue(out.contains("http://shop.paddock.local:8090"))
        XCTAssertTrue(out.contains("bind \"unix//h/Paddock/run/lan.sock\""))
        XCTAssertFalse(out.contains("{http.request.host}"), "the page never echoes what the request asked for")
    }

    func testLanLandingPageExplainsWhenNothingIsShared() {
        let out = render([site("blog")], lan: Caddyfile.LANSharing(sites: [], port: 8090))
        XCTAssertTrue(out.contains("No sites are shared"))
        XCTAssertFalse(out.contains("http://blog.paddock.local"))
    }

    func testWithoutTheMasterSwitchNothingIsRenderedForTheLan() {
        XCTAssertFalse(render([site("blog")], lan: nil).contains("paddock.local"))
    }

    // MARK: - Proxy routes

    private func render(_ sites: [Site], proxies: [String: [String: Int]]) -> String {
        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        return Caddyfile.render(sites: sites, defaultPHP: v84, paths: paths, settings: settings, proxies: proxies)
    }

    func testASecuredSiteProxiesOverHTTPSBeforeItsPHP() {
        let out = render([site("shop", secured: true, pinned: true, php: v83)],
                         proxies: ["shop": ["/app": 8080, "/app/admin": 9000]])
        XCTAssertTrue(out.contains("""
        https://shop.test, https://*.shop.test {
            bind "unix//h/Paddock/run/https.sock"
            tls internal
            handle "/app/admin/*" {
                reverse_proxy 127.0.0.1:9000
            }
            handle "/app/admin" {
                reverse_proxy 127.0.0.1:9000
            }
            handle "/app/*" {
                reverse_proxy 127.0.0.1:8080
            }
            handle "/app" {
                reverse_proxy 127.0.0.1:8080
            }
            handle {
                import paddock_php "/h/Paddock/run/php-8.3.sock"
            }
            handle_errors 502 {
                @proxy0 path "/app/admin" "/app/admin/*"
                respond @proxy0 "Paddock: nothing is listening on port 9000 for /app/admin (is the task running?)" 502
                @proxy1 path "/app" "/app/*"
                respond @proxy1 "Paddock: nothing is listening on port 8080 for /app (is the task running?)" 502
            }
        }
        """), out)
        XCTAssertTrue(out.contains("http://shop.test, http://*.shop.test {\n    bind \"unix//h/Paddock/run/http.sock\"\n"
            + "    redir https://{host}:18443{uri}\n}"), "a secured site's HTTP still redirects: it proxies over HTTPS only")
    }

    func testAnUnsecuredSiteGetsItsOwnHTTPBlock() {
        let out = render([site("blog")], proxies: ["blog": ["/ws": 6001]])
        XCTAssertTrue(out.contains("""
        http://blog.test, http://*.blog.test {
            bind "unix//h/Paddock/run/http.sock"
            handle "/ws/*" {
                reverse_proxy 127.0.0.1:6001
            }
            handle "/ws" {
                reverse_proxy 127.0.0.1:6001
            }
            handle {
                import paddock_php "/h/Paddock/run/php-8.4.sock"
            }
            handle_errors 502 {
                @proxy0 path "/ws" "/ws/*"
                respond @proxy0 "Paddock: nothing is listening on port 6001 for /ws (is the task running?)" 502
            }
        }
        """), out)
        XCTAssertFalse(out.contains("https://blog.test"))
    }

    /// A site without routes, and every config without any, renders exactly as before.
    func testNoRoutesRendersAsBefore() {
        let sites = [site("plain"), site("blog", pinned: true, php: v83), site("shop", secured: true)]
        XCTAssertEqual(render(sites, proxies: [:]), render(sites))
        XCTAssertEqual(render(sites, proxies: ["shop": [:], "gone": ["/x": 9000]]), render(sites),
                       "empty routes, and routes of a site that isn't served, change nothing")
    }

    /// Routes are validated before they get here; the renderer checks every prefix again (one that doesn't pass
    /// the file's rule is left out, its site rendering as if it had no routes) and quotes those it keeps, and
    /// builds every target from a number: nothing from a file can become a directive.
    func testAHostilePrefixNeverReachesTheConfig() {
        let hostile = ["/a\" {\n respond hacked\n}", "/{path}", "/a b", "/*", "/x\\"]
        for prefix in hostile {
            let out = render([site("shop")], proxies: ["shop": [prefix: 8080]])
            XCTAssertEqual(out, render([site("shop")]), prefix)
            XCTAssertFalse(out.contains("hacked"))
        }
        let mixed = render([site("shop")], proxies: ["shop": ["/ok": 8080, "/a\" {\n respond hacked\n}": 9000]])
        XCTAssertTrue(mixed.contains(#"handle "/ok/*" {"#))
        XCTAssertFalse(mixed.contains("hacked"))
        XCTAssertFalse(mixed.contains("9000"))
    }
}
