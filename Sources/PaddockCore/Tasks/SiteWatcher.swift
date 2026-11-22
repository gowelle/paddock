import CoreServices
import Foundation

/// Watches a site's folder (FSEvents, file-level events) and says, debounced, when its code or its
/// `paddock.json` changed: one second of quiet after the last relevant change, but never more than five seconds
/// after the first, so a long checkout restarts tasks once, soon after it ends. Nothing is called after `stop`.
public final class SiteWatcher: @unchecked Sendable {
    /// What a path in the site is.
    public enum Kind: Equatable, Sendable {
        case ignored
        /// PHP code, the environment, or the locked dependencies.
        case code
        /// The site's own `paddock.json`.
        case tasksFile
    }

    /// What changed since the last call.
    public struct Changes: Equatable, Sendable {
        public var code = false
        public var tasksFile = false
        /// The watched folder itself changed (moved, deleted): the site may be gone.
        public var rootChanged = false
        /// When the code changed: the latest of its files' own times. Nil means now (a file that is gone, or
        /// events FSEvents lost, have no time of their own).
        public var codeChangedAt: Date?

        public init(code: Bool = false, tasksFile: Bool = false, rootChanged: Bool = false, codeChangedAt: Date? = nil) {
            self.code = code
            self.tasksFile = tasksFile
            self.rootChanged = rootChanged
            self.codeChangedAt = codeChangedAt
        }

        /// Both runs of changes as one: the later code time, or now if either has none.
        public func merged(with other: Changes) -> Changes {
            var result = Changes(code: code || other.code, tasksFile: tasksFile || other.tasksFile,
                                 rootChanged: rootChanged || other.rootChanged)
            switch (code, other.code) {
            case (true, true):
                if let mine = codeChangedAt, let theirs = other.codeChangedAt { result.codeChangedAt = max(mine, theirs) }
            case (true, false): result.codeChangedAt = codeChangedAt
            case (false, true): result.codeChangedAt = other.codeChangedAt
            case (false, false): break
            }
            return result
        }
    }

    /// The later of a file's modification and status-change times (a rename into place changes the latter);
    /// nil if it isn't there.
    public static func fileTime(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        func date(_ spec: timespec) -> Date { Date(timeIntervalSince1970: Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9) }
        return max(date(info.st_mtimespec), date(info.st_ctimespec))
    }

    /// Folders at the site's root FSEvents is told to leave out (fewer callbacks; `classify` still decides).
    public static let excludedFolders = ["vendor", "node_modules", ".git", "storage"]

    /// What a batch of events means. An event FSEvents flags as lost or coalesced (`MustScanSubDirs`,
    /// `UserDropped`, `KernelDropped`) counts as a code change whatever its path, since anything may have
    /// changed under it; the watched folder itself changing (`RootChanged`) too, and says so.
    public static func changes(for events: [(path: String, flags: FSEventStreamEventFlags)], root: String,
                               changedAt: (String) -> Date? = fileTime) -> Changes {
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                           | kFSEventStreamEventFlagKernelDropped)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var changes = Changes()
        for event in events {
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                changes = changes.merged(with: Changes(code: true, rootChanged: true))
                continue
            }
            if event.flags & lost != 0 {
                changes = changes.merged(with: Changes(code: true))
                continue
            }
            guard event.path.hasPrefix(prefix) else { continue }
            let relative = String(event.path.dropFirst(prefix.count))
            // A folder created or renamed into place (`mv app.new app`): its files changed, with no time of their own.
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                let moved = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
                if event.flags & moved != 0, isWatchedFolder(relative) { changes = changes.merged(with: Changes(code: true)) }
                continue
            }
            switch classify(relative) {
            case .code: changes = changes.merged(with: Changes(code: true, codeChangedAt: changedAt(event.path)))
            case .tasksFile: changes.tasksFile = true
            case .ignored: continue
            }
        }
        return changes
    }

    /// When a run of changes fires.
    public struct Debounce: Sendable {
        public let quiet: TimeInterval
        public let maximumWait: TimeInterval

        public init(quiet: TimeInterval, maximumWait: TimeInterval) {
            self.quiet = quiet
            self.maximumWait = maximumWait
        }

        public func fireTime(firstChange: Date, lastChange: Date) -> Date {
            min(lastChange.addingTimeInterval(quiet), firstChange.addingTimeInterval(maximumWait))
        }
    }

    public let folder: URL
    private let debounce: Debounce
    private let onChange: @Sendable (Changes) -> Void
    private let queue = DispatchQueue(label: "app.paddock.tasks.watch")
    // Only touched on `queue`:
    private var stream: FSEventStreamRef?
    private var pending = Changes()
    private var firstChange: Date?
    private var lastChange: Date?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lateCallbacks = 0

    public init(folder: URL, debounce: Debounce = Debounce(quiet: 1, maximumWait: 5),
                onChange: @escaping @Sendable (Changes) -> Void) {
        self.folder = URL(fileURLWithPath: SiteTasksFile.realPath(folder.path) ?? folder.path, isDirectory: true)
        self.debounce = debounce
        self.onChange = onChange
        queue.setSpecific(key: Self.onQueue, value: true)
    }

    deinit { stop() }

    // MARK: - The path filter

    /// Folders whose files are never the site's code (anywhere in the tree for `vendor` and `node_modules`).
    static let ignoredAnywhere: Set<String> = ["vendor", "node_modules"]
    /// Paths from the site's root that are never its code (the folder or file itself, and anything under it).
    static let ignoredPaths = ["storage", "bootstrap/cache", "public/build", "public/hot"]

    /// What a path relative to the site's root is, by its name alone (so a deleted or renamed-into-place file
    /// counts as much as an edited one).
    public static func classify(_ relative: String) -> Kind {
        if relative == SiteTasksFile.fileName { return .tasksFile }
        if ignoredPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return .ignored }
        let components = relative.split(separator: "/").map(String.init)
        guard let name = components.last else { return .ignored }
        for folder in components.dropLast() where folder.hasPrefix(".") || ignoredAnywhere.contains(folder) {
            return .ignored
        }
        if name.hasSuffix(".php") || name == ".env" || name.hasPrefix(".env.") || name == "composer.lock" {
            return .code
        }
        return .ignored
    }

    /// Whether a folder (relative to the site's root) can hold the site's code: not under an ignored path.
    static func isWatchedFolder(_ relative: String) -> Bool {
        guard !relative.isEmpty else { return false }
        if ignoredPaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return false }
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") || ignoredAnywhere.contains(String($0)) }
    }

    // MARK: - Running

    public func start() {
        queue.sync {
            guard stream == nil, !stopped else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<SiteWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                watcher.received((0..<count).compactMap { index in
                    (array[index] as? String).map { ($0, flags[index]) }
                })
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                                 | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
                return
            }
            let excluded = Self.excludedFolders.map { folder.appendingPathComponent($0).path }
            _ = FSEventStreamSetExclusionPaths(created, excluded as CFArray)
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Stops the stream and any pending change; returns once nothing more will be called.
    public func stop() {
        let work = {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
        if DispatchQueue.getSpecific(key: Self.onQueue) == true { work() } else { queue.sync(execute: work) }
    }

    private static let onQueue = DispatchSpecificKey<Bool>()

    public var isStopped: Bool { queue.sync { stopped } }

    /// Callbacks that arrived after `stop` (there should be none).
    public var callbacksAfterStop: Int { queue.sync { lateCallbacks } }

    /// On `queue`.
    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        guard !stopped else { lateCallbacks += 1; return }
        let changes = Self.changes(for: events.map { (path: $0.0, flags: $0.1) }, root: folder.path)
        guard changes.code || changes.tasksFile || changes.rootChanged else { return }
        pending = pending.merged(with: changes)
        let now = Date()
        if firstChange == nil { firstChange = now }
        lastChange = now
        schedule()
    }

    private func schedule() {
        guard let firstChange, let lastChange else { return }
        let fire = debounce.fireTime(firstChange: firstChange, lastChange: lastChange)
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.fire() }
            timer.resume()
            self.timer = timer
        }
        timer?.schedule(deadline: .now() + max(0, fire.timeIntervalSinceNow))
    }

    private func fire() {
        guard !stopped else { return }
        let changes = pending
        pending = Changes()
        firstChange = nil
        lastChange = nil
        onChange(changes)
    }
}
