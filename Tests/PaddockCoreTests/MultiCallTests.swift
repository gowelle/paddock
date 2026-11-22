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

    /// With Xdebug switched on for the version and its library in place, `php` loads it (after the ini, before
    /// the user's own arguments); `composer` never does; and a switch with no library adds nothing.
    func testPhpLoadsXdebugWhenItIsOnAndInstalled() throws {
        try installPHP()
        let binary = paths.phpDir(v85).appendingPathComponent("php").path
        try StateStore(paths: paths).update { $0.xdebug = [self.v85] }
        // Switched on, but no library yet: nothing is added (PHP would warn about a missing file).
        XCTAssertEqual(plan("php", ["-v"]), .exec(path: binary, arguments: [binary, "-v"], setEnvironment: [:]))

        let library = Xdebug.library(v85, paths: paths)
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("so".utf8).write(to: library)
        let loading = ["-d", "zend_extension=\(library.path)", "-d", "xdebug.mode=debug",
                       "-d", "xdebug.start_with_request=trigger"]
        XCTAssertEqual(plan("php", ["artisan", "test"]),
                       .exec(path: binary, arguments: [binary] + loading + ["artisan", "test"], setEnvironment: [:]))
        let composer = resources.appendingPathComponent("composer.phar").path
        XCTAssertEqual(plan("composer", ["install"]),
                       .exec(path: binary, arguments: [binary, composer, "install"], setEnvironment: [:]))

        try StateStore(paths: paths).update { $0.xdebug = [] }
        XCTAssertEqual(plan("php", ["-v"]), .exec(path: binary, arguments: [binary, "-v"], setEnvironment: [:]))
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

    func testComposerRunsPharAndLeavesComposerHomeAlone() throws {
        try installPHP()
        let binary = paths.phpDir(v85).appendingPathComponent("php").path
        let phar = resources.appendingPathComponent("composer.phar").path
        // No COMPOSER_HOME of Paddock's: the owner's ~/.composer (auth.json, global packages) stays in use.
        XCTAssertEqual(plan("composer", ["--help"]),
                       .exec(path: binary, arguments: [binary, phar, "--help"], setEnvironment: [:]))
        XCTAssertEqual(plan("composer", ["install"], env: ["COMPOSER_HOME": "/mine"]),
                       .exec(path: binary, arguments: [binary, phar, "install"], setEnvironment: [:]))
    }

    func testNoPHPInstalled() {
        XCTAssertEqual(plan("php", ["-v"]), .noPHP)
        XCTAssertEqual(plan("composer", []), .noPHP)
        XCTAssertEqual(MultiCall.noPHPMessage, "No PHP installed. Open Paddock or run: paddock use 8.5")
    }
}
