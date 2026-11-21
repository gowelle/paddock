import Darwin
import Foundation

/// Stopping tasks and an earlier daemon's orphans in the background (flights), and the pid records.
extension SiteTaskManager {
    // MARK: - Stopping

    /// Begins stopping a launched task in the background with its grace (shortened, when the daemon is shutting
    /// down, to what is left of `shutdownGrace`). The stop's flight is what requests wait for.
    func beginStopLocked(_ name: String, _ task: Launched, note: String? = nil) {
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
    func beginReclaimLocked(_ name: String, _ task: Launched, _ record: ServiceProcessRecord) {
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
    func deadline(of flight: Flight) -> Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        let own = flight.began.addingTimeInterval(flight.grace)
        guard let started = shutdownStarted else { return own }
        return min(own, started.addingTimeInterval(shutdownGrace))
    }

    func endFlight(_ name: String, _ flight: Flight) {
        update { runtime in
            if runtime[name]?.flight === flight { runtime[name]?.flight = nil }
        }
        flight.finish()
        scheduleRefresh()
    }

    func flight(_ name: String) -> Flight? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime[name]?.flight
    }

    /// Waits (outside every lock) for flights, side by side: each at most its grace and a few seconds more.
    func wait(for flights: [Flight]) {
        for flight in flights { flight.wait(flight.grace + 10) }
    }

    // MARK: - Orphans

    /// The processes of the recorded group that are provably left from that run: started no earlier than the
    /// recorded process, in the same boot (the record must say which), working in the site's folder, and this
    /// user's. Nothing else is ever counted, or signalled.
    func leftovers(of record: ServiceProcessRecord, in folder: String) -> [Int32] {
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
    func updateRecord(_ name: String, generation: Int) {
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
    func ensureRunFolder(_ folder: URL) throws {
        let fm = FileManager.default
        var current = paths.run
        for component in ["tasks", folder.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent] {
            current = current.appendingPathComponent(component, isDirectory: true)
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        }
    }

    func stopLeftovers(_ process: String, site: String, task: String, folder: String) {
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
}
