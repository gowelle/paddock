import Foundation

/// Finds `paddock-ports`, the helper that forwards the HTTP and HTTPS ports to Caddy's Unix sockets.
public enum PortHelperLocator {
    static let name = "paddock-ports"

    /// `paddock-ports` beside the running executable (following symlinks), else in the app's
    /// `Contents/MacOS` (`<Bundled.resources>/../MacOS`), else inside the resources folder itself.
    public static func binary() -> URL? {
        var directories: [URL] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return binary(executableDirectories: directories, resources: Bundled.resources)
    }

    static func binary(executableDirectories directories: [URL], resources: URL) -> URL? {
        let candidates = directories.map { $0.appendingPathComponent(name) } + [
            resources.deletingLastPathComponent().appendingPathComponent("MacOS/\(name)").standardizedFileURL,
            resources.appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath()
    }
}
