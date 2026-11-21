import Darwin
import Foundation
import XCTest
@testable import PaddockCore

/// Proxy routes end to end: a site's approved `proxy` paths go to a local port through the site's own address
/// (HTTPS when secured, HTTP otherwise), websockets included; nothing unapproved is ever forwarded. Scratch home,
/// free high ports, an echo server bound to 127.0.0.1.
final class SiteProxyTests: XCTestCase {
    private var home: TaskHome!
    private var engine: Engine?
    private var echo: EchoServer?

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TaskHome()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        echo?.stop()
        if let home { for pid in home.leftoverProcesses() where home.owns(pid) { kill(pid, SIGKILL) } }
        home?.cleanUp()
    }

    // MARK: - Helpers

    private func makeEngine() async throws -> Engine {
        let engine = Engine(paths: home.paths, settings: home.settings, installAction: nil, backoffScale: 0.02,
                            managesPortHelper: true, portHelper: TestSupport.portHelper,
                            portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [])),
                            taskEnvironment: { [home] in home!.environment }, log: { _ in })
        self.engine = engine
        try engine.start()
        XCTAssertTrue(engine.status().running, "blocked by \(engine.status().blockedBy)")
        await engine.startTasks()
        return engine
    }

    private func approve(_ engine: Engine, _ site: String) async throws {
        guard case .ok(let status) = await engine.handle(.tasksStatus(site: site)),
              let hash = status.sites.first(where: { $0.name == site })?.tasks?.pendingHash else {
            return XCTFail("nothing to approve")
        }
        guard case .ok = await engine.handle(.tasksApprove(site: site, hash: hash)) else { return XCTFail("approve") }
    }

    private func secure(_ engine: Engine, _ site: String) async throws {
        guard case .ok = await engine.handle(.secure(site: site)) else { return XCTFail("secure \(site)") }
    }

    private var root: URL { home.paths.caddyData.appendingPathComponent("pki/authorities/local/root.crt") }

    private struct Fetched { let status: Int; let body: String }

    /// curl through the site's own address (resolved to 127.0.0.1), HTTPS verified against the scratch CA only.
    /// A handshake that fails while Caddy loads a new certificate (status 0) is retried for 10 seconds.
    private func fetch(_ host: String, _ path: String, https: Bool = true) throws -> Fetched {
        let port = https ? home.settings.httpsPort : home.settings.httpPort
        let deadline = Date().addingTimeInterval(10)
        while true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-q", "-s", "--http1.1", "--max-time", "10", "-w", "\n%{http_code}",
                                 "--resolve", "\(host):\(port):127.0.0.1"]
                + (https ? ["--cacert", root.path] : [])
                + ["\(https ? "https" : "http")://\(host):\(port)\(path)"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let newline = text.lastIndex(of: "\n") ?? text.startIndex
            let status = Int(text[text.index(after: newline)...]) ?? 0
            let result = Fetched(status: status, body: String(text[..<newline]))
            if status != 0 || Date() >= deadline { return result }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func waitForRoot() {
        XCTAssertTrue(waitFor(15) { FileManager.default.fileExists(atPath: self.root.path) }, "Caddy's root certificate")
    }

    // MARK: - Tests

    func testApprovedRoutesForwardHTTPAndWebsocketsAndNothingElse() async throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort])
        echo = try EchoServer(port: port)
        try home.makeSite("shop", tasks: #"{"proxy": {"/app": \#(port)}}"#)
        try home.makeSite("blog", tasks: nil)
        let engine = try await makeEngine()
        try await secure(engine, "shop")
        try await secure(engine, "blog")
        waitForRoot()

        let unapproved = try fetch("shop.test", "/app/x")
        XCTAssertFalse(unapproved.body.contains("echo"), "an unapproved route forwards nothing: \(unapproved.body)")

        try await approve(engine, "shop")
        let forwarded = try fetch("shop.test", "/app/hello?x=1")
        XCTAssertEqual(forwarded.status, 200)
        XCTAssertTrue(forwarded.body.hasPrefix("echo /app/hello?x=1 host=shop.test:\(home.settings.httpsPort)"),
                      "the path and query arrive intact: \(forwarded.body)")
        XCTAssertTrue(try fetch("shop.test", "/app").body.hasPrefix("echo /app "), "the prefix itself")
        XCTAssertFalse(try fetch("shop.test", "/apple").body.contains("echo"), "only on a segment boundary")
        XCTAssertFalse(try fetch("shop.test", "/").body.contains("echo"), "the rest of the site is PHP")
        XCTAssertFalse(try fetch("blog.test", "/app/x").body.contains("echo"), "another site is unaffected")

        let socket = try WebSocketProbe.roundTrip(host: "shop.test", port: home.settings.httpsPort, path: "/app/ws",
                                                  root: root, message: "hello through Paddock")
        XCTAssertTrue(socket.status.contains(" 101 "), socket.status)
        XCTAssertEqual(socket.echo, "hello through Paddock")

        let status = engine.status()
        XCTAssertEqual(status.sites.first { $0.name == "shop" }?.tasks?.routes, ["/app": port])
        XCTAssertTrue(Messages.siteTasksLines(status.sites).contains("shop: forward https://shop.test/app → 127.0.0.1:\(port)"))

        // A changed file keeps the approved route.
        try home.writeTasks("shop", #"{"proxy": {"/app": \#(port + 1), "/other": \#(port)}}"#)
        engine.tasks.refresh()
        XCTAssertEqual(engine.status().sites.first { $0.name == "shop" }?.tasks?.approval, .changed)
        XCTAssertTrue(try fetch("shop.test", "/app/still").body.hasPrefix("echo /app/still"))
        XCTAssertFalse(try fetch("shop.test", "/other").body.contains("echo"), "nothing unapproved")

        // Nothing listening: a short plain answer.
        echo?.stop()
        echo = nil
        let down = try fetch("shop.test", "/app/x")
        XCTAssertEqual(down.status, 502)
        XCTAssertEqual(down.body, "Paddock: nothing is listening on port \(port) for /app (is the task running?)")

        // Withdrawn: gone.
        guard case .ok = await engine.handle(.tasksRevoke(site: "shop")) else { return XCTFail("revoke") }
        let revoked = try fetch("shop.test", "/app/x")
        XCTAssertNotEqual(revoked.status, 502, revoked.body)
        XCTAssertFalse(revoked.body.contains("nothing is listening"))
    }

    func testAnUnsecuredSiteProxiesOverHTTP() async throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort])
        echo = try EchoServer(port: port)
        try home.makeSite("plain", tasks: #"{"proxy": {"/ws": \#(port)}}"#)
        let engine = try await makeEngine()
        try await approve(engine, "plain")
        let forwarded = try fetch("plain.test", "/ws/x?y=2", https: false)
        XCTAssertEqual(forwarded.status, 200)
        XCTAssertTrue(forwarded.body.hasPrefix("echo /ws/x?y=2"), forwarded.body)
        XCTAssertFalse(try fetch("plain.test", "/", https: false).body.contains("echo"))
    }

    /// A route to one of Paddock's own ports is left out and said so; the site's other routes, and other sites,
    /// work.
    func testARouteToPaddocksOwnPortIsLeftOut() async throws {
        let port = TestSupport.freeTCPPort(excluding: [home.settings.httpPort, home.settings.httpsPort])
        echo = try EchoServer(port: port)
        try home.makeSite("shop", tasks: #"{"proxy": {"/app": \#(port), "/own": \#(home.settings.httpsPort)}}"#)
        try home.makeSite("plain", tasks: nil)
        let engine = try await makeEngine()
        try await approve(engine, "shop")
        XCTAssertTrue(try fetch("shop.test", "/app/x", https: false).body.hasPrefix("echo /app/x"))
        XCTAssertFalse(try fetch("shop.test", "/own", https: false).body.contains("echo"))
        let tasks = try XCTUnwrap(engine.status().sites.first { $0.name == "shop" }?.tasks)
        XCTAssertEqual(tasks.routes, ["/app": port])
        XCTAssertTrue(tasks.notice?.contains(Messages.routeOnPaddocksPort(prefix: "/own", port: home.settings.httpsPort)) ?? false,
                      tasks.notice ?? "no notice")
        XCTAssertTrue([200, 404].contains(try fetch("plain.test", "/", https: false).status),
                      "another site is still served by its router")
    }
}
