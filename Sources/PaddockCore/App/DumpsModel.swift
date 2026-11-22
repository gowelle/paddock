import Combine
import Foundation

/// What listens for dumps: `DumpListener` in the app, a fake in tests.
public protocol DumpListening: AnyObject {
    func start() throws
    func stop()
}

extension DumpListener: DumpListening {}

/// Everything the Dumps window shows, and every action it takes. The views hold no logic. While the window is
/// open it listens for dumps and has PHP send them; when it closes it stops both, and `dump()` shows in the
/// page again.
@MainActor
public final class DumpsModel: ObservableObject {
    /// The dumps received, newest first; at most `limit`.
    @Published public private(set) var dumps: [Dump] = []
    @Published public private(set) var isListening = false
    /// Why dumps can't be received, when they can't.
    @Published public private(set) var problem: String?
    /// One quiet line about something received that could not be shown.
    @Published public private(set) var notice: String?
    /// The lines folded or unfolded by hand: `<dump>:<line>` -> unfolded.
    @Published public private(set) var folds: [String: Bool] = [:]

    /// How many dumps are kept; older ones go as newer ones arrive.
    public static let limit = 200
    /// Lines this deep and deeper start folded.
    public static let unfoldedDepth = 2

    public let port: Int
    private let makeListener: (Int, @escaping @Sendable (Data) -> Void) -> DumpListening
    private let route: @MainActor (Int?) async -> Void
    private let copyText: (@MainActor (String) -> Void)?
    private var listener: DumpListening?
    private var nextID = 0

    /// `route` tells the daemon where PHP sends its dumps (a port, or nil for nowhere); `copy` puts text on the
    /// pasteboard.
    public init(port: Int = DumpDestination.defaultPort,
                listener: @escaping (Int, @escaping @Sendable (Data) -> Void) -> DumpListening
                    = { DumpListener(port: $0, receive: $1) },
                route: @escaping @MainActor (Int?) async -> Void,
                copy: (@MainActor (String) -> Void)? = nil) {
        self.port = port
        self.makeListener = listener
        self.route = route
        self.copyText = copy
    }

    // MARK: - Derived, for the views

    /// What to say in place of the dumps while there are none.
    public var emptyText: String? {
        guard dumps.isEmpty else { return nil }
        if let problem { return problem }
        return isListening
            ? "Listening. Call dump() or dd() in a site and it shows here instead of in the page."
            : "Not listening."
    }

    /// `Listening on port 9912`.
    public var statusLine: String {
        if problem != nil { return "Not listening" }
        return isListening ? "Listening on port \(port)" : "Not listening"
    }

    /// Whether a line's members are on show: as folded or unfolded by hand, else by how deep it is.
    public func isUnfolded(_ node: DumpNode, in dump: Dump, depth: Int) -> Bool {
        folds["\(dump.id):\(node.id)"] ?? (depth < Self.unfoldedDepth)
    }

    // MARK: - Actions

    /// The window opened: listen, and have PHP send its dumps here.
    public func open() async {
        guard listener == nil else { return }
        let made = makeListener(port) { [weak self] line in
            // Read off the main thread; only the result comes back to it.
            let result = Result { try DumpDecoder.decode(line: line, id: 0) }
            Task { @MainActor in self?.received(result) }
        }
        do {
            try made.start()
        } catch DumpListenerError.portInUse(let port) {
            problem = "Paddock can't listen for dumps: port \(port) is in use. Quit the other dump server "
                + "(php artisan dump-server), then open this window again."
            return
        } catch DumpListenerError.failed(let reason) {
            problem = "Paddock can't listen for dumps: \(reason)"
            return
        } catch {
            problem = "Paddock can't listen for dumps: \(error.localizedDescription)"
            return
        }
        listener = made
        isListening = true
        problem = nil
        await route(port)
    }

    /// The window closed: stop listening, and let `dump()` show where it always did.
    public func close() async {
        guard let listener else {
            problem = nil
            return
        }
        listener.stop()
        self.listener = nil
        isListening = false
        await route(nil)
    }

    /// Makes the daemon's setting match: PHP is sending dumps somewhere nothing listens (the app quit with the
    /// window open), or isn't sending them here though this is listening (the daemon restarted).
    public func reconcile(daemonSendsTo: Int?) async {
        if isListening, daemonSendsTo != port { await route(port) }
        if !isListening, daemonSendsTo != nil { await route(nil) }
    }

    public func clear() {
        dumps = []
        folds = [:]
        notice = nil
    }

    /// Folds or unfolds a line's members.
    public func toggle(_ node: DumpNode, in dump: Dump, depth: Int) {
        guard node.isFoldable else { return }
        folds["\(dump.id):\(node.id)"] = !isUnfolded(node, in: dump, depth: depth)
    }

    /// Puts the dump on the pasteboard as text, as a terminal would show it.
    public func copy(_ dump: Dump) {
        copyText?(dump.text)
    }

    // MARK: - Private

    /// A line that arrived, decoded (or not): shown, newest first, while listening.
    public func received(_ result: Result<Dump, Error>) {
        guard isListening else { return }
        switch result {
        case .success(let dump):
            nextID += 1
            dumps.insert(Dump(id: nextID, time: dump.time, origin: dump.origin, file: dump.file, line: dump.line,
                              root: dump.root), at: 0)
            if dumps.count > Self.limit {
                let dropped = dumps.removeLast()
                folds = folds.filter { !$0.key.hasPrefix("\(dropped.id):") }
            }
        case .failure(DumpError.tooLarge):
            notice = "A dump was too large to show here."
        case .failure:
            // Something other than a dump was sent to the port: nothing to show.
            notice = "Something that isn't a dump was sent to port \(port)."
        }
    }
}
