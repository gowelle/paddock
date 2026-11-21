import Foundation

/// A site's approved tasks, as kept in state.json: the definition exactly as approved (it is what runs, even
/// after the file changes), the folder it was approved for, and the tasks the user stopped by hand.
public struct ApprovedTasks: Codable, Equatable, Sendable {
    /// `SiteTasksFile.hash` of `file`.
    public let hash: String
    public let file: StoredTasksFile
    /// The site's folder, symlinks resolved, when it was approved. The approval holds only for that folder.
    public let sitePath: String
    /// Tasks the user stopped by hand: they stay stopped (across daemon restarts) until started again.
    public var stopped: Set<String>
    /// When the site was last seen gone (its folder missing or no longer a site); the approval is dropped a
    /// while after that. Nil while the site is there.
    public var goneSince: Date?

    public init(hash: String, file: StoredTasksFile, sitePath: String, stopped: Set<String>, goneSince: Date? = nil) {
        self.hash = hash
        self.file = file
        self.sitePath = sitePath
        self.stopped = stopped
        self.goneSince = goneSince
    }

    private enum CodingKeys: String, CodingKey { case hash, file, sitePath, stopped, goneSince }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decode(String.self, forKey: .hash)
        file = try c.decode(StoredTasksFile.self, forKey: .file)
        sitePath = try c.decode(String.self, forKey: .sitePath)
        stopped = (try? c.decodeIfPresent(Set<String>.self, forKey: .stopped)) ?? []
        goneSince = try? c.decodeIfPresent(Date.self, forKey: .goneSince)
    }

    /// The stored definition follows the file's rules and hashes (with this build's canonical form) to `hash`.
    /// Anything else approves nothing: a hand-edited state file, or an approval made with another form.
    public var isIntact: Bool { file.problem() == nil && file.hash == hash }

    /// How long an approval is kept after its site went away, in case the folder comes back.
    public static let keptAfterSiteGone: TimeInterval = 30 * 24 * 60 * 60
}

/// What a site's approval means for what runs.
public enum TaskApproval {
    public struct Evaluation: Equatable, Sendable {
        public let approval: TaskApprovalState
        /// The approved definition to run; nil runs nothing.
        public let running: SiteTasksFile?
        /// What approving now would approve (the current file), when that differs from what runs.
        public let pending: SiteTasksFile?
        /// Why the current file can't be used, when it can't.
        public let problem: String?
    }

    /// The one rule: only an intact approval made for this very folder runs anything, and it runs its stored
    /// definition: a file that changed, went away or broke keeps the approved version running (`changed`).
    /// Without such an approval nothing runs.
    public static func evaluate(current: SiteTasksFile.LoadResult, approved: ApprovedTasks?,
                                sitePath: String) -> Evaluation {
        if let approved, approved.isIntact, approved.sitePath == sitePath {
            switch current {
            case .file(_, let hash) where hash == approved.hash:
                return Evaluation(approval: .approved, running: approved.file, pending: nil, problem: nil)
            case .file(let file, _):
                return Evaluation(approval: .changed, running: approved.file, pending: file, problem: nil)
            case .none:
                return Evaluation(approval: .changed, running: approved.file, pending: nil, problem: nil)
            case .invalid(let reason):
                return Evaluation(approval: .changed, running: approved.file, pending: nil, problem: reason)
            }
        }
        switch current {
        case .none:
            return Evaluation(approval: .none, running: nil, pending: nil, problem: nil)
        case .file(let file, _) where file.isEmpty:
            return Evaluation(approval: .none, running: nil, pending: nil, problem: nil)
        case .file(let file, _):
            return Evaluation(approval: .needsApproval, running: nil, pending: file, problem: nil)
        case .invalid(let reason):
            return Evaluation(approval: .invalid(reason: reason), running: nil, pending: nil, problem: reason)
        }
    }
}

// MARK: - Status

/// Where a site's tasks stand with the user's approval.
public enum TaskApprovalState: Codable, Equatable, Sendable {
    /// No `paddock.json` (or one with nothing in it).
    case none
    /// A `paddock.json` nobody approved: nothing runs.
    case needsApproval
    case approved
    /// The file changed (or went away) since it was approved: the approved version keeps running.
    case changed
    /// The file breaks a rule and nothing of it was ever approved.
    case invalid(reason: String)

    private enum Wire: Codable {
        case none, needsApproval, approved, changed
        case invalid(reason: String)
    }

    /// A state this build doesn't know reads as `needsApproval`: never as approved.
    public init(from decoder: Decoder) throws {
        switch try? Wire(from: decoder) {
        case .none?: self = .none
        case .needsApproval?: self = .needsApproval
        case .approved?: self = .approved
        case .changed?: self = .changed
        case .invalid(let reason)?: self = .invalid(reason: reason)
        case nil: self = .needsApproval
        }
    }

    public func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .none: wire = .none
        case .needsApproval: wire = .needsApproval
        case .approved: wire = .approved
        case .changed: wire = .changed
        case .invalid(let reason): wire = .invalid(reason: reason)
        }
        try wire.encode(to: encoder)
    }
}

/// Why a task is stopped.
public enum TaskStopReason: String, Codable, Sendable {
    /// The user stopped it (it stays stopped until started).
    case byYou
    /// It kept finishing by itself (exit status 0), so it isn't a long-running command.
    case exited
    /// `autostart` is false and nobody started it.
    case notAutostart
    /// From a newer build.
    case unknown

    public init(from decoder: Decoder) throws {
        self = TaskStopReason(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

public enum TaskState: Codable, Equatable, Sendable {
    case running(pid: Int32)
    case starting
    case stopped(reason: TaskStopReason?)
    /// Exited with an error: `reason` says whether Paddock restarts it or gave up.
    case crashed(reason: String)
    /// The site's `paddock.json` isn't approved, so it doesn't run.
    case waitingForApproval
    /// A process an earlier Paddock left running that Paddock can't prove is its own: left alone, and no
    /// second copy is started.
    case alreadyRunning(pid: Int32)

    private enum Wire: Codable {
        case running(pid: Int32)
        case starting
        case stopped(reason: TaskStopReason?)
        case crashed(reason: String)
        case waitingForApproval
        case alreadyRunning(pid: Int32)
    }

    /// A state this build doesn't know reads as crashed with an "unknown state" reason.
    public init(from decoder: Decoder) throws {
        switch try? Wire(from: decoder) {
        case .running(let pid)?: self = .running(pid: pid)
        case .starting?: self = .starting
        case .stopped(let reason)?: self = .stopped(reason: reason)
        case .crashed(let reason)?: self = .crashed(reason: reason)
        case .waitingForApproval?: self = .waitingForApproval
        case .alreadyRunning(let pid)?: self = .alreadyRunning(pid: pid)
        case nil: self = .crashed(reason: "unknown state")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .running(let pid): wire = .running(pid: pid)
        case .starting: wire = .starting
        case .stopped(let reason): wire = .stopped(reason: reason)
        case .crashed(let reason): wire = .crashed(reason: reason)
        case .waitingForApproval: wire = .waitingForApproval
        case .alreadyRunning(let pid): wire = .alreadyRunning(pid: pid)
        }
        try wire.encode(to: encoder)
    }
}

/// One task as clients see it. Text from `paddock.json` is already sanitised for display.
public struct TaskStatus: Codable, Equatable, Sendable {
    public let name: String
    public let run: String
    public let state: TaskState
    public let restartOnChange: Bool
    public let logPath: String
    /// A sentence about the task (say, that Paddock cut its stop short when it shut down).
    public let warning: String?

    public init(name: String, run: String, state: TaskState, restartOnChange: Bool, logPath: String, warning: String?) {
        self.name = name
        self.run = run
        self.state = state
        self.restartOnChange = restartOnChange
        self.logPath = logPath
        self.warning = warning
    }
}

/// One line of what approving would approve: a task and its command, or a proxy path and its port.
public struct PendingTask: Codable, Equatable, Sendable {
    /// A task's name, or a proxy path such as `/app`.
    public let name: String
    /// The task's command as Paddock shows it; nil for a proxy line.
    public let run: String?
    /// For a proxy line, the port on this Mac the path is forwarded to.
    public let port: Int?

    public init(name: String, run: String?, port: Int?) {
        self.name = name
        self.run = run
        self.port = port
    }
}

/// A site's tasks as clients see them.
public struct SiteTasksStatus: Codable, Equatable, Sendable {
    public let approval: TaskApprovalState
    /// The tasks that run (or would, once approved).
    public let tasks: [TaskStatus]
    /// What approving would approve, only while the approval is `needsApproval` or `changed`.
    public let pending: [PendingTask]
    /// The hash of what `pending` shows: approving names it, so only what was shown is approved.
    public let pendingHash: String?
    public let notice: String?

    public init(approval: TaskApprovalState, tasks: [TaskStatus], pending: [PendingTask], pendingHash: String?,
                notice: String?) {
        self.approval = approval
        self.tasks = tasks
        self.pending = pending
        self.pendingHash = pendingHash
        self.notice = notice
    }

    private enum CodingKeys: String, CodingKey { case approval, tasks, pending, pendingHash, notice }

    /// Tolerant: missing lists are empty, and one task this build can't read never costs the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = (try? c.decodeIfPresent(TaskApprovalState.self, forKey: .approval)) ?? .needsApproval
        tasks = (try? c.decodeIfPresent([Lenient<TaskStatus>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        pending = (try? c.decodeIfPresent([Lenient<PendingTask>].self, forKey: .pending))?.compactMap(\.value) ?? []
        pendingHash = try? c.decodeIfPresent(String.self, forKey: .pendingHash)
        notice = try? c.decodeIfPresent(String.self, forKey: .notice)
    }

    /// The pending lines for a file: its tasks by name, then its proxy paths, each shown as `Messages` shows
    /// text from a file.
    static func pendingLines(_ file: SiteTasksFile) -> [PendingTask] {
        file.tasks.keys.sorted().map { PendingTask(name: $0, run: Messages.shownCommand(file.tasks[$0]!.run), port: nil) }
            + file.proxy.keys.sorted().map { PendingTask(name: $0, run: nil, port: file.proxy[$0]) }
    }
}
