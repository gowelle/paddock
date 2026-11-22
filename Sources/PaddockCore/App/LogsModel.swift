import Combine
import Foundation

/// Everything the Logs window shows, and every action it takes. The views hold no logic. It reads a log only
/// while the window shows, and only the one chosen.
@MainActor
public final class LogsModel: ObservableObject {
    /// The logs there are, grouped.
    @Published public private(set) var sections: [LogSection] = []
    /// The log on show (its path).
    @Published public private(set) var selection: String?
    /// What the chosen log says, oldest first; at most `entryLimit`.
    @Published public private(set) var entries: [LogEntry] = []
    /// Only entries mentioning this are shown.
    @Published public private(set) var filter = ""
    /// While paused, nothing new is added (it is caught up on when resumed).
    @Published public private(set) var isPaused = false
    /// The entries whose detail (a stack trace) is unfolded.
    @Published public private(set) var expanded: Set<Int> = []
    /// Counts what was added to the bottom, so the view can keep the newest in sight.
    @Published public private(set) var arrivals = 0
    /// Counts requests from elsewhere in the app to see a log, so a view that can open the window does.
    @Published public private(set) var openRequests = 0

    /// How many entries are kept; older ones go as newer ones arrive.
    public static let entryLimit = 3000
    /// Seconds between looks at the chosen log.
    public static let pollInterval: UInt64 = 1
    /// Every this many looks, the list of logs is read again.
    static let sectionsEvery = 5

    private let find: @MainActor () -> [LogSection]
    private let read: @Sendable (URL, LogPosition?) -> LogChunk
    private let reveal: (@MainActor (URL) -> Void)?
    private var position: LogPosition?
    private var parser = LogParser()
    private var watchers = 0
    private var task: Task<Void, Never>?
    private var ticks = 0

    /// `find` lists the logs (`LogCatalog.sections`); `read` reads one (`LogTail.read`); `reveal` shows a file
    /// in Finder.
    public init(find: @escaping @MainActor () -> [LogSection],
                read: @escaping @Sendable (URL, LogPosition?) -> LogChunk = { LogTail.read($0, after: $1) },
                reveal: (@MainActor (URL) -> Void)? = nil) {
        self.find = find
        self.read = read
        self.reveal = reveal
    }

    // MARK: - Derived, for the views

    public var selected: LogSource? {
        guard let selection else { return nil }
        return sections.lazy.flatMap(\.sources).first { $0.id == selection }
    }

    /// The entries to show: all of them, or those mentioning the filter.
    public var shown: [LogEntry] {
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty ? entries : entries.filter { $0.matches(wanted) }
    }

    /// What to say in place of the entries when there are none to show; nil otherwise.
    public var emptyText: String? {
        if sections.isEmpty { return "No logs yet. They appear here once Paddock has started." }
        guard selected != nil else { return "Choose a log to read it." }
        if entries.isEmpty { return "Nothing in this log yet." }
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty, shown.isEmpty { return "Nothing in this log mentions \u{201C}\(wanted)\u{201D}." }
        return nil
    }

    public func isExpanded(_ entry: LogEntry) -> Bool { expanded.contains(entry.id) }

    // MARK: - Actions

    /// Reads the list of logs again. The chosen log stays chosen while it is still listed; with none chosen,
    /// the first is.
    public func refreshSections() {
        let found = find()
        if found != sections { sections = found }
        let all = found.flatMap(\.sources)
        if let selection, !all.contains(where: { $0.id == selection }) { choose(nil) }
        if selection == nil, let first = all.first { choose(first.id) }
    }

    /// Shows another log, from its end.
    public func select(_ id: String?) async {
        guard id != selection else { return }
        choose(id)
        await poll()
    }

    /// Shows the log at `path` (a task's or a service's log, opened from elsewhere in the app); listed or not
    /// yet, it is chosen once the list has it.
    public func show(path: String) async {
        refreshSections()
        guard sections.flatMap(\.sources).contains(where: { $0.id == path }) else { return }
        await select(path)
    }

    /// Asked from another window (a task's or a service's Open Log): chooses that log and asks for the Logs
    /// window to come forward.
    public func request(path: String) async {
        await show(path: path)
        openRequests += 1
    }

    public func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
    }

    /// Stops adding new lines, or goes on and catches up.
    public func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused { await poll() }
    }

    /// Folds or unfolds an entry's detail.
    public func toggle(_ entry: LogEntry) {
        guard !entry.detail.isEmpty else { return }
        if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
    }

    /// Shows the chosen log's file in Finder.
    public func revealSelected() {
        if let source = selected { reveal?(source.url) }
    }

    /// Reads what the chosen log has gained (all of its end, the first time). Does nothing while paused.
    public func poll() async {
        guard !isPaused, let source = selected else { return }
        let id = source.id
        let read = self.read
        let from = position
        let chunk = await Task.detached(priority: .utility) { read(source.url, from) }.value
        // The answer to a log no longer on show, or to an earlier look than one already applied, is dropped.
        guard selection == id, position == from, !isPaused else { return }
        position = chunk.position
        if chunk.restarted {
            entries = []
            expanded = []
            parser = LogParser()
        }
        guard !chunk.lines.isEmpty else { return }
        var updated = entries
        parser.append(chunk.lines, to: &updated)
        if updated.count > Self.entryLimit {
            updated.removeFirst(updated.count - Self.entryLimit)
            let kept = Set(updated.map(\.id))
            if !expanded.isSubset(of: kept) { expanded.formIntersection(kept) }
        }
        entries = updated
        arrivals += 1
    }

    // MARK: - Watching

    /// Called when the Logs window appears; the first watcher starts the reading.
    public func beginWatching() {
        watchers += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollInterval * 1_000_000_000)
            }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        task?.cancel()
        task = nil
    }

    /// One look: the list of logs every few, the chosen log every time.
    func tick() async {
        if ticks % Self.sectionsEvery == 0 { refreshSections() }
        ticks += 1
        await poll()
    }

    // MARK: - Private

    private func choose(_ id: String?) {
        selection = id
        position = nil
        entries = []
        expanded = []
        parser = LogParser()
    }
}
