import Foundation

/// Which folder this is, beyond its path: its inode and creation time. A folder deleted and made again, or another
/// folder renamed into its place, has another identity at the same path. (macOS hands volumes another device number
/// across reboots, so it isn't part of it.)
public struct FolderIdentity: Codable, Equatable, Hashable, Sendable {
    public let inode: UInt64
    public let birthSeconds: Int
    public let birthNanoseconds: Int

    public init(inode: UInt64, birthSeconds: Int, birthNanoseconds: Int) {
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    /// The identity of the directory at `path` (following links), or nil when there is none.
    public static func of(path: String) -> FolderIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FolderIdentity(inode: UInt64(info.st_ino),
                              birthSeconds: Int(info.st_birthtimespec.tv_sec),
                              birthNanoseconds: Int(info.st_birthtimespec.tv_nsec))
    }
}

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
    /// The identity of the folder at `sitePath` when it was approved: the approval holds only for that very
    /// folder. Nil in an approval stored before Paddock remembered it (adopted once at the next start when the
    /// site is served from that path; until then it holds for no folder).
    public var folder: FolderIdentity?

    public init(hash: String, file: StoredTasksFile, sitePath: String, stopped: Set<String>, goneSince: Date? = nil,
                folder: FolderIdentity? = nil) {
        self.hash = hash
        self.file = file
        self.sitePath = sitePath
        self.stopped = stopped
        self.goneSince = goneSince
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey { case hash, file, sitePath, stopped, goneSince, folder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decode(String.self, forKey: .hash)
        file = try c.decode(StoredTasksFile.self, forKey: .file)
        sitePath = try c.decode(String.self, forKey: .sitePath)
        stopped = (try? c.decodeIfPresent(Set<String>.self, forKey: .stopped)) ?? []
        goneSince = try? c.decodeIfPresent(Date.self, forKey: .goneSince)
        folder = try? c.decodeIfPresent(FolderIdentity.self, forKey: .folder)
    }

    /// It holds for the folder at `path` whose identity is `identity`: intact, approved for that path and that
    /// very folder.
    public func holds(at path: String, identity: FolderIdentity?) -> Bool {
        isIntact && sitePath == path && folder != nil && folder == identity
    }

    /// The stored definition follows the file's rules and hashes (with this build's canonical form) to `hash`.
    /// Anything else approves nothing: a hand-edited state file, or an approval made with another form.
    /// (Forwarding paths that today's rules refuse don't count against it: `TaskApproval.refusedPaths`.)
    public var isIntact: Bool { file.problem(checkingPaths: false) == nil && file.hash == hash }

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
        /// Forwarding paths of the running (approved) definition that today's rules refuse: left out.
        public var refusedPaths: [String] = []
        /// There is an approval for this path, but the folder there now is not the one it was approved for.
        public var folderReplaced = false

        init(approval: TaskApprovalState, running: SiteTasksFile?, pending: SiteTasksFile?, problem: String?,
             refusedPaths: [String] = [], folderReplaced: Bool = false) {
            self.approval = approval
            self.running = running
            self.pending = pending
            self.problem = problem
            self.refusedPaths = refusedPaths
            self.folderReplaced = folderReplaced
        }
    }

    /// The one rule: only an intact approval made for this very folder (its path and its identity) runs anything,
    /// and it runs its stored definition: a file that changed, went away or broke keeps the approved version
    /// running (`changed`). Without such an approval nothing runs; an approval for this path whose folder was
    /// replaced says so (`folderReplaced`).
    public static func evaluate(current: SiteTasksFile.LoadResult, approved: ApprovedTasks?,
                                sitePath: String, folderIdentity: FolderIdentity? = nil) -> Evaluation {
        let replaced = approved.map { $0.isIntact && $0.sitePath == sitePath && !$0.holds(at: sitePath, identity: folderIdentity) }
            ?? false
        var evaluation = evaluateFile(current: current, approved: replaced ? nil : approved, sitePath: sitePath)
        evaluation.folderReplaced = replaced
        // An approval made before today's path rules: its tasks run, the paths those rules refuse are left out,
        // and it needs approving again.
        if let running = evaluation.running {
            evaluation.refusedPaths = refusedPaths(running.proxy)
            if !evaluation.refusedPaths.isEmpty && evaluation.approval == .approved {
                evaluation = Evaluation(approval: .changed, running: running, pending: nil, problem: nil,
                                        refusedPaths: evaluation.refusedPaths)
            }
        }
        return evaluation
    }

    /// The paths of `routes` that today's rules refuse (one that is not plain, or a case twin of another).
    public static func refusedPaths(_ routes: [String: Int]) -> [String] {
        var refused = Set(routes.keys.filter { !SiteTasksFile.isProxyPath($0) })
        var seen: [String: String] = [:]
        for path in routes.keys.sorted() where !refused.contains(path) {
            if seen[path.lowercased()] != nil { refused.insert(path) } else { seen[path.lowercased()] = path }
        }
        return refused.sorted()
    }

    private static func evaluateFile(current: SiteTasksFile.LoadResult, approved: ApprovedTasks?,
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

extension TaskApproval {
    /// The routes that can be used: the paths today's rules accept, to a port that isn't Paddock's own.
    public static func usableRoutes(_ routes: [String: Int], reservedPorts: Set<Int>) -> [String: Int] {
        let refused = Set(refusedPaths(routes))
        return routes.filter { !refused.contains($0.key) && !reservedPorts.contains($0.value) }
    }

    /// The proxy routes Paddock serves: for each served site, the routes of an intact approval made for that very
    /// folder (the approved definition, whatever the file says now), less any to one of `reservedPorts` (Paddock's
    /// own).
    public static func routes(state: State, sites: [Site], reservedPorts: Set<Int>) -> [String: [String: Int]] {
        var routes: [String: [String: Int]] = [:]
        for site in sites {
            guard let approval = state.taskApprovals[site.name], let path = SiteTasksFile.realPath(site.path),
                  approval.holds(at: path, identity: FolderIdentity.of(path: path)) else { continue }
            let usable = usableRoutes(approval.file.proxy, reservedPorts: reservedPorts)
            if !usable.isEmpty { routes[site.name] = usable }
        }
        return routes
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
    /// Its stop was asked for and it is being given its grace.
    case stopping
    /// Processes an earlier run left in the task's group (its first process gone) still run: left alone, and no
    /// second copy is started (`paddock tasks restart <task> --force` stops them).
    case leftFromEarlierRun

    private enum Wire: Codable {
        case running(pid: Int32)
        case starting
        case stopped(reason: TaskStopReason?)
        case crashed(reason: String)
        case waitingForApproval
        case alreadyRunning(pid: Int32)
        case stopping
        case leftFromEarlierRun
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
        case .stopping?: self = .stopping
        case .leftFromEarlierRun?: self = .leftFromEarlierRun
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
        case .stopping: wire = .stopping
        case .leftFromEarlierRun: wire = .leftFromEarlierRun
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
    /// True when the crash was terminal: its supervisor gave up restarting it (5 failures in 60 seconds).
    /// Nil from an older daemon, and when it isn't crashed.
    public let gaveUp: Bool?

    public init(name: String, run: String, state: TaskState, restartOnChange: Bool, logPath: String, warning: String?,
                gaveUp: Bool? = nil) {
        self.name = name
        self.run = run
        self.state = state
        self.restartOnChange = restartOnChange
        self.logPath = logPath
        self.warning = warning
        self.gaveUp = gaveUp
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
    /// The command's length in Unicode scalars (as the 2000 limit counts), so a view can always show the whole
    /// command or say how long it is.
    public let runLength: Int?

    /// `runLength` defaults to the length of `run`.
    public init(name: String, run: String?, port: Int?, runLength: Int? = nil) {
        self.name = name
        self.run = run
        self.port = port
        self.runLength = runLength ?? run?.unicodeScalars.count
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
    /// The approved proxy routes in effect: path prefix -> port on 127.0.0.1.
    public let routes: [String: Int]
    /// The site's folder, symlinks resolved: where `pending` was read, and what approving names
    /// (`tasksApprove`'s `folder`). Nil from an older daemon.
    public let folder: String?

    public init(approval: TaskApprovalState, tasks: [TaskStatus], pending: [PendingTask], pendingHash: String?,
                notice: String?, routes: [String: Int] = [:], folder: String? = nil) {
        self.approval = approval
        self.tasks = tasks
        self.pending = pending
        self.pendingHash = pendingHash
        self.notice = notice
        self.routes = routes
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey { case approval, tasks, pending, pendingHash, notice, routes, folder }

    /// Tolerant: missing lists are empty, and one task this build can't read never costs the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approval = (try? c.decodeIfPresent(TaskApprovalState.self, forKey: .approval)) ?? .needsApproval
        tasks = (try? c.decodeIfPresent([Lenient<TaskStatus>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        pending = (try? c.decodeIfPresent([Lenient<PendingTask>].self, forKey: .pending))?.compactMap(\.value) ?? []
        pendingHash = try? c.decodeIfPresent(String.self, forKey: .pendingHash)
        notice = try? c.decodeIfPresent(String.self, forKey: .notice)
        routes = ((try? c.decodeIfPresent([String: Int].self, forKey: .routes)) ?? nil) ?? [:]
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
    }

    /// The pending lines for a file: its tasks by name, then its proxy paths, each shown as `Messages` shows
    /// text from a file.
    public static func pendingLines(_ file: SiteTasksFile) -> [PendingTask] {
        file.tasks.keys.sorted().map { name in
            let run = file.tasks[name]!.run
            return PendingTask(name: name, run: Messages.shownCommand(run), port: nil, runLength: run.unicodeScalars.count)
        }
            + file.proxy.keys.sorted().map { PendingTask(name: $0, run: nil, port: file.proxy[$0]) }
    }
}
