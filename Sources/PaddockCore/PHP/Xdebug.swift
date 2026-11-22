import Foundation

public enum XdebugError: Error, Equatable {
    /// Paddock has no Xdebug build for this PHP version.
    case notAvailable(PHPVersion)
    /// Its archive could not be fetched, verified or unpacked.
    case installFailed(PHPVersion, reason: String)
}

/// Xdebug for Paddock's PHP: one loadable `xdebug.so` per PHP version, Paddock's own build
/// (`Scripts/build-xdebug.sh`), named by the PHP manifest. It is kept outside the PHP build's folder (so a PHP
/// update never loses it) and outside the user's `ext/` folder (so it never replaces a file of theirs), and
/// it is loaded from PHP's command line, so the user's php.ini is never edited.
public struct Xdebug: Sendable {
    public static let fileName = "xdebug.so"
    /// Beside the library: which archive it came from, so a newer build replaces it.
    static let recordName = "xdebug.sha256"

    private let paths: Paths
    private let manifest: PHPManifest
    private let downloader: ArtifactDownloader

    public init(paths: Paths, manifest: PHPManifest,
                downloader: ArtifactDownloader = ArtifactDownloader()) {
        self.paths = paths
        self.manifest = manifest
        self.downloader = downloader
    }

    /// Where a PHP version's `xdebug.so` is, installed or not.
    public static func library(_ v: PHPVersion, paths: Paths) -> URL {
        paths.phpExtensions(v).appendingPathComponent(fileName)
    }

    /// What PHP is started with to load Xdebug for step debugging that begins only when asked for (a request's
    /// `XDEBUG_TRIGGER` or `XDEBUG_SESSION`, or the browser extension's cookie). Where the debugger connects
    /// (`xdebug.client_host`, `xdebug.client_port`: 127.0.0.1 and 9003 unless set) is left to php.ini.
    ///
    /// A command-line setting beats php.ini, so one the user's php.ini (`ini`) sets itself is left out here:
    /// `xdebug.mode = debug,develop,coverage` in php.ini is theirs to choose.
    public static func arguments(library: URL, ini: URL? = nil) -> [String] {
        let theirs = ini.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(settings(in:)) ?? []
        var arguments = ["-d", "zend_extension=\(library.path)"]
        for (name, value) in [("xdebug.mode", "debug"), ("xdebug.start_with_request", "trigger")]
        where !theirs.contains(name) {
            arguments += ["-d", "\(name)=\(value)"]
        }
        return arguments
    }

    /// Xdebug's own default for where the debugger listens.
    public static let defaultClientPort = 9003

    /// The port the debugger must listen on: the php.ini's `xdebug.client_port` when it sets a usable one,
    /// else Xdebug's default.
    public static func clientPort(ini: URL?) -> Int {
        guard let text = ini.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return defaultClientPort }
        var port = defaultClientPort
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first != ";", first != "#", let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "xdebug.client_port" else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let number = Int(value), (1...65535).contains(number) { port = number }
        }
        return port
    }

    /// Zed's debug configuration for listening to Xdebug, as its PHP documentation gives it: the contents of
    /// a project's `.zed/debug.json`.
    public static func zedConfiguration(port: Int = defaultClientPort) -> String {
        """
        [
          {
            "label": "PHP: Listen to Xdebug",
            "adapter": "Xdebug",
            "request": "launch",
            "port": \(port)
          }
        ]

        """
    }

    /// The names an ini text sets: `name = value` lines, not comments (`;` or `#`) and not section headers.
    static func settings(in ini: String) -> Set<String> {
        var names: Set<String> = []
        for line in ini.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first != ";", first != "#", first != "[",
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            names.insert(trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased())
        }
        return names
    }

    /// Those arguments when Xdebug is switched on for the version and its library is installed; none otherwise
    /// (PHP would warn on every start about a file that isn't there).
    public static func arguments(for v: PHPVersion, state: State, paths: Paths) -> [String] {
        guard state.xdebug.contains(v) else { return [] }
        let library = library(v, paths: paths)
        guard FileManager.default.fileExists(atPath: library.path) else { return [] }
        return arguments(library: library, ini: paths.phpIni(v))
    }

    /// Whether Paddock has an Xdebug build for the version.
    public func isAvailable(_ v: PHPVersion) -> Bool {
        manifest.build(for: v)?.xdebug != nil
    }

    /// The versions among `installed` that Paddock has an Xdebug build for.
    public func available(among installed: [PHPVersion]) -> [PHPVersion] {
        installed.filter(isAvailable)
    }

    /// True when the version's library is in place and came from the manifest's current archive.
    public func isInstalled(_ v: PHPVersion) -> Bool {
        guard let asset = manifest.build(for: v)?.xdebug else { return false }
        let folder = paths.phpExtensions(v)
        let record = try? String(contentsOf: folder.appendingPathComponent(Self.recordName), encoding: .utf8)
        return record?.trimmingCharacters(in: .whitespacesAndNewlines) == asset.sha256.lowercased()
            && FileManager.default.fileExists(atPath: Self.library(v, paths: paths).path)
    }

    /// Puts the version's `xdebug.so` in place from its verified archive, unless it is already there from that
    /// archive. Paddock's own builds are in the app, so this needs no network.
    public func ensureInstalled(_ v: PHPVersion) async throws {
        guard let asset = manifest.build(for: v)?.xdebug else { throw XdebugError.notAvailable(v) }
        if isInstalled(v) { return }
        let fm = FileManager.default
        let folder = paths.phpExtensions(v)
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent(".xdebug-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let archive = try await downloader.fetch(asset, into: staging, progress: nil)
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try Self.extract(archive, into: unpacked)
            let library = unpacked.appendingPathComponent(Self.fileName)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: library.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  (try? fm.destinationOfSymbolicLink(atPath: library.path)) == nil else {
                throw XdebugError.installFailed(v, reason: "its archive did not contain \(Self.fileName)")
            }
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: library.path)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // The record goes first and comes back last: a library without its record is installed again.
            let record = folder.appendingPathComponent(Self.recordName)
            try? fm.removeItem(at: record)
            let target = Self.library(v, paths: paths)
            if fm.fileExists(atPath: target.path) {
                // Swapped in one step, so a PHP starting meanwhile never sees half a file.
                _ = try fm.replaceItemAt(target, withItemAt: library)
            } else {
                try fm.moveItem(at: library, to: target)
            }
            let licence = unpacked.appendingPathComponent("LICENSE")
            if fm.fileExists(atPath: licence.path) {
                let kept = folder.appendingPathComponent("xdebug-LICENSE")
                try? fm.removeItem(at: kept)
                try? fm.moveItem(at: licence, to: kept)
            }
            try Data((asset.sha256.lowercased() + "\n").utf8).write(to: record, options: .atomic)
        } catch let error as XdebugError {
            throw error
        } catch let error as ArtifactError {
            switch error {
            case .cancelled: throw CancellationError()
            case .checksumMismatch: throw XdebugError.installFailed(v, reason: "its archive failed its checksum")
            case .notAvailable: throw XdebugError.installFailed(v, reason: "its archive isn't on this Mac")
            case .downloadFailed(let reason): throw XdebugError.installFailed(v, reason: reason)
            }
        } catch {
            throw XdebugError.installFailed(v, reason: error.localizedDescription)
        }
    }

    private static func extract(_ archive: URL, into directory: URL) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", directory.path]
        let errors = Pipe()
        tar.standardError = errors
        tar.standardOutput = FileHandle.nullDevice
        try tar.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Paddock.Xdebug", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not unpack its archive: \(message)"])
        }
    }
}
