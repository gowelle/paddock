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

extension ApprovalPrompt {
    /// The request that approves exactly this: its hash and its folder.
    public var approveRequest: Request { .tasksApprove(site: site, hash: hash, folder: resolvedFolder) }
}

/// What the approval sheet shows.
public enum ApprovalSheetState: Equatable, Sendable {
    /// Reading the site's `paddock.json` again.
    case loading
    /// Something to approve: Approve is on.
    case ready(ApprovalPrompt)
    /// Nothing to approve, and why: only `Close` is offered.
    case nothingToApprove(String)
    /// The file couldn't be read again (the daemon's sentence, or why it didn't answer): only `Close`.
    case failed(String)
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
    /// The site's folder as the daemon read it (symlinks resolved): approving names it. Nil from an older daemon.
    public let resolvedFolder: String?
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
                notice: tasks?.notice ?? site.notice)
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
            return TaskRow(site: siteName, name: task.name, command: task.run, stateText: Messages.taskState(task.state, task: task.name),
                           restartsOnChange: task.restartOnChange, warning: task.warning,
                           canStart: inForce && startable, canStop: inForce && stoppable)
        }
    }

    /// What approving the site's file would approve, as the status has it now; nil when there is nothing to approve.
    public func approvalPrompt(for siteName: String) -> ApprovalPrompt? {
        guard let site = sites.first(where: { $0.name == siteName }), let tasks = site.tasks,
              tasks.approval == .needsApproval || tasks.approval == .changed,
              !tasks.pending.isEmpty, let hash = tasks.pendingHash else { return nil }
        let folder = Messages.displayName(tasks.folder ?? site.path, limit: 256) ?? "?"
        return ApprovalPrompt(site: site.name, folder: folder, heading: "\(folder)/\(SiteTasksFile.fileName) would run:",
                              lines: Messages.approvalLines(tasks.pending, site: site), hash: hash,
                              isChange: tasks.approval == .changed, resolvedFolder: tasks.folder)
    }

    /// The prompt the open sheet shows, once loaded and while there is something to approve.
    public var shownApproval: ApprovalPrompt? {
        guard approvalSite != nil, case .ready(let prompt) = approvalState else { return nil }
        return prompt
    }

    /// The open sheet shows a prompt, for the site it is open for: the only time Approve is on.
    public var canApprove: Bool {
        guard let shown = shownApproval else { return false }
        return shown.site == approvalSite
    }

    private static func folder(of site: Site) -> String {
        Messages.displayName(site.path, limit: 256) ?? "?"
    }

    /// Shown when a site's file has nothing to approve and Paddock has no sentence for why.
    public static let nothingToApprove = "Nothing to approve."

    /// Why the site has nothing to approve, in the daemon's words where it has some: no such site, no
    /// `paddock.json`, the file's problem, the site's notice (the file went away or broke after it was approved).
    private func nothingToApproveReason(_ siteName: String) -> String {
        guard let site = sites.first(where: { $0.name == siteName }) else {
            return Messages.taskError(.unknownSite(siteName))
        }
        switch site.tasks?.approval ?? .none {
        case .none: return Messages.taskError(.noTasksFile(site: siteName))
        case .invalid(let reason): return Messages.tasksFileInvalid(site: siteName, reason: reason)
        case .changed: return site.tasks?.notice ?? Self.nothingToApprove
        case .approved, .needsApproval: return Self.nothingToApprove
        }
    }

    // MARK: - Approval

    /// Opens the approval sheet for the site, clean, and loads what its `paddock.json` holds now (a read). Approve
    /// stays off until a prompt is in.
    public func showApproval(site: String) async {
        approvalSite = site
        approvalError = nil
        await loadApproval(site: site)
    }

    /// Approves exactly what the open sheet shows (its hash). Nothing without a prompt shown for this site. If the
    /// file changed after it was shown, the daemon refuses: its sentence goes to the sheet (and the error line)
    /// and the sheet loads again, to show the new content (or why there is nothing to approve) for the user to
    /// decide on again.
    public func approveTasks(site: String) async {
        guard canApprove, approvalSite == site, let shown = shownApproval, shown.site == site else { return }
        let response = await act(shown.approveRequest)
        if case .error(let code, let message)? = response {
            approvalError = message
            if code == ErrorCode.tasksChanged, approvalSite == site { await loadApproval(site: site) }
        } else if response == nil {
            approvalError = lastError
        } else if approvalSite == site {
            dismissApproval()
        }
        await refresh()
    }

    /// `Not Now` or `Close`.
    public func dismissApproval() {
        approvalSite = nil
        approvalState = .loading
        approvalError = nil
    }

    /// Sets the sheet's state from every outcome of reading the site's file again.
    private func loadApproval(site: String) async {
        approvalState = .loading
        let outcome = await exchange(.tasksStatus(site: site), timeout: 30)
        guard approvalSite == site else { return }
        switch outcome {
        case .refused(let message), .failed(let message), .answer(.error(_, let message)):
            approvalState = .failed(message)
        case .answer:
            approvalState = approvalPrompt(for: site).map { .ready($0) } ?? .nothingToApprove(nothingToApproveReason(site))
        }
    }

    // MARK: - Actions

    /// Stops the site's tasks and withdraws their approval (`paddock tasks off`).
    public func revokeTasks(site: String) async { await taskAction(.tasksRevoke(site: site)) }
    public func startTask(site: String, task: String) async { await taskAction(.taskStart(site: site, task: task)) }
    public func stopTask(site: String, task: String) async { await taskAction(.taskStop(site: site, task: task)) }
    public func restartTask(site: String, task: String) async { await taskAction(.taskRestart(site: site, task: task)) }

    /// Writes the starter `paddock.json` (queue and scheduler) for a Laravel site; never overwrites.
    public func createStarterFile(site: String) async { await taskAction(.tasksInit(site: site)) }

    /// Shows the task's log (in the Logs window, where the app has one); says so when there is none yet.
    public func openTaskLog(site: String, task: String) {
        guard let path = sites.first(where: { $0.name == site })?.tasks?.tasks.first(where: { $0.name == task })?.logPath
        else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            showNotice("\(task) hasn't written a log yet.", tasks: true)
            return
        }
        show(log: URL(fileURLWithPath: path))
    }

    /// A log goes to the Logs window when there is one, else to the system's default handler.
    func show(log: URL) {
        if let showLog { showLog(log) } else { openItem?(log) }
    }

    private func taskAction(_ request: Request) async {
        _ = await act(request)
        await refresh()
    }
}
