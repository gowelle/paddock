import ArgumentParser
import Darwin
import Foundation
import PaddockCore

/// `paddock tasks …`: the commands a site's `paddock.json` keeps running (queue worker, scheduler…), each
/// only after the user approved them.
struct TaskGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasks",
        abstract: "Run a site's own commands (queue worker, scheduler…) from its paddock.json.",
        subcommands: [
            TasksList.self, TasksInit.self, TasksOn.self, TasksOff.self, TaskStart.self, TaskStop.self, TaskRestart.self,
            TaskLogs.self,
        ],
        defaultSubcommand: TasksList.self
    )
}

/// `--site <name>`: the site a tasks command is about, when not the one containing the current folder.
struct SiteOption: ParsableArguments {
    @Option(name: .customLong("site"), help: "The site (default: the site containing the current folder).")
    var name: String?

    /// The named site, or the one containing the current folder; a sentence and exit 1 when there is none.
    func site(in status: EngineStatus) throws -> Site {
        try CLI.site(named: name, in: status)
    }
}

extension CLI {
    /// The site a tasks command acts on, and the status after reading its `paddock.json` again.
    static func taskSite(_ option: SiteOption) throws -> (Site, EngineStatus) {
        let site = try option.site(in: try send(.status, timeout: 30))
        return try freshTasks(of: site.name)
    }

    /// The site and the status after the daemon read the site's `paddock.json` again (a read-only request).
    static func freshTasks(of name: String) throws -> (Site, EngineStatus) {
        let status = try send(.tasksStatus(site: name), timeout: 30)
        guard let site = status.sites.first(where: { $0.name == name }) else {
            throw failure(Messages.taskError(.unknownSite(name)))
        }
        return (site, status)
    }

    /// Runs `work`; if it takes more than three seconds, says it is waiting for the task to finish.
    @discardableResult
    static func whileWaiting<T>(for task: String, _ work: () throws -> T) rethrows -> T {
        let notice = SlowNotice()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { notice.show(Messages.waitingForTask(task)) }
        defer { notice.finish() }
        return try work()
    }

    /// The task as the user typed it, if the site has it (as running or approved) or has a log for it.
    static func task(_ typed: String, of site: Site) throws -> String {
        let known = site.tasks?.tasks.contains { $0.name == typed } ?? false
        let logged = SiteTasksFile.isTaskName(typed)
            && FileManager.default.fileExists(atPath: paths.taskLog(site: site.name, task: typed).path)
        guard known || logged else { throw failure(Messages.taskError(.unknownTask(site: site.name, task: typed))) }
        return typed
    }

    /// `queue is running (pid 12).`, or the task's state when it isn't running.
    static func taskLine(_ name: String, site: String, in status: EngineStatus) -> String {
        guard let task = status.sites.first(where: { $0.name == site })?.tasks?.tasks.first(where: { $0.name == name }) else {
            return "\(name): unknown"
        }
        if case .running(let pid) = task.state { return "\(name) is running (pid \(pid))." }
        return "\(name): \(Messages.taskState(task.state))"
    }
}

struct TasksList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List a site's tasks, or every site's outside a site folder.")
    @OptionGroup var site: SiteOption

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        let target: Site
        if site.name == nil {
            let registry = SiteRegistry(state: StateStore(paths: CLI.paths).load(),
                                        defaultPHP: status.defaultPHP ?? PHPVersion(major: 8, minor: 5))
            guard let here = registry.site(containing: CLI.currentDirectory),
                  status.sites.contains(where: { $0.name == here.name }) else {
                let lines = Messages.siteTasksLines(status.sites)
                return print(lines.isEmpty ? Messages.noSiteHasTasks : lines.joined(separator: "\n"))
            }
            target = try CLI.freshTasks(of: here.name).0
        } else {
            target = try CLI.freshTasks(of: try site.site(in: status).name).0
        }
        guard let tasks = target.tasks, tasks.approval != .none else {
            return print(Messages.taskError(.noTasksFile(site: target.name)))
        }
        switch tasks.approval {
        case .needsApproval: print(Messages.tasksWaitingForApproval(site: target.name))
        case .invalid(let reason): print(Messages.tasksFileInvalid(site: target.name, reason: reason))
        case .approved, .changed, .none: print(Messages.taskTable(tasks))
        }
    }
}

struct TasksInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Write a starter paddock.json for a Laravel project (never over one).")
    @OptionGroup var site: SiteOption

    func run() throws {
        let (target, _) = try CLI.taskSite(site)
        let folder = URL(fileURLWithPath: SiteTasksFile.realPath(target.path) ?? target.path, isDirectory: true)
        let file = folder.appendingPathComponent(SiteTasksFile.fileName)
        var info = stat()
        if lstat(file.path, &info) == 0 {
            throw CLI.failure(Messages.taskError(.fileExists(site: target.name, path: file.path)))
        }
        guard SiteTasksFile.starter(forSiteAt: folder) != nil else {
            print(Messages.tasksExample(site: target.name, path: file.path))
            print("")
            print(SiteTasksFile.example, terminator: "")
            return
        }
        try CLI.refuseChangesFromDevelopmentBuild()
        try CLI.send(.tasksInit(site: target.name))
        print(Messages.tasksFileWritten(path: file.path))
    }
}

struct TasksOn: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Show every command in the site's paddock.json and approve them, so they run with Paddock.")
    @OptionGroup var site: SiteOption
    @Flag(name: .customLong("show"), help: "Only show what would be approved.") var show = false

    func run() throws {
        if !show { try CLI.refuseChangesFromDevelopmentBuild() }
        let (target, _) = try CLI.taskSite(site)
        let folder = URL(fileURLWithPath: SiteTasksFile.realPath(target.path) ?? target.path, isDirectory: true)
        let path = folder.appendingPathComponent(SiteTasksFile.fileName).path
        let file: SiteTasksFile
        let hash: String
        switch SiteTasksFile.load(siteFolder: folder) {
        case .none: throw CLI.failure(Messages.taskError(.noTasksFile(site: target.name)))
        case .invalid(let reason): throw CLI.failure(Messages.taskError(.invalid(site: target.name, reason: reason)))
        case .file(let found, let foundHash):
            file = found
            hash = foundHash
        }
        guard !file.isEmpty else { return print(Messages.nothingToApprove(path: path)) }
        // Exactly what will run, each command as written (a command that can't be shown that way is refused).
        print(show ? "\(path) would run:" : "Approving what \(path) runs:")
        for line in Messages.approvalLines(SiteTasksStatus.pendingLines(file)) { print("  " + line) }
        for task in file.tasks.keys.sorted() {
            if let problem = Messages.commandProblem(in: file.tasks[task]!.run) {
                throw CLI.failure(Messages.commandNotShowable(task: task, problem: problem))
            }
        }
        guard !show else { return print("Approve it with: paddock tasks on") }
        let status = try CLI.send(.tasksApprove(site: target.name, hash: hash))
        print("Approved.")
        for task in status.sites.first(where: { $0.name == target.name })?.tasks?.tasks ?? [] {
            print("  \(task.name): \(Messages.taskState(task.state))")
        }
    }
}

struct TasksOff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Stop the site's tasks and withdraw their approval.")
    @OptionGroup var site: SiteOption

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let (target, _) = try CLI.taskSite(site)
        try CLI.whileWaiting(for: "\(target.name)'s tasks") { try CLI.send(.tasksRevoke(site: target.name)) }
        print("Stopped \(target.name)'s tasks and withdrew their approval.")
    }
}

struct TaskStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a task.")
    @Argument(help: "The task's name, such as queue.") var task: String
    @OptionGroup var site: SiteOption

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let (target, _) = try CLI.taskSite(site)
        let status = try CLI.send(.taskStart(site: target.name, task: task))
        print(CLI.taskLine(task, site: target.name, in: status))
    }
}

struct TaskStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop a task; it stays stopped, also when Paddock restarts, until started.")
    @Argument(help: "The task's name, such as queue.") var task: String
    @OptionGroup var site: SiteOption

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let (target, _) = try CLI.taskSite(site)
        try CLI.whileWaiting(for: task) { try CLI.send(.taskStop(site: target.name, task: task)) }
        print("\(task) stopped.")
    }
}

struct TaskRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart a task.")
    @Argument(help: "The task's name, such as queue.") var task: String
    @Flag(name: .customLong("force"),
          help: "Also stop the processes an earlier run of this task left behind in the site's folder (and only those).")
    var force = false
    @OptionGroup var site: SiteOption

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let (target, _) = try CLI.taskSite(site)
        let status = try CLI.whileWaiting(for: task) {
            try CLI.send(force ? .taskForceRestart(site: target.name, task: task) : .taskRestart(site: target.name, task: task))
        }
        if force, let report = status.sites.first(where: { $0.name == target.name })?.tasks?.tasks
            .first(where: { $0.name == task })?.warning {
            print(report)
        }
        print(CLI.taskLine(task, site: target.name, in: status))
    }
}

struct TaskLogs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show the end of a task's log.")
    @Argument(help: "The task's name, such as queue.") var task: String
    @Flag(name: .short, help: "Keep showing new lines as they are written (Ctrl-C to stop).") var follow = false
    @Option(name: .customShort("n"), help: "How many lines to show.") var lines = 50
    @OptionGroup var site: SiteOption

    func run() throws {
        let (target, _) = try CLI.taskSite(site)
        let name = try CLI.task(task, of: target)
        let log = CLI.paths.taskLog(site: target.name, task: name)
        print(log.path)
        let last = Self.lastLines(of: log, count: max(0, lines))
        if !last.isEmpty { print(last.joined(separator: "\n")) }
        fflush(stdout)
        guard follow else { return }
        Self.follow(log)
    }

    /// The last `count` lines of a file (read from its end only).
    static func lastLines(of url: URL, count: Int) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window = UInt64(max(256 * 1024, count * 1024))
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).dropLast(text.hasSuffix("\n") ? 1 : 0).suffix(count))
    }

    /// Prints what is appended to the file from now on, until interrupted, across rotations (`LogFollower`).
    /// Reads the file only: the daemon isn't involved.
    static func follow(_ url: URL) -> Never {
        let follower = LogFollower(url: url)
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            let data = follower.read()
            if !data.isEmpty { FileHandle.standardOutput.write(data) }
        }
    }
}
