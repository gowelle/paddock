import Darwin
import Foundation

/// What clients see of every site's tasks.
extension SiteTaskManager {
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
                                            warning: state.report ?? warning ?? state.listening,
                                            gaveUp: gaveUp(process, state: state) ? true : nil))
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
            if evaluation.folderReplaced { notices.append(Messages.tasksFolderReplaced) }
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
                    guard let problem = Messages.commandProblem(in: pending.tasks[task]!.run) else { continue }
                    notices.append(Messages.commandNotShowable(task: task, problem: problem))
                    break
                }
            }
            if evaluation.running != nil, let reason = environment?.fallbackReason {
                notices.append(Messages.tasksUseBasicEnvironment(reason))
            }
            let reserved = reservedPorts()
            notices += evaluation.refusedPaths.map(Messages.forwardingPathNoLongerAccepted)
            let approvedRoutes = TaskApproval.usableRoutes(evaluation.running?.proxy ?? [:], reservedPorts: [])
            for (prefix, port) in approvedRoutes.sorted(by: { $0.key < $1.key }) where reserved.contains(port) {
                notices.append(Messages.routeOnPaddocksPort(prefix: prefix, port: port))
            }
            result[view.name] = SiteTasksStatus(
                approval: evaluation.approval, tasks: tasks,
                pending: pending.map(SiteTasksStatus.pendingLines) ?? [], pendingHash: pending?.hash,
                notice: notices.isEmpty ? nil : notices.joined(separator: " "),
                routes: approvedRoutes.filter { !reserved.contains($0.value) }, folder: view.folder)
        }
        return result
    }

    /// Whether the task's last crash was terminal: its supervisor gave up, or it settled as given up.
    func gaveUp(_ process: String, state: Runtime) -> Bool {
        if case .gaveUp? = state.settled { return true }
        return supervisor.hasGivenUp(process)
    }

    /// A task's state, always the truth: what the supervisor says, refined by why Paddock left it as it is.
    func describe(_ process: String, task: String, definition: TaskDefinition, state: Runtime,
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
}
