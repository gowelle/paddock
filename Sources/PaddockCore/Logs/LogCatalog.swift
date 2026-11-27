import Foundation

/// One log file the Logs window can show.
public struct LogSource: Identifiable, Equatable, Sendable {
    /// The file's path: what identifies it.
    public var id: String { url.path }
    /// What the list calls it: `Web server`, `PostgreSQL 18`, `queue`, `laravel.log`.
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// A titled group of logs: `Paddock`, `PHP`, `Services`, a site's tasks, a site's own logs.
public struct LogSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let sources: [LogSource]

    public init(title: String, sources: [LogSource]) {
        self.title = title
        self.sources = sources
    }
}

/// Finds the logs there are to show: the ones Paddock writes (the daemon's, the web server's, PHP's, each
/// service's, each site task's) and each site's own (`storage/logs/*.log`). It only lists; nothing here
/// reads, rotates or changes a file, and a site's files are never written to.
public enum LogCatalog {
    /// How many of one site's own logs are listed: the newest, with `laravel.log` always among them.
    public static let siteLogLimit = 20

    /// Every section that has at least one log, in a fixed order. `status` names the services and sites;
    /// without it only Paddock's own files show.
    public static func sections(paths: Paths, status: EngineStatus?) -> [LogSection] {
        let fm = FileManager.default
        let names = Set(((try? fm.contentsOfDirectory(atPath: paths.log.path)) ?? []).filter { $0.hasSuffix(".log") })
        func own(_ name: String, _ title: String) -> LogSource? {
            names.contains(name) ? LogSource(title: title, url: paths.log.appendingPathComponent(name)) : nil
        }
        var sections: [LogSection] = []

        let paddock = [own("paddockd.log", "Paddock"), own("caddy.log", "Web server"),
                       own("lan.log", "LAN listener"), own("paddock-ports.log", "Port helper")]
            .compactMap { $0 }
        if !paddock.isEmpty { sections.append(LogSection(title: "Paddock", sources: paddock)) }

        // php-<v>.log holds PHP's errors; php-fpm-<v>.log is PHP-FPM's own. Newest version first.
        let versions = Set(names.compactMap { name -> PHPVersion? in
            guard name.hasPrefix("php-"), !name.hasPrefix("php-fpm-") else { return nil }
            return PHPVersion(String(name.dropFirst(4).dropLast(4)))
        }).union(names.compactMap { name -> PHPVersion? in
            guard name.hasPrefix("php-fpm-"), !name.hasSuffix(".out.log") else { return nil }
            return PHPVersion(String(name.dropFirst(8).dropLast(4)))
        })
        let php = versions.sorted(by: >).flatMap { v in
            [own("php-\(v).log", "PHP \(v) errors"), own("php-fpm-\(v).log", "PHP-FPM \(v)")].compactMap { $0 }
        }
        if !php.isEmpty { sections.append(LogSection(title: "PHP", sources: php)) }

        let services = (status?.services ?? []).compactMap { service -> LogSource? in
            let url = paths.serviceLog(service.id)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return LogSource(title: Messages.displayName(service.name) ?? service.id, url: url)
        }
        if !services.isEmpty { sections.append(LogSection(title: "Services", sources: services)) }

        for site in status?.sites ?? [] {
            let name = Messages.displayName(site.name) ?? site.name
            let tasks = (site.tasks?.tasks ?? []).compactMap { task -> LogSource? in
                guard fm.fileExists(atPath: task.logPath) else { return nil }
                return LogSource(title: Messages.displayName(task.name) ?? task.name, url: URL(fileURLWithPath: task.logPath))
            }
            if !tasks.isEmpty { sections.append(LogSection(title: "\(name): tasks", sources: tasks)) }
            let logs = siteLogs(in: URL(fileURLWithPath: site.path, isDirectory: true))
            if !logs.isEmpty { sections.append(LogSection(title: "\(name): logs", sources: logs)) }
        }
        return sections
    }

    /// A site's own logs: the regular `*.log` files directly in its `storage/logs` (a symlink is never
    /// followed: it could name any file), `laravel.log` first, then the most recently written, at most
    /// `siteLogLimit` in all.
    static func siteLogs(in site: URL) -> [LogSource] {
        let folder = site.appendingPathComponent("storage/logs", isDirectory: true)
        let fm = FileManager.default
        var found: [(name: String, modified: Date)] = []
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".log") {
            guard let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            found.append((name, attributes[.modificationDate] as? Date ?? .distantPast))
        }
        found.sort { a, b in
            if (a.name == "laravel.log") != (b.name == "laravel.log") { return a.name == "laravel.log" }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.name < b.name
        }
        return found.prefix(siteLogLimit).map {
            LogSource(title: Messages.displayName($0.name) ?? $0.name, url: folder.appendingPathComponent($0.name))
        }
    }
}
