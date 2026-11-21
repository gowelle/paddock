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
        for minor in 1...5 {
            let v = PHPVersion(major: 8, minor: minor)
            XCTAssertNotNil(m.build(for: v), "missing 8.\(minor)")
        }
        XCTAssertNil(m.build(for: PHPVersion(major: 8, minor: 4), variant: "nope"))
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
}
