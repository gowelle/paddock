import Foundation
import XCTest
@testable import PaddockCore

/// The vendored router names the same site for site.test and site.paddock.local.
final class LANRouterTests: XCTestCase {
    func testLanNamesMapToTheSameSiteNames() throws {
        try TestSupport.requireVendored()
        XCTAssertEqual(try name("blog.test"), "blog")
        XCTAssertEqual(try name("blog.paddock.local"), "blog")
        XCTAssertEqual(try name("blog.paddock.local:8080"), "blog")
        XCTAssertEqual(try name("www.blog.paddock.local"), "blog")
        XCTAssertEqual(try name("api.blog.paddock.local"), "api.blog")
        XCTAssertEqual(try name("api.blog.test"), "api.blog")
    }

    private func name(_ host: String) throws -> String {
        let php = Bundled.resources.appendingPathComponent("php/8.5/default/php")
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored php missing; run Scripts/fetch-vendor.sh")
        }
        let router = Bundled.resources.appendingPathComponent("router")
        let script = """
        require $argv[1]."/cli/Valet/Server.php";
        $server = new Valet\\Server(["tld" => "test", "lan_domain" => "paddock.local"]);
        echo $server->siteNameFromHttpHost($argv[2]);
        """
        let p = Process()
        p.executableURL = php
        p.arguments = ["-r", script, router.path, host]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        return text
    }
}
