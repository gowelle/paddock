import Foundation

/// Where Paddock's own build archives (`paddock-builds://<file>`) are found on this Mac.
public enum BuildSource {
    public static let scheme = "paddock-builds"

    /// A `paddock-builds://<file>` URL becomes the first existing of `<PADDOCK_BUILDS_DIR>/<file>` and
    /// `<Bundled.resources>/builds/<file>`, or nil when neither exists (or the name is not a plain file
    /// name). Any other URL is returned unchanged.
    public static func resolve(_ url: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard url.scheme == scheme else { return url }
        guard let name = fileName(url) else { return nil }
        var directories: [URL] = []
        if let dir = environment["PADDOCK_BUILDS_DIR"], !dir.isEmpty {
            directories.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        directories.append(Bundled.resources(environment: environment)
            .appendingPathComponent("builds", isDirectory: true))
        let fm = FileManager.default
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// The archive name a `paddock-builds://` URL names: one path component, never `.` or `..`.
    public static func fileName(_ url: URL) -> String? {
        let prefix = "\(scheme)://"
        let text = url.absoluteString
        guard text.hasPrefix(prefix) else { return nil }
        let name = String(text.dropFirst(prefix.count))
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("%"), !name.contains("?"), !name.contains("#") else { return nil }
        return name
    }
}
