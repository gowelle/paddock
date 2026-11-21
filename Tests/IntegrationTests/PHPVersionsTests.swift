import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Two PHP versions side by side, and the `php` / `composer` shims following the current folder.
/// The 8.4 build is downloaded once from the bundled manifest and cached under Vendor/php/8.4/.
final class PHPVersionsTests: XCTestCase {
    private var home: TestHome!
    private var engine: Engine?
    private let v84 = PHPVersion("8.4")!
    private let v85 = PHPVersion("8.5")!

    override func setUpWithError() throws {
        try TestSupport.requireVendored()
        home = try TestHome()
    }

    override func tearDown() {
        engine?.shutdown()
        engine = nil
        home?.cleanUp()
    }

    // MARK: - Tests

    func testTwoVersionsServeSideBySide() async throws {
        try startEngine()
        try installPHP84()
        let isolated = await engine!.handle(.isolate(site: "plain-php", version: v84))
        guard case .ok = isolated else { return XCTFail("\(isolated)") }

        let plain = try get("plain-php.test", "/")
        XCTAssertTrue(plain.hasPrefix("plain:8.4"), plain)
        // A pinned site's subdomains are served by the pinned version too.
        let sub = try get("api.plain-php.test", "/")
        XCTAssertTrue(sub.hasPrefix("plain:8.4"), sub)
        let laravel = try get("laravel-like.test", "/version.php")
        XCTAssertTrue(laravel.hasPrefix("laravel:8.5"), laravel)
    }

    func testRemovePHPWhilePinnedIsInUse() async throws {
        try startEngine()
        try installPHP84()
        _ = await engine!.handle(.isolate(site: "plain-php", version: v84))
        let response = await engine!.handle(.removePHP(version: v84))
        guard case .error(let code, _) = response else { return XCTFail("\(response)") }
        XCTAssertEqual(code, ErrorCode.phpInUse)
        XCTAssertTrue(engine!.installer.isInstalled(v84))
    }

    func testShimsFollowTheSiteYouAreIn() async throws {
        try startEngine()
        try installPHP84()
        _ = await engine!.handle(.isolate(site: "plain-php", version: v84))
        try installShims()

        let inPlain = try shim("php", ["-r", "echo PHP_VERSION;"], cwd: home.parked.appendingPathComponent("plain-php"))
        XCTAssertEqual(inPlain.status, 0, inPlain.err)
        XCTAssertTrue(inPlain.out.hasPrefix("8.4."), inPlain.out)
        let inLaravel = try shim("php", ["-r", "echo PHP_VERSION;"],
                                 cwd: home.parked.appendingPathComponent("laravel-like/public"))
        XCTAssertTrue(inLaravel.out.hasPrefix("8.5."), inLaravel.out)
        let outside = try shim("php", ["-r", "echo PHP_VERSION;"], cwd: home.root)
        XCTAssertTrue(outside.out.hasPrefix("8.5."), outside.out)
    }

    func testPhpShimPassesFlagsAndExitStatusThrough() throws {
        try startEngine()
        try installShims()
        let version = try shim("php", ["--version"], cwd: home.root)
        XCTAssertEqual(version.status, 0, version.err)
        XCTAssertTrue(version.out.hasPrefix("PHP 8.5."), version.out)
        let short = try shim("php", ["-v"], cwd: home.root)
        XCTAssertTrue(short.out.hasPrefix("PHP 8.5."), short.out)
        let failing = try shim("php", ["-r", "exit(7);"], cwd: home.root)
        XCTAssertEqual(failing.status, 7)
    }

    func testComposerShimRunsComposerWithHomeInsideAPathWithASpace() throws {
        try startEngine()
        try installShims()
        let version = try shim("composer", ["--version"], cwd: home.root)
        XCTAssertEqual(version.status, 0, version.err)
        XCTAssertTrue(version.out.hasPrefix("Composer version "), version.out)
        let help = try shim("composer", ["--help"], cwd: home.root)
        XCTAssertEqual(help.status, 0, help.err)
        XCTAssertTrue(help.out.contains("Usage:"), help.out)
    }

    func testComposerShimHonoursComposerHomeFromTheEnvironment() throws {
        try startEngine()
        try installShims()
        let mine = try home.makeDirectory("my composer home")
        let result = try shim("composer", ["config", "--global", "--list"], cwd: home.root,
                              extraEnv: ["COMPOSER_HOME": mine.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains(mine.path), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.home.appendingPathComponent("composer").path))
    }

    func testShimsWorkFromAHomeWithASpace() throws {
        engine?.shutdown()
        home.cleanUp()
        home = try TestHome(rootName: "pdk \(TestSupport.token())")
        XCTAssertTrue(home.paths.home.path.contains(" "))
        try startEngine()
        try installShims()
        let composer = try shim("composer", ["--version"], cwd: home.root)
        XCTAssertTrue(composer.out.hasPrefix("Composer version "), composer.err + composer.out)
        let config = try shim("composer", ["config", "--global", "--list"], cwd: home.root)
        XCTAssertEqual(config.status, 0, config.err)
        // Composer's own default: the (stand-in) user's ~/.composer, never a folder inside Paddock's home.
        XCTAssertTrue(config.out.contains(userHome.appendingPathComponent(".composer").path),
                      "COMPOSER_HOME isn't the user's own: \(config.out)")
        XCTAssertFalse(config.out.contains(home.paths.home.appendingPathComponent("composer").path), config.out)
    }

    func testEngineInstallShimsCopiesTheSiblingPaddockOfTheRunningDaemon() throws {
        let daemon = products.appendingPathComponent("paddockd")
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else { throw XCTSkip("paddockd not built") }
        let engine = Engine.development(paths: home.paths, settings: home.settings)
        // Under XCTest the running executable is xctest, which has no `paddock` beside it: a no-op.
        try engine.installShims()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.bin.path))
        try engine.installShims(runningExecutable: daemon)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: home.paths.bin.appendingPathComponent("php").path), "paddock")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: home.paths.bin.appendingPathComponent("paddock").path))
    }

    // MARK: - Helpers

    private var products: URL { Bundle(for: PHPVersionsTests.self).bundleURL.deletingLastPathComponent() }

    private func startEngine() throws {
        let engine = Engine.development(paths: home.paths, settings: home.settings)
        self.engine = engine
        try engine.start()
        XCTAssertTrue(engine.status().running, "blocked by \(engine.status().blockedBy)")
    }

    private func installShims() throws {
        let paddock = products.appendingPathComponent("paddock")
        guard FileManager.default.isExecutableFile(atPath: paddock.path) else {
            throw XCTSkip("paddock not built at \(paddock.path)")
        }
        try Shims.install(paths: home.paths, source: paddock, resources: TestSupport.repoVendor)
    }

    /// Puts PHP 8.4 into the home from the cache, downloading it into the cache first if needed.
    private func installPHP84() throws {
        let cache = TestSupport.repoVendor.appendingPathComponent("php/8.4/default", isDirectory: true)
        let fm = FileManager.default
        func cached() -> Bool { ["php", "php-fpm"].allSatisfy { fm.isExecutableFile(atPath: cache.appendingPathComponent($0).path) } }
        if !cached() {
            let scratch = try home.makeDirectory("php84-download")
            let scratchPaths = Paths(home: scratch)
            let manifest = try PHPManifest.bundled()
            let installer = PHPInstaller(paths: scratchPaths, manifest: manifest)
            let done = expectation(description: "download")
            var failure: Error?
            Task {
                do { try await installer.install(v84) } catch { failure = error }
                done.fulfill()
            }
            wait(for: [done], timeout: 300)
            if let failure {
                if case PHPInstallError.checksumMismatch = failure { throw failure }
                throw XCTSkip("Could not download PHP 8.4 (\(failure))")
            }
            try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = cache.deletingLastPathComponent().appendingPathComponent(".default-\(TestSupport.token())")
            try fm.copyItem(at: scratchPaths.phpDir(v84), to: staged)
            if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
            try fm.moveItem(at: staged, to: cache)
        }
        let target = home.paths.phpDir(v84)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: cache, to: target)
        let ini = home.paths.phpIni(v84)
        try fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: ini.path) {
            try Data(FPMConfig.defaultIni(version: v84, paths: home.paths).utf8).write(to: ini)
        }
        XCTAssertTrue(engine?.installer.isInstalled(v84) ?? true)
    }

    private struct ShimResult { let status: Int32; let out: String; let err: String }

    private var userHome: URL { home.root.appendingPathComponent("user home", isDirectory: true) }

    private func shim(_ name: String, _ args: [String], cwd: URL, extraEnv: [String: String] = [:]) throws -> ShimResult {
        let binary = home.paths.bin.appendingPathComponent(name)
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_HOME"] = home.paths.home.path
        env["PADDOCK_RESOURCES"] = TestSupport.repoVendor.path
        env.removeValue(forKey: "COMPOSER_HOME")
        env.removeValue(forKey: "XDG_CONFIG_HOME")
        // A stand-in home, so Composer never reads or creates anything in the real ~/.composer.
        env["HOME"] = userHome.path
        env.merge(extraEnv) { $1 }
        process.environment = env
        process.currentDirectoryURL = cwd
        let outFile = home.root.appendingPathComponent("out-\(TestSupport.token())")
        let errFile = home.root.appendingPathComponent("err-\(TestSupport.token())")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("\(name) \(args) timed out")
        }
        process.waitUntilExit()
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return ShimResult(status: process.terminationStatus, out: read(outFile), err: read(errFile))
    }

    /// Plain HTTP/1.1 GET to 127.0.0.1 with the given Host header, via the system curl.
    private func get(_ host: String, _ path: String) throws -> String {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-q", "-s", "--max-time", "10", "-H", "Host: \(host)",
                          "http://127.0.0.1:\(home.settings.httpPort)\(path)"]
        let out = Pipe()
        curl.standardOutput = out
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
