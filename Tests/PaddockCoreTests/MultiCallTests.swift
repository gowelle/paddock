import XCTest
@testable import PaddockCore

final class MultiCallTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private let v85 = PHPVersion("8.5")!
    private let resources = URL(fileURLWithPath: "/opt res/Resources", isDirectory: true)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdk multicall-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func installPHP() throws {
        let dir = paths.phpDir(v85)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let file = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    private func plan(_ argv0: String, _ args: [String], env: [String: String] = [:]) -> MultiCall.Plan {
        MultiCall.plan(argv0: argv0, arguments: args, directory: root.path, environment: env,
                       paths: paths, resources: { self.resources })
    }

    func testOtherNamesAreNotMultiCall() {
        XCTAssertEqual(plan("paddock", ["--help"]), .notMultiCall)
        XCTAssertEqual(plan("/x/bin/paddockd", []), .notMultiCall)
    }

    func testPhpWithoutIniPassesArgumentsUntouched() throws {
        try installPHP()
        let binary = paths.phpDir(v85).appendingPathComponent("php").path
        XCTAssertEqual(plan("php", ["--version", "-v"]),
                       .exec(path: binary, arguments: [binary, "--version", "-v"], setEnvironment: [:]))
        // argv[0] may be a full path.
        XCTAssertEqual(plan("/Users/x/Library/Application Support/Paddock/bin/php", ["-r", "echo 1;"]),
                       .exec(path: binary, arguments: [binary, "-r", "echo 1;"], setEnvironment: [:]))
    }

    func testPhpUsesIniOnlyWhenItExists() throws {
        try installPHP()
        let binary = paths.phpDir(v85).appendingPathComponent("php").path
        let ini = paths.phpIni(v85)
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: ini)
        XCTAssertEqual(plan("php", ["-v"]),
                       .exec(path: binary, arguments: [binary, "-c", ini.path, "-v"], setEnvironment: [:]))
    }

    func testComposerRunsPharAndSetsComposerHomeOnlyWhenUnset() throws {
        try installPHP()
        let binary = paths.phpDir(v85).appendingPathComponent("php").path
        let phar = resources.appendingPathComponent("composer.phar").path
        let home = paths.home.appendingPathComponent("composer").path
        XCTAssertEqual(plan("composer", ["--help"]),
                       .exec(path: binary, arguments: [binary, phar, "--help"],
                             setEnvironment: ["COMPOSER_HOME": home]))
        XCTAssertEqual(plan("composer", ["install"], env: ["COMPOSER_HOME": "/mine"]),
                       .exec(path: binary, arguments: [binary, phar, "install"], setEnvironment: [:]))
    }

    func testNoPHPInstalled() {
        XCTAssertEqual(plan("php", ["-v"]), .noPHP)
        XCTAssertEqual(plan("composer", []), .noPHP)
        XCTAssertEqual(MultiCall.noPHPMessage, "No PHP installed. Open Paddock or run: paddock use 8.5")
    }
}
