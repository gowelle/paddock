import CryptoKit
import Darwin
import XCTest
@testable import PaddockCore

final class ServiceInstallerTests: XCTestCase {
    private var scratch: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdk-svcinst-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(home: scratch.appendingPathComponent("home", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static let quarantine = "com.apple.quarantine"

    private func sha256(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private func setQuarantine(_ file: URL) {
        let value = "0081;00000000;Test;"
        XCTAssertEqual(setxattr(file.path, Self.quarantine, value, value.utf8.count, 0, 0), 0)
    }

    private func hasQuarantine(_ file: URL) -> Bool {
        getxattr(file.path, Self.quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// `pkg/tool` in a tar.gz, the file quarantined before it was archived.
    private func makeArchive() throws -> URL {
        let source = scratch.appendingPathComponent("src/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let tool = source.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho tool\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        setQuarantine(tool)
        let archive = scratch.appendingPathComponent("tool.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, "pkg"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return archive
    }

    private func recipe(_ assets: [RecipeAsset]) -> ServiceRecipe {
        ServiceRecipe(kind: "tool", displayName: "Tool", version: "1.2", licence: "MIT", assets: assets,
                      start: RecipeCommand(executable: "{bin}/tool"), ready: .tcp(port: "{port.main}"),
                      ports: [RecipePort(name: "main", preferred: 4000)])
    }

    func testUnpacksAVerifiedArchiveStrippingComponentsAndQuarantine() async throws {
        let archive = try makeArchive()
        let recipe = recipe([RecipeAsset(artifact: Artifact(url: archive, sha256: try sha256(archive)),
                                         archive: "tar.gz", stripComponents: 1)])
        let installer = ServiceInstaller(paths: paths)
        XCTAssertFalse(installer.isInstalled(recipe))
        let bin = try await installer.install(recipe)
        XCTAssertEqual(bin, paths.serviceBin(kind: "tool", version: "1.2"))
        let tool = bin.appendingPathComponent("tool")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path))
        XCTAssertFalse(hasQuarantine(tool), "Gatekeeper must not stop a verified download")
        XCTAssertTrue(installer.isInstalled(recipe))

        // Installed once: a second install fetches nothing (the source can be gone).
        try FileManager.default.removeItem(at: archive)
        let again = try await installer.install(recipe)
        XCTAssertEqual(again, bin)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
            .filter { $0.hasPrefix(".service-install-") }, [])
    }

    func testInstallsASingleBinaryUnderItsName() async throws {
        let file = scratch.appendingPathComponent("tool-darwin-amd64")
        try Data("binary".utf8).write(to: file)
        setQuarantine(file)
        XCTAssertTrue(hasQuarantine(file))
        let recipe = recipe([RecipeAsset(artifact: Artifact(url: file, sha256: try sha256(file), size: 6),
                                         archive: "binary", installAs: "tool")])
        let bin = try await ServiceInstaller(paths: paths).install(recipe)
        let tool = bin.appendingPathComponent("tool")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool.path))
        XCTAssertFalse(hasQuarantine(tool))
    }

    func testAChecksumMismatchInstallsNothing() async throws {
        let archive = try makeArchive()
        let recipe = recipe([RecipeAsset(artifact: Artifact(url: archive, sha256: String(repeating: "a", count: 64)),
                                         archive: "tar.gz")])
        do {
            try await ServiceInstaller(paths: paths).install(recipe)
            XCTFail("installed a file that failed its checksum")
        } catch {
            XCTAssertEqual(error as? ServiceInstallError, .checksumMismatch(file: "tool.tar.gz"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serviceBin(kind: "tool", version: "1.2").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
            .filter { $0.hasPrefix(".service-install-") }, [])
    }

    func testADifferentInstallIsReplaced() async throws {
        let first = scratch.appendingPathComponent("one")
        try Data("one".utf8).write(to: first)
        let second = scratch.appendingPathComponent("two")
        try Data("two".utf8).write(to: second)
        let installer = ServiceInstaller(paths: paths)
        let bin = try await installer.install(recipe([RecipeAsset(
            artifact: Artifact(url: first, sha256: try sha256(first)), archive: "binary", installAs: "tool")]))
        let newer = recipe([RecipeAsset(artifact: Artifact(url: second, sha256: try sha256(second)),
                                        archive: "binary", installAs: "tool")])
        XCTAssertFalse(installer.isInstalled(newer))
        try await installer.install(newer)
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("tool"), encoding: .utf8), "two")
    }

    func testStaleStagingIsRemoved() throws {
        let stale = paths.home.appendingPathComponent(".service-install-\(UUID().uuidString)", isDirectory: true)
        let other = paths.home.appendingPathComponent(".service-install-notauuid", isDirectory: true)
        for dir in [stale, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        ServiceInstaller(paths: paths).removeStaleStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
