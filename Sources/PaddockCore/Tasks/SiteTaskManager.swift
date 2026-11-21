import Darwin
import Foundation

public enum SiteTaskError: Error, Equatable, Sendable {
    case unknownSite(String)
    case noTasksFile(site: String)
    /// `reason` is already sanitised.
    case invalid(site: String, reason: String)
    case notApproved(site: String)
    case unknownTask(site: String, task: String)
    /// A command that would show other than it runs: the first such character, by position (in Unicode scalars,
    /// from 1) and code point.
    case notShowable(site: String, task: String, position: Int, codePoint: UInt32)
    /// The file's hash isn't the one the user was shown.
    case changedSinceShown(site: String)
    case alreadyRunning(site: String, task: String, pid: Int32)
    /// Processes an earlier run left in the task's group still run.
    case leftoverProcesses(site: String, task: String)
    case stillStopping(task: String)
    case couldNotStart(site: String, task: String, reason: String)
    case fileExists(site: String, path: String)
    case notLaravel(site: String)
    case couldNotWrite(site: String, reason: String)
    case shuttingDown
}

/// Runs the approved tasks of every site (`paddock.json`), each as `[shell, "-c", run]` in the site's folder
/// with the user's shell environment and Paddock's `bin` first on PATH, supervised in its own process group,
/// its output written by Paddock to a size-bounded log.
///
/// Nothing runs that the user hasn't approved: what runs is the approved definition kept in state.json, for the
/// folder it was approved for.
///
/// Decisions (what should run, what to stop) are made one at a time under a lock that is never held while
/// waiting: a stop (with its task's grace, up to 300 seconds) or the stop of an earlier daemon's orphan runs in
/// the background, side by side with the others, and the requests that asked for it wait for it outside the
/// lock. `statuses` never waits and never reads a file.
public final class SiteTaskManager: @unchecked Sendable {
    let paths: Paths
    let store: StateStore
    let supervisor: Supervisor
    private let captureEnvironment: @Sendable () -> ShellEnvironment
    private let sites: @Sendable () -> [Site]
    private let inspector: ServiceProcessInspector
    private let refreshInterval: TimeInterval?
    /// The longest a task's stop may take once the daemon is shutting down.
    let shutdownGrace: TimeInterval
    /// Multiplies the windows in which clean exits are counted (tests shorten them with the restart delays).
    private let timeScale: TimeInterval
    private let log: @Sendable (String) -> Void

    /// At daemon shutdown a task gets at most this long to stop (its `stopSeconds` may allow up to 300), so
    /// tasks and services, stopping side by side, fit inside the LaunchAgent's exit timeout.
    public static let shutdownGraceCap: TimeInterval = 60
    /// A task that exits with status 0 `exitedLimit` times within `exitedWindow` seconds, or `exitedLongLimit`
    /// times within `exitedLongWindow`, is left stopped: it isn't a command that keeps running.
    static let exitedLimit = 3
    static let exitedWindow: TimeInterval = 10
    static let exitedLongLimit = 10
    static let exitedLongWindow: TimeInterval = 600
    /// A task's log is rotated (one previous file kept) when it would pass this size.
    public static let logLimit: UInt64 = 5 * 1024 * 1024
    /// After a spawn, when the pid record is brought up to date with the program the shell handed over to.
    static let recordUpdates: [TimeInterval] = [0.5, 2, 10]
    /// After a launch, when Paddock looks at what the task listens on.
    static let listenerChecks: [TimeInterval] = [5, 30]

    /// Short-lived: held for decisions, never while a process is given its grace.
    private let operationLock = NSLock()
    // Only touched while holding `operationLock`:
    /// Process name -> what was started under it.
    private var launched: [String: Launched] = [:]
    private var cache: [String: CachedFile] = [:]
    private var nextGeneration = 1

    /// Guards everything below; held only for an instant, and never while calling the supervisor (whose exit
    /// callbacks take it).
    private let stateLock = NSLock()
    private var views: [String: SiteView] = [:]
    private var environment: ShellEnvironment?
    private var runtime: [String: Runtime] = [:]
    private var logs: [String: RotatingLog] = [:]
    /// Tasks that don't start with Paddock but the user started (until the daemon exits).
    private var startedByHand: Set<String> = []
    private var shutdownStarted: Date?
    private var timer: DispatchSourceTimer?
    private var reconcilePending = false
    /// Site name -> the watcher of its folder, for every approved site.
    private var watchers: [String: SiteWatcher] = [:]
    private let refreshQueue = DispatchQueue(label: "app.paddock.tasks.refresh")

    private struct SiteView {
        let name: String
        /// The site's folder, symlinks resolved.
        let folder: String
        let evaluation: TaskApproval.Evaluation
        let stopped: Set<String>
    }

    private enum Settled: Equatable {
        case exited
        case gaveUp(status: Int32)
    }

    private enum Held: Equatable {
        /// A live process the record names that Paddock can't prove its own.
        case process(Int32)
        /// Processes left in the recorded group, whose first process is gone.
        case leftovers
    }

    /// What Paddock knows of one task beyond what the supervisor says.
    private struct Runtime {
        var cleanExits: [Date] = []
        var settled: Settled?
        var lastExit: Int32?
        var held: Held?
        var startFailure: String?
        var flight: Flight?
        /// What a forced restart stopped, until the task is next stopped.
        var report: String?
        /// The code changed while it was stopping or starting: restart it once more when it is running.
        var changePending = false
        /// It listens beyond this Mac (the last check said so).
        var listening: String?
    }

    private struct Launched {
        let site: String
        let task: String
        let definition: TaskDefinition
        let folder: String
        /// Bumped at every launch, so late work tied to an earlier launch does nothing.
        let generation: Int

        func isSameWork(as other: Launched) -> Bool {
            site == other.site && task == other.task && definition == other.definition && folder == other.folder
        }
    }

    private struct CachedFile {
        let folder: String
        let stamp: SiteTasksFile.Stamp?
        let result: SiteTasksFile.LoadResult
    }

    /// A stop (or an orphan's stop) in progress, which requests can wait for.
    private final class Flight: @unchecked Sendable {
        enum Kind { case stop, reclaim }
        let kind: Kind
        let began = Date()
        let grace: TimeInterval
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var finished = false
        private var shortened = false

        init(kind: Kind, grace: TimeInterval) {
            self.kind = kind
            self.grace = grace
            group.enter()
        }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var wasCutShort: Bool { lock.lock(); defer { lock.unlock() }; return shortened }
        func cutShort() { lock.lock(); shortened = true; lock.unlock() }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            group.leave()
        }

        /// True if it finished within `timeout`.
        @discardableResult
        func wait(_ timeout: TimeInterval) -> Bool { group.wait(timeout: .now() + timeout) == .success }
    }

    /// `environment` asks the user's shell (`ShellEnvironment.forDaemon`); it is called when the first task
    /// starts and on every approval. `sites` lists the served sites. `refreshInterval` (nil: never) re-reads
    /// every `paddock.json` now and then. `timeScale` shortens the clean-exit windows (tests).
    public init(paths: Paths, store: StateStore, supervisor: Supervisor,
                environment: @escaping @Sendable () -> ShellEnvironment,
                sites: @escaping @Sendable () -> [Site], inspector: ServiceProcessInspector = .live,
                refreshInterval: TimeInterval? = 30, shutdownGrace: TimeInterval = SiteTaskManager.shutdownGraceCap,
                timeScale: TimeInterval = 1, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.store = store
        self.supervisor = supervisor
        captureEnvironment = environment
        self.sites = sites
        self.inspector = inspector
        self.refreshInterval = refreshInterval
        self.shutdownGrace = min(shutdownGrace, Self.shutdownGraceCap)
        self.timeScale = timeScale
        self.log = log
    }

    static func processName(site: String, task: String) -> String { "task/\(site)/\(task)" }

    public func logFile(site: String, task: String) -> URL { paths.taskLog(site: site, task: task) }

    /// The writer of a task's log (one per task, kept across its restarts).
    public func logWriter(site: String, task: String) -> RotatingLog {
        let name = Self.processName(site: site, task: task)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = logs[name] { return existing }
        let writer = RotatingLog(url: logFile(site: site, task: task), limit: Self.logLimit)
        logs[name] = writer
        return writer
    }

    private func recordFile(site: String, task: String) -> URL {
        paths.taskRun(site: site, task: task).appendingPathComponent("pid")
    }

    // MARK: - Lifecycle

    /// At daemon start: forgets pid records from an earlier boot (no process outlives a reboot), starts every
    /// approved task that starts with Paddock (stopping first, in the background, what a dead daemon left running
    /// when it is provably Paddock's own), and from then on re-reads the sites' files every `refreshInterval`
    /// seconds. The user's shell environment is read when the first task starts (or the user approves one):
    /// a Paddock without approved tasks never runs the shell.
    public func start() {
        removeRecordsFromEarlierBoots()
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        refreshLocked()
        guard let refreshInterval else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil, shutdownStarted == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    private func removeRecordsFromEarlierBoots() {
        guard let boot = ServiceProcessRecord.currentBoot() else { return }
        let root = paths.run.appendingPathComponent("tasks", isDirectory: true)
        let fm = FileManager.default
        for site in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for task in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(site).path)) ?? [] {
                let file = recordFile(site: site, task: task)
                if let record = ServiceProcessRecord.read(from: file), let made = record.bootSeconds, made != boot {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// From here on nothing starts again, and every stop in progress, or begun later, ends (with SIGKILL if need
    /// be) within `shutdownGrace` of now: the daemon is on its way out.
    func beginShutdown() {
        stateLock.lock()
        guard shutdownStarted == nil else { stateLock.unlock(); return }
        shutdownStarted = Date()
        let timer = self.timer
        self.timer = nil
        let inFlight = runtime.compactMap { name, state in state.flight.map { (name, $0) } }
        let watching = Array(watchers.values)
        watchers = [:]
        stateLock.unlock()
        timer?.cancel()
        for watcher in watching { watcher.stop() }
        for (name, flight) in inFlight where flight.kind == .stop {
            DispatchQueue.global().asyncAfter(deadline: .now() + shutdownGrace) { [weak self] in
                guard let self, !flight.isFinished else { return }
                flight.cutShort()
                self.supervisor.signal(name, SIGKILL)
            }
        }
    }

    private var isShuttingDown: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shutdownStarted != nil
    }

    /// Stops every task side by side, for the daemon's exit, all within `shutdownGrace`; a task cut short says so
    /// in its log. Returns once they have all stopped.
    public func stopAll() {
        beginShutdown()
        operationLock.lock()
        for (name, task) in launched { beginStopLocked(name, task) }
        stateLock.lock()
        let flights = runtime.values.compactMap(\.flight)
        stateLock.unlock()
        operationLock.unlock()
        for flight in flights { flight.wait(shutdownGrace + 10) }
    }

    // MARK: - Refreshing

    /// Re-reads every site's `paddock.json` (each only when it changed on disk) and brings the running tasks in
    /// line: an approved file's tasks run; a changed, removed or broken one keeps the approved version running;
    /// anything unapproved runs nothing; tasks of a site that is gone are stopped, and its approval is dropped a
    /// month later. Never waits for a stop.
    public func refresh() {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        refreshLocked()
    }

    /// Reads one site's `paddock.json` again for its status, and changes nothing else (what runs follows the
    /// approval, not the file).
    public func reloadFile(site name: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let site = sites().first(where: { $0.name == name }), let folder = SiteTasksFile.realPath(site.path) else {
            return
        }
        cache[name] = nil
        let result = load(site: name, folder: folder)
        let approved = store.load().taskApprovals[name]
        let evaluation = TaskApproval.evaluate(current: result, approved: approved, sitePath: folder)
        stateLock.lock()
        if approved != nil || result != .none {
            views[name] = SiteView(name: name, folder: folder, evaluation: evaluation,
                                   stopped: approved?.sitePath == folder ? approved?.stopped ?? [] : [])
        } else {
            views[name] = nil
        }
        stateLock.unlock()
    }

    /// A refresh soon, off the caller's thread (after a stop finished, so what waited for it can start).
    private func scheduleRefresh() {
        stateLock.lock()
        guard shutdownStarted == nil, !reconcilePending else { stateLock.unlock(); return }
        reconcilePending = true
        stateLock.unlock()
        refreshQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.reconcilePending = false
            self.stateLock.unlock()
            self.refresh()
        }
    }

    private func refreshLocked() {
        let now = Date()
        let state = store.load()
        var views: [String: SiteView] = [:]
        var present: [String: String] = [:]
        for site in sites() {
            guard let folder = SiteTasksFile.realPath(site.path) else { continue }
            present[site.name] = folder
            let result = load(site: site.name, folder: folder)
            let approved = state.taskApprovals[site.name]
            let evaluation = TaskApproval.evaluate(current: result, approved: approved, sitePath: folder)
            guard approved != nil || result != .none else { continue }
            let stopped = approved?.sitePath == folder ? approved?.stopped ?? [] : []
            views[site.name] = SiteView(name: site.name, folder: folder, evaluation: evaluation, stopped: stopped)
        }
        cache = cache.filter { present[$0.key] == $0.value.folder }

        // Approvals whose site is gone (or is now another folder) are kept a while, then dropped.
        var gone: [String] = []
        var back: [String] = []
        var expired: [String] = []
        for (name, approval) in state.taskApprovals {
            if present[name] == approval.sitePath {
                if approval.goneSince != nil { back.append(name) }
            } else if let since = approval.goneSince {
                if now.timeIntervalSince(since) > ApprovedTasks.keptAfterSiteGone { expired.append(name) }
            } else {
                gone.append(name)
            }
        }
        if !(gone.isEmpty && back.isEmpty && expired.isEmpty) {
            do {
                try store.update { state in
                    for name in gone { state.taskApprovals[name]?.goneSince = now }
                    for name in back { state.taskApprovals[name]?.goneSince = nil }
                    for name in expired { state.taskApprovals[name] = nil }
                }
            } catch {
                log("could not save site task approvals: \(error.localizedDescription)")
            }
            for name in gone { log("site \(name) is gone; its tasks were stopped and its approval is kept for 30 days") }
            for name in expired { log("dropped the task approval of site \(name), gone for 30 days") }
        }

        stateLock.lock()
        self.views = views
        stateLock.unlock()
        syncWatchers(views)
        reconcileLocked(views: views)
    }

    // MARK: - Watching the code

    /// The watcher of an approved site's folder, if any (tests).
    func watcher(site: String) -> SiteWatcher? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return watchers[site]
    }

    /// One watcher per approved site (its approval runs something), on the site's folder; the others stopped.
    private func syncWatchers(_ views: [String: SiteView]) {
        stateLock.lock()
        guard shutdownStarted == nil else { stateLock.unlock(); return }
        var stale: [SiteWatcher] = []
        var fresh: [SiteWatcher] = []
        for (site, watcher) in watchers {
            guard let view = views[site], view.evaluation.running != nil,
                  watcher.folder.path == view.folder else {
                stale.append(watcher)
                watchers[site] = nil
                continue
            }
        }
        for view in views.values where view.evaluation.running != nil && watchers[view.name] == nil {
            let site = view.name
            let watcher = SiteWatcher(folder: URL(fileURLWithPath: view.folder, isDirectory: true)) { [weak self] changes in
                // Never on the watcher's own queue: the manager may be stopping that watcher.
                self?.refreshQueue.async { self?.siteChanged(site, changes) }
            }
            watchers[site] = watcher
            fresh.append(watcher)
        }
        stateLock.unlock()
        for watcher in stale { watcher.stop() }
        for watcher in fresh { watcher.start() }
    }

    /// The site's `paddock.json` changed: read it again. Its code changed: restart (gracefully, in the
    /// background) every task with restart-on-change that isn't stopped by the user; a task given up on runs
    /// again (fixing the code is how it recovers); one still stopping or starting is restarted once more after.
    private func siteChanged(_ site: String, _ changes: SiteWatcher.Changes) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        if changes.tasksFile { refreshLocked() }
        guard changes.code else { return }
        stateLock.lock()
        let view = views[site]
        stateLock.unlock()
        guard let view, let running = view.evaluation.running else { return }
        for (task, definition) in running.tasks where definition.restartsOnChange && !view.stopped.contains(task) {
            let name = Self.processName(site: site, task: task)
            if flight(name) != nil {
                update { $0[name, default: Runtime()].changePending = true }
                continue
            }
            let gaveUp: Bool
            if case .gaveUp? = settledState(name) { gaveUp = true } else { gaveUp = supervisor.hasGivenUp(name) }
            if gaveUp { clearSettled(name) }
            if let launch = launched[name] {
                if case .stopped = supervisor.status(name), !gaveUp { continue }
                beginStopLocked(name, launch, note: Messages.taskRestartingForChange)
            }
        }
        reconcileLocked(views: views)
    }

    private func settledState(_ name: String) -> Settled? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime[name]?.settled
    }

    /// Five and thirty seconds after a launch (and only for that launch): whether the task listens on anything
    /// but 127.0.0.1 or [::1]. It is warned, not stopped; a check that can't list the listeners warns nothing.
    private func checkListeners(_ name: String, generation: Int) {
        operationLock.lock()
        guard launched[name]?.generation == generation, case .running(let pid) = supervisor.status(name) else {
            operationLock.unlock()
            return
        }
        operationLock.unlock()
        let addresses = try? ServiceManager.listeningAddresses(processGroup: pid, runner: SystemCommandRunner())
        let warning = addresses?.first { !ServiceManager.isLoopback($0) }
            .map { Messages.listeningEverywhere(port: SiteWatcher.port(of: $0) ?? 0) }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard launched[name]?.generation == generation else { return }
        update { $0[name, default: Runtime()].listening = warning }
    }

    /// The file's last reading, read again only when its stamp changed.
    private func load(site: String, folder: String) -> SiteTasksFile.LoadResult {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let stamp = SiteTasksFile.stamp(siteFolder: url)
        if let cached = cache[site], cached.folder == folder, cached.stamp == stamp { return cached.result }
        let result = stamp == nil ? .none : SiteTasksFile.load(siteFolder: url)
        cache[site] = CachedFile(folder: folder, stamp: stamp, result: result)
        return result
    }

    /// Begins stopping what should no longer run (unapproved, removed from the definition, its site gone,
    /// stopped by the user, or a definition that changed) and starts what should run and doesn't. Anything
    /// still stopping is left to the end of its stop (which refreshes again).
    private func reconcileLocked(views: [String: SiteView]) {
        stateLock.lock()
        let byHand = startedByHand
        let settled = runtime.compactMapValues(\.settled)
        stateLock.unlock()
        var wanted: [String: Launched] = [:]
        for view in views.values {
            guard let running = view.evaluation.running else { continue }
            for (task, definition) in running.tasks {
                let name = Self.processName(site: view.name, task: task)
                guard !view.stopped.contains(task), definition.startsWithPaddock || byHand.contains(name),
                      settled[name] == nil else { continue }
                wanted[name] = Launched(site: view.name, task: task, definition: definition, folder: view.folder,
                                        generation: 0)
            }
        }
        for (name, task) in launched where !(wanted[name].map { $0.isSameWork(as: task) } ?? false) {
            let siteGone = views[task.site] == nil || views[task.site]?.folder != task.folder
            beginStopLocked(name, task, note: siteGone ? Messages.taskSiteGone : nil)
        }
        update { runtime in
            for (name, state) in runtime where wanted[name] == nil && state.held != nil { runtime[name]?.held = nil }
        }
        for (name, task) in wanted.sorted(by: { $0.key < $1.key }) where flight(name) == nil {
            guard launched[name] != nil else {
                prepareLaunchLocked(name, task)
                continue
            }
            switch supervisor.status(name) {
            case .running:
                break
            case .crashed(let status):
                if supervisor.hasGivenUp(name) {
                    update { $0[name, default: Runtime()].settled = $0[name]?.settled ?? .gaveUp(status: status) }
                }
            case .stopped:
                launched[name] = nil
                prepareLaunchLocked(name, task)
            }
        }
    }

    // MARK: - Starting

    /// Starts the task unless a pid record says something of an earlier run is still there: an orphan that is
    /// provably Paddock's own is stopped first (in the background; the task starts after); a process that
    /// isn't provably ours, or processes left in the recorded group, are left alone and the task doesn't start.
    private func prepareLaunchLocked(_ name: String, _ task: Launched) {
        let file = recordFile(site: task.site, task: task.task)
        if let record = ServiceProcessRecord.read(from: file) {
            if let made = record.bootSeconds, let boot = ServiceProcessRecord.currentBoot(), made != boot {
                try? FileManager.default.removeItem(at: file)
            } else if case .running(let pid) = supervisor.status(name), pid == record.pid {
                return
            } else {
                switch record.identity(belongs: { [inspector] pid in
                    inspector.workingDirectory(pid).flatMap(SiteTasksFile.realPath) == task.folder
                }) {
                case .runningButNotOurs:
                    log("task \(task.site)/\(task.task): pid \(record.pid) is still running but was not started by this "
                        + "Paddock; leaving it alone")
                    update { $0[name, default: Runtime()].held = .process(record.pid) }
                    return
                case .orphan:
                    beginReclaimLocked(name, task, record)
                    return
                case .gone:
                    if !leftovers(of: record, in: task.folder).isEmpty {
                        log("task \(task.site)/\(task.task): processes left from an earlier run are still running; "
                            + "leaving them alone")
                        update { $0[name, default: Runtime()].held = .leftovers }
                        return
                    }
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        update { $0[name, default: Runtime()].held = nil }
        launchLocked(name, task)
    }

    private func launchLocked(_ name: String, _ task: Launched) {
        let environment = environmentLocked()
        let writer = logWriter(site: task.site, task: task.task)
        let record = recordFile(site: task.site, task: task.task)
        do {
            try ensureRunFolder(record.deletingLastPathComponent())
        } catch {
            update { $0[name, default: Runtime()].startFailure = error.localizedDescription }
            return
        }
        let generation = nextGeneration
        nextGeneration += 1
        let launch = Launched(site: task.site, task: task.task, definition: task.definition, folder: task.folder,
                              generation: generation)
        var spec = ProcessSpec(
            name: name, executable: URL(fileURLWithPath: environment.shell), arguments: ["-c", task.definition.run],
            environment: environment.forTasks(paths: paths), logFile: writer.url, stopSignal: SIGTERM,
            stopGrace: TimeInterval(task.definition.stopGrace), inheritsEnvironment: false,
            didSpawn: { [weak self] pid in
                if let live = ServiceProcessRecord.live(pid: pid) { try? live.write(to: record) }
                for delay in Self.recordUpdates {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self?.updateRecord(name, generation: generation)
                    }
                }
            })
        spec.output = writer
        spec.workingDirectory = URL(fileURLWithPath: task.folder, isDirectory: true)
        spec.exitDecision = { [weak self] status in self?.exitDecision(name, status: status) ?? .stop }
        spec.didExit = { [weak self] status, restarting in
            self?.didExit(name, site: task.site, task: task.task, status: status, restarting: restarting)
        }
        writer.append(Self.noteLine("Starting."))
        do {
            try supervisor.start(spec)
            launched[name] = launch
            var changedMeanwhile = false
            update {
                $0[name, default: Runtime()].startFailure = nil
                $0[name]?.listening = nil
                changedMeanwhile = $0[name]?.changePending ?? false
                $0[name]?.changePending = false
            }
            for delay in Self.listenerChecks {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.checkListeners(name, generation: generation)
                }
            }
            // The code changed again while it was restarting: once more, so it runs the newest code.
            if changedMeanwhile { beginStopLocked(name, launch, note: Messages.taskRestartingForChange) }
        } catch {
            update { $0[name, default: Runtime()].startFailure = Messages.taskCouldNotRun(shell: environment.shell) }
            log("task \(task.site)/\(task.task) could not be started: \(error)")
        }
    }

    /// The policy for a task's exits, asked by the supervisor (while it is busy): an error is restarted with
    /// backoff and counts toward the supervisor's give-up; a clean exit (status 0) is restarted with backoff but
    /// never counts as a failure, unless the task has finished `exitedLimit` times within `exitedWindow` seconds or
    /// `exitedLongLimit` times within `exitedLongWindow`: then it is left stopped.
    private func exitDecision(_ name: String, status: Int32) -> ExitDecision {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = runtime[name] ?? Runtime()
        defer { runtime[name] = state }
        state.lastExit = status
        guard status == 0 else { return .restart }
        let now = Date()
        state.cleanExits = state.cleanExits.filter { now.timeIntervalSince($0) < Self.exitedLongWindow * timeScale } + [now]
        let recent = state.cleanExits.filter { now.timeIntervalSince($0) < Self.exitedWindow * timeScale }.count
        if recent >= Self.exitedLimit || state.cleanExits.count >= Self.exitedLongLimit {
            state.settled = .exited
            return .stop
        }
        return .restartUncounted(after: Supervisor.backoff(afterFailures: state.cleanExits.count))
    }

    private func didExit(_ name: String, site: String, task: String, status: Int32, restarting: Bool) {
        let writer = logWriter(site: site, task: task)
        if restarting {
            writer.append(Self.noteLine("Exited with status \(status); restarting."))
        } else if status == 0 {
            writer.append(Self.noteLine(Messages.taskKeepsFinishing(task: task)))
        } else {
            update { $0[name, default: Runtime()].settled = .gaveUp(status: status) }
            writer.append(Self.noteLine(Messages.taskGaveUp(status: status, task: task)))
        }
    }

    // MARK: - Stopping

    /// Begins stopping a launched task in the background with its grace (shortened, when the daemon is shutting
    /// down, to what is left of `shutdownGrace`). The stop's flight is what requests wait for.
    private func beginStopLocked(_ name: String, _ task: Launched, note: String? = nil) {
        launched[name] = nil
        let allowed = TimeInterval(task.definition.stopGrace)
        stateLock.lock()
        var grace = allowed
        if let started = shutdownStarted { grace = max(0, min(allowed, shutdownGrace - Date().timeIntervalSince(started))) }
        let flight = Flight(kind: .stop, grace: grace)
        runtime[name, default: Runtime()].flight = flight
        runtime[name]?.report = nil
        stateLock.unlock()
        let writer = logWriter(site: task.site, task: task.task)
        let record = recordFile(site: task.site, task: task.task)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let outcome = self.supervisor.stop(name, grace: grace)
            try? FileManager.default.removeItem(at: record)
            if let note { writer.append(Self.noteLine(note)) }
            if flight.wasCutShort || (outcome == .killed && grace < allowed) {
                let note = Messages.taskCutShort(after: Int(Date().timeIntervalSince(flight.began).rounded()),
                                                 allowed: task.definition.stopGrace)
                writer.append(Self.noteLine(note))
                self.log("task \(task.site)/\(task.task): \(note)")
            }
            self.endFlight(name, flight)
        }
    }

    /// Stops an earlier daemon's orphan (provably ours) in the background: SIGTERM to its group, its grace (cut
    /// to the shutdown deadline if the daemon is exiting), then SIGKILL. The task starts when it is gone.
    private func beginReclaimLocked(_ name: String, _ task: Launched, _ record: ServiceProcessRecord) {
        let grace = TimeInterval(task.definition.stopGrace)
        let flight = Flight(kind: .reclaim, grace: grace)
        update { $0[name, default: Runtime()].flight = flight }
        log("stopping task \(task.site)/\(task.task) (process group \(record.pgid)), left running by an earlier Paddock")
        let file = recordFile(site: task.site, task: task.task)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let pgid = record.pgid
            kill(-pgid, SIGTERM)
            while kill(-pgid, 0) == 0 {
                if Date() >= self.deadline(of: flight) {
                    kill(-pgid, SIGKILL)
                    let end = Date().addingTimeInterval(5)
                    while kill(-pgid, 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? FileManager.default.removeItem(at: file)
            self.endFlight(name, flight)
        }
    }

    /// When a flight's grace ends: its own, or the shutdown deadline if that comes first.
    private func deadline(of flight: Flight) -> Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        let own = flight.began.addingTimeInterval(flight.grace)
        guard let started = shutdownStarted else { return own }
        return min(own, started.addingTimeInterval(shutdownGrace))
    }

    private func endFlight(_ name: String, _ flight: Flight) {
        update { runtime in
            if runtime[name]?.flight === flight { runtime[name]?.flight = nil }
        }
        flight.finish()
        scheduleRefresh()
    }

    private func flight(_ name: String) -> Flight? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime[name]?.flight
    }

    /// Waits (outside every lock) for flights, side by side: each at most its grace and a few seconds more.
    private func wait(for flights: [Flight]) {
        for flight in flights { flight.wait(flight.grace + 10) }
    }

    // MARK: - Orphans

    /// The processes of the recorded group that are provably left from that run: started no earlier than the
    /// recorded process, in the same boot (the record must say which), working in the site's folder, and this
    /// user's. Nothing else is ever counted, or signalled.
    private func leftovers(of record: ServiceProcessRecord, in folder: String) -> [Int32] {
        guard let made = record.bootSeconds, made == ServiceProcessRecord.currentBoot(),
              let members = ServiceProcessRecord.members(ofGroup: record.pgid) else { return [] }
        return members.filter { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(),
                  getpgid(pid) == record.pgid else { return false }
            let started = (Int64(info.pbi_start_tvsec), Int64(info.pbi_start_tvusec))
            guard started >= (record.startSeconds, record.startMicroseconds),
                  let directory = inspector.workingDirectory(pid).flatMap(SiteTasksFile.realPath) else { return false }
            return directory == folder || directory.hasPrefix(folder + "/")
        }
    }

    /// Brings a running task's pid record up to date: the shell usually hands over to the command (`exec`), so
    /// the program recorded at spawn changes. Only for the same launch and the very process recorded.
    private func updateRecord(_ name: String, generation: Int) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let task = launched[name], task.generation == generation,
              case .running(let pid) = supervisor.status(name) else { return }
        let file = recordFile(site: task.site, task: task.task)
        guard let recorded = ServiceProcessRecord.read(from: file), recorded.pid == pid,
              let now = ServiceProcessRecord.live(pid: pid), now.startSeconds == recorded.startSeconds,
              now.startMicroseconds == recorded.startMicroseconds, !now.isSameProgram(as: recorded) else { return }
        try? now.write(to: file)
    }

    /// `run/tasks/<site>/<task>`, owner-only like the rest of `run/`.
    private func ensureRunFolder(_ folder: URL) throws {
        let fm = FileManager.default
        var current = paths.run
        for component in ["tasks", folder.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent] {
            current = current.appendingPathComponent(component, isDirectory: true)
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        }
    }

    // MARK: - Requests

    /// Approves the site's `paddock.json` as it is now, if it still has the hash the user was shown, and starts
    /// its tasks. Refuses a file with a command that can't be shown as it runs. Doesn't wait for tasks of an
    /// earlier approved version to stop: the new ones start when they have.
    @discardableResult
    public func approve(site name: String, hash: String) throws -> SiteTasksStatus {
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        _ = try approvable(site: name, hash: hash)
        let captured = captureEnvironment()
        log("site tasks: \(captured.description)")
        operationLock.lock()
        defer { operationLock.unlock() }
        let (folder, file) = try approvable(site: name, hash: hash)
        update { _ in self.environment = captured }
        try store.update { state in
            let previous = state.taskApprovals[name]
            let stopped = previous?.sitePath == folder ? previous!.stopped.intersection(file.tasks.keys) : []
            state.taskApprovals[name] = ApprovedTasks(hash: hash, file: file, sitePath: folder, stopped: stopped)
        }
        clearSettled(site: name)
        log("approved the tasks of site \(name): \(file.tasks.keys.sorted().joined(separator: ", "))")
        refreshLocked()
        return statuses()[name] ?? SiteTasksStatus(approval: .approved, tasks: [], pending: [], pendingHash: nil, notice: nil)
    }

    /// The site's folder and current file, if it can be approved with `hash`.
    private func approvable(site name: String, hash: String) throws -> (String, SiteTasksFile) {
        let folder = try folder(of: name)
        switch SiteTasksFile.load(siteFolder: URL(fileURLWithPath: folder, isDirectory: true)) {
        case .none: throw SiteTaskError.noTasksFile(site: name)
        case .invalid(let reason): throw SiteTaskError.invalid(site: name, reason: reason)
        case .file(let current, let currentHash):
            guard currentHash == hash else { throw SiteTaskError.changedSinceShown(site: name) }
            for task in current.tasks.keys.sorted() {
                if let (position, codePoint) = Messages.unshowableCharacter(in: current.tasks[task]!.run) {
                    throw SiteTaskError.notShowable(site: name, task: task, position: position, codePoint: codePoint)
                }
            }
            return (folder, current)
        }
    }

    /// Stops the site's tasks (side by side, each with its grace) and withdraws its approval; returns once they
    /// have stopped.
    public func revoke(site name: String) throws {
        operationLock.lock()
        guard sites().contains(where: { $0.name == name }) || store.load().taskApprovals[name] != nil else {
            operationLock.unlock()
            throw SiteTaskError.unknownSite(name)
        }
        do { try store.update { $0.taskApprovals[name] = nil } } catch { operationLock.unlock(); throw error }
        let prefix = Self.processName(site: name, task: "")
        update { _ in self.startedByHand = self.startedByHand.filter { !$0.hasPrefix(prefix) } }
        clearSettled(site: name)
        refreshLocked()
        let flights = siteFlights(name)
        operationLock.unlock()
        wait(for: flights)
    }

    /// Starts one approved task (and forgets that the user stopped it). If it is still stopping, starts it once
    /// it has stopped.
    public func start(site name: String, task: String) throws {
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        let process = Self.processName(site: name, task: task)
        operationLock.lock()
        do {
            refreshLocked()
            _ = try definition(site: name, task: task)
            try setStopped(false, site: name, task: task)
        } catch { operationLock.unlock(); throw error }
        clearSettled(process)
        update { _ in self.startedByHand.insert(process) }
        let pending = flight(process)
        operationLock.unlock()
        if let pending { wait(for: [pending]) }
        operationLock.lock()
        refreshLocked()
        operationLock.unlock()
        try checkStarted(process, site: name, task: task)
    }

    /// Stops one task, and remembers (across daemon restarts) not to start it until the user does. Returns once
    /// it has stopped, or after its grace (and SIGKILL) at most.
    public func stop(site name: String, task: String) throws {
        let process = Self.processName(site: name, task: task)
        operationLock.lock()
        do {
            refreshLocked()
            _ = try definition(site: name, task: task)
            try setStopped(true, site: name, task: task)
        } catch { operationLock.unlock(); throw error }
        if let running = launched[process] { beginStopLocked(process, running, note: "Stopped by you.") }
        refreshLocked()
        let pending = flight(process)
        operationLock.unlock()
        if let pending, !pending.wait(pending.grace + 10) { throw SiteTaskError.stillStopping(task: task) }
    }

    /// Stops the task and starts it again (also when it had been stopped, or given up on). With `force`, first
    /// stops the processes an earlier run left in its recorded group (only those: same group, started no earlier,
    /// same boot, in the site's folder, this user's) and says which in the task's warning.
    public func restart(site name: String, task: String, force: Bool = false) throws {
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        let process = Self.processName(site: name, task: task)
        operationLock.lock()
        let folder: String
        do {
            refreshLocked()
            _ = try definition(site: name, task: task)
            try setStopped(false, site: name, task: task)
            folder = try self.folder(of: name)
        } catch { operationLock.unlock(); throw error }
        if let running = launched[process] { beginStopLocked(process, running, note: "Restarting.") }
        clearSettled(process)
        update { _ in self.startedByHand.insert(process) }
        let pending = flight(process)
        operationLock.unlock()
        if let pending { wait(for: [pending]) }
        if force { stopLeftovers(process, site: name, task: task, folder: folder) }
        operationLock.lock()
        refreshLocked()
        operationLock.unlock()
        try checkStarted(process, site: name, task: task)
    }

    private func stopLeftovers(_ process: String, site: String, task: String, folder: String) {
        let file = recordFile(site: site, task: task)
        var stopped: [Int32] = []
        if let record = ServiceProcessRecord.read(from: file) {
            stopped = leftovers(of: record, in: folder).sorted()
            for pid in stopped { kill(pid, SIGKILL) }
            let end = Date().addingTimeInterval(5)
            while stopped.contains(where: { kill($0, 0) == 0 }) && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            try? FileManager.default.removeItem(at: file)
        }
        let report = Messages.leftoversStopped(task: task, pids: stopped)
        logWriter(site: site, task: task).append(Self.noteLine(report))
        log("task \(site)/\(task): \(report)")
        update {
            $0[process, default: Runtime()].held = nil
            $0[process]?.report = report
        }
    }

    /// Writes the starter `paddock.json` into a Laravel site that has none (never over one, never through a
    /// link), and returns where.
    @discardableResult
    public func writeStarter(site name: String) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        let folder = URL(fileURLWithPath: try self.folder(of: name), isDirectory: true)
        guard let text = SiteTasksFile.starter(forSiteAt: folder) else { throw SiteTaskError.notLaravel(site: name) }
        let file = folder.appendingPathComponent(SiteTasksFile.fileName)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw SiteTaskError.fileExists(site: name, path: file.path) }
            throw SiteTaskError.couldNotWrite(site: name, reason: String(cString: strerror(errno)))
        }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        guard written == bytes.count else { throw SiteTaskError.couldNotWrite(site: name, reason: "short write") }
        refreshLocked()
        return file
    }

    private func folder(of name: String) throws -> String {
        guard let site = sites().first(where: { $0.name == name }), let folder = SiteTasksFile.realPath(site.path) else {
            throw SiteTaskError.unknownSite(name)
        }
        return folder
    }

    /// The task's approved definition, or why there is none.
    private func definition(site name: String, task: String) throws -> TaskDefinition {
        guard sites().contains(where: { $0.name == name }) else { throw SiteTaskError.unknownSite(name) }
        stateLock.lock()
        let view = views[name]
        stateLock.unlock()
        guard let view else { throw SiteTaskError.noTasksFile(site: name) }
        guard let running = view.evaluation.running else {
            switch view.evaluation.approval {
            case .invalid(let reason): throw SiteTaskError.invalid(site: name, reason: reason)
            case .none: throw SiteTaskError.noTasksFile(site: name)
            default: throw SiteTaskError.notApproved(site: name)
            }
        }
        guard let definition = running.tasks[task] else { throw SiteTaskError.unknownTask(site: name, task: task) }
        return definition
    }

    private func setStopped(_ stopped: Bool, site: String, task: String) throws {
        try store.update { state in
            if stopped { state.taskApprovals[site]?.stopped.insert(task) } else { state.taskApprovals[site]?.stopped.remove(task) }
        }
    }

    private func siteFlights(_ site: String) -> [Flight] {
        let prefix = Self.processName(site: site, task: "")
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime.filter { $0.key.hasPrefix(prefix) }.compactMap(\.value.flight)
    }

    private func checkStarted(_ process: String, site: String, task: String) throws {
        stateLock.lock()
        let state = runtime[process]
        stateLock.unlock()
        switch state?.held {
        case .process(let pid)?: throw SiteTaskError.alreadyRunning(site: site, task: task, pid: pid)
        case .leftovers?: throw SiteTaskError.leftoverProcesses(site: site, task: task)
        case nil: break
        }
        if let failure = state?.startFailure { throw SiteTaskError.couldNotStart(site: site, task: task, reason: failure) }
    }

    // MARK: - Reporting

    /// Every site with a `paddock.json` or an approval, by name. Never waits for a change in progress.
    public func statuses() -> [String: SiteTasksStatus] {
        stateLock.lock()
        let views = self.views
        let environment = self.environment
        let runtime = self.runtime
        let byHand = startedByHand
        stateLock.unlock()

        var result: [String: SiteTasksStatus] = [:]
        for view in views.values {
            let evaluation = view.evaluation
            var tasks: [TaskStatus] = []
            if let running = evaluation.running {
                for name in running.tasks.keys.sorted() {
                    let definition = running.tasks[name]!
                    let process = Self.processName(site: view.name, task: name)
                    let state = runtime[process] ?? Runtime()
                    let (taskState, warning) = describe(process, task: name, definition: definition, state: state,
                                                        stoppedByUser: view.stopped.contains(name),
                                                        startedByHand: byHand.contains(process))
                    tasks.append(TaskStatus(name: name, run: Messages.shownCommand(definition.run), state: taskState,
                                            restartOnChange: definition.restartsOnChange,
                                            logPath: logFile(site: view.name, task: name).path,
                                            warning: state.report ?? warning ?? state.listening))
                }
            } else if let pending = evaluation.pending {
                tasks = pending.tasks.keys.sorted().map { name in
                    TaskStatus(name: name, run: Messages.shownCommand(pending.tasks[name]!.run), state: .waitingForApproval,
                               restartOnChange: pending.tasks[name]!.restartsOnChange,
                               logPath: logFile(site: view.name, task: name).path, warning: nil)
                }
            }
            let showsPending = evaluation.approval == .needsApproval || evaluation.approval == .changed
            let pending = showsPending ? evaluation.pending : nil
            var notices: [String] = []
            if evaluation.approval == .changed {
                if let problem = evaluation.problem {
                    notices.append(Messages.tasksFileBroken(site: view.name, reason: problem))
                } else if pending == nil {
                    notices.append(Messages.tasksFileRemoved(site: view.name))
                } else {
                    notices.append(Messages.tasksChanged(site: view.name))
                }
            }
            if let pending {
                for task in pending.tasks.keys.sorted() {
                    guard let (position, codePoint) = Messages.unshowableCharacter(in: pending.tasks[task]!.run) else { continue }
                    notices.append(Messages.commandNotShowable(task: task, position: position, codePoint: codePoint))
                    break
                }
            }
            if evaluation.running != nil, let reason = environment?.fallbackReason {
                notices.append(Messages.tasksUseBasicEnvironment(reason))
            }
            result[view.name] = SiteTasksStatus(
                approval: evaluation.approval, tasks: tasks,
                pending: pending.map(SiteTasksStatus.pendingLines) ?? [], pendingHash: pending?.hash,
                notice: notices.isEmpty ? nil : notices.joined(separator: " "))
        }
        return result
    }

    /// A task's state, always the truth: what the supervisor says, refined by why Paddock left it as it is.
    private func describe(_ process: String, task: String, definition: TaskDefinition, state: Runtime,
                          stoppedByUser: Bool, startedByHand: Bool) -> (TaskState, String?) {
        if let flight = state.flight { return (flight.kind == .stop ? .stopping : .starting, nil) }
        switch state.held {
        case .process(let pid)?: return (.alreadyRunning(pid: pid), nil)
        case .leftovers?: return (.leftFromEarlierRun, nil)
        case nil: break
        }
        switch supervisor.status(process) {
        case .running(let pid):
            return (.running(pid: pid), nil)
        case .crashed(let status):
            if supervisor.hasGivenUp(process) || state.settled == .gaveUp(status: status) {
                return (.crashed(reason: Messages.taskGaveUp(status: status, task: task)), nil)
            }
            // Finished cleanly and about to start again.
            if status == 0 { return (.starting, nil) }
            return (.crashed(reason: Messages.taskRestarting(status: status)), nil)
        case .stopped:
            if stoppedByUser { return (.stopped(reason: .byYou), nil) }
            switch state.settled {
            case .exited?: return (.stopped(reason: .exited), Messages.taskKeepsFinishing(task: task))
            case .gaveUp(let status)?: return (.crashed(reason: Messages.taskGaveUp(status: status, task: task)), nil)
            case nil: break
            }
            if let failure = state.startFailure { return (.crashed(reason: failure), nil) }
            if !definition.startsWithPaddock && !startedByHand { return (.stopped(reason: .notAutostart), nil) }
            return (.starting, nil)
        }
    }

    // MARK: - Small pieces

    private func environmentLocked() -> ShellEnvironment {
        stateLock.lock()
        let current = environment
        stateLock.unlock()
        if let current { return current }
        let captured = captureEnvironment()
        log("site tasks: \(captured.description)")
        update { _ in self.environment = captured }
        return captured
    }

    private func update(_ body: (inout [String: Runtime]) -> Void) {
        stateLock.lock()
        body(&runtime)
        stateLock.unlock()
    }

    private func clearSettled(_ name: String) {
        update { runtime in
            runtime[name]?.settled = nil
            runtime[name]?.cleanExits = []
            runtime[name]?.lastExit = nil
            runtime[name]?.startFailure = nil
        }
    }

    private func clearSettled(site: String) {
        let prefix = Self.processName(site: site, task: "")
        stateLock.lock()
        let names = runtime.keys.filter { $0.hasPrefix(prefix) }
        stateLock.unlock()
        for name in names { clearSettled(name) }
    }

    /// A line of Paddock's own in a task's log.
    static func noteLine(_ text: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return "[paddock \(formatter.string(from: Date()))] \(text)\n"
    }
}
