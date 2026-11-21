import Foundation

/// One task of a site, as the site's tasks list shows it. Text from `paddock.json` comes sanitised by the daemon.
public struct TaskRow: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let site: String
    public let name: String
    /// The whole command, as it runs.
    public let command: String
    /// As `paddock tasks` says it: `running (pid 12)`, `stopped by you`…
    public let stateText: String
    public let restartsOnChange: Bool
    public let warning: String?
    public let canStart: Bool
    public let canStop: Bool
}

/// A site's tasks section: its tasks, what needs the user, and its forwarding.
public struct SiteTasksSection: Identifiable, Equatable, Sendable {
    public var id: String { site }
    public let site: String
    /// The site's folder, for display.
    public let folder: String
    /// Why nothing of the file runs (it breaks a rule); nil otherwise.
    public let problem: String?
    /// The file is new or changed and has something to approve.
    public let needsApproval: Bool
    /// No `paddock.json` (or an empty one): `Create paddock.json` is offered.
    public let canCreateStarterFile: Bool
    /// An approval is in force (`Turn Off` withdraws it).
    public let canRevoke: Bool
    public let tasks: [TaskRow]
    /// The forwarding in effect: `forward https://shop.test/app → 127.0.0.1:8080`.
    public let routes: [String]
    /// The site's notice (the file changed; forwarding not in effect…).
    public let notice: String?
}

/// What approving a site's `paddock.json` would approve: every command and forwarding line exactly as the daemon
/// reported them, and the hash naming exactly that.
public struct ApprovalPrompt: Equatable, Sendable {
    public let site: String
    public let folder: String
    /// `/Users/you/Code/shop/paddock.json would run:`
    public let heading: String
    /// `queue: php artisan queue:work`, `forward https://shop.test/app → 127.0.0.1:8080`, in full.
    public let lines: [String]
    public let hash: String
    /// The file changed since it was approved (the approved version keeps running until this is approved).
    public let isChange: Bool
}

extension AppModel {
    // MARK: - Derived

    /// Every site, with its tasks (or the offer to start a `paddock.json`).
    public var taskSites: [SiteTasksSection] {
        sites.map { site in
            let tasks = site.tasks
            let approval = tasks?.approval ?? .none
            let problem: String?
            if case .invalid(let reason) = approval {
                problem = Messages.tasksFileInvalid(site: site.name, reason: reason)
            } else {
                problem = nil
            }
            let inForce = approval == .approved || approval == .changed
            return SiteTasksSection(
                site: site.name, folder: Self.folder(of: site), problem: problem,
                needsApproval: approvalPrompt(for: site.name) != nil,
                canCreateStarterFile: approval == .none, canRevoke: inForce,
                tasks: taskRows(for: site.name),
                routes: tasks.map { Messages.routeLines($0, site: site) } ?? [],
                notice: tasks?.notice)
        }
    }

    /// The site's tasks that run (or would, once approved).
    public func taskRows(for siteName: String) -> [TaskRow] {
        guard let tasks = sites.first(where: { $0.name == siteName })?.tasks else { return [] }
        let inForce = tasks.approval == .approved || tasks.approval == .changed
        return tasks.tasks.map { task in
            var startable = false
            var stoppable = false
            switch task.state {
            case .running, .starting: stoppable = true
            case .stopped: startable = true
            case .crashed: startable = true; stoppable = true
            case .waitingForApproval, .alreadyRunning, .stopping, .leftFromEarlierRun: break
            }
            return TaskRow(site: siteName, name: task.name, command: task.run, stateText: Messages.taskState(task.state),
                           restartsOnChange: task.restartOnChange, warning: task.warning,
                           canStart: inForce && startable, canStop: inForce && stoppable)
        }
    }

    /// What approving the site's file would approve, as the status has it now; nil when there is nothing to approve.
    public func approvalPrompt(for siteName: String) -> ApprovalPrompt? {
        guard let site = sites.first(where: { $0.name == siteName }), let tasks = site.tasks,
              tasks.approval == .needsApproval || tasks.approval == .changed,
              !tasks.pending.isEmpty, let hash = tasks.pendingHash else { return nil }
        let folder = Self.folder(of: site)
        return ApprovalPrompt(site: site.name, folder: folder, heading: "\(folder)/\(SiteTasksFile.fileName) would run:",
                              lines: Messages.approvalLines(tasks.pending, site: site), hash: hash,
                              isChange: tasks.approval == .changed)
    }

    /// The open sheet's content is loaded, for the site it is open for.
    public var canApprove: Bool {
        guard let shown = shownApproval else { return false }
        return shown.site == approvalSite
    }

    private static func folder(of site: Site) -> String {
        Messages.displayName(site.path, limit: 256) ?? "?"
    }

    // MARK: - Approval

    /// Opens the approval sheet for the site and loads what its `paddock.json` holds now (a read). Approve stays
    /// off until that is in.
    public func showApproval(site: String) async {
        approvalSite = site
        shownApproval = nil
        await loadApproval(site: site)
    }

    /// Approves exactly what the open sheet shows (its hash). Nothing without a loaded sheet for this site. If the
    /// file changed after it was shown, the daemon refuses: its sentence goes to the error line and the sheet shows
    /// the new content, to be approved (or not) by the user again.
    public func approveTasks(site: String) async {
        guard approvalSite == site, let shown = shownApproval, shown.site == site else { return }
        guard let response = await send(.tasksApprove(site: site, hash: shown.hash)) else { return }
        finish(response)
        if case .error(let code, _) = response {
            if code == ErrorCode.tasksChanged, approvalSite == site {
                shownApproval = nil
                await loadApproval(site: site)
            }
        } else if approvalSite == site {
            dismissApproval()
        }
        await refresh()
    }

    /// `Not Now`.
    public func dismissApproval() {
        approvalSite = nil
        shownApproval = nil
    }

    private func loadApproval(site: String) async {
        _ = await send(.tasksStatus(site: site), timeout: 30)
        guard approvalSite == site else { return }
        shownApproval = approvalPrompt(for: site)
    }

    // MARK: - Actions

    /// Stops the site's tasks and withdraws their approval (`paddock tasks off`).
    public func revokeTasks(site: String) async { await perform(.tasksRevoke(site: site)) }
    public func startTask(site: String, task: String) async { await perform(.taskStart(site: site, task: task)) }
    public func stopTask(site: String, task: String) async { await perform(.taskStop(site: site, task: task)) }
    public func restartTask(site: String, task: String) async { await perform(.taskRestart(site: site, task: task)) }

    /// Writes the starter `paddock.json` (queue and scheduler) for a Laravel site; never overwrites.
    public func createStarterFile(site: String) async { await perform(.tasksInit(site: site)) }

    /// Opens the task's log with the system's default handler.
    public func openTaskLog(site: String, task: String) {
        guard let path = sites.first(where: { $0.name == site })?.tasks?.tasks.first(where: { $0.name == task })?.logPath
        else { return }
        openItem?(URL(fileURLWithPath: path))
    }
}
