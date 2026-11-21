import Darwin
import Foundation

public enum SiteTaskError: Error, Equatable, Sendable {
    case unknownSite(String)
    case noTasksFile(site: String)
    /// `reason` is already sanitised.
    case invalid(site: String, reason: String)
    case notApproved(site: String)
    case unknownTask(site: String, task: String)
    /// A command that would show other than it runs (control characters, escape sequences…).
    case notShowable(site: String, task: String)
    /// The file's hash isn't the one the user was shown.
    case changedSinceShown(site: String)
    case alreadyRunning(site: String, task: String, pid: Int32)
    case couldNotStart(site: String, task: String, reason: String)
    case fileExists(site: String, path: String)
    case notLaravel(site: String)
    case couldNotWrite(site: String, reason: String)
    case shuttingDown
}

/// Runs the approved tasks of every site (`paddock.json`), each as `[shell, "-c", run]` in the site's folder
/// with the user's shell environment and Paddock's `bin` first on PATH, supervised in its own process group.
///
/// Nothing runs that the user hasn't approved: what runs is the approved definition kept in state.json, for the
/// folder it was approved for. Changes (`refresh`, `approve`, `revoke`, `start`, `stop`, `restart`, `stopAll`)
/// run one at a time; `statuses` never waits for them and never reads a file: it reports what the last refresh
/// saw and what the supervisor says now.
public final class SiteTaskManager: @unchecked Sendable {
    let paths: Paths
    let store: StateStore
    let supervisor: Supervisor
    private let captureEnvironment: @Sendable () -> ShellEnvironment
    private let sites: @Sendable () -> [Site]
    private let inspector: ServiceProcessInspector
    private let refreshInterval: TimeInterval?
    /// The longest a task's stop may take when the daemon shuts down.
    let shutdownGrace: TimeInterval
    private let log: @Sendable (String) -> Void

    /// At daemon shutdown a task gets at most this long to stop (its `stopSeconds` may allow up to 300), so
    /// tasks and services, stopping side by side, fit inside the LaunchAgent's exit timeout.
    public static let shutdownGraceCap: TimeInterval = 60
    /// A task that exits with status 0 this many times within `exitedWindow` seconds is left stopped.
    static let exitedLimit = 3
    static let exitedWindow: TimeInterval = 10
    /// A task's log is rotated (one previous file kept) past this size.
    static let logLimit: UInt64 = 5 * 1024 * 1024
    /// After a spawn, when the pid record is brought up to date with the program the shell handed over to.
    static let recordUpdates: [TimeInterval] = [0.5, 2, 10]

    private let operationLock = NSLock()
    /// Guards everything below up to `operationLock`'s fields; held only for an instant, and never while
    /// calling the supervisor (whose exit callbacks take it).
    private let stateLock = NSLock()
    private var views: [String: SiteView] = [:]
    private var environment: ShellEnvironment?
    /// Process name -> recent exits with status 0.
    private var cleanExits: [String: [Date]] = [:]
    /// Process name -> why it stopped by itself (it is not started again until the user says so).
    private var settled: [String: Settled] = [:]
    private var lastExit: [String: Int32] = [:]
    /// Process name -> the pid of a process holding the task that Paddock can't prove its own.
    private var heldBy: [String: Int32] = [:]
    /// Process name -> why it couldn't be started.
    private var startFailures: [String: String] = [:]
    private var shuttingDown = false
    private var timer: DispatchSourceTimer?

    // Only touched while holding `operationLock`:
    /// Process name -> what was started under it.
    private var launched: [String: Launched] = [:]
    /// Tasks that don't start with Paddock but the user started (until the daemon exits).
    private var startedByHand: Set<String> = []
    private var cache: [String: CachedFile] = [:]

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

    private struct Launched: Equatable {
        let site: String
        let task: String
        let definition: TaskDefinition
        let folder: String
    }

    private struct CachedFile {
        let folder: String
        let stamp: SiteTasksFile.Stamp?
        let result: SiteTasksFile.LoadResult
    }

    /// `environment` asks the user's shell (`ShellEnvironment.forDaemon`); it is called at `start` and on every
    /// approval. `sites` lists the served sites. `refreshInterval` (nil: never) re-reads every `paddock.json`
    /// now and then, so status notices an edited file.
    public init(paths: Paths, store: StateStore, supervisor: Supervisor,
                environment: @escaping @Sendable () -> ShellEnvironment,
                sites: @escaping @Sendable () -> [Site], inspector: ServiceProcessInspector = .live,
                refreshInterval: TimeInterval? = 30, shutdownGrace: TimeInterval = SiteTaskManager.shutdownGraceCap,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.store = store
        self.supervisor = supervisor
        captureEnvironment = environment
        self.sites = sites
        self.inspector = inspector
        self.refreshInterval = refreshInterval
        self.shutdownGrace = min(shutdownGrace, Self.shutdownGraceCap)
        self.log = log
    }

    static func processName(site: String, task: String) -> String { "task/\(site)/\(task)" }

    public func logFile(site: String, task: String) -> URL { paths.taskLog(site: site, task: task) }

    private func recordFile(site: String, task: String) -> URL {
        paths.taskRun(site: site, task: task).appendingPathComponent("pid")
    }

    // MARK: - Lifecycle

    /// At daemon start: starts every approved task that starts with Paddock (stopping first what a dead daemon
    /// left running, when it is provably Paddock's own), and from then on re-reads the sites' files every
    /// `refreshInterval` seconds. The user's shell environment is read when the first task starts (or the
    /// user approves one), not before: a Paddock without approved tasks never runs the shell.
    public func start() {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        refreshLocked()
        guard let refreshInterval else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil, !shuttingDown else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.paddock.tasks.refresh"))
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    /// From here on nothing starts again: the daemon is on its way out.
    func beginShutdown() {
        stateLock.lock()
        shuttingDown = true
        let timer = self.timer
        self.timer = nil
        stateLock.unlock()
        timer?.cancel()
    }

    private var isShuttingDown: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shuttingDown
    }

    /// Stops every task side by side, for the daemon's exit: each gets its `stopSeconds`, but no more than
    /// `shutdownGrace`; one cut short says so in its log.
    public func stopAll() {
        beginShutdown()
        operationLock.lock()
        defer { operationLock.unlock() }
        let all = launched
        let group = DispatchGroup()
        for (name, task) in all {
            DispatchQueue.global().async(group: group) {
                let grace = min(TimeInterval(task.definition.stopGrace), self.shutdownGrace)
                let outcome = self.supervisor.stop(name, grace: grace)
                if outcome == .killed, TimeInterval(task.definition.stopGrace) > grace {
                    let note = Messages.taskCutShort(after: Int(grace), allowed: task.definition.stopGrace)
                    self.note(note, site: task.site, task: task.task)
                    self.log("task \(task.site)/\(task.task): \(note)")
                }
                self.removeRecord(site: task.site, task: task.task)
            }
        }
        group.wait()
        launched = [:]
    }

    // MARK: - Refreshing

    /// Re-reads every site's `paddock.json` (each only when it changed on disk) and brings the running tasks in
    /// line: an approved file's tasks run; a changed, removed or broken one keeps the approved version running;
    /// anything unapproved runs nothing; tasks of a site that is gone are stopped, and its approval is dropped a
    /// month later.
    public func refresh() {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        refreshLocked()
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
        reconcileLocked(views: views)
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

    /// Stops what should no longer run (unapproved, removed from the definition, its site gone, stopped by the
    /// user, or a definition that changed) and starts what should run and doesn't.
    private func reconcileLocked(views: [String: SiteView]) {
        var wanted: [String: Launched] = [:]
        for view in views.values {
            guard let running = view.evaluation.running else { continue }
            for (task, definition) in running.tasks {
                let name = Self.processName(site: view.name, task: task)
                guard !view.stopped.contains(task), definition.startsWithPaddock || startedByHand.contains(name),
                      settledState(name) == nil else { continue }
                wanted[name] = Launched(site: view.name, task: task, definition: definition, folder: view.folder)
            }
        }
        for (name, task) in launched where wanted[name] != task {
            let siteGone = views[task.site] == nil || views[task.site]?.folder != task.folder
            stopLocked(name, task, note: siteGone ? Messages.taskSiteGone : nil)
        }
        let heldNames = Set(heldByNames())
        for name in heldNames where wanted[name] == nil { setHeld(nil, for: name) }
        for (name, task) in wanted.sorted(by: { $0.key < $1.key }) {
            if launched[name] != nil {
                switch supervisor.status(name) {
                case .running, .crashed: updateRecord(name, site: task.site, task: task.task)
                case .stopped: launched[name] = nil; launchLocked(name, task)
                }
            } else {
                launchLocked(name, task)
            }
        }
        for task in launched.values { rotateIfNeeded(logFile(site: task.site, task: task.task)) }
    }

    // MARK: - Starting and stopping

    private func launchLocked(_ name: String, _ task: Launched) {
        if let holder = reclaimOrphan(name, task) {
            setHeld(holder, for: name)
            return
        }
        setHeld(nil, for: name)
        let environment = environmentLocked()
        let log = logFile(site: task.site, task: task.task)
        let record = recordFile(site: task.site, task: task.task)
        do {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ensureRunFolder(record.deletingLastPathComponent())
        } catch {
            setStartFailure("\(error.localizedDescription)", for: name)
            return
        }
        rotateIfNeeded(log)
        var spec = ProcessSpec(
            name: name, executable: URL(fileURLWithPath: environment.shell), arguments: ["-c", task.definition.run],
            environment: environment.forTasks(paths: paths), logFile: log, stopSignal: SIGTERM,
            stopGrace: TimeInterval(task.definition.stopGrace), inheritsEnvironment: false,
            didSpawn: { [weak self] pid in
                try? ServiceProcessRecord.live(pid: pid)?.write(to: record)
                for delay in Self.recordUpdates {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self?.updateRecord(name, site: task.site, task: task.task)
                    }
                }
            })
        spec.workingDirectory = URL(fileURLWithPath: task.folder, isDirectory: true)
        spec.restartsAfterExit = { [weak self] status in self?.restartsAfterExit(name, status: status) ?? false }
        spec.didExit = { [weak self] status, restarting in
            self?.didExit(name, site: task.site, task: task.task, status: status, restarting: restarting)
        }
        note("Starting.", site: task.site, task: task.task)
        do {
            try supervisor.start(spec)
            launched[name] = task
            setStartFailure(nil, for: name)
        } catch {
            setStartFailure(Messages.taskCouldNotRun(shell: environment.shell), for: name)
            self.log("task \(task.site)/\(task.task) could not be started: \(error)")
        }
    }

    private func stopLocked(_ name: String, _ task: Launched, note: String? = nil) {
        supervisor.stop(name)
        removeRecord(site: task.site, task: task.task)
        launched[name] = nil
        if let note { self.note(note, site: task.site, task: task.task) }
    }

    /// Called by the supervisor (while it is busy) after each unexpected exit: a third clean exit within
    /// `exitedWindow` seconds leaves the task stopped.
    private func restartsAfterExit(_ name: String, status: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        lastExit[name] = status
        guard status == 0 else { return true }
        let now = Date()
        let recent = (cleanExits[name] ?? []).filter { now.timeIntervalSince($0) < Self.exitedWindow } + [now]
        cleanExits[name] = recent
        guard recent.count >= Self.exitedLimit else { return true }
        settled[name] = .exited
        return false
    }

    private func didExit(_ name: String, site: String, task: String, status: Int32, restarting: Bool) {
        if !restarting && status != 0 {
            stateLock.lock()
            settled[name] = .gaveUp(status: status)
            stateLock.unlock()
            note(Messages.taskGaveUp(status: status, task: task), site: site, task: task)
        } else if !restarting {
            note(Messages.taskKeepsExiting, site: site, task: task)
        } else {
            note("Exited with status \(status); restarting.", site: site, task: task)
        }
        removeRecordIfStopped(name, site: site, task: task)
    }

    private func removeRecordIfStopped(_ name: String, site: String, task: String) {
        if case .stopped = supervisor.status(name) { removeRecord(site: site, task: task) }
    }

    // MARK: - Orphans

    /// What a pid record left by an earlier daemon names. Provably Paddock's own orphan (same pid, start
    /// time, group, program as last recorded, parent launchd, working in the site's folder; or the remaining
    /// members of such a group whose leader is gone): stopped, and nil returned so the task starts afresh.
    /// The same process but not provably ours: left alone, and its pid returned. Gone: the record is removed.
    private func reclaimOrphan(_ name: String, _ task: Launched) -> Int32? {
        let file = recordFile(site: task.site, task: task.task)
        guard let record = ServiceProcessRecord.read(from: file) else { return nil }
        if case .running(let pid) = supervisor.status(name), pid == record.pid { return nil }
        let inSiteFolder: (Int32) -> Bool = { [inspector] pid in
            guard let directory = inspector.workingDirectory(pid) else { return false }
            return SiteTasksFile.realPath(directory) == task.folder
        }
        switch record.identity(belongs: inSiteFolder) {
        case .runningButNotOurs:
            log("task \(task.site)/\(task.task): pid \(record.pid) is still running but was not started by this "
                + "Paddock; leaving it alone")
            return record.pid
        case .orphan:
            log("stopping task \(task.site)/\(task.task) (process group \(record.pgid)), left running by an earlier Paddock")
            record.stopGroup(signal: SIGTERM, grace: TimeInterval(task.definition.stopGrace))
        case .gone:
            if record.orphanedGroupMembers(belongs: inSiteFolder) != nil {
                log("stopping what is left of task \(task.site)/\(task.task) (process group \(record.pgid))")
                record.stopGroup(signal: SIGTERM, grace: TimeInterval(task.definition.stopGrace))
            }
        }
        try? FileManager.default.removeItem(at: file)
        return nil
    }

    /// Brings a running task's pid record up to date: the shell usually hands over to the command (`exec`), so
    /// the program recorded at spawn changes. Only for the very process recorded (same pid and start time).
    private func updateRecord(_ name: String, site: String, task: String) {
        guard case .running(let pid) = supervisor.status(name) else { return }
        let file = recordFile(site: site, task: task)
        guard let recorded = ServiceProcessRecord.read(from: file), recorded.pid == pid,
              let now = ServiceProcessRecord.live(pid: pid), now.startSeconds == recorded.startSeconds,
              now.startMicroseconds == recorded.startMicroseconds, now != recorded else { return }
        try? now.write(to: file)
    }

    private func removeRecord(site: String, task: String) {
        try? FileManager.default.removeItem(at: recordFile(site: site, task: task))
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
    /// its tasks. Refuses a file with a command that can't be shown as it runs.
    @discardableResult
    public func approve(site name: String, hash: String) throws -> SiteTasksStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        let folder = try folder(of: name)
        let result = SiteTasksFile.load(siteFolder: URL(fileURLWithPath: folder, isDirectory: true))
        cache[name] = nil
        let file: SiteTasksFile
        switch result {
        case .none: throw SiteTaskError.noTasksFile(site: name)
        case .invalid(let reason): throw SiteTaskError.invalid(site: name, reason: reason)
        case .file(let current, let currentHash):
            guard currentHash == hash else { throw SiteTaskError.changedSinceShown(site: name) }
            if let task = current.tasks.keys.sorted().first(where: { !Messages.isShowable(current.tasks[$0]!.run) }) {
                throw SiteTaskError.notShowable(site: name, task: task)
            }
            file = current
        }
        captureEnvironmentLocked()
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

    /// Stops the site's tasks and withdraws its approval.
    public func revoke(site name: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard sites().contains(where: { $0.name == name }) || store.load().taskApprovals[name] != nil else {
            throw SiteTaskError.unknownSite(name)
        }
        try store.update { $0.taskApprovals[name] = nil }
        startedByHand = startedByHand.filter { !$0.hasPrefix(Self.processName(site: name, task: "")) }
        clearSettled(site: name)
        refreshLocked()
    }

    /// Starts one approved task (and forgets that the user stopped it).
    public func start(site name: String, task: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        refreshLocked()
        _ = try definition(site: name, task: task)
        let process = Self.processName(site: name, task: task)
        try setStopped(false, site: name, task: task)
        clearSettled(process)
        startedByHand.insert(process)
        refreshLocked()
        try checkStarted(process, site: name, task: task)
    }

    /// Stops one task, and remembers (across daemon restarts) not to start it until the user does.
    public func stop(site name: String, task: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        refreshLocked()
        _ = try definition(site: name, task: task)
        try setStopped(true, site: name, task: task)
        let process = Self.processName(site: name, task: task)
        if let running = launched[process] { stopLocked(process, running, note: "Stopped by you.") }
        refreshLocked()
    }

    /// Stops the task and starts it again (also when it had been stopped, or given up on).
    public func restart(site name: String, task: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
        refreshLocked()
        _ = try definition(site: name, task: task)
        let process = Self.processName(site: name, task: task)
        try setStopped(false, site: name, task: task)
        if let running = launched[process] { stopLocked(process, running, note: "Restarting.") }
        clearSettled(process)
        startedByHand.insert(process)
        refreshLocked()
        try checkStarted(process, site: name, task: task)
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

    private func checkStarted(_ process: String, site: String, task: String) throws {
        stateLock.lock()
        let holder = heldBy[process]
        let failure = startFailures[process]
        stateLock.unlock()
        if let holder { throw SiteTaskError.alreadyRunning(site: site, task: task, pid: holder) }
        if let failure { throw SiteTaskError.couldNotStart(site: site, task: task, reason: failure) }
    }

    // MARK: - Reporting

    /// Every site with a `paddock.json` or an approval, by name. Never waits for a change in progress.
    public func statuses() -> [String: SiteTasksStatus] {
        stateLock.lock()
        let views = self.views
        let environment = self.environment
        let settled = self.settled
        let lastExit = self.lastExit
        let heldBy = self.heldBy
        let startFailures = self.startFailures
        stateLock.unlock()

        var result: [String: SiteTasksStatus] = [:]
        for view in views.values {
            let evaluation = view.evaluation
            var tasks: [TaskStatus] = []
            if let running = evaluation.running {
                for name in running.tasks.keys.sorted() {
                    let definition = running.tasks[name]!
                    let process = Self.processName(site: view.name, task: name)
                    var warning: String?
                    let state: TaskState
                    if let holder = heldBy[process] {
                        state = .alreadyRunning(pid: holder)
                    } else {
                        switch supervisor.status(process) {
                        case .running(let pid):
                            state = .running(pid: pid)
                        case .crashed(let status):
                            state = .crashed(reason: settled[process] == .gaveUp(status: status)
                                             ? Messages.taskGaveUp(status: status, task: name)
                                             : Messages.taskRestarting(status: status))
                        case .stopped:
                            if view.stopped.contains(name) {
                                state = .stopped(reason: .byYou)
                            } else if settled[process] == .exited {
                                state = .stopped(reason: .exited)
                                warning = Messages.taskKeepsExiting
                            } else if case .gaveUp(let status)? = settled[process] {
                                state = .crashed(reason: Messages.taskGaveUp(status: status, task: name))
                            } else if let failure = startFailures[process] {
                                state = .crashed(reason: failure)
                            } else if !definition.startsWithPaddock {
                                state = .stopped(reason: .notAutostart)
                            } else {
                                state = lastExit[process] == nil ? .starting : .stopped(reason: nil)
                            }
                        }
                    }
                    tasks.append(TaskStatus(name: name, run: Messages.shownCommand(definition.run), state: state,
                                            restartOnChange: definition.restartsOnChange,
                                            logPath: logFile(site: view.name, task: name).path, warning: warning))
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
            if let pending, let hidden = pending.tasks.keys.sorted().first(where: { !Messages.isShowable(pending.tasks[$0]!.run) }) {
                notices.append(Messages.commandNotShowable(task: hidden))
            }
            if evaluation.running != nil, environment?.usedFallback == true {
                notices.append(Messages.tasksUseBasicEnvironment)
            }
            result[view.name] = SiteTasksStatus(
                approval: evaluation.approval, tasks: tasks,
                pending: pending.map(SiteTasksStatus.pendingLines) ?? [], pendingHash: pending?.hash,
                notice: notices.isEmpty ? nil : notices.joined(separator: " "))
        }
        return result
    }

    // MARK: - Small pieces

    private func captureEnvironmentLocked() {
        let captured = captureEnvironment()
        log("site tasks: \(captured.description)")
        stateLock.lock()
        environment = captured
        stateLock.unlock()
    }

    private func environmentLocked() -> ShellEnvironment {
        stateLock.lock()
        let current = environment
        stateLock.unlock()
        if let current { return current }
        captureEnvironmentLocked()
        return environmentLocked()
    }

    private func settledState(_ name: String) -> Settled? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settled[name]
    }

    private func clearSettled(_ name: String) {
        stateLock.lock()
        settled[name] = nil
        cleanExits[name] = nil
        lastExit[name] = nil
        startFailures[name] = nil
        stateLock.unlock()
    }

    private func clearSettled(site: String) {
        let prefix = Self.processName(site: site, task: "")
        stateLock.lock()
        settled = settled.filter { !$0.key.hasPrefix(prefix) }
        cleanExits = cleanExits.filter { !$0.key.hasPrefix(prefix) }
        lastExit = lastExit.filter { !$0.key.hasPrefix(prefix) }
        startFailures = startFailures.filter { !$0.key.hasPrefix(prefix) }
        stateLock.unlock()
    }

    private func heldByNames() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(heldBy.keys)
    }

    private func setHeld(_ pid: Int32?, for name: String) {
        stateLock.lock()
        heldBy[name] = pid
        stateLock.unlock()
    }

    private func setStartFailure(_ reason: String?, for name: String) {
        stateLock.lock()
        startFailures[name] = reason
        stateLock.unlock()
    }

    /// A line of Paddock's own in the task's log.
    private func note(_ text: String, site: String, task: String) {
        let file = logFile(site: site, task: task)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        let bytes = Array("[paddock \(formatter.string(from: Date()))] \(text)\n".utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    /// Past `logLimit`, the log is copied to `<name>.log.1` (replacing the previous one) and emptied. The task
    /// keeps writing to it (it was opened for appending), from the start.
    func rotateIfNeeded(_ file: URL) {
        var info = stat()
        guard stat(file.path, &info) == 0, UInt64(info.st_size) > Self.logLimit,
              let data = try? Data(contentsOf: file) else { return }
        let previous = file.appendingPathExtension("1")
        do {
            try data.write(to: previous, options: .atomic)
            _ = truncate(file.path, 0)
        } catch {
            log("could not rotate \(file.path): \(error.localizedDescription)")
        }
    }
}
