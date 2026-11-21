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
    /// Decides where `paddock-builds://` archives are found (`BuildSource`).
    private let environment: [String: String]
    static let recordName = ".paddock-install.json"
    /// The recipe an installed folder was made from: an instance can run from it even after the catalog
    /// stops offering that version.
    static let recipeName = ".paddock-recipe.json"
    static let stagingPrefix = ".service-install-"

    public init(paths: Paths, downloader: ArtifactDownloader = ArtifactDownloader(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.downloader = downloader
        self.environment = environment
    }

    /// What a finished install was made from: the SHA-256 of each asset, in order.
    private struct Record: Codable, Equatable {
        var sha256: [String]
    }

    private func record(of recipe: ServiceRecipe) -> Record {
        Record(sha256: recipe.assets.map { $0.artifact.sha256.lowercased() })
    }

    private func installedRecord(kind: String, version: String) -> Record? {
        let file = paths.serviceBin(kind: kind, version: version).appendingPathComponent(Self.recordName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Whether the recipe's binaries are in place, from exactly the recipe's downloads.
    public func isInstalled(_ recipe: ServiceRecipe) -> Bool {
        installedRecord(kind: recipe.kind, version: recipe.version) == record(of: recipe)
    }

    /// What is stored beside an installed version's binaries.
    public enum StoredRecipe: Equatable {
        /// No finished install, or one without a stored recipe (made before Paddock stored them).
        case none
        /// The stored recipe, validated like any catalog's.
        case valid(ServiceRecipe)
        /// A stored recipe that doesn't decode, doesn't match its install, or fails validation: never used.
        case invalid(String)
    }

    /// The stored recipe of an installed `kind` `version`, validated (`ServiceCatalog.validate`) before
    /// any field of it is used.
    public func storedRecipe(kind: String, version: String) -> StoredRecipe {
        let file = paths.serviceBin(kind: kind, version: version).appendingPathComponent(Self.recipeName)
        guard let record = installedRecord(kind: kind, version: version),
              let data = try? Data(contentsOf: file) else { return .none }
        let recipe: ServiceRecipe
        do { recipe = try JSONDecoder().decode(ServiceRecipe.self, from: data) } catch {
            return .invalid("it can't be read")
        }
        guard recipe.kind == kind, recipe.version == version, record == self.record(of: recipe) else {
            return .invalid("it doesn't match the installed files")
        }
        do { try ServiceCatalog.validate([recipe]) } catch { return .invalid("\(error)") }
        return .valid(recipe)
    }

    /// The valid stored recipe of an installed `kind` `version`, if there is one.
    public func installedRecipe(kind: String, version: String) -> ServiceRecipe? {
        if case .valid(let recipe) = storedRecipe(kind: kind, version: version) { return recipe }
        return nil
    }

    /// Whether `kind` `version` has a finished install (whatever its stored recipe).
    public func hasInstall(kind: String, version: String) -> Bool {
        installedRecord(kind: kind, version: version) != nil
    }

    /// Stores `recipe` beside its installed binaries (for installs made before recipes were stored, or whose
    /// stored recipe was invalid). Only when exactly its downloads are installed.
    public func storeRecipe(_ recipe: ServiceRecipe) throws {
        guard isInstalled(recipe) else { return }
        let file = paths.serviceBin(kind: recipe.kind, version: recipe.version).appendingPathComponent(Self.recipeName)
        try JSONEncoder().encode(recipe).write(to: file, options: .atomic)
    }

    /// Whether every download of the recipe is already a file on this Mac (Paddock's own builds, or a
    /// local copy), so installing it needs no network.
    public func isLocallyAvailable(_ recipe: ServiceRecipe) -> Bool {
        recipe.assets.allSatisfy { asset in
            guard let source = BuildSource.resolve(asset.artifact.url, environment: environment), source.isFileURL else {
                return false
            }
            return FileManager.default.fileExists(atPath: source.path)
        }
    }

    /// How many of the recipe's assets are already installed: an install made from exactly its first assets
    /// (before the recipe gained a later one, such as PostGIS over PostgreSQL), which can be completed from
    /// its own files. Zero when nothing, or something else, is installed.
    private func installedPrefix(_ recipe: ServiceRecipe) -> Int {
        guard let installed = installedRecord(kind: recipe.kind, version: recipe.version) else { return 0 }
        let wanted = record(of: recipe).sha256
        guard !installed.sha256.isEmpty, installed.sha256.count < wanted.count,
              Array(wanted.prefix(installed.sha256.count)) == installed.sha256 else { return 0 }
        return installed.sha256.count
    }

    /// Whether the recipe can be installed without the network: every download is a file on this Mac, or
    /// its first assets are installed already and the rest are.
    public func canInstallLocally(_ recipe: ServiceRecipe) -> Bool {
        if isLocallyAvailable(recipe) { return true }
        let installed = installedPrefix(recipe)
        guard installed > 0 else { return false }
        return recipe.assets.dropFirst(installed).allSatisfy { asset in
            guard let source = BuildSource.resolve(asset.artifact.url, environment: environment), source.isFileURL else {
                return false
            }
            return FileManager.default.fileExists(atPath: source.path)
        }
    }

    /// The recipe's `{bin}` folder, installing it first if needed. Cancelling the calling task stops the
    /// download and throws `CancellationError`.
    @discardableResult
    public func install(_ recipe: ServiceRecipe) async throws -> URL {
        let target = paths.serviceBin(kind: recipe.kind, version: recipe.version)
        if isInstalled(recipe) { return target }
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let installed = installedPrefix(recipe)
        // Every download is verified before any is unpacked.
        var files: [URL] = []
        for asset in recipe.assets.dropFirst(installed) {
            try Task.checkCancellation()
            do {
                files.append(try await downloader.fetch(asset.artifact, into: staging, progress: nil))
            } catch let error as ArtifactError {
                throw Self.installError(error, asset)
            }
        }
        try Task.checkCancellation()
        return try assemble(recipe, files: files, staging: staging, installed: installed)
    }

    /// Installs from files already on this Mac only (`canInstallLocally`); never touches the network.
    @discardableResult
    public func installLocally(_ recipe: ServiceRecipe) throws -> URL {
        let target = paths.serviceBin(kind: recipe.kind, version: recipe.version)
        if isInstalled(recipe) { return target }
        let staging = try makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let installed = installedPrefix(recipe)
        var files: [URL] = []
        for asset in recipe.assets.dropFirst(installed) {
            do {
                files.append(try downloader.fetchLocal(asset.artifact, into: staging))
            } catch let error as ArtifactError {
                throw Self.installError(error, asset)
            }
        }
        return try assemble(recipe, files: files, staging: staging, installed: installed)
    }

    /// Deletes an installed version's folder (fine if it is absent).
    public func remove(kind: String, version: String) {
        try? FileManager.default.removeItem(at: paths.serviceBin(kind: kind, version: version))
    }

    private func makeStaging() throws -> URL {
        let staging = paths.home.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private static func installError(_ error: ArtifactError, _ asset: RecipeAsset) -> Error {
        switch error {
        case .checksumMismatch: return ServiceInstallError.checksumMismatch(file: fileName(asset.artifact.url))
        case .downloadFailed(let reason): return ServiceInstallError.downloadFailed(reason: reason)
        case .notAvailable: return ServiceInstallError.notAvailable(file: fileName(asset.artifact.url))
        case .cancelled: return CancellationError()
        }
    }

    /// Unpacks verified downloads into `staging/stage` with the record and the recipe, and moves that into
    /// place in one step (swapping out an unfinished or different install). Each asset is unpacked on its own
    /// and merged in: no asset may replace a file (or a symlink) another one put there, nor write through
    /// one. With `installed` > 0, the stage starts as a copy (a clone, on APFS) of the install made from the
    /// recipe's first `installed` assets, and `files` are the rest.
    private func assemble(_ recipe: ServiceRecipe, files: [URL], staging: URL, installed: Int = 0) throws -> URL {
        let fm = FileManager.default
        let target = paths.serviceBin(kind: recipe.kind, version: recipe.version)
        let stage = staging.appendingPathComponent("stage", isDirectory: true)
        if installed > 0 {
            try Self.cloneTree(target, to: stage)
            for name in [Self.recordName, Self.recipeName] { try? fm.removeItem(at: stage.appendingPathComponent(name)) }
        } else {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        }
        for (index, (asset, file)) in zip(recipe.assets.dropFirst(installed), files).enumerated() {
            let unpacked = staging.appendingPathComponent("asset-\(index)", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try unpack(asset, file: file, into: unpacked)
            try? fm.removeItem(at: file)
            try Self.merge(unpacked, into: stage, relative: "")
            try? fm.removeItem(at: unpacked)
        }
        Self.removeQuarantine(under: stage)
        try JSONEncoder().encode(record(of: recipe)).write(to: stage.appendingPathComponent(Self.recordName))
        try JSONEncoder().encode(recipe).write(to: stage.appendingPathComponent(Self.recipeName))

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
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

    /// Moves everything under `source` into `destination`: folders are merged (a destination folder must be
    /// a real folder, never a symlink to one), and any other entry must not exist there yet.
    static func merge(_ source: URL, into destination: URL, relative: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: source.path).sorted() {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            var fromInfo = stat()
            guard lstat(from.path, &fromInfo) == 0 else { continue }
            var toInfo = stat()
            let exists = lstat(to.path, &toInfo) == 0
            if (fromInfo.st_mode & S_IFMT) == S_IFDIR {
                if !exists {
                    try fm.moveItem(at: from, to: to)
                } else if (toInfo.st_mode & S_IFMT) == S_IFDIR {
                    try merge(from, into: to, relative: path)
                } else {
                    throw ServiceInstallError.unpackFailed(reason: "two downloads both provide \(path)")
                }
            } else {
                guard !exists else { throw ServiceInstallError.unpackFailed(reason: "two downloads both provide \(path)") }
                try fm.moveItem(at: from, to: to)
            }
        }
    }

    /// A copy of an installed tree (a clone of every file on APFS, so it costs no space or time).
    static func cloneTree(_ source: URL, to destination: URL) throws {
        let failed = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in clonefile(from!, to!, UInt32(CLONE_NOFOLLOW)) != 0 }
        }
        if failed { try FileManager.default.copyItem(at: source, to: destination) }
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
