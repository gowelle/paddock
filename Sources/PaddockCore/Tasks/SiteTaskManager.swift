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
    case notShowable(site: String, task: String, problem: CommandProblem)
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
    let captureEnvironment: @Sendable () -> ShellEnvironment
    let sites: @Sendable () -> [Site]
    let inspector: ServiceProcessInspector
    let refreshInterval: TimeInterval?
    /// The longest a task's stop may take once the daemon is shutting down.
    let shutdownGrace: TimeInterval
    /// Multiplies the windows in which clean exits are counted (tests shorten them with the restart delays).
    let timeScale: TimeInterval
    /// Every process Paddock supervises elsewhere (the web stack, services): never a task's leftover.
    let supervisedPids: @Sendable () -> Set<Int32>
    /// Where leftover checks learn about processes (tests present their own).
    var processes: ProcessSource {
        get { stateLock.lock(); defer { stateLock.unlock() }; return processSource }
        set { stateLock.lock(); processSource = newValue; stateLock.unlock() }
    }
    private var processSource = ProcessSource.live
    /// Told after every refresh, so the web side can follow the sites' routes (the engine sets it).
    var routesMayHaveChanged: (@Sendable ([String: [String: Int]]) -> Void)?
    /// Called (tests) in a forced restart between the end of the task's stop and the pass over leftovers.
    var beforeForcePassForTesting: (@Sendable () -> Void)?
    /// Paddock's own ports: never a proxy route's target.
    let reservedPorts: @Sendable () -> Set<Int>
    let log: @Sendable (String) -> Void

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
    /// After each spawn (a launch, or the supervisor's restart), when Paddock looks at what the task listens on.
    static let listenerChecks: [TimeInterval] = [5, 30]
    /// At most one restart for a code change per task in this many seconds; changes inside it make one restart
    /// at its end.
    static let changeRestartWindow: TimeInterval = 10

    /// Short-lived: held for decisions, never while a process is given its grace.
    let operationLock = NSLock()
    // Only touched while holding `operationLock`:
    /// Process name -> what was started under it.
    var launched: [String: Launched] = [:]
    var cache: [String: CachedFile] = [:]
    var nextGeneration = 1

    /// Guards everything below; held only for an instant, and never while calling the supervisor (whose exit
    /// callbacks take it).
    let stateLock = NSLock()
    var views: [String: SiteView] = [:]
    var environment: ShellEnvironment?
    var runtime: [String: Runtime] = [:]
    var logs: [String: RotatingLog] = [:]
    /// Tasks that don't start with Paddock but the user started (until the daemon exits).
    var startedByHand: Set<String> = []
    var shutdownStarted: Date?
    var timer: DispatchSourceTimer?
    var reconcilePending = false
    /// Site name -> the watcher of its folder, for every approved site.
    var watchers: [String: SiteWatcher] = [:]
    let refreshQueue = DispatchQueue(label: "app.paddock.tasks.refresh")

    struct SiteView {
        let name: String
        /// The site's folder, symlinks resolved.
        let folder: String
        let evaluation: TaskApproval.Evaluation
        let stopped: Set<String>
    }

    enum Settled: Equatable {
        case exited
        case gaveUp(status: Int32)
    }

    enum Held: Equatable {
        /// A live process the record names that Paddock can't prove its own.
        case process(Int32)
        /// Processes left in the recorded group, whose first process is gone.
        case leftovers
    }

    /// What Paddock knows of one task beyond what the supervisor says.
    struct Runtime {
        var cleanExits: [Date] = []
        var settled: Settled?
        var lastExit: Int32?
        var held: Held?
        var startFailure: String?
        var flight: Flight?
        /// What a forced restart stopped, until the task is next stopped.
        var report: String?
        /// When its current launch started: a change noticed before it is already in the code it runs.
        var launchedAt: Date?
        /// When it was last restarted for a code change.
        var lastChangeRestart: Date?
        /// A change noticed inside the window, waiting for its end (the time it was noticed).
        var deferredChange: Date?
        /// A forced restart is in progress: nothing launches the task until it is over.
        var forcePending = false
        /// It listens beyond this Mac (the last check said so).
        var listening: String?
    }

    struct Launched {
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

    struct CachedFile {
        let folder: String
        let stamp: SiteTasksFile.Stamp?
        let result: SiteTasksFile.LoadResult
    }

    /// A stop (or an orphan's stop) in progress, which requests can wait for.
    final class Flight: @unchecked Sendable {
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
                timeScale: TimeInterval = 1, supervisedPids: @escaping @Sendable () -> Set<Int32> = { [] },
                reservedPorts: @escaping @Sendable () -> Set<Int> = { [] },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.store = store
        self.supervisor = supervisor
        captureEnvironment = environment
        self.sites = sites
        self.inspector = inspector
        self.refreshInterval = refreshInterval
        self.shutdownGrace = min(shutdownGrace, Self.shutdownGraceCap)
        self.timeScale = timeScale
        self.supervisedPids = supervisedPids
        self.reservedPorts = reservedPorts
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

    func recordFile(site: String, task: String) -> URL {
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

    func removeRecordsFromEarlierBoots() {
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

    var isShuttingDown: Bool {
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
        let supervised = supervisor.names
        operationLock.unlock()
        for flight in flights { flight.wait(shutdownGrace + 10) }
        // Anything else the supervisor knows (a task waiting to be restarted, say) is told to stay stopped.
        for name in supervised { supervisor.stop(name, grace: 1) }
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
    func scheduleRefresh() {
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

    func refreshLocked() {
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
        // The routes in effect follow from the views just worked out: the engine only compares them.
        if let routesMayHaveChanged {
            let reserved = reservedPorts()
            var routes: [String: [String: Int]] = [:]
            for view in views.values {
                guard let running = view.evaluation.running else { continue }
                let usable = TaskApproval.usableRoutes(running.proxy, reservedPorts: reserved)
                if !usable.isEmpty { routes[view.name] = usable }
            }
            routesMayHaveChanged(routes)
        }
    }

    /// The file's last reading, read again only when its stamp changed.
    func load(site: String, folder: String) -> SiteTasksFile.LoadResult {
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
    func reconcileLocked(views: [String: SiteView]) {
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
        // A site's new launches wait while any of its tasks is stopping (the end of that stop refreshes again):
        // a task renamed in a new definition must not race the old one for its port.
        stateLock.lock()
        let sitesStopping = Set(runtime.compactMap { name, state in
            state.flight?.kind == .stop ? name.split(separator: "/").dropFirst().first.map(String.init) : nil
        })
        stateLock.unlock()
        stateLock.lock()
        let forcing = Set(runtime.filter(\.value.forcePending).keys)
        stateLock.unlock()
        for (name, task) in wanted.sorted(by: { $0.key < $1.key }) where flight(name) == nil && !forcing.contains(name) {
            if launched[name] == nil && sitesStopping.contains(task.site) { continue }
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
    func prepareLaunchLocked(_ name: String, _ task: Launched) {
        // Nothing starts once the daemon is on its way out, whoever asks.
        guard !isShuttingDown else { return }
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
                    if sortLeftovers(of: record, in: task.folder).holds {
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

    func launchLocked(_ name: String, _ task: Launched) {
        guard !isShuttingDown else { return }
        let environment = environmentLocked()
        // Capturing the environment may have taken a while: check again.
        guard !isShuttingDown else { return }
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
                for delay in Self.listenerChecks {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self?.checkListeners(name, generation: generation, pid: pid)
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
            update {
                $0[name, default: Runtime()].startFailure = nil
                $0[name]?.listening = nil
                $0[name]?.launchedAt = Date()
            }
        } catch {
            update { $0[name, default: Runtime()].startFailure = Messages.taskCouldNotRun(shell: environment.shell) }
            log("task \(task.site)/\(task.task) could not be started: \(error)")
        }
    }

    /// The policy for a task's exits, asked by the supervisor (while it is busy): an error is restarted with
    /// backoff and counts toward the supervisor's give-up; a clean exit (status 0) is restarted with backoff but
    /// never counts as a failure, unless the task has finished `exitedLimit` times within `exitedWindow` seconds or
    /// `exitedLongLimit` times within `exitedLongWindow`: then it is left stopped.
    func exitDecision(_ name: String, status: Int32) -> ExitDecision {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = runtime[name] ?? Runtime()
        defer { runtime[name] = state }
        state.lastExit = status
        // The daemon is on its way out: no restart.
        if shutdownStarted != nil { return .stop }
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

    func didExit(_ name: String, site: String, task: String, status: Int32, restarting: Bool) {
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

    // MARK: - Small pieces

    func environmentLocked() -> ShellEnvironment {
        stateLock.lock()
        let current = environment
        stateLock.unlock()
        if let current { return current }
        let captured = captureEnvironment()
        log("site tasks: \(captured.description)")
        update { _ in self.environment = captured }
        return captured
    }

    func update(_ body: (inout [String: Runtime]) -> Void) {
        stateLock.lock()
        body(&runtime)
        stateLock.unlock()
    }

    func clearSettled(_ name: String) {
        update { runtime in
            runtime[name]?.settled = nil
            runtime[name]?.cleanExits = []
            runtime[name]?.lastExit = nil
            runtime[name]?.startFailure = nil
        }
    }

    func clearSettled(site: String) {
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
