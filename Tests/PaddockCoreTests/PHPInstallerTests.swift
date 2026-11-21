import CryptoKit
import XCTest
@testable import PaddockCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URL) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try Self.handler!(request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A download that never answers until it is cancelled.
final class StallingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class PHPInstallerTests: XCTestCase {
    private var home: URL!
    private var scratch: URL!
    private var paths: Paths!
    private let v84 = PHPVersion("8.4")!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-phpinst-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Paths(home: home)
        StubURLProtocol.handler = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        StubURLProtocol.handler = nil
    }

    // MARK: fixtures

    private func makeTarGz(binaryNamed name: String) throws -> Data {
        let dir = scratch.appendingPathComponent("fx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \(name)\n".utf8).write(to: dir.appendingPathComponent(name))
        let archive = scratch.appendingPathComponent("\(UUID().uuidString).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.path, name]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return try Data(contentsOf: archive)
    }

    private func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        var manifest: PHPManifest
        var cli: Data
        var fpm: Data
    }

    private func makeFixture(cliSHA: String? = nil) throws -> Fixture {
        let cli = try makeTarGz(binaryNamed: "php")
        let fpm = try makeTarGz(binaryNamed: "php-fpm")
        let build = PHPManifest.Build(
            version: v84, patch: "8.4.1", variant: "default",
            cli: .init(url: URL(string: "https://stub.test/php-cli.tar.gz")!, sha256: cliSHA ?? sha(cli)),
            fpm: .init(url: URL(string: "https://stub.test/php-fpm.tar.gz")!, sha256: sha(fpm)))
        return Fixture(manifest: PHPManifest(builds: [build]), cli: cli, fpm: fpm)
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func serve(_ f: Fixture, failFPM: Bool = false) {
        StubURLProtocol.handler = { url in
            if url.lastPathComponent == "php-cli.tar.gz" { return f.cli }
            if failFPM { throw URLError(.networkConnectionLost) }
            return f.fpm
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoManifest: URL { repoRoot.appendingPathComponent("Resources/php-manifest.json") }

    private func leftoverTempDirs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".php-install") }
    }

    // MARK: tests

    func testVersionParsing() throws {
        XCTAssertEqual(PHPVersion("8.4")?.description, "8.4")
        XCTAssertEqual(PHPVersion("8.4.8")?.description, "8.4")
        XCTAssertEqual(PHPVersion("php@8.4")?.description, "8.4")
        XCTAssertEqual(PHPVersion("84")?.description, "8.4")
        XCTAssertEqual(PHPVersion("8.1"), PHPVersion(major: 8, minor: 1))
        XCTAssertNil(PHPVersion("8.0"))
        XCTAssertNil(PHPVersion("7.4"))
        XCTAssertNil(PHPVersion("80"))
        XCTAssertNil(PHPVersion("abc"))
        XCTAssertNil(PHPVersion(""))
        XCTAssertNil(PHPVersion("8"))
        XCTAssertNil(PHPVersion("8.4.1.2"))
        XCTAssertTrue(PHPVersion("8.3")! < PHPVersion("8.10")!)
        let data = try JSONEncoder().encode([PHPVersion("8.4")!])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"8.4\"]")
        XCTAssertThrowsError(try JSONDecoder().decode([PHPVersion].self, from: Data("[\"7.4\"]".utf8)))
    }

    func testBundledManifestDecodes() throws {
        let m = try PHPManifest.bundled()
        XCTAssertNotNil(m.build(for: PHPVersion(major: 8, minor: 5)))
        XCTAssertNil(m.build(for: PHPVersion(major: 8, minor: 4), variant: "nope"))
    }

    /// The repository's manifest offers only Paddock's own Swoole-free builds, from `paddock-builds://`.
    func testManifestOffersOnlyPaddocksOwnBuilds() throws {
        let m = try JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: repoManifest))
        XCTAssertEqual(m.builds.map(\.version.description).sorted(), ["8.4", "8.5"])
        XCTAssertEqual(m.build(for: PHPVersion("8.4")!)?.patch, "8.4.28")
        XCTAssertEqual(m.build(for: PHPVersion("8.5")!)?.patch, "8.5.13")
        for minor in 1...3 { XCTAssertNil(m.build(for: PHPVersion(major: 8, minor: minor))) }
        for build in m.builds {
            for (asset, kind) in [(build.cli, "cli"), (build.fpm, "fpm")] {
                XCTAssertEqual(asset.url.absoluteString,
                               "paddock-builds://php-\(build.patch)-\(kind)-macos-x86_64.tar.gz")
                XCTAssertEqual(asset.sha256.count, 64)
                XCTAssertNotNil(asset.size)
            }
        }
    }

    /// Scripts/versions.lock and the manifest name the same archives with the same checksums.
    func testManifestAgreesWithTheLock() throws {
        let m = try JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: repoManifest))
        let lock = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/versions.lock"), encoding: .utf8)
        let lines = lock.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        for build in m.builds {
            for (asset, kind) in [(build.cli, "cli"), (build.fpm, "fpm")] {
                let line = lines.first { $0.first == "php-\(build.version)-\(kind)" }
                XCTAssertEqual(line, ["php-\(build.version)-\(kind)", asset.url.absoluteString, asset.sha256])
            }
        }
    }

    func testInstallPlacesBinaries() async throws {
        let f = try makeFixture()
        serve(f)
        let installer = PHPInstaller(paths: paths, manifest: f.manifest, session: stubSession())
        var reported: [Double] = []
        try await installer.install(v84) { reported.append($0) }
        XCTAssertTrue(installer.isInstalled(v84))
        XCTAssertEqual(installer.installed(), [v84])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.phpBinary(v84).path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.fpmBinary(v84).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.phpIni(v84).path))
        XCTAssertEqual(reported.last, 1)
        XCTAssertTrue(leftoverTempDirs().isEmpty)

        try installer.remove(v84)
        XCTAssertFalse(installer.isInstalled(v84))
        XCTAssertNoThrow(try installer.remove(v84))
    }

    func testChecksumMismatchLeavesNothing() async throws {
        let f = try makeFixture(cliSHA: String(repeating: "0", count: 64))
        serve(f)
        let installer = PHPInstaller(paths: paths, manifest: f.manifest, session: stubSession())
        do {
            try await installer.install(v84)
            XCTFail("expected checksum mismatch")
        } catch let error as PHPInstallError {
            XCTAssertEqual(error, .checksumMismatch(v84, file: "php"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.phpDir(v84).path))
        XCTAssertTrue(leftoverTempDirs().isEmpty)
    }

    func testInterruptedDownloadLeavesNothingAndRetryWorks() async throws {
        let f = try makeFixture()
        serve(f, failFPM: true)
        let installer = PHPInstaller(paths: paths, manifest: f.manifest, session: stubSession())
        do {
            try await installer.install(v84)
            XCTFail("expected download failure")
        } catch let error as PHPInstallError {
            guard case .downloadFailed(let v, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(v, v84)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.phpDir(v84).path))
        XCTAssertTrue(installer.installed().isEmpty)
        XCTAssertTrue(leftoverTempDirs().isEmpty)

        serve(f)
        try await installer.install(v84)
        XCTAssertTrue(installer.isInstalled(v84))
    }

    func testNotInManifest() async throws {
        let f = try makeFixture()
        let installer = PHPInstaller(paths: paths, manifest: f.manifest, session: stubSession())
        let v83 = PHPVersion("8.3")!
        do {
            try await installer.install(v83)
            XCTFail("expected notInManifest")
        } catch let error as PHPInstallError {
            XCTAssertEqual(error, .notInManifest(v83))
        }
    }

    func testInstallBundledIsIdempotent() throws {
        let resources = scratch.appendingPathComponent("res", isDirectory: true)
        let src = resources.appendingPathComponent("php/8.5/default", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let file = src.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let installer = PHPInstaller(paths: paths, manifest: PHPManifest(builds: []),
                                     session: stubSession(), bundledResources: resources)
        let v85 = PHPVersion("8.5")!
        XCTAssertEqual(try installer.installBundled(), v85)
        XCTAssertTrue(installer.isInstalled(v85))
        let ini = paths.phpIni(v85)
        XCTAssertEqual(try String(contentsOf: ini), FPMConfig.defaultIni(version: v85, paths: paths))
        try Data("memory_limit=1G\n".utf8).write(to: ini)
        // marker proves the second call does not re-copy
        let marker = paths.phpDir(v85).appendingPathComponent("marker")
        try Data().write(to: marker)

        XCTAssertEqual(try installer.installBundled(), v85)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: ini), "memory_limit=1G\n")
        XCTAssertEqual(installer.installed(), [v85])
        XCTAssertTrue(leftoverTempDirs().isEmpty)
    }

    func testCancelledInstallStopsTheDownloadAndLeavesNothing() async throws {
        let f = try makeFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        let installer = PHPInstaller(paths: paths, manifest: f.manifest, session: URLSession(configuration: config))
        let task = Task { try await installer.install(v84) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let began = Date()
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled install should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertFalse(installer.isInstalled(v84))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.phpDir(v84).path))
        XCTAssertEqual(leftoverTempDirs(), [])
    }

    // MARK: Paddock's own builds, and updating installed builds

    private struct LocalBuilds {
        var manifest: PHPManifest
        var build: PHPManifest.Build
        var environment: [String: String]
    }

    /// Archives named as Paddock's builds are, in a builds directory that `PADDOCK_BUILDS_DIR` points at;
    /// each binary prints `tag`.
    private func makeLocalBuilds(patch: String = "8.4.28", tag: String = "new",
                                 archivesPresent: Bool = true) throws -> LocalBuilds {
        let dir = scratch.appendingPathComponent("builds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var assets: [PHPManifest.Asset] = []
        for (kind, name) in [("cli", "php"), ("fpm", "php-fpm")] {
            let file = "php-\(patch)-\(kind)-macos-x86_64.tar.gz"
            let data = try makeTarGz(binaryNamed: name, saying: tag)
            if archivesPresent { try data.write(to: dir.appendingPathComponent(file)) }
            assets.append(.init(url: URL(string: "paddock-builds://\(file)")!, sha256: sha(data), size: data.count))
        }
        let build = PHPManifest.Build(version: v84, patch: patch, variant: "default", cli: assets[0], fpm: assets[1])
        return LocalBuilds(manifest: PHPManifest(builds: [build]), build: build,
                           environment: ["PADDOCK_BUILDS_DIR": dir.path,
                                         "PADDOCK_RESOURCES": scratch.appendingPathComponent("no-res").path])
    }

    private func makeTarGz(binaryNamed name: String, saying tag: String) throws -> Data {
        let dir = scratch.appendingPathComponent("fx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\necho \(name) \(tag)\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let archive = scratch.appendingPathComponent("\(UUID().uuidString).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.path, name]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return try Data(contentsOf: archive)
    }

    private func noNetworkSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A build installed the way Paddock 0.x installed one: binaries, no build.json.
    private func makeOldStyleInstall(_ v: PHPVersion, tag: String = "old") throws {
        let dir = paths.phpDir(v)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let file = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\necho \(name) \(tag)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let ini = paths.phpIni(v)
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("memory_limit=3G\n".utf8).write(to: ini)
    }

    private func phpText(_ v: PHPVersion) throws -> String {
        try String(contentsOf: paths.phpDir(v).appendingPathComponent("php"), encoding: .utf8)
    }

    private final class Lines: @unchecked Sendable {
        var lines: [String] = []
    }

    func testInstallFromPaddockBuildsUsesNoNetworkAndRecordsTheBuild() async throws {
        NoNetworkURLProtocol.requests = 0
        let local = try makeLocalBuilds()
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        try await installer.install(v84)
        XCTAssertTrue(installer.isInstalled(v84))
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
        XCTAssertEqual(installer.buildRecord(v84),
                       PHPBuildRecord(patch: "8.4.28", cliSHA256: local.build.cli.sha256,
                                      fpmSHA256: local.build.fpm.sha256))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.phpDir(v84).appendingPathComponent("build.json").path))
        XCTAssertTrue(leftoverTempDirs().isEmpty)
    }

    func testInstallWithAMissingLocalBuildFailsWithoutTheNetworkAndLeavesNothing() async throws {
        NoNetworkURLProtocol.requests = 0
        let local = try makeLocalBuilds(archivesPresent: false)
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        do {
            try await installer.install(v84)
            XCTFail("expected a failure")
        } catch let error as PHPInstallError {
            XCTAssertEqual(error, .buildMissing(v84, file: "php-8.4.28-cli-macos-x86_64.tar.gz"))
        }
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.phpDir(v84).path))
        XCTAssertTrue(leftoverTempDirs().isEmpty)
    }

    func testUpdateReplacesAnOldStyleInstallAndKeepsPhpIni() throws {
        try makeOldStyleInstall(v84)
        let local = try makeLocalBuilds()
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        let log = Lines()
        installer.updateOutdatedBuilds { log.lines.append($0) }
        XCTAssertEqual(try phpText(v84), "#!/bin/sh\necho php new\n")
        XCTAssertEqual(installer.buildRecord(v84)?.patch, "8.4.28")
        XCTAssertEqual(installer.buildRecord(v84)?.cliSHA256, local.build.cli.sha256)
        XCTAssertTrue(installer.isInstalled(v84))
        XCTAssertEqual(try String(contentsOf: paths.phpIni(v84), encoding: .utf8), "memory_limit=3G\n")
        XCTAssertEqual(log.lines, ["updated PHP 8.4 to build 8.4.28"])
        XCTAssertTrue(leftoverTempDirs().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.phpDir(v84).deletingLastPathComponent().path),
                       ["default"], "no stray directories beside the build")
    }

    func testUpdateReplacesAnInstallFromAnotherBuild() async throws {
        let old = try makeLocalBuilds(patch: "8.4.27", tag: "older")
        try await PHPInstaller(paths: paths, manifest: old.manifest, session: noNetworkSession(),
                               environment: old.environment).install(v84)
        let current = try makeLocalBuilds()
        let installer = PHPInstaller(paths: paths, manifest: current.manifest, session: noNetworkSession(),
                                     environment: current.environment)
        installer.updateOutdatedBuilds { _ in }
        XCTAssertEqual(try phpText(v84), "#!/bin/sh\necho php new\n")
        XCTAssertEqual(installer.buildRecord(v84)?.patch, "8.4.28")
    }

    func testUpdateLeavesACurrentInstallAlone() async throws {
        let local = try makeLocalBuilds()
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        try await installer.install(v84)
        let marker = paths.phpDir(v84).appendingPathComponent("marker")
        try Data().write(to: marker)
        let log = Lines()
        installer.updateOutdatedBuilds { log.lines.append($0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(log.lines, [])
    }

    func testUpdateWithoutALocalArchiveKeepsTheOldBuildAndLogsOneLine() throws {
        NoNetworkURLProtocol.requests = 0
        try makeOldStyleInstall(v84)
        let local = try makeLocalBuilds(archivesPresent: false)
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        let log = Lines()
        installer.updateOutdatedBuilds { log.lines.append($0) }
        XCTAssertEqual(try phpText(v84), "#!/bin/sh\necho php old\n")
        XCTAssertNil(installer.buildRecord(v84))
        XCTAssertEqual(log.lines.count, 1, "\(log.lines)")
        XCTAssertTrue(log.lines.first?.contains("PHP 8.4") ?? false, "\(log.lines)")
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
        XCTAssertEqual(try String(contentsOf: paths.phpIni(v84), encoding: .utf8), "memory_limit=3G\n")
        XCTAssertTrue(leftoverTempDirs().isEmpty)
    }

    func testUpdateNeverDownloads() throws {
        NoNetworkURLProtocol.requests = 0
        try makeOldStyleInstall(v84)
        let build = PHPManifest.Build(
            version: v84, patch: "8.4.28", variant: "default",
            cli: .init(url: URL(string: "https://stub.test/php-cli.tar.gz")!, sha256: String(repeating: "1", count: 64)),
            fpm: .init(url: URL(string: "https://stub.test/php-fpm.tar.gz")!, sha256: String(repeating: "2", count: 64)))
        let installer = PHPInstaller(paths: paths, manifest: PHPManifest(builds: [build]), session: noNetworkSession(),
                                     environment: [:])
        let log = Lines()
        installer.updateOutdatedBuilds { log.lines.append($0) }
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
        XCTAssertEqual(try phpText(v84), "#!/bin/sh\necho php old\n")
        XCTAssertEqual(log.lines.count, 1, "\(log.lines)")
    }

    func testUpdateIgnoresVersionsTheManifestDoesNotOffer() throws {
        let v83 = PHPVersion("8.3")!
        try makeOldStyleInstall(v83)
        let local = try makeLocalBuilds()
        let installer = PHPInstaller(paths: paths, manifest: local.manifest, session: noNetworkSession(),
                                     environment: local.environment)
        let log = Lines()
        installer.updateOutdatedBuilds { log.lines.append($0) }
        XCTAssertEqual(try phpText(v83), "#!/bin/sh\necho php old\n")
        XCTAssertEqual(log.lines, [])
        XCTAssertFalse(installer.isInstalled(v84), "an update installs nothing new")
    }

    func testInstallBundledCopiesTheBuildRecord() throws {
        let resources = scratch.appendingPathComponent("res", isDirectory: true)
        let src = resources.appendingPathComponent("php/8.5/default", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let file = src.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let record = PHPBuildRecord(patch: "8.5.13", cliSHA256: "aa", fpmSHA256: "bb")
        try JSONEncoder().encode(record).write(to: src.appendingPathComponent("build.json"))
        let installer = PHPInstaller(paths: paths, manifest: PHPManifest(builds: []),
                                     session: stubSession(), bundledResources: resources)
        let v85 = PHPVersion("8.5")!
        XCTAssertEqual(try installer.installBundled(), v85)
        XCTAssertEqual(installer.buildRecord(v85), record)
    }
}
