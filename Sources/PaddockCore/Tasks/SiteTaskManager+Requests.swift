import Darwin
import Foundation

/// What clients ask of sites' tasks: approving, withdrawing, starting, stopping, restarting, starting a file.
extension SiteTaskManager {
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
        // The daemon may have begun shutting down while the shell was being read.
        guard !isShuttingDown else { throw SiteTaskError.shuttingDown }
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
    func approvable(site name: String, hash: String) throws -> (String, SiteTasksFile) {
        let folder = try folder(of: name)
        switch SiteTasksFile.load(siteFolder: URL(fileURLWithPath: folder, isDirectory: true)) {
        case .none: throw SiteTaskError.noTasksFile(site: name)
        case .invalid(let reason): throw SiteTaskError.invalid(site: name, reason: reason)
        case .file(let current, let currentHash):
            guard currentHash == hash else { throw SiteTaskError.changedSinceShown(site: name) }
            for task in current.tasks.keys.sorted() {
                if let problem = Messages.commandProblem(in: current.tasks[task]!.run) {
                    throw SiteTaskError.notShowable(site: name, task: task, problem: problem)
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
        // A forced restart answers with what it did (the task's warning), even when the task stays held back.
        if !force { try checkStarted(process, site: name, task: task) }
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

    func folder(of name: String) throws -> String {
        guard let site = sites().first(where: { $0.name == name }), let folder = SiteTasksFile.realPath(site.path) else {
            throw SiteTaskError.unknownSite(name)
        }
        return folder
    }

    /// The task's approved definition, or why there is none.
    func definition(site name: String, task: String) throws -> TaskDefinition {
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

    func setStopped(_ stopped: Bool, site: String, task: String) throws {
        try store.update { state in
            if stopped { state.taskApprovals[site]?.stopped.insert(task) } else { state.taskApprovals[site]?.stopped.remove(task) }
        }
    }

    func siteFlights(_ site: String) -> [Flight] {
        let prefix = Self.processName(site: site, task: "")
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime.filter { $0.key.hasPrefix(prefix) }.compactMap(\.value.flight)
    }

    func checkStarted(_ process: String, site: String, task: String) throws {
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
}
