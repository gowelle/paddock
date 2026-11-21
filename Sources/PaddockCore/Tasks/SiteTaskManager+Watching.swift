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

    /// The site's `paddock.json` changed: read it again. Its code changed: restart (gracefully, in the
    /// background) every task with restart-on-change that isn't stopped by the user; a task given up on runs
    /// again (fixing the code is how it recovers); one still stopping or starting is restarted once more after.
    func siteChanged(_ site: String, _ changes: SiteWatcher.Changes) {
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

    func settledState(_ name: String) -> Settled? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime[name]?.settled
    }

    /// Five and thirty seconds after a launch (and only for that launch): whether the task listens on anything
    /// but 127.0.0.1 or [::1]. It is warned, not stopped; a check that can't list the listeners warns nothing.
    func checkListeners(_ name: String, generation: Int) {
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
}
