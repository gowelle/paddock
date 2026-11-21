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
    /// The site a tasks command acts on, and the status it was found in.
    static func taskSite(_ option: SiteOption) throws -> (Site, EngineStatus) {
        let status = try send(.status, timeout: 30)
        return (try option.site(in: status), status)
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
                  let served = status.sites.first(where: { $0.name == here.name }) else {
                let lines = Messages.siteTasksLines(status.sites)
                return print(lines.isEmpty ? Messages.noSiteHasTasks : lines.joined(separator: "\n"))
            }
            target = served
        } else {
            target = try site.site(in: status)
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
        if let hidden = file.tasks.keys.sorted().first(where: { !Messages.isShowable(file.tasks[$0]!.run) }) {
            throw CLI.failure(Messages.commandNotShowable(task: hidden))
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
        try CLI.send(.tasksRevoke(site: target.name))
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
        try CLI.send(.taskStop(site: target.name, task: task))
        print("\(task) stopped.")
    }
}

struct TaskRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart a task.")
    @Argument(help: "The task's name, such as queue.") var task: String
    @OptionGroup var site: SiteOption

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let (target, _) = try CLI.taskSite(site)
        let status = try CLI.send(.taskRestart(site: target.name, task: task))
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

    /// Prints what is appended to the file from now on, until interrupted; starts over when the file is
    /// rotated (replaced or emptied). Reads the file only: the daemon isn't involved.
    static func follow(_ url: URL) -> Never {
        var handle = try? FileHandle(forReadingFrom: url)
        var offset = (try? handle?.seekToEnd()) ?? 0
        var identity = fileIdentity(url)
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            let now = fileIdentity(url)
            if handle == nil || now?.inode != identity?.inode || (now?.size ?? 0) < offset {
                try? handle?.close()
                handle = try? FileHandle(forReadingFrom: url)
                offset = 0
                identity = now
            }
            guard let handle else { continue }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            guard !data.isEmpty else { continue }
            offset += UInt64(data.count)
            FileHandle.standardOutput.write(data)
        }
    }

    private static func fileIdentity(_ url: URL) -> (inode: UInt64, size: UInt64)? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt64(info.st_size))
    }
}
