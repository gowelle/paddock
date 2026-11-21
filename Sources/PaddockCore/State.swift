import Foundation

/// Durable user state, persisted as state.json. Everything else under the Paddock home is regenerated.
public struct State: Codable, Equatable, Sendable {
    public var parked: [String]
    /// Site name -> directory path.
    public var links: [String: String]
    public var secured: Set<String>
    /// Site name -> pinned PHP version.
    public var phpPins: [String: PHPVersion]
    public var defaultPHP: PHPVersion?
    public var previousResolver: String?
    /// Added services, in the order they were added.
    public var services: [ServiceInstance]

    public init(parked: [String] = [], links: [String: String] = [:], secured: Set<String> = [],
                phpPins: [String: PHPVersion] = [:], defaultPHP: PHPVersion? = nil,
                previousResolver: String? = nil, services: [ServiceInstance] = []) {
        self.parked = parked
        self.links = links
        self.secured = secured
        self.phpPins = phpPins
        self.defaultPHP = defaultPHP
        self.previousResolver = previousResolver
        self.services = services
    }

    private enum CodingKeys: String, CodingKey {
        case parked, links, secured, phpPins, defaultPHP, previousResolver, services
    }

    /// As before services existed, plus `services` (absent in older files: none).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parked = try c.decode([String].self, forKey: .parked)
        links = try c.decode([String: String].self, forKey: .links)
        secured = try c.decode(Set<String>.self, forKey: .secured)
        phpPins = try c.decode([String: PHPVersion].self, forKey: .phpPins)
        defaultPHP = try c.decodeIfPresent(PHPVersion.self, forKey: .defaultPHP)
        previousResolver = try c.decodeIfPresent(String.self, forKey: .previousResolver)
        services = try c.decodeIfPresent([ServiceInstance].self, forKey: .services) ?? []
    }

    /// First-run state: `~/Paddock` parked, expanded to an absolute path.
    public static var initial: State {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Paddock", isDirectory: true).path
        return State(parked: [dir])
    }
}

public enum StateError: Error, Equatable {
    /// state.json exists but couldn't be read; it is left untouched rather than overwritten.
    case unreadable(path: String, reason: String)
}

extension StateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Paddock can't read \(path) (\(reason)), so it changed nothing. Check the file's permissions."
        }
    }
}

public final class StateStore: @unchecked Sendable {
    let paths: Paths
    private let lock = NSLock()

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Never throws. Missing or empty file gives `State.initial`; an undecodable file is
    /// renamed to `state.json.corrupt-<unix timestamp>` and `State.initial` is returned. A file that
    /// exists but can't be read also reads as `State.initial`, but `update` then refuses to write.
    public func load() -> State {
        lock.lock()
        defer { lock.unlock() }
        switch loadLocked() {
        case .found(let state): return state
        case .missing, .unreadable: return .initial
        }
    }

    /// Throws `StateError.unreadable` (writing nothing) when state.json exists but can't be read, so a
    /// real file with links, pins and the saved resolver is never replaced by defaults.
    @discardableResult
    public func update(_ body: (inout State) -> Void) throws -> State {
        lock.lock()
        defer { lock.unlock() }
        var state: State
        switch loadLocked() {
        case .found(let found): state = found
        case .missing: state = .initial
        case .unreadable(let reason):
            throw StateError.unreadable(path: paths.stateFile.path, reason: reason)
        }
        body(&state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try data.write(to: paths.stateFile, options: .atomic)
        return state
    }

    private enum Loaded {
        case found(State)
        /// No file, an empty one, or a corrupt one that was moved aside.
        case missing
        case unreadable(reason: String)
    }

    private func loadLocked() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: paths.stateFile)
        } catch {
            // Only "there is no file" counts as missing.
            if !FileManager.default.fileExists(atPath: paths.stateFile.path) { return .missing }
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            return .unreadable(reason: underlying?.localizedDescription ?? error.localizedDescription)
        }
        if data.isEmpty { return .missing }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            return .found(state)
        }
        let aside = paths.home.appendingPathComponent(
            "state.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: paths.stateFile, to: aside)
        return .missing
    }
}
