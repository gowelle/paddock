import CryptoKit
import Foundation

public enum PHPInstallError: Error, Equatable {
    case notInManifest(PHPVersion)
    case checksumMismatch(PHPVersion, file: String)
    case downloadFailed(PHPVersion, reason: String)
    case inUse(PHPVersion)
}

/// Installs PHP builds under `paths.phpRoot`.
public final class PHPInstaller {
    private let paths: Paths
    private let manifest: PHPManifest
    private let session: URLSession
    private let bundledResources: URL

    public init(paths: Paths, manifest: PHPManifest, session: URLSession = .shared,
                bundledResources: URL = Bundled.resources) {
        self.paths = paths
        self.manifest = manifest
        self.session = session
        self.bundledResources = bundledResources
    }

    public func phpBinary(_ v: PHPVersion) -> URL {
        paths.phpDir(v).appendingPathComponent("php")
    }

    public func fpmBinary(_ v: PHPVersion) -> URL {
        paths.phpDir(v).appendingPathComponent("php-fpm")
    }

    public func isInstalled(_ v: PHPVersion) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: phpBinary(v).path)
            && fm.isExecutableFile(atPath: fpmBinary(v).path)
    }

    /// Whether the manifest lists a downloadable build of this version.
    public func isAvailable(_ v: PHPVersion) -> Bool {
        manifest.build(for: v) != nil
    }

    /// Versions whose directory holds both binaries, ascending.
    public func installed() -> [PHPVersion] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.phpRoot.path)) ?? []
        return names.compactMap { PHPVersion($0) }.filter(isInstalled).sorted()
    }

    /// Copies the newest bundled build into place. No-op if that version is already installed.
    @discardableResult
    public func installBundled() throws -> PHPVersion {
        let fm = FileManager.default
        let root = bundledResources.appendingPathComponent("php", isDirectory: true)
        let candidates = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .compactMap { PHPVersion($0) }
            .filter { fm.fileExists(atPath: root.appendingPathComponent("\($0)/default/php").path) }
        guard let v = candidates.max() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        if !isInstalled(v) {
            let source = root.appendingPathComponent("\(v)/default", isDirectory: true)
            let target = paths.phpDir(v)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = try makeStagingDirectory()
            defer { try? fm.removeItem(at: staging) }
            let stage = staging.appendingPathComponent("stage", isDirectory: true)
            try fm.copyItem(at: source, to: stage)
            try place(stage, at: target)
        }
        try ensurePhpIni(v)
        return v
    }

    public func install(_ v: PHPVersion, progress: ((Double) -> Void)? = nil) async throws {
        guard let build = manifest.build(for: v) else { throw PHPInstallError.notInManifest(v) }
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }
        let stage = staging.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        let assets: [(Asset, String)] = [(build.cli, "php"), (build.fpm, "php-fpm")]
        progress?(0)
        for (index, (asset, name)) in assets.enumerated() {
            let archive = staging.appendingPathComponent("\(name).tar.gz")
            try await download(asset, to: archive, version: v)
            try verify(archive, expected: asset.sha256, version: v, file: name)
            try extract(archive, into: stage, version: v)
            let binary = stage.appendingPathComponent(name)
            guard fm.fileExists(atPath: binary.path) else {
                throw PHPInstallError.downloadFailed(v, reason: "\(name) archive did not contain \(name)")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            progress?(Double(index + 1) / Double(assets.count))
        }

        try place(stage, at: paths.phpDir(v))
        try ensurePhpIni(v)
    }

    /// Deletes the version's directory; fine if it is absent.
    public func remove(_ v: PHPVersion) throws {
        let dir = paths.phpDir(v).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private typealias Asset = PHPManifest.Asset

    private func makeStagingDirectory() throws -> URL {
        let dir = paths.home.appendingPathComponent(".php-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func download(_ asset: Asset, to destination: URL, version v: PHPVersion) async throws {
        do {
            let (tmp, response) = try await session.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PHPInstallError.downloadFailed(v, reason: "HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch let error as PHPInstallError {
            throw error
        } catch {
            throw PHPInstallError.downloadFailed(v, reason: error.localizedDescription)
        }
    }

    private func verify(_ file: URL, expected: String, version v: PHPVersion, file name: String) throws {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw PHPInstallError.checksumMismatch(v, file: name)
        }
    }

    private func extract(_ archive: URL, into directory: URL, version v: PHPVersion) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", directory.path]
        let errors = Pipe()
        tar.standardError = errors
        tar.standardOutput = FileHandle.nullDevice
        do {
            try tar.run()
        } catch {
            throw PHPInstallError.downloadFailed(v, reason: "tar failed to start: \(error.localizedDescription)")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PHPInstallError.downloadFailed(v, reason: "extract failed: \(message)")
        }
    }

    /// Moves a finished directory into place with one rename, replacing any previous one.
    private func place(_ stage: URL, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: stage, to: target)
    }

    /// Writes the default php.ini if none exists; never overwrites.
    private func ensurePhpIni(_ v: PHPVersion) throws {
        let ini = paths.phpIni(v)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: ini.path) else { return }
        try fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FPMConfig.defaultIni(version: v, paths: paths).utf8).write(to: ini)
    }
}
