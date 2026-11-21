import CryptoKit
import Foundation

/// A file Paddock fetches: where from, and what it must hash to.
public struct Artifact: Codable, Equatable, Sendable {
    public let url: URL
    public let sha256: String
    /// Bytes, when known; a file of another size is rejected like a checksum mismatch.
    public let size: Int?

    public init(url: URL, sha256: String, size: Int? = nil) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public enum ArtifactError: Error, Equatable {
    case checksumMismatch
    case downloadFailed(String)
    /// A `paddock-builds://` archive that is on neither the builds folder nor in the app.
    case notAvailable
    case cancelled
}

/// Fetches an artifact (downloads it, or copies a local build that `BuildSource` resolves) into a
/// temporary file inside a given directory, verifies it, and hands back that file. Whatever fails or is
/// cancelled leaves nothing behind.
public struct ArtifactDownloader: Sendable {
    private let session: URLSession
    private let environment: [String: String]

    public init(session: URLSession = .shared,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.session = session
        self.environment = environment
    }

    /// The verified file, inside `directory` (so it can be renamed anywhere on that volume). The caller
    /// owns it. Cancelling the calling task stops the work and throws `ArtifactError.cancelled`.
    public func fetch(_ asset: Artifact, into directory: URL, progress: ((Double) -> Void)?) async throws -> URL {
        guard let source = BuildSource.resolve(asset.url, environment: environment) else {
            throw ArtifactError.notAvailable
        }
        progress?(0)
        let file: URL
        if source.isFileURL {
            file = try copyLocal(source, asset: asset, into: directory)
        } else {
            file = try await download(source, asset: asset, into: directory)
        }
        progress?(1)
        return file
    }

    /// Copies and verifies an artifact that is already on this Mac. Never touches the network.
    public func fetchLocal(_ asset: Artifact, into directory: URL) throws -> URL {
        guard let source = BuildSource.resolve(asset.url, environment: environment), source.isFileURL else {
            throw ArtifactError.notAvailable
        }
        return try copyLocal(source, asset: asset, into: directory)
    }

    // MARK: - Helpers

    private func temporaryFile(in directory: URL, for asset: Artifact) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = asset.url.lastPathComponent.isEmpty ? "artifact" : asset.url.lastPathComponent
        return directory.appendingPathComponent(".\(UUID().uuidString)-\(name)")
    }

    private func copyLocal(_ source: URL, asset: Artifact, into directory: URL) throws -> URL {
        if Task.isCancelled { throw ArtifactError.cancelled }
        let target = try temporaryFile(in: directory, for: asset)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try verify(target, asset)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            if let error = error as? ArtifactError { throw error }
            throw ArtifactError.downloadFailed(error.localizedDescription)
        }
    }

    private func download(_ source: URL, asset: Artifact, into directory: URL) async throws -> URL {
        let target = try temporaryFile(in: directory, for: asset)
        do {
            let (tmp, response) = try await session.download(from: source)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ArtifactError.downloadFailed("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: tmp, to: target)
            try verify(target, asset)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw ArtifactError.cancelled
            }
            if let error = error as? ArtifactError { throw error }
            throw ArtifactError.downloadFailed(error.localizedDescription)
        }
    }

    private func verify(_ file: URL, _ asset: Artifact) throws {
        if let size = asset.size {
            let actual = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
            guard actual == size else { throw ArtifactError.checksumMismatch }
        }
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if Task.isCancelled { throw ArtifactError.cancelled }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.sha256.lowercased() else { throw ArtifactError.checksumMismatch }
    }
}
