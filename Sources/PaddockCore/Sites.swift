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

    public var id: String { name }
    public var host: String { "\(name).\(tld)" }
    public var url: String { "\(secured ? "https" : "http")://\(host)" }

    public init(name: String, path: String, kind: Kind, secured: Bool, php: PHPVersion,
                pinned: Bool, tld: String = "test") {
        self.name = name
        self.path = path
        self.kind = kind
        self.secured = secured
        self.php = php
        self.pinned = pinned
        self.tld = tld
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

        for (rawName, target) in state.links {
            guard let name = SiteName.normalize(rawName), isDirectory(target) else { continue }
            // Two raw names may normalize alike; pick deterministically.
            if byName[name] != nil && rawName != name { continue }
            byName[name] = make(name: name, path: target, kind: .linked)
        }

        for parkedPath in state.parked {
            let parentURL = URL(fileURLWithPath: parkedPath, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: parentURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let folder = entry.lastPathComponent
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
                    php: pin ?? defaultPHP, pinned: pin != nil, tld: settings.tld)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
