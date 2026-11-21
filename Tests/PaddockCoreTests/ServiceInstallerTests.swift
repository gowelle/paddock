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

    /// A hostile archive: a `../` entry, an absolute path and a symlink pointing outside followed by a file
    /// through it. Nothing may land outside the staging folder, whatever tar decides.
    func testAnArchiveCannotWriteOutsideItsFolder() async throws {
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let archive = scratch.appendingPathComponent("evil.tar")
        try Self.tar([
            .file("../escaped", "dotdot"),
            .file("/tmp/pdk-absolute-\(UUID().uuidString)", "absolute"),
            .symlink("link", outside.path),
            .file("link/through", "via symlink"),
            .file("ok", "fine"),
        ]).write(to: archive)
        let recipe = recipe([RecipeAsset(artifact: Artifact(url: archive, sha256: try sha256(archive)), archive: "tar.gz")])
        _ = try? await ServiceInstaller(paths: paths).install(recipe)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [], "nothing through the symlink")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home.deletingLastPathComponent()
            .appendingPathComponent("escaped").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escaped").path))
        let absolute = try FileManager.default.contentsOfDirectory(atPath: "/tmp").filter { $0.hasPrefix("pdk-absolute-") }
        XCTAssertEqual(absolute, [], "an absolute path is never written as such")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.home.path)
            .filter { $0.hasPrefix(".service-install-") }, [])
    }

    /// A recipe whose downloads are on this Mac installs without the network, and the installed folder
    /// keeps the recipe it was made from, so the service runs even after the catalog drops that version.
    func testLocalInstallAndTheStoredRecipe() throws {
        let file = scratch.appendingPathComponent("tool-bin")
        try Data("binary".utf8).write(to: file)
        let local = recipe([RecipeAsset(artifact: Artifact(url: file, sha256: try sha256(file)), archive: "binary",
                                        installAs: "tool")])
        let remote = recipe([RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/t")!, sha256: "00"),
                                         archive: "binary", installAs: "tool")])
        let installer = ServiceInstaller(paths: paths)
        XCTAssertTrue(installer.isLocallyAvailable(local))
        XCTAssertFalse(installer.isLocallyAvailable(remote))
        XCTAssertNil(installer.installedRecipe(kind: "tool", version: "1.2"))
        try installer.installLocally(local)
        XCTAssertEqual(installer.installedRecipe(kind: "tool", version: "1.2"), local)
        XCTAssertThrowsError(try installer.installLocally(remote))
        installer.remove(kind: "tool", version: "1.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serviceBin(kind: "tool", version: "1.2").path))
    }

    // MARK: - A tar writer for hostile archives

    enum Entry {
        case file(String, String)
        case symlink(String, String)
    }

    /// A gzip-compressed ustar archive with exactly these entries (names as given, unchecked).
    static func tar(_ entries: [Entry]) throws -> Data {
        var tar = Data()
        for entry in entries {
            let (name, type, link, body): (String, UInt8, String, Data)
            switch entry {
            case .file(let n, let text): (name, type, link, body) = (n, UInt8(ascii: "0"), "", Data(text.utf8))
            case .symlink(let n, let target): (name, type, link, body) = (n, UInt8(ascii: "2"), target, Data())
            }
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, _ offset: Int, _ length: Int) {
                for (i, byte) in text.utf8.prefix(length).enumerated() { header[offset + i] = byte }
            }
            put(name, 0, 100)
            put("0000644", 100, 7)
            put("0000000", 108, 7)
            put("0000000", 116, 7)
            put(String(format: "%011o", body.count), 124, 11)
            put(String(format: "%011o", 0), 136, 11)
            header[156] = type
            put(link, 157, 100)
            put("ustar", 257, 5)
            put("00", 263, 2)
            for i in 148..<156 { header[i] = UInt8(ascii: " ") }
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), 148, 6)
            header[154] = 0
            tar.append(contentsOf: header)
            tar.append(body)
            tar.append(Data(count: (512 - body.count % 512) % 512))
        }
        tar.append(Data(count: 1024))
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-tar-\(UUID().uuidString)")
        try tar.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", raw.path]
        let out = Pipe()
        gzip.standardOutput = out
        try gzip.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        gzip.waitUntilExit()
        return data
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
