import Foundation

/// One added service: a recipe's kind and series, the version it runs, its own folders and its saved
/// ports. Kept in `state.json`; the ports never move once chosen.
public struct ServiceInstance: Codable, Equatable, Identifiable, Sendable {
    /// `mail`, `postgres-18`, `mysql-8-4`, `postgres-18-2`: lowercase letters, digits and dashes.
    public let id: String
    public let kind: String
    /// The recipe series it belongs to (`18`). Empty when read from a file written before series existed;
    /// `ServiceManager` fills it in from the catalog.
    public var series: String
    /// The version that runs (and last ran) on its data; changes only once a newer one is ready.
    public var version: String
    public var name: String
    /// Port name -> port.
    public var ports: [String: Int]
    /// Started when Paddock starts.
    public var autostart: Bool
    public let createdAt: Date

    public init(id: String, kind: String, series: String, version: String, name: String, ports: [String: Int],
                autostart: Bool, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.series = series
        self.version = version
        self.name = name
        self.ports = ports
        self.autostart = autostart
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, kind, series, version, name, ports, autostart, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        series = try c.decodeIfPresent(String.self, forKey: .series) ?? ""
        version = try c.decode(String.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        ports = try c.decode([String: Int].self, forKey: .ports)
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? true
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public struct Identity: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// `[a-z0-9]` runs joined by single dashes, and not `bin` (the shared binaries' folder): safe as a
    /// folder name and in a socket path. Checked again for every id read back from `state.json`.
    public static func isValidID(_ id: String) -> Bool {
        let runs = id.split(separator: "-", omittingEmptySubsequences: false)
        return !id.isEmpty && id != "bin" && runs.allSatisfy { run in
            !run.isEmpty && run.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// The id and name of a new instance: `<kind>-<series, dots as dashes>` (`mysql-8-4`, `MySQL 8.4`), or
    /// `<kind>` (`Mail`) when the recipe keeps the series out of ids; later ones of the same id get `-2`,
    /// `-3`… (`(2)`). Data under an id therefore always belongs to one kind and series.
    public static func newIdentity(kind: String, series: String, displayName: String, seriesInID: Bool,
                                   existing: Set<String>) -> Identity {
        let baseID = seriesInID ? "\(kind)-\(series.replacingOccurrences(of: ".", with: "-"))" : kind
        let baseName = seriesInID ? "\(displayName) \(series)" : displayName
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

/// What an instance is doing, as `status` reports it. A state this build doesn't know (from a newer
/// daemon) reads as `unavailable(reason: "unknown state")`.
public enum ServiceState: Codable, Equatable, Sendable {
    case running
    /// Started, not ready yet.
    case starting
    case stopped
    /// Exited, or never became ready; its log says why.
    case crashed
    /// One of its saved ports is held by another program (named, as Paddock shows names).
    case portInUse(holder: String)
    /// Paddock can't run it (say, neither its recipe nor its binaries are here any more).
    case unavailable(reason: String)

    /// The wire form (the synthesized one), so decoding can fall back instead of failing.
    private enum Wire: Codable {
        case running, starting, stopped, crashed
        case portInUse(holder: String)
        case unavailable(reason: String)
    }

    public init(from decoder: Decoder) throws {
        switch try? Wire(from: decoder) {
        case .running?: self = .running
        case .starting?: self = .starting
        case .stopped?: self = .stopped
        case .crashed?: self = .crashed
        case .portInUse(let holder)?: self = .portInUse(holder: holder)
        case .unavailable(let reason)?: self = .unavailable(reason: reason)
        case nil: self = .unavailable(reason: "unknown state")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .running: wire = .running
        case .starting: wire = .starting
        case .stopped: wire = .stopped
        case .crashed: wire = .crashed
        case .portInUse(let holder): wire = .portInUse(holder: holder)
        case .unavailable(let reason): wire = .unavailable(reason: reason)
        }
        try wire.encode(to: encoder)
    }
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
    /// A sentence about its last add (say, that existing data was reused), until it is next stopped.
    public let notice: String?
    /// A newer version of its series that `paddock service update` would switch to.
    public let updateAvailable: String?
    /// Its series (`18`); nil from an older daemon.
    public let series: String?

    public init(id: String, name: String, kind: String, version: String, displayName: String, state: ServiceState,
                ports: [String: Int], env: [String], openURL: String?, dataPath: String, autostart: Bool,
                mainPort: Int?, notice: String? = nil, updateAvailable: String? = nil, series: String? = nil) {
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
        self.notice = notice
        self.updateAvailable = updateAvailable
        self.series = series
    }
}

/// Decodes a value when it can and nothing when it can't, so one bad element never fails a whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
