import CryptoKit
import Darwin
import Foundation

/// One task in `paddock.json`: a command line the site needs kept running.
public struct TaskDefinition: Codable, Equatable, Sendable {
    /// One command line, run by the user's shell in the site's folder. Never changed by Paddock.
    public let run: String
    /// Nil when the file doesn't say (its default comes from the command; an explicit value is approved as such).
    public let restartOnChange: Bool?
    /// Nil means true: the task starts with Paddock.
    public let autostart: Bool?
    /// Seconds a stop waits after SIGTERM before SIGKILL; nil means `defaultStopSeconds`.
    public let stopSeconds: Int?

    public static let defaultStopSeconds = 30
    public static let stopSecondsRange = 1...300

    public init(run: String, restartOnChange: Bool?, autostart: Bool?, stopSeconds: Int?) {
        self.run = run
        self.restartOnChange = restartOnChange
        self.autostart = autostart
        self.stopSeconds = stopSeconds
    }

    public var startsWithPaddock: Bool { autostart ?? true }
    public var stopGrace: Int { stopSeconds ?? Self.defaultStopSeconds }
    /// Whether the task restarts when the site's code changes. Off unless the file turns it on; the default
    /// that depends on the command comes with watching the code.
    public var restartsOnChange: Bool { restartOnChange ?? false }
}

/// A site's `paddock.json`: the commands Paddock keeps running for it, and the paths of the site it forwards
/// to local ports. Read only by `load`, which applies every rule; nothing runs until the user approves it.
public struct SiteTasksFile: Codable, Equatable, Sendable {
    public let tasks: [String: TaskDefinition]
    /// Path prefix (`/app`) -> a port on 127.0.0.1.
    public let proxy: [String: Int]

    public init(tasks: [String: TaskDefinition], proxy: [String: Int]) {
        self.tasks = tasks
        self.proxy = proxy
    }

    private enum CodingKeys: String, CodingKey { case tasks, proxy }

    /// Tolerant: missing sections are empty. (A stored definition is checked with `problem` before use.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([String: TaskDefinition].self, forKey: .tasks) ?? [:]
        proxy = try c.decodeIfPresent([String: Int].self, forKey: .proxy) ?? [:]
    }

    public static let fileName = "paddock.json"
    public static let maximumBytes = 64 * 1024
    public static let maximumTasks = 16
    public static let maximumProxyPaths = 16
    public static let maximumRunLength = 2000
    public static let maximumRunBytes = 8000
    public static let proxyPorts = 1024...65535

    public var isEmpty: Bool { tasks.isEmpty && proxy.isEmpty }

    public enum LoadResult: Equatable, Sendable {
        /// No `paddock.json` in the site's folder.
        case none
        case file(SiteTasksFile, hash: String)
        /// A file that breaks a rule; `reason` is a plain phrase (`unknown key "taks"`), text from the file in it
        /// already sanitised.
        case invalid(reason: String)
    }

    // MARK: - Reading

    /// Reads `<siteFolder>/paddock.json`: only a regular file, or a link to one inside the site's folder; at
    /// most 64 KB, checked before reading; never blocking on a FIFO. A file that changes while it is read is
    /// read once more.
    public static func load(siteFolder: URL) -> LoadResult {
        if case .result(let first) = readOnce(siteFolder: siteFolder) { return first }
        switch readOnce(siteFolder: siteFolder) {
        case .result(let second): return second
        case .changing: return .invalid(reason: TasksFileProblem.changing)
        }
    }

    private enum ReadOutcome {
        case result(LoadResult)
        case changing
    }

    private static func readOnce(siteFolder: URL) -> ReadOutcome {
        guard let root = realPath(siteFolder.path) else { return .result(.none) }
        let path = root + "/" + fileName
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return .result(errno == ENOENT || errno == ENOTDIR ? .none : .invalid(reason: TasksFileProblem.unreadable))
        }
        var target = path
        if (info.st_mode & S_IFMT) == S_IFLNK {
            guard let resolved = realPath(path) else { return .result(.invalid(reason: TasksFileProblem.outside)) }
            guard resolved.hasPrefix(root == "/" ? "/" : root + "/") else { return .result(.invalid(reason: TasksFileProblem.outside)) }
            target = resolved
            guard stat(target, &info) == 0 else { return .result(.invalid(reason: TasksFileProblem.unreadable)) }
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .result(.invalid(reason: TasksFileProblem.notRegular)) }
        guard info.st_size <= maximumBytes else { return .result(.invalid(reason: TasksFileProblem.tooLarge)) }

        let fd = open(target, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .result(.invalid(reason: TasksFileProblem.unreadable)) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            return .result(.invalid(reason: TasksFileProblem.notRegular))
        }
        guard before.st_size <= maximumBytes else { return .result(.invalid(reason: TasksFileProblem.tooLarge)) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maximumBytes {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .result(.invalid(reason: TasksFileProblem.unreadable))
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard data.count <= maximumBytes else { return .result(.invalid(reason: TasksFileProblem.tooLarge)) }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size, after.st_ino == before.st_ino,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec, Int64(data.count) == Int64(after.st_size)
        else { return .changing }
        return .result(parse(data))
    }

    /// What a cache of the file is keyed on: the entry itself and, for a link, what it points to. Nil when the
    /// site has no `paddock.json`. Only `lstat`/`stat`: cheap enough for every site on every refresh.
    public struct Stamp: Equatable, Sendable {
        let entries: [[Int64]]
    }

    public static func stamp(siteFolder: URL) -> Stamp? {
        func fields(_ info: stat) -> [Int64] {
            [Int64(info.st_dev), Int64(bitPattern: UInt64(info.st_ino)), Int64(info.st_size), Int64(info.st_mode),
             Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
             Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
        }
        let root = realPath(siteFolder.path) ?? siteFolder.path
        let path = root + "/" + fileName
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var entries = [fields(info)]
        if (info.st_mode & S_IFMT) == S_IFLNK {
            var target = stat()
            entries.append(stat(path, &target) == 0 ? fields(target) : [])
        }
        return Stamp(entries: entries)
    }

    /// `path` with every symlink resolved, if it exists.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Rules

    /// Parses the file's text and applies every rule.
    public static func parse(_ data: Data) -> LoadResult {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .invalid(reason: TasksFileProblem.notJSON)
        }
        guard let top = object as? [String: Any] else { return .invalid(reason: TasksFileProblem.notObject) }
        for key in top.keys.sorted() where key != "tasks" && key != "proxy" {
            return .invalid(reason: TasksFileProblem.unknownKey(key))
        }
        var tasks: [String: TaskDefinition] = [:]
        if let section = top["tasks"] {
            guard let entries = section as? [String: Any] else { return .invalid(reason: TasksFileProblem.tasksNotObject) }
            for name in entries.keys.sorted() {
                guard isTaskName(name) else { return .invalid(reason: TasksFileProblem.badTaskName(name)) }
                switch task(named: name, entries[name]!) {
                case .success(let definition): tasks[name] = definition
                case .failure(let problem): return .invalid(reason: problem.reason)
                }
            }
        }
        var proxy: [String: Int] = [:]
        if let section = top["proxy"] {
            guard let entries = section as? [String: Any] else { return .invalid(reason: TasksFileProblem.proxyNotObject) }
            for path in entries.keys.sorted() {
                guard isProxyPath(path) else { return .invalid(reason: TasksFileProblem.badProxyPath(path)) }
                guard let port = wholeNumber(entries[path]!), proxyPorts.contains(port) else {
                    return .invalid(reason: TasksFileProblem.badProxyPort(path))
                }
                proxy[path] = port
            }
        }
        let file = SiteTasksFile(tasks: tasks, proxy: proxy)
        if let problem = file.problem() { return .invalid(reason: problem) }
        return .file(file, hash: file.hash)
    }

    private struct ParseProblem: Error { let reason: String }

    private static func task(named name: String, _ value: Any) -> Result<TaskDefinition, ParseProblem> {
        guard let options = value as? [String: Any] else { return .failure(ParseProblem(reason: TasksFileProblem.taskNotObject(name))) }
        for key in options.keys.sorted() where !["run", "restartOnChange", "autostart", "stopSeconds"].contains(key) {
            return .failure(ParseProblem(reason: TasksFileProblem.unknownKey(key)))
        }
        guard let raw = options["run"] else { return .failure(ParseProblem(reason: TasksFileProblem.missingRun(name))) }
        guard let run = raw as? String else { return .failure(ParseProblem(reason: TasksFileProblem.badRun(name))) }
        var flags: [String: Bool] = [:]
        for key in ["restartOnChange", "autostart"] {
            guard let value = options[key] else { continue }
            guard let flag = boolean(value) else { return .failure(ParseProblem(reason: TasksFileProblem.badFlag(key, name))) }
            flags[key] = flag
        }
        var stopSeconds: Int?
        if let value = options["stopSeconds"] {
            guard let seconds = wholeNumber(value) else { return .failure(ParseProblem(reason: TasksFileProblem.badStopSeconds(name))) }
            stopSeconds = seconds
        }
        return .success(TaskDefinition(run: run, restartOnChange: flags["restartOnChange"], autostart: flags["autostart"],
                                       stopSeconds: stopSeconds))
    }

    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON number with no fraction that fits an Int; never a boolean.
    private static func wholeNumber(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    /// The rules for the values themselves; also applied to an approved definition read back from state.json.
    public func problem() -> String? {
        if tasks.count > Self.maximumTasks { return TasksFileProblem.tooManyTasks }
        for name in tasks.keys.sorted() {
            guard Self.isTaskName(name) else { return TasksFileProblem.badTaskName(name) }
            let definition = tasks[name]!
            guard Self.isRunLine(definition.run) else { return TasksFileProblem.badRun(name) }
            if let seconds = definition.stopSeconds, !TaskDefinition.stopSecondsRange.contains(seconds) {
                return TasksFileProblem.badStopSeconds(name)
            }
        }
        if proxy.count > Self.maximumProxyPaths { return TasksFileProblem.tooManyProxyPaths }
        for path in proxy.keys.sorted() {
            guard Self.isProxyPath(path) else { return TasksFileProblem.badProxyPath(path) }
            guard Self.proxyPorts.contains(proxy[path]!) else { return TasksFileProblem.badProxyPort(path) }
        }
        return nil
    }

    /// `^[a-z][a-z0-9-]{0,30}$`
    public static func isTaskName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...31).contains(bytes.count), (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "-") }
    }

    /// `^/[A-Za-z0-9._~/-]{1,100}$` without `..` or `//`.
    static func isProxyPath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard (2...101).contains(bytes.count), bytes[0] == UInt8(ascii: "/"), !path.contains(".."), !path.contains("//")
        else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || "._~/-".utf8.contains(byte)
        }
    }

    /// 1…2000 Unicode scalars and at most 8000 bytes, with no NUL and no line break.
    public static func isRunLine(_ run: String) -> Bool {
        (1...maximumRunLength).contains(run.unicodeScalars.count) && run.utf8.count <= maximumRunBytes
            && !run.unicodeScalars.contains { $0 == "\0" || $0 == "\n" || $0 == "\r" }
    }

    // MARK: - The canonical form

    /// What approval is tied to: every task (by name) with its defaults applied and `restartOnChange` as written
    /// (unset stays unset), and every proxy line, each field length-prefixed so that no two files share a form.
    /// Formatting and key order never change it. Versioned: a future form is a different approval, never
    /// mistaken for this one.
    public var canonicalForm: String {
        func field(_ name: String, _ value: String) -> String { "\(name) \(value.utf8.count):\(value)\n" }
        var text = "paddock.json tasks v1\n"
        text += "tasks \(tasks.count)\n"
        for name in tasks.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let definition = tasks[name]!
            text += field("task", name)
            text += field("run", definition.run)
            text += "autostart \(definition.startsWithPaddock)\n"
            text += "stopSeconds \(definition.stopGrace)\n"
            text += "restartOnChange \(definition.restartOnChange.map { "\($0)" } ?? "unset")\n"
        }
        text += "proxy \(proxy.count)\n"
        for path in proxy.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            text += field("path", path) + "port \(proxy[path]!)\n"
        }
        return text
    }

    /// `v1:` and the SHA-256 of `canonicalForm`, in hex.
    public var hash: String {
        "v1:" + SHA256.hash(data: Data(canonicalForm.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Starting a file

    /// For a Laravel project (an `artisan` file at its root): a file running its queue worker and scheduler.
    /// Nil for any other folder.
    public static func starter(forSiteAt folder: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("artisan").path,
                                             isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return """
        {
          "tasks": {
            "queue": { "run": "php artisan queue:work" },
            "scheduler": { "run": "php artisan schedule:work" }
          }
        }

        """
    }

    /// What `paddock tasks init` shows for a project that isn't Laravel.
    public static let example = """
    {
      "tasks": {
        "worker": { "run": "npm run worker" }
      }
    }

    """
}

/// The file Paddock keeps in state.json for an approval: the definition exactly as approved.
public typealias StoredTasksFile = SiteTasksFile

/// Why a `paddock.json` can't be used: plain phrases, text from the file in them shown only as `printable`
/// makes it.
enum TasksFileProblem {
    static let notJSON = "it isn't valid JSON"
    static let notObject = "it must be a JSON object"
    static let notRegular = "it isn't a regular file"
    static let outside = "it is a link to a file outside the site's folder"
    static let unreadable = "Paddock can't read it"
    static let tooLarge = "it is larger than 64 KB"
    static let changing = "it kept changing while Paddock read it"
    static let tasksNotObject = #""tasks" must be an object of named tasks"#
    static let proxyNotObject = #""proxy" must be an object of paths and ports"#
    static let tooManyTasks = "it has more than \(SiteTasksFile.maximumTasks) tasks"
    static let tooManyProxyPaths = "it has more than \(SiteTasksFile.maximumProxyPaths) proxy paths"

    static func shown(_ text: String) -> String { Messages.printable(text) ?? "?" }

    static func unknownKey(_ key: String) -> String { "unknown key \"\(shown(key))\"" }
    static func badTaskName(_ name: String) -> String {
        "task name \"\(shown(name))\" must start with a lowercase letter and use only lowercase letters, digits and dashes, "
            + "up to 31 characters"
    }
    static func taskNotObject(_ name: String) -> String { "task \"\(name)\" must be an object with a \"run\" command" }
    static func missingRun(_ name: String) -> String { "task \"\(name)\" has no \"run\" command" }
    static func badRun(_ name: String) -> String {
        "the \"run\" command of task \"\(name)\" must be one line of 1 to \(SiteTasksFile.maximumRunLength) characters"
    }
    static func badFlag(_ key: String, _ name: String) -> String { "\"\(key)\" of task \"\(name)\" must be true or false" }
    static func badStopSeconds(_ name: String) -> String {
        "\"stopSeconds\" of task \"\(name)\" must be a whole number from 1 to 300"
    }
    static func badProxyPath(_ path: String) -> String {
        "proxy path \"\(shown(path))\" must start with / and use only letters, digits and . _ ~ / -, without .. or //"
    }
    static func badProxyPort(_ path: String) -> String {
        "the port for proxy path \"\(shown(path))\" must be a whole number from 1024 to 65535"
    }
}
