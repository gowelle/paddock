import CryptoKit
import XCTest
@testable import PaddockCore

/// Xdebug's library for a PHP version: found through the manifest, installed from a verified archive into
/// Paddock's own extensions folder, and loaded from PHP's command line only when switched on.
final class XdebugTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private let v84 = PHPVersion("8.4")!
    private let v85 = PHPVersion("8.5")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdk xdebug-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A `.tar.gz` holding `files` at its top level, as an artifact with its real checksum.
    private func archive(_ name: String, _ files: [String: String]) throws -> Artifact {
        let folder = root.appendingPathComponent("make-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, contents) in files { try Data(contents.utf8).write(to: folder.appendingPathComponent(file)) }
        let url = root.appendingPathComponent(name)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", url.path, "-C", folder.path] + files.keys.sorted()
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        let data = try Data(contentsOf: url)
        return Artifact(url: url, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
    }

    private func manifest(xdebug84: Artifact?) -> PHPManifest {
        let none = Artifact(url: URL(fileURLWithPath: "/nowhere"), sha256: "00")
        return PHPManifest(builds: [
            .init(version: v84, patch: "8.4.28", variant: "default", cli: none, fpm: none, xdebug: xdebug84),
            .init(version: v85, patch: "8.5.13", variant: "default", cli: none, fpm: none),
        ])
    }

    func testTheManifestSaysWhichVersionsHaveXdebug() throws {
        let xdebug = Xdebug(paths: paths, manifest: manifest(xdebug84: try archive("x.tar.gz", ["xdebug.so": "so"])))
        XCTAssertTrue(xdebug.isAvailable(v84))
        XCTAssertFalse(xdebug.isAvailable(v85))
        XCTAssertFalse(xdebug.isAvailable(PHPVersion("8.3")!), "not in the manifest at all")
        XCTAssertEqual(xdebug.available(among: [v84, v85]), [v84])
    }

    func testAManifestWithoutXdebugStillDecodes() throws {
        let json = """
        {"builds":[{"version":"8.4","patch":"8.4.28","variant":"default",
          "cli":{"url":"paddock-builds://a.tar.gz","sha256":"aa","size":1},
          "fpm":{"url":"paddock-builds://b.tar.gz","sha256":"bb","size":1}},
         {"version":"8.5","patch":"8.5.13","variant":"default",
          "cli":{"url":"paddock-builds://c.tar.gz","sha256":"cc","size":1},
          "fpm":{"url":"paddock-builds://d.tar.gz","sha256":"dd","size":1},
          "xdebug":{"url":"paddock-builds://x.tar.gz","sha256":"ee","size":2}}]}
        """
        let manifest = try JSONDecoder().decode(PHPManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.build(for: v84)?.xdebug)
        XCTAssertEqual(manifest.build(for: v85)?.xdebug?.sha256, "ee")
    }

    func testInstallingPutsTheLibraryInPaddocksOwnFolderOnce() async throws {
        let first = try archive("first.tar.gz", ["xdebug.so": "first build", "LICENSE": "terms"])
        let xdebug = Xdebug(paths: paths, manifest: manifest(xdebug84: first))
        XCTAssertFalse(xdebug.isInstalled(v84))
        try await xdebug.ensureInstalled(v84)
        let library = Xdebug.library(v84, paths: paths)
        XCTAssertEqual(library.path, paths.bin.appendingPathComponent("php-extensions/8.4/xdebug.so").path)
        XCTAssertEqual(try String(contentsOf: library, encoding: .utf8), "first build")
        XCTAssertTrue(xdebug.isInstalled(v84))
        XCTAssertFalse(library.path.hasPrefix(paths.phpDir(v84).path), "outside the PHP build's folder, which an update replaces")
        // Nothing is left behind beside it but the library, its record and its licence.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.deletingLastPathComponent().path).sorted(),
                       ["xdebug-LICENSE", "xdebug.sha256", "xdebug.so"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.bin.appendingPathComponent("php-extensions").path),
                       ["8.4"], "no staging folder left")

        // Already there from this archive: not unpacked again (a hand-changed file shows it was left alone).
        try Data("changed by hand".utf8).write(to: library)
        try await xdebug.ensureInstalled(v84)
        XCTAssertEqual(try String(contentsOf: library, encoding: .utf8), "changed by hand")

        // A newer archive in the manifest replaces it.
        let second = try archive("second.tar.gz", ["xdebug.so": "second build"])
        let newer = Xdebug(paths: paths, manifest: manifest(xdebug84: second))
        XCTAssertFalse(newer.isInstalled(v84))
        try await newer.ensureInstalled(v84)
        XCTAssertEqual(try String(contentsOf: library, encoding: .utf8), "second build")
    }

    func testAnArchiveThatFailsItsChecksumOrLacksTheLibraryInstallsNothing() async throws {
        let good = try archive("good.tar.gz", ["xdebug.so": "so"])
        let wrong = Artifact(url: good.url, sha256: String(repeating: "0", count: 64), size: good.size)
        let library = Xdebug.library(v84, paths: paths)
        do {
            try await Xdebug(paths: paths, manifest: manifest(xdebug84: wrong)).ensureInstalled(v84)
            XCTFail("a wrong checksum must not install")
        } catch let error as XdebugError {
            XCTAssertEqual(error, .installFailed(v84, reason: "its archive failed its checksum"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        let empty = try archive("empty.tar.gz", ["README": "no library here"])
        do {
            try await Xdebug(paths: paths, manifest: manifest(xdebug84: empty)).ensureInstalled(v84)
            XCTFail("an archive without the library must not install")
        } catch let error as XdebugError {
            XCTAssertEqual(error, .installFailed(v84, reason: "its archive did not contain xdebug.so"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        do {
            try await Xdebug(paths: paths, manifest: manifest(xdebug84: good)).ensureInstalled(v85)
            XCTFail("no Xdebug for 8.5 in this manifest")
        } catch let error as XdebugError {
            XCTAssertEqual(error, .notAvailable(v85))
        }
    }

    func testPHPLoadsItOnlyWhenSwitchedOnAndInstalled() throws {
        let library = Xdebug.library(v84, paths: paths)
        var state = State()
        XCTAssertEqual(Xdebug.arguments(for: v84, state: state, paths: paths), [], "off")
        state.xdebug = [v84]
        XCTAssertEqual(Xdebug.arguments(for: v84, state: state, paths: paths), [], "on, but not installed")
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("so".utf8).write(to: library)
        XCTAssertEqual(Xdebug.arguments(for: v84, state: state, paths: paths),
                       ["-d", "zend_extension=\(library.path)", "-d", "xdebug.mode=debug", "-d", "xdebug.start_with_request=trigger"])
        XCTAssertEqual(Xdebug.arguments(for: v85, state: state, paths: paths), [], "another version's switch")
    }

    func testAnOlderDaemonsStatusHasNoXdebug() throws {
        let status = try JSONDecoder().decode(EngineStatus.self, from: Data(#"{"running":true}"#.utf8))
        XCTAssertEqual(status.xdebug, [])
        XCTAssertEqual(status.xdebugAvailable, [])
    }
}
