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

    public init(parked: [String] = [], links: [String: String] = [:], secured: Set<String> = [],
                phpPins: [String: PHPVersion] = [:], defaultPHP: PHPVersion? = nil,
                previousResolver: String? = nil) {
        self.parked = parked
        self.links = links
        self.secured = secured
        self.phpPins = phpPins
        self.defaultPHP = defaultPHP
        self.previousResolver = previousResolver
    }

    /// First-run state: `~/Paddock` parked, expanded to an absolute path.
    public static var initial: State {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Paddock", isDirectory: true).path
        return State(parked: [dir])
    }
}

public final class StateStore: @unchecked Sendable {
    private let paths: Paths
    private let lock = NSLock()

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Never throws. Missing or empty file gives `State.initial`; an undecodable file is
    /// renamed to `state.json.corrupt-<unix timestamp>` and `State.initial` is returned.
    public func load() -> State {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    public func update(_ body: (inout State) -> Void) throws -> State {
        lock.lock()
        defer { lock.unlock() }
        var state = loadLocked()
        body(&state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try data.write(to: paths.stateFile, options: .atomic)
        return state
    }

    private func loadLocked() -> State {
        guard let data = try? Data(contentsOf: paths.stateFile), !data.isEmpty else {
            return .initial
        }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        let aside = paths.home.appendingPathComponent(
            "state.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: paths.stateFile, to: aside)
        return .initial
    }
}
