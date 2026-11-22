import Darwin
import Foundation

/// Watching each approved site's code (restart on change, `paddock.json` edits) and what tasks listen on.
extension SiteTaskManager {
    // MARK: - Watching the code

    /// The watcher of an approved site's folder, if any (tests).
    func watcher(site: String) -> SiteWatcher? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return watchers[site]
    }

    /// One watcher per approved site (its approval runs something), on the site's folder; the others stopped.
    func syncWatchers(_ views: [String: SiteView]) {
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

    /// The site's `paddock.json` changed (or its folder did): look at the site again. Its code changed: restart
    /// (gracefully, in the background) every task with restart-on-change that isn't stopped by the user. A task
    /// given up on runs again (fixing the code is how it recovers). A task already stopping or starting needs
    /// nothing: its next launch reads the new code. At most one restart per task in `changeRestartWindow`
    /// seconds; changes inside it make one restart at its end.
    func siteChanged(_ site: String, _ changes: SiteWatcher.Changes, at noticed: Date = Date()) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        if changes.tasksFile || changes.rootChanged { refreshLocked() }
        guard changes.code else { return }
        stateLock.lock()
        let view = views[site]
        stateLock.unlock()
        guard let view, let running = view.evaluation.running else { return }
        // When the change happened: its files' own time when they all have one (a write just before a launch can
        // reach us after it), else when it was noticed.
        let changedAt = changes.codeChangedAt.map { min($0, noticed) } ?? noticed
        for (task, definition) in running.tasks where definition.restartsOnChange && !view.stopped.contains(task) {
            restartForChangeLocked(Self.processName(site: site, task: task), noticed: changedAt)
        }
        reconcileLocked(views: views)
    }

    /// One task's restart for a change noticed at `noticed` (operation lock held).
    func restartForChangeLocked(_ name: String, noticed: Date) {
        stateLock.lock()
        let state = runtime[name] ?? Runtime()
        stateLock.unlock()
        if let launchedAt = state.launchedAt, noticed < launchedAt { return }
        if state.flight != nil { return }
        let gaveUp: Bool
        if case .gaveUp? = state.settled { gaveUp = true } else { gaveUp = supervisor.hasGivenUp(name) }
        if gaveUp {
            clearSettled(name)
            if let launch = launched[name] { beginStopLocked(name, launch, note: Messages.taskRestartingForChange) }
            return
        }
        guard let launch = launched[name] else { return }
        if case .stopped = supervisor.status(name) { return }
        let now = Date()
        let window = Self.changeRestartWindow * timeScale
        if let last = state.lastChangeRestart, now.timeIntervalSince(last) < window {
            guard state.deferredChange == nil else { return }
            update { $0[name]?.deferredChange = noticed }
            refreshQueue.asyncAfter(deadline: .now() + window - now.timeIntervalSince(last)) { [weak self] in
                self?.deferredChangeRestart(name)
            }
            return
        }
        update {
            $0[name]?.lastChangeRestart = now
            $0[name]?.deferredChange = nil
        }
        beginStopLocked(name, launch, note: Messages.taskRestartingForChange)
    }

    /// The end of a task's change window, with a change waiting.
    func deferredChangeRestart(_ name: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isShuttingDown else { return }
        stateLock.lock()
        let noticed = runtime[name]?.deferredChange
        runtime[name]?.deferredChange = nil
        let view = views.values.first { view in
            view.evaluation.running?.tasks.keys.contains { Self.processName(site: view.name, task: $0) == name } ?? false
        }
        stateLock.unlock()
        guard let noticed, let view, let task = view.evaluation.running?.tasks
                .first(where: { Self.processName(site: view.name, task: $0.key) == name }),
              task.value.restartsOnChange, !view.stopped.contains(task.key) else { return }
        restartForChangeLocked(name, noticed: noticed)
    }

    func settledState(_ name: String) -> Settled? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime[name]?.settled
    }

    /// Five and thirty seconds after each spawn (a launch, or the supervisor's restart; only for that launch and
    /// that process): whether the task listens on anything only this Mac can't reach. It is warned, not stopped;
    /// a check that can't list the listeners warns nothing.
    func checkListeners(_ name: String, generation: Int, pid: Int32) {
        operationLock.lock()
        guard launched[name]?.generation == generation, case .running(let current) = supervisor.status(name),
              current == pid else {
            operationLock.unlock()
            return
        }
        operationLock.unlock()
        let addresses = (try? ServiceManager.listeningAddresses(processGroup: pid, runner: SystemCommandRunner())) ?? []
        let warning = addresses.compactMap(ListeningAddress.init).lazy.compactMap(Messages.listening).first
        operationLock.lock()
        defer { operationLock.unlock() }
        guard launched[name]?.generation == generation, case .running(let still) = supervisor.status(name), still == pid
        else { return }
        update { $0[name, default: Runtime()].listening = warning }
    }
}
