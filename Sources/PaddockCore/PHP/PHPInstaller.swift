import Darwin
import Foundation

public enum PHPInstallError: Error, Equatable {
    case notInManifest(PHPVersion)
    case checksumMismatch(PHPVersion, file: String)
    case downloadFailed(PHPVersion, reason: String)
    /// The manifest names a `paddock-builds://` archive that is not on this Mac.
    case buildMissing(PHPVersion, file: String)
    case inUse(PHPVersion)
}

/// What an installed version directory was installed from: `build.json` beside the binaries. Builds
/// installed before Paddock recorded this have none.
public struct PHPBuildRecord: Codable, Equatable, Sendable {
    public static let fileName = "build.json"

    public var patch: String
    public var cliSHA256: String
    public var fpmSHA256: String

    public init(patch: String, cliSHA256: String, fpmSHA256: String) {
        self.patch = patch
        self.cliSHA256 = cliSHA256
        self.fpmSHA256 = fpmSHA256
    }

    public init(_ build: PHPManifest.Build) {
        self.init(patch: build.patch, cliSHA256: build.cli.sha256.lowercased(), fpmSHA256: build.fpm.sha256.lowercased())
    }

    /// Whether this records exactly the archives `build` names.
    func matches(_ build: PHPManifest.Build) -> Bool {
        cliSHA256.lowercased() == build.cli.sha256.lowercased() && fpmSHA256.lowercased() == build.fpm.sha256.lowercased()
    }
}

/// Installs PHP builds under `paths.phpRoot`.
public final class PHPInstaller {
    private let paths: Paths
    private let manifest: PHPManifest
    private let downloader: ArtifactDownloader
    private let bundledResources: URL

    /// `environment` decides where `paddock-builds://` archives are found (`BuildSource`).
    public init(paths: Paths, manifest: PHPManifest, session: URLSession = .shared,
                bundledResources: URL = Bundled.resources,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.manifest = manifest
        self.downloader = ArtifactDownloader(session: session, environment: environment)
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

    /// Fetches (downloads, or copies from Paddock's own builds on this Mac), verifies and places a build.
    /// Cancelling the calling task stops the download and throws `CancellationError`; like any failure, it
    /// leaves nothing behind.
    public func install(_ v: PHPVersion, progress: ((Double) -> Void)? = nil) async throws {
        guard let build = manifest.build(for: v) else { throw PHPInstallError.notInManifest(v) }
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }

        progress?(0)
        var archives: [URL] = []
        for (index, (asset, name)) in assets(of: build).enumerated() {
            try Task.checkCancellation()
            do {
                archives.append(try await downloader.fetch(asset, into: staging, progress: nil))
            } catch let error as ArtifactError {
                throw installError(error, version: v, asset: asset, binary: name)
            }
            progress?(Double(index + 1) / 2)
        }
        try Task.checkCancellation()
        let stage = try assemble(build, from: archives, in: staging)
        try Task.checkCancellation()
        try place(stage, at: paths.phpDir(v))
        try ensurePhpIni(v)
    }

    /// The record of the build installed for `v`, if it has one.
    public func buildRecord(_ v: PHPVersion) -> PHPBuildRecord? {
        guard let data = try? Data(contentsOf: paths.phpDir(v).appendingPathComponent(PHPBuildRecord.fileName))
        else { return nil }
        return try? JSONDecoder().decode(PHPBuildRecord.self, from: data)
    }

    /// Brings every installed version the manifest offers up to the manifest's build, when that build's
    /// archives are on this Mac (`paddock-builds://`): updating the app updates the PHP it installed. It
    /// never downloads. A version whose record already matches is left alone; one whose build isn't here
    /// is kept as it is, with one line in `log`. The directory is swapped in one step; its `ext/` folder
    /// (extensions such as Xdebug) is carried over, and the user's php.ini (kept outside it) is untouched.
    /// Versions in `skipping` are left alone. Returns the versions that could not be updated.
    @discardableResult
    public func updateOutdatedBuilds(skipping: Set<PHPVersion> = [], log: (String) -> Void) -> Set<PHPVersion> {
        var failed: Set<PHPVersion> = []
        for v in installed() where !skipping.contains(v) {
            guard let build = manifest.build(for: v) else { continue }
            if let record = buildRecord(v), record.matches(build) { continue }
            do {
                try replaceFromLocalBuild(build)
                log("updated PHP \(v) to build \(build.patch)")
            } catch PHPInstallError.buildMissing(_, let file) {
                failed.insert(v)
                log("PHP \(v) is not Paddock's current build \(build.patch), whose \(file) isn't on this Mac; "
                    + "keeping the installed one")
            } catch {
                failed.insert(v)
                log("could not update PHP \(v) to build \(build.patch), keeping the installed one: \(error)")
            }
        }
        return failed
    }

    /// Deletes staging folders an interrupted install or update left in the home (`.php-install-<UUID>`).
    /// Only call it when no install is running.
    public func removeStaleStaging() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: paths.home.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix)
            && UUID(uuidString: String(name.dropFirst(Self.stagingPrefix.count))) != nil {
            let url = paths.home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            try? fm.removeItem(at: url)
        }
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

    private func assets(of build: PHPManifest.Build) -> [(Asset, String)] {
        [(build.cli, "php"), (build.fpm, "php-fpm")]
    }

    private func installError(_ error: ArtifactError, version v: PHPVersion, asset: Asset,
                              binary name: String) -> Error {
        switch error {
        case .checksumMismatch: return PHPInstallError.checksumMismatch(v, file: name)
        case .downloadFailed(let reason): return PHPInstallError.downloadFailed(v, reason: reason)
        case .notAvailable:
            return PHPInstallError.buildMissing(v, file: BuildSource.fileName(asset.url) ?? asset.url.lastPathComponent)
        case .cancelled: return CancellationError()
        }
    }

    /// Copies the build's archives from this Mac, verifies them and swaps the version's directory for it.
    private func replaceFromLocalBuild(_ build: PHPManifest.Build) throws {
        let v = build.version
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }
        var archives: [URL] = []
        for (asset, name) in assets(of: build) {
            do {
                archives.append(try downloader.fetchLocal(asset, into: staging))
            } catch let error as ArtifactError {
                throw installError(error, version: v, asset: asset, binary: name)
            }
        }
        let stage = try assemble(build, from: archives, in: staging)
        try place(stage, at: paths.phpDir(v))
        try ensurePhpIni(v)
    }

    /// Unpacks the verified cli and fpm archives into `staging/stage` with the build's record; returns it.
    private func assemble(_ build: PHPManifest.Build, from archives: [URL], in staging: URL) throws -> URL {
        let v = build.version
        let fm = FileManager.default
        let stage = staging.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for (archive, (_, name)) in zip(archives, assets(of: build)) {
            try extract(archive, into: stage, version: v)
            try? fm.removeItem(at: archive)
            let binary = stage.appendingPathComponent(name)
            guard fm.fileExists(atPath: binary.path) else {
                throw PHPInstallError.downloadFailed(v, reason: "\(name) archive did not contain \(name)")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let record = try JSONEncoder().encode(PHPBuildRecord(build))
        try record.write(to: stage.appendingPathComponent(PHPBuildRecord.fileName))
        return stage
    }

    private static let stagingPrefix = ".php-install-"

    private func makeStagingDirectory() throws -> URL {
        let dir = paths.home.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    /// Moves a finished directory into place in one step. A previous directory is swapped out
    /// atomically (`stage` then holds it, and goes away with the staging directory), so a running `php`
    /// or PHP-FPM never sees a half-replaced build. The previous directory's `ext/` (the php.ini's
    /// `extension_dir`, where Xdebug and the user's extensions live) is copied into the new one first:
    /// extensions are built per minor version, so they still load after a patch update.
    private func place(_ stage: URL, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: target.path) else {
            try fm.moveItem(at: stage, to: target)
            return
        }
        let ext = target.appendingPathComponent("ext", isDirectory: true)
        let stagedExt = stage.appendingPathComponent("ext", isDirectory: true)
        if fm.fileExists(atPath: ext.path), !fm.fileExists(atPath: stagedExt.path) {
            try fm.copyItem(at: ext, to: stagedExt)
        }
        let failure: Int32 = stage.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        guard failure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
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
