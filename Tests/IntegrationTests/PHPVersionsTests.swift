import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// Two PHP versions side by side, and the `php` / `composer` shims following the current folder.
/// PHP 8.4 is installed from Paddock's own build in Vendor/builds, without the network.
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

    /// The installed app ships its builds in Contents/Resources/builds, so `paddock use 8.4` needs no
    /// network: PADDOCK_BUILDS_DIR stands in for that folder here.
    func testInstalling84FromTheBuildsFolderMakesNoNetworkRequest() throws {
        let manifest = try PHPManifest.bundled()
        let build = try XCTUnwrap(manifest.build(for: v84))
        let builds = try home.makeDirectory("builds")
        for asset in [build.cli, build.fpm] {
            let name = asset.url.host ?? ""
            let source = TestSupport.repoVendor.appendingPathComponent("builds/\(name)")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw XCTSkip("Vendor/builds/\(name) missing; build it with Scripts/build-php.sh 8.4")
            }
            try FileManager.default.copyItem(at: source, to: builds.appendingPathComponent(name))
        }
        OfflineURLProtocol.requests = 0
        // Resources that hold no builds: only PADDOCK_BUILDS_DIR can supply the archives.
        let environment = ["PADDOCK_BUILDS_DIR": builds.path,
                           "PADDOCK_RESOURCES": try home.makeDirectory("empty-resources").path]
        let installer = PHPInstaller(paths: home.paths, manifest: manifest, session: offline(), environment: environment)
        try runInstall(installer)
        XCTAssertEqual(OfflineURLProtocol.requests, 0)
        XCTAssertTrue(installer.isInstalled(v84))
        XCTAssertEqual(installer.buildRecord(v84)?.patch, build.patch)
        let version = Process()
        version.executableURL = installer.phpBinary(v84)
        version.arguments = ["-n", "-r", "echo PHP_VERSION;"]
        let out = Pipe()
        version.standardOutput = out
        try version.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        version.waitUntilExit()
        XCTAssertEqual(text, build.patch)
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

    /// Installs PHP 8.4 into the home the way `paddock use 8.4` does: from the manifest's
    /// `paddock-builds://` archive in Vendor/builds, verified, with no network.
    private func installPHP84() throws {
        let installer = PHPInstaller(paths: home.paths, manifest: try PHPManifest.bundled(), session: offline())
        try runInstall(installer)
        XCTAssertTrue(engine?.installer.isInstalled(v84) ?? true)
    }

    private func runInstall(_ installer: PHPInstaller) throws {
        let done = expectation(description: "install")
        let failure = Locked<Error?>(nil)
        let v84 = self.v84
        Task {
            do { try await installer.install(v84) } catch { failure.value = error }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        if let error = failure.value {
            if case PHPInstallError.buildMissing = error {
                throw XCTSkip("Vendor/builds lacks the PHP 8.4 archives; build them with Scripts/build-php.sh 8.4")
            }
            throw error
        }
    }

    /// A session that fails (and counts) every request.
    private func offline() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: config)
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

/// Fails and counts every request: a test using it proves nothing was downloaded.
final class OfflineURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
