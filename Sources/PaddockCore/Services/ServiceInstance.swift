import Foundation

/// One added service: a recipe's kind and version, its own folders and its saved ports. Kept in
/// `state.json`; the ports never move once chosen.
public struct ServiceInstance: Codable, Equatable, Identifiable, Sendable {
    /// `mail`, `postgres-18`, `postgres-18-2`: lowercase letters, digits and dashes.
    public let id: String
    public let kind: String
    public let version: String
    public var name: String
    /// Port name -> port.
    public var ports: [String: Int]
    /// Started when Paddock starts.
    public var autostart: Bool
    public let createdAt: Date

    public init(id: String, kind: String, version: String, name: String, ports: [String: Int], autostart: Bool,
                createdAt: Date) {
        self.id = id
        self.kind = kind
        self.version = version
        self.name = name
        self.ports = ports
        self.autostart = autostart
        self.createdAt = createdAt
    }

    public struct Identity: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// `[a-z0-9]` runs joined by single dashes: safe as a folder name and in a socket path.
    public static func isValidID(_ id: String) -> Bool {
        let runs = id.split(separator: "-", omittingEmptySubsequences: false)
        return !id.isEmpty && runs.allSatisfy { run in
            !run.isEmpty && run.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// The id and name of a new instance. The first of a kind is `<kind>` (`Mail`) when the kind has one
    /// version, else `<kind>-<major>` (`PostgreSQL 18`); later ones of the same id get `-2`, `-3`… (`(2)`).
    public static func newIdentity(kind: String, version: String, displayName: String, kindHasSeveralVersions: Bool,
                                   existing: Set<String>) -> Identity {
        let major = version.split(whereSeparator: { $0 == "." || $0 == "-" }).first.map(String.init) ?? version
        let baseID = kindHasSeveralVersions ? "\(kind)-\(major.lowercased())" : kind
        let baseName = kindHasSeveralVersions ? "\(displayName) \(major)" : displayName
        guard existing.contains(baseID) else { return Identity(id: baseID, name: baseName) }
        var n = 2
        while existing.contains("\(baseID)-\(n)") { n += 1 }
        return Identity(id: "\(baseID)-\(n)", name: "\(baseName) (\(n))")
    }

    /// The instance `typed` names: its id or its name, in any case.
    public static func find(_ typed: String, in instances: [ServiceInstance]) -> ServiceInstance? {
        let wanted = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return instances.first { $0.id == wanted } ?? instances.first { $0.name.lowercased() == wanted }
    }
}

/// What an instance is doing, as `status` reports it.
public enum ServiceState: Codable, Equatable, Sendable {
    case running
    /// Started, not ready yet.
    case starting
    case stopped
    /// Exited, or never became ready; its log says why.
    case crashed
    /// One of its saved ports is held by another program (named, as Paddock shows names).
    case portInUse(holder: String)
    /// Paddock can't run it (say, its recipe is no longer in the catalog).
    case unavailable(reason: String)
}

/// One instance as clients see it.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public let id, name, kind, version, displayName: String
    public var state: ServiceState
    public let ports: [String: Int]
    /// The `.env` lines for a Laravel app, rendered.
    public let env: [String]
    public let openURL: String?
    public let dataPath: String
    public let autostart: Bool
    /// The recipe's first port (`paddock service add` says "running on port …").
    public let mainPort: Int?

    public init(id: String, name: String, kind: String, version: String, displayName: String, state: ServiceState,
                ports: [String: Int], env: [String], openURL: String?, dataPath: String, autostart: Bool,
                mainPort: Int?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.version = version
        self.displayName = displayName
        self.state = state
        self.ports = ports
        self.env = env
        self.openURL = openURL
        self.dataPath = dataPath
        self.autostart = autostart
        self.mainPort = mainPort
    }
}
