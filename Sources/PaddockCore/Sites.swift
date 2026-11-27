import Foundation

public enum SiteName {
    /// Lowercase; each run of characters outside a-z0-9 becomes one "-"; edges trimmed. Nil if empty.
    public static func normalize(_ folder: String) -> String? {
        var out = ""
        var pendingDash = false
        for scalar in folder.lowercased().unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The one rule for several folder (or link) names that normalize to the same site name, used by
    /// both `SiteRegistry` and `RouterConfig` so they serve the same folder: an exactly named one
    /// (`raw == normalize(raw)`) wins, otherwise the first in case-insensitive lexicographic order.
    /// Returns `raws` in claiming order; the first to claim a name keeps it.
    public static func claimOrder(_ raws: [String]) -> [String] {
        raws.sorted { a, b in
            let (aExact, bExact) = (normalize(a) == a, normalize(b) == b)
            if aExact != bExact { return aExact }
            let (la, lb) = (a.lowercased(), b.lowercased())
            return la != lb ? la < lb : a < b
        }
    }
}

public struct Site: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case parked, linked }

    public let name: String
    public let path: String
    public let kind: Kind
    public var secured: Bool
    /// Effective PHP version: the pin if present, otherwise the default.
    public var php: PHPVersion
    public var pinned: Bool
    public let tld: String
    /// The owner chose this site for the LAN; only meaningful while the master switch is on.
    public var lan: Bool
    /// The site's tasks (`paddock.json`), as the daemon last saw them; nil without a file or from an older daemon.
    public var tasks: SiteTasksStatus?
    /// A sentence about the site itself when it has no tasks to show it under (its forwarding still active after a
    /// withdrawal Paddock couldn't apply); nil otherwise, and from an older daemon.
    public var notice: String?

    public var id: String { name }
    public var host: String { "\(name).\(tld)" }
    public var url: String { "\(secured ? "https" : "http")://\(host)" }

    public init(name: String, path: String, kind: Kind, secured: Bool, php: PHPVersion,
                pinned: Bool, tld: String = "test", lan: Bool = false, tasks: SiteTasksStatus? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.secured = secured
        self.php = php
        self.pinned = pinned
        self.tld = tld
        self.lan = lan
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case name, path, kind, secured, php, pinned, tld, lan, tasks, notice }

    /// As before tasks existed; `tasks` that can't be read are left out rather than costing the site.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(Kind.self, forKey: .kind)
        secured = try c.decode(Bool.self, forKey: .secured)
        php = try c.decode(PHPVersion.self, forKey: .php)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        tld = try c.decode(String.self, forKey: .tld)
        lan = (try? c.decodeIfPresent(Bool.self, forKey: .lan)) ?? false
        tasks = try? c.decodeIfPresent(SiteTasksStatus.self, forKey: .tasks)
        notice = try? c.decodeIfPresent(String.self, forKey: .notice)
    }
}

public struct SiteRegistry {
    private let state: State
    private let defaultPHP: PHPVersion
    private let settings: Settings
    private let fileManager: FileManager

    public init(state: State, defaultPHP: PHPVersion, settings: Settings = .current,
                fileManager: FileManager = .default) {
        self.state = state
        self.defaultPHP = defaultPHP
        self.settings = settings
        self.fileManager = fileManager
    }

    /// All served sites, sorted by name. Links win over parked folders; earlier parked paths win.
    public func sites() -> [Site] {
        var byName: [String: Site] = [:]

        // Two raw names may normalize alike: the shared rule picks one (as RouterConfig does).
        for rawName in SiteName.claimOrder(Array(state.links.keys)) {
            guard let target = state.links[rawName], let name = SiteName.normalize(rawName),
                  byName[name] == nil, isDirectory(target) else { continue }
            byName[name] = make(name: name, path: target, kind: .linked)
        }

        for parkedPath in state.parked {
            let parentURL = URL(fileURLWithPath: parkedPath, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: parentURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for folder in SiteName.claimOrder(entries.map(\.lastPathComponent)) {
                let path = parentURL.appendingPathComponent(folder, isDirectory: true).path
                guard !folder.hasPrefix("."), isDirectory(path),
                      let name = SiteName.normalize(folder), byName[name] == nil else { continue }
                byName[name] = make(name: name, path: path, kind: .parked)
            }
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    public func site(named name: String) -> Site? {
        sites().first { $0.name == name }
    }

    /// The site whose directory contains `directory` (or equals it); the deepest match wins.
    public func site(containing directory: String) -> Site? {
        let target = Self.canonical(directory)
        var best: (site: Site, length: Int)?
        for site in sites() {
            let root = Self.canonical(site.path)
            guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                continue
            }
            if best == nil || root.count > best!.length {
                best = (site, root.count)
            }
        }
        return best?.site
    }

    private func make(name: String, path: String, kind: Site.Kind) -> Site {
        let pin = state.phpPins[name]
        return Site(name: name, path: path, kind: kind, secured: state.secured.contains(name),
                    php: pin ?? defaultPHP, pinned: pin != nil, tld: settings.tld,
                    lan: state.lanSites.contains(name))
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
