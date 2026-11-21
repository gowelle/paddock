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

    /// The helper a privileged install may use on the real system: the one in the `.app` the running
    /// program belongs to (`<X>.app/Contents/MacOS/paddock-ports`), whether the program runs from the app
    /// itself or is the copy in `bin/` whose `.resources` record names that app's Resources folder. Nil for
    /// a repository or debug build, so such a build never installs its own helper as root.
    public static func bundledBinary() -> URL? {
        var directories: [URL] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return bundledBinary(executableDirectories: directories)
    }

    static func bundledBinary(executableDirectories directories: [URL]) -> URL? {
        let apps = directories.compactMap { directory -> URL? in
            if let app = Bundled.enclosingApp(ofExecutableIn: directory) { return app }
            guard let text = try? String(contentsOf: directory.appendingPathComponent(".resources"), encoding: .utf8)
            else { return nil }
            let resources = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
            guard resources.lastPathComponent == "Resources" else { return nil }
            return Bundled.enclosingApp(ofExecutableIn: resources.deletingLastPathComponent()
                .appendingPathComponent("MacOS", isDirectory: true))
        }
        return apps.map { $0.appendingPathComponent("Contents/MacOS/\(name)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath()
    }
}
