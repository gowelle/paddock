import Darwin
import Foundation

public enum ServiceInstallError: Error, Equatable, Sendable {
    /// The download (named by its file name) is not the file the catalog names.
    case checksumMismatch(file: String)
    case downloadFailed(reason: String)
    /// A `paddock-builds://` archive that is not on this Mac.
    case notAvailable(file: String)
    case unpackFailed(reason: String)
}

/// Installs a recipe's binaries into `services/bin/<kind>/<version>`: every asset is fetched and verified
/// against the catalog's SHA-256 before anything is unpacked, unpacked into a staging folder, and moved into
/// place in one step. A failed or cancelled install leaves nothing behind; a finished one is reused by
/// every instance of that version.
public final class ServiceInstaller: Sendable {
    private let paths: Paths
    private let downloader: ArtifactDownloader
    static let recordName = ".paddock-install.json"
    static let stagingPrefix = ".service-install-"

    public init(paths: Paths, downloader: ArtifactDownloader = ArtifactDownloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    /// What a finished install was made from: the SHA-256 of each asset, in order.
    private struct Record: Codable, Equatable {
        var sha256: [String]
    }

    private func record(of recipe: ServiceRecipe) -> Record {
        Record(sha256: recipe.assets.map { $0.artifact.sha256.lowercased() })
    }

    /// Whether the recipe's binaries are in place, from exactly the recipe's downloads.
    public func isInstalled(_ recipe: ServiceRecipe) -> Bool {
        let file = paths.serviceBin(kind: recipe.kind, version: recipe.version).appendingPathComponent(Self.recordName)
        guard let data = try? Data(contentsOf: file), let found = try? JSONDecoder().decode(Record.self, from: data)
        else { return false }
        return found == record(of: recipe)
    }

    /// The recipe's `{bin}` folder, installing it first if needed. Cancelling the calling task stops the
    /// download and throws `CancellationError`.
    @discardableResult
    public func install(_ recipe: ServiceRecipe) async throws -> URL {
        let target = paths.serviceBin(kind: recipe.kind, version: recipe.version)
        if isInstalled(recipe) { return target }
        let fm = FileManager.default
        let staging = paths.home.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Every download is verified before any is unpacked.
        var files: [URL] = []
        for asset in recipe.assets {
            try Task.checkCancellation()
            do {
                files.append(try await downloader.fetch(asset.artifact, into: staging, progress: nil))
            } catch let error as ArtifactError {
                switch error {
                case .checksumMismatch:
                    throw ServiceInstallError.checksumMismatch(file: Self.fileName(asset.artifact.url))
                case .downloadFailed(let reason): throw ServiceInstallError.downloadFailed(reason: reason)
                case .notAvailable: throw ServiceInstallError.notAvailable(file: Self.fileName(asset.artifact.url))
                case .cancelled: throw CancellationError()
                }
            }
        }
        try Task.checkCancellation()

        let stage = staging.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for (asset, file) in zip(recipe.assets, files) {
            try unpack(asset, file: file, into: stage)
            try? fm.removeItem(at: file)
        }
        Self.removeQuarantine(under: stage)
        try JSONEncoder().encode(record(of: recipe)).write(to: stage.appendingPathComponent(Self.recordName))
        try Task.checkCancellation()

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            // An unfinished or different install: swapped out in one step, then deleted with the staging folder.
            let failure: Int32 = stage.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to in
                    renamex_np(from!, to!, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
                }
            }
            guard failure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        } else {
            try fm.moveItem(at: stage, to: target)
        }
        return target
    }

    /// Deletes staging folders an interrupted install left in the home. Only call it when no install runs.
    public func removeStaleStaging() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.home.path)) ?? []
        where name.hasPrefix(Self.stagingPrefix) && UUID(uuidString: String(name.dropFirst(Self.stagingPrefix.count))) != nil {
            try? fm.removeItem(at: paths.home.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func fileName(_ url: URL) -> String {
        BuildSource.fileName(url) ?? url.lastPathComponent
    }

    private func unpack(_ asset: RecipeAsset, file: URL, into stage: URL) throws {
        let fm = FileManager.default
        switch asset.archive {
        case "binary":
            guard let name = asset.installAs, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw ServiceInstallError.unpackFailed(reason: "a binary download needs a plain file name")
            }
            let destination = stage.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: file, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        case "tar.gz", "tar.xz", "zip":
            // bsdtar reads all three, and refuses absolute paths and `..` in entries.
            var arguments = ["-xf", file.path, "-C", stage.path]
            if asset.stripComponents > 0 { arguments += ["--strip-components", "\(asset.stripComponents)"] }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = arguments
            let errors = Pipe()
            tar.standardError = errors
            tar.standardOutput = FileHandle.nullDevice
            tar.standardInput = FileHandle.nullDevice
            do { try tar.run() } catch {
                throw ServiceInstallError.unpackFailed(reason: "tar failed to start: \(error.localizedDescription)")
            }
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ServiceInstallError.unpackFailed(reason: message)
            }
        default:
            throw ServiceInstallError.unpackFailed(reason: "unknown archive type \(asset.archive)")
        }
    }

    /// Takes macOS's quarantine mark off everything unpacked (an archive can carry it into its files), so
    /// Gatekeeper never stops a verified download from running. Downloads Paddock makes itself aren't
    /// quarantined; this covers archives that were.
    static func removeQuarantine(under directory: URL) {
        let name = "com.apple.quarantine"
        var items = [directory.path]
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            for case let relative as String in enumerator { items.append(directory.appendingPathComponent(relative).path) }
        }
        for path in items { removexattr(path, name, XATTR_NOFOLLOW) }
    }
}
