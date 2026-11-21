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
        guard !isShuttingDown else { return }
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
        sortLeftovers(of: record, in: folder).ours
    }

    /// The live members of the recorded group, sorted: those provably left from that run (`ours`), and the
    /// others with why not. Never this daemon, nor anything Paddock supervises.
    func sortLeftovers(of record: ServiceProcessRecord, in folder: String)
        -> (ours: [Int32], others: [(Int32, LeftoverReason)]) {
        let members = (ServiceProcessRecord.members(ofGroup: record.pgid) ?? []).filter { $0 > 1 }.sorted()
        let paddocks = supervisedPids().union(supervisor.runningPids).union([getpid()])
        let sameBoot = record.bootSeconds != nil && record.bootSeconds == ServiceProcessRecord.currentBoot()
        var ours: [Int32] = []
        var others: [(Int32, LeftoverReason)] = []
        for pid in members {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, getpgid(pid) == record.pgid else { continue }
            if paddocks.contains(pid) { others.append((pid, .runByPaddock)); continue }
            guard sameBoot else { others.append((pid, .anotherBoot)); continue }
            guard info.pbi_uid == getuid() else { others.append((pid, .anotherUser)); continue }
            let started = (Int64(info.pbi_start_tvsec), Int64(info.pbi_start_tvusec))
            guard started >= (record.startSeconds, record.startMicroseconds) else {
                others.append((pid, .startedEarlier))
                continue
            }
            let directory = inspector.workingDirectory(pid).flatMap(SiteTasksFile.realPath)
            guard let directory, directory == folder || directory.hasPrefix(folder + "/") else {
                others.append((pid, .notInSiteFolder))
                continue
            }
            ours.append(pid)
        }
        return (ours, others)
    }

    /// Whether the group still holds the task back: something provably from that run, or something that may be
    /// (this user's, started with that run, but working outside the site's folder).
    func holdsTask(_ sorted: (ours: [Int32], others: [(Int32, LeftoverReason)])) -> Bool {
        !sorted.ours.isEmpty || sorted.others.contains { $0.1 == .notInSiteFolder }
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

    /// `restart --force`'s pass, while the task is held (`forcePending`): under the operation lock, only if
    /// nothing of the task is launched and its record is still the one read when the request began, SIGKILL to the
    /// recorded group's members that are provably left from that run. Then, if nothing that may be from it is left,
    /// the record goes and the task can start; otherwise the record stays and the task stays held back. Says what
    /// it stopped and what it left, and why.
    func stopLeftovers(_ process: String, site: String, task: String, folder: String, expected: ServiceProcessRecord?) {
        let file = recordFile(site: site, task: task)
        var stopped: [Int32] = []
        var left: [(Int32, LeftoverReason)] = []
        var holding = false
        operationLock.lock()
        let current = ServiceProcessRecord.read(from: file)
        let unchanged = current != nil && expected != nil && current!.pid == expected!.pid
            && current!.pgid == expected!.pgid && current!.startSeconds == expected!.startSeconds
            && current!.startMicroseconds == expected!.startMicroseconds
        let record = launched[process] == nil && unchanged ? current : nil
        if let record {
            stopped = sortLeftovers(of: record, in: folder).ours
            for pid in stopped { kill(pid, SIGKILL) }
        }
        operationLock.unlock()
        if let record {
            let end = Date().addingTimeInterval(5)
            while stopped.contains(where: { kill($0, 0) == 0 }) && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            let after = sortLeftovers(of: record, in: folder)
            left = after.others
            holding = holdsTask(after)
            operationLock.lock()
            if !holding, ServiceProcessRecord.read(from: file).map({ $0.pid == record.pid && $0.pgid == record.pgid }) == true {
                try? FileManager.default.removeItem(at: file)
            }
            operationLock.unlock()
        }
        let report = Messages.leftoversStopped(task: task, stopped: stopped, left: left)
        logWriter(site: site, task: task).append(Self.noteLine(report))
        log("task \(site)/\(task): \(report)")
        update {
            $0[process, default: Runtime()].held = holding ? .leftovers : nil
            $0[process]?.report = report
        }
    }
}
