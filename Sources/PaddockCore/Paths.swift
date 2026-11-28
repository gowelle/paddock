import Foundation

public struct Paths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// PADDOCK_HOME if set, else ~/Library/Application Support/Paddock.
    public static var current: Paths {
        if let h = ProcessInfo.processInfo.environment["PADDOCK_HOME"], !h.isEmpty {
            return Paths(home: URL(fileURLWithPath: h, isDirectory: true))
        }
        return system
    }

    /// The owner's real home: ~/Library/Application Support/Paddock.
    public static var system: Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paddock", isDirectory: true))
    }

    /// Whether this is the owner's real home.
    public var isSystemHome: Bool {
        home.standardizedFileURL.path == Paths.system.home.standardizedFileURL.path
    }

    public var bin: URL { home.appendingPathComponent("bin", isDirectory: true) }
    /// PHP builds. Not `bin/php`: that name is the `php` command (a link to `paddock`).
    public var phpRoot: URL { bin.appendingPathComponent("php-versions", isDirectory: true) }
    public var config: URL { home.appendingPathComponent("config", isDirectory: true) }
    public var run: URL { home.appendingPathComponent("run", isDirectory: true) }
    public var log: URL { home.appendingPathComponent("log", isDirectory: true) }
    public var stateFile: URL { home.appendingPathComponent("state.json") }
    public var backup: URL { home.appendingPathComponent("backup", isDirectory: true) }
    public var caddyData: URL { home.appendingPathComponent("caddy", isDirectory: true) }
    public var caddyfile: URL { config.appendingPathComponent("Caddyfile") }
    public var routerHome: URL { config.appendingPathComponent("valet", isDirectory: true) }
    public var daemonSocket: URL { run.appendingPathComponent("paddockd.sock") }
    public var caddyAdminSocket: URL { run.appendingPathComponent("caddy-admin.sock") }
    /// Caddy serves plain HTTP here; in a development home the port helper forwards the HTTP port to it.
    public var httpSocket: URL { run.appendingPathComponent("http.sock") }
    /// Caddy serves HTTPS here; the helper forwards the HTTPS port to it.
    public var httpsSocket: URL { run.appendingPathComponent("https.sock") }

    /// The first Unix socket of the web stack whose path is too long for macOS (more than 103 bytes:
    /// `sun_path` holds 104 including the terminating NUL), or nil when they all fit.
    public var tooLongSocket: String? {
        [httpSocket, httpsSocket, caddyAdminSocket].map(\.path).first { Wire.socketAddress($0) == nil }
    }

    /// Added services: shared binaries in `bin/`, and one folder per instance.
    public var services: URL { home.appendingPathComponent("services", isDirectory: true) }

    /// A recipe's unpacked binaries, shared by every instance of that version.
    public func serviceBin(kind: String, version: String) -> URL {
        services.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    /// An instance's folder, holding `data/` (kept on remove) and `config/` (regenerated).
    public func serviceHome(_ id: String) -> URL { services.appendingPathComponent(id, isDirectory: true) }
    public func serviceData(_ id: String) -> URL { serviceHome(id).appendingPathComponent("data", isDirectory: true) }
    public func serviceConfig(_ id: String) -> URL {
        serviceHome(id).appendingPathComponent("config", isDirectory: true)
    }

    /// An instance's sockets and pid files: short, so Unix socket paths fit.
    public func serviceRun(_ id: String) -> URL {
        run.appendingPathComponent("svc", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func serviceLog(_ id: String) -> URL { log.appendingPathComponent("service-\(id).log") }

    /// Site tasks' logs: `log/tasks/<site>/<task>.log` (site and task names are plain: letters, digits, dashes).
    public var taskLogs: URL { log.appendingPathComponent("tasks", isDirectory: true) }

    public func taskLog(site: String, task: String) -> URL {
        taskLogs.appendingPathComponent(site, isDirectory: true).appendingPathComponent("\(task).log")
    }

    /// A site task's pid record folder, `run/tasks/<site>/<task>`.
    public func taskRun(site: String, task: String) -> URL {
        run.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent(site, isDirectory: true)
            .appendingPathComponent(task, isDirectory: true)
    }

    /// User-edited PHP settings; unlike `config/`, never regenerated.
    public var userPHP: URL { home.appendingPathComponent("php", isDirectory: true) }

    public func phpDir(_ v: PHPVersion, variant: String = "default") -> URL {
        phpRoot.appendingPathComponent(v.description, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// Extensions Paddock adds to a PHP version (Xdebug): outside the version's own folder, which an update
    /// replaces, and outside the user's `ext/`.
    public func phpExtensions(_ v: PHPVersion) -> URL {
        bin.appendingPathComponent("php-extensions", isDirectory: true)
            .appendingPathComponent(v.description, isDirectory: true)
    }

    public func fpmSocket(_ v: PHPVersion) -> URL {
        run.appendingPathComponent("php-\(v).sock")
    }

    public func phpIni(_ v: PHPVersion) -> URL {
        userPHP.appendingPathComponent(v.description, isDirectory: true)
            .appendingPathComponent("php.ini")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [home, bin, phpRoot, userPHP, config, routerHome, run, log, backup, caddyData] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Owner only, so the sockets inside are reachable by no one else, whatever mode they get.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
    }
}

/// Where the bundled programs (caddy, composer.phar, router/, php/, php-manifest.json) live.
public struct Bundled {
    public static var resources: URL {
        resources(environment: ProcessInfo.processInfo.environment)
    }

    /// `resources` as seen with `environment` in place of this process's.
    public static func resources(environment: [String: String]) -> URL {
        let executable = Bundle.main.executableURL
        return resolveResources(
            environment: environment,
            bundleURL: Bundle.main.bundleURL,
            executableDirectory: executable?.deletingLastPathComponent(),
            resolvedExecutableDirectory: executable?.resolvingSymlinksInPath().deletingLastPathComponent(),
            fallback: repoVendor)
    }

    /// <repo>/Sources/PaddockCore/Paths.swift -> <repo>/Vendor
    private static var repoVendor: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor", isDirectory: true)
    }

    /// Lookup order: PADDOCK_RESOURCES, the enclosing .app (the main bundle, or an executable in
    /// `<name>.app/Contents/MacOS/` such as `paddockd` and `paddock`), the path recorded in `.resources` next to
    /// the running executable (the copy in `bin/` records it), then `fallback` (the repo's Vendor/).
    static func resolveResources(environment: [String: String], bundleURL: URL,
                                 executableDirectory: URL?, resolvedExecutableDirectory: URL? = nil,
                                 fallback: URL) -> URL {
        if let r = environment["PADDOCK_RESOURCES"], !r.isEmpty {
            return URL(fileURLWithPath: r, isDirectory: true)
        }
        if bundleURL.pathExtension == "app" {
            return bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
        let directories = [executableDirectory, resolvedExecutableDirectory].compactMap { $0 }
        if let app = directories.lazy.compactMap(enclosingApp(ofExecutableIn:)).first {
            return app.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
        for directory in directories {
            let record = directory.appendingPathComponent(".resources")
            if let text = try? String(contentsOf: record, encoding: .utf8) {
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
            }
        }
        return fallback
    }

    /// `/X/Paddock.app` for `/X/Paddock.app/Contents/MacOS`, else nil.
    static func enclosingApp(ofExecutableIn directory: URL) -> URL? {
        let macOS = directory.standardizedFileURL
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}
