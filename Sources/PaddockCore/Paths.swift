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
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paddock", isDirectory: true)
        return Paths(home: support)
    }

    public var bin: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public var phpRoot: URL { bin.appendingPathComponent("php", isDirectory: true) }
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

    public func phpDir(_ v: PHPVersion, variant: String = "default") -> URL {
        phpRoot.appendingPathComponent(v.description, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    public func fpmSocket(_ v: PHPVersion) -> URL {
        run.appendingPathComponent("php-\(v).sock")
    }

    public func phpIni(_ v: PHPVersion) -> URL {
        config.appendingPathComponent("php", isDirectory: true)
            .appendingPathComponent(v.description, isDirectory: true)
            .appendingPathComponent("php.ini")
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [home, bin, phpRoot, config, routerHome, run, log, backup, caddyData] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Where the bundled programs (caddy, composer.phar, router/, php/, php-manifest.json) live.
public struct Bundled {
    public static var resources: URL {
        let main = Bundle.main.bundleURL
        if main.pathExtension == "app" {
            return main.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
        if let r = ProcessInfo.processInfo.environment["PADDOCK_RESOURCES"], !r.isEmpty {
            return URL(fileURLWithPath: r, isDirectory: true)
        }
        // <repo>/Sources/PaddockCore/Paths.swift -> <repo>
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Vendor", isDirectory: true)
    }
}
