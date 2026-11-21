import XCTest
@testable import PaddockCore

final class CaddyValidateTests: XCTestCase {
    func testPlainHomeValidates() throws {
        try validate(homeName: "pdk-cv-\(token())")
    }

    func testHomeWithSpaceValidates() throws {
        try validate(homeName: "pdk cv \(token())")
    }

    private func token() -> String { String(UUID().uuidString.prefix(8)) }

    private func validate(homeName: String) throws {
        let caddy = Bundled.resources.appendingPathComponent("caddy")
        guard FileManager.default.isExecutableFile(atPath: caddy.path) else {
            throw XCTSkip("Vendored caddy missing; run Scripts/fetch-vendor.sh")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(homeName, isDirectory: true)
        let paths = Paths(home: home)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: home) }

        var settings = Settings()
        settings.httpPort = 18080
        settings.httpsPort = 18443
        let v84 = PHPVersion("8.4")!, v83 = PHPVersion("8.3")!
        let sites = [
            Site(name: "pinned", path: "/s/pinned", kind: .parked, secured: false, php: v83, pinned: true),
            Site(name: "secure", path: "/s/secure", kind: .parked, secured: true, php: v84, pinned: false),
        ]
        let text = Caddyfile.render(sites: sites, defaultPHP: v84, paths: paths, settings: settings)
        try Data(text.utf8).write(to: paths.caddyfile)

        let process = Process()
        process.executableURL = caddy
        process.arguments = ["validate", "--config", paths.caddyfile.path, "--adapter", "caddyfile"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "caddy validate failed:\n\(String(decoding: data, as: UTF8.self))\n\(text)")
    }
}
