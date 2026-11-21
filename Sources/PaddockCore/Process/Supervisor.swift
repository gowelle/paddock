import Darwin
import Foundation

public struct ProcessSpec: Sendable {
    public var name: String
    public var executable: URL
    public var arguments: [String]
    /// Added to (and overriding) the supervisor's own environment, or the whole environment when
    /// `inheritsEnvironment` is false.
    public var environment: [String: String]
    /// False gives the process exactly `environment` and nothing of the supervisor's own.
    public var inheritsEnvironment: Bool
    /// Called with the pid after every spawn, restarts included (the service manager records it).
    public var didSpawn: (@Sendable (Int32) -> Void)?
    /// stdout and stderr are appended here.
    public var logFile: URL
    /// What `stop` sends the process group first.
    public var stopSignal: Int32
    /// Seconds between `stopSignal` and SIGKILL; nil uses the supervisor's grace period.
    public var stopGrace: TimeInterval?
    /// Where the process runs; nil keeps the supervisor's own working directory.
    public var workingDirectory: URL?

    public init(name: String, executable: URL, arguments: [String], environment: [String: String] = [:],
                logFile: URL, stopSignal: Int32 = SIGTERM, stopGrace: TimeInterval? = nil,
                inheritsEnvironment: Bool = true, didSpawn: (@Sendable (Int32) -> Void)? = nil) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.logFile = logFile
        self.stopSignal = stopSignal
        self.stopGrace = stopGrace
        self.inheritsEnvironment = inheritsEnvironment
        self.didSpawn = didSpawn
    }
}

public enum ProcessStatus: Equatable, Sendable, CustomStringConvertible {
    case running(pid: Int32)
    case stopped
    /// Exited unexpectedly: waiting to be restarted, or given up on. Signals are reported as 128 + signal.
    case crashed(exitCode: Int32)

    public var description: String {
        switch self {
        case .running(let pid): return "running (pid \(pid))"
        case .stopped: return "stopped"
        case .crashed(let code): return "crashed (exit \(code))"
        }
    }
}

public enum SupervisorError: Error, Equatable {
    case spawnFailed(name: String, errno: Int32)
}

/// Runs child processes, each in its own process group, and restarts them when they exit unexpectedly.
/// Restarts back off 1s, 2s, 4s… capped at 30s; after 5 failures within 60 seconds the process is left crashed.
public final class Supervisor: @unchecked Sendable {
    static let maxFailures = 5
    static let failureWindow: TimeInterval = 60

    /// Seconds to wait before restarting after the given number of recent failures (1-based).
    static func backoff(afterFailures n: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, n - 1))))
    }

    private final class Entry {
        var spec: ProcessSpec
        var pid: Int32?
        var status: ProcessStatus = .stopped
        /// Set by stop(); the exit that follows is not a failure.
        var wantsRunning = true
        /// Bumped on every start/stop so a pending restart from an earlier generation is dropped.
        var generation = 0
        var failures: [Date] = []
        /// Entered at spawn, left once the process is reaped; any number of stop() calls can wait on it.
        var exited: DispatchGroup?

        init(spec: ProcessSpec) { self.spec = spec }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let backoffScale: TimeInterval
    private let stopGracePeriod: TimeInterval

    /// `backoffScale` multiplies the restart delays (tests use a small value).
    public init(backoffScale: TimeInterval = 1, stopGracePeriod: TimeInterval = 5) {
        self.backoffScale = backoffScale
        self.stopGracePeriod = stopGracePeriod
    }

    deinit { stopAll() }

    /// Starts the process. If one with this name is already running, does nothing.
    public func start(_ spec: ProcessSpec) throws {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[spec.name], entry.pid != nil, entry.wantsRunning { return }
        let entry = entries[spec.name] ?? Entry(spec: spec)
        entry.spec = spec
        entry.wantsRunning = true
        entry.failures = []
        entry.generation += 1
        entries[spec.name] = entry
        try spawnLocked(entry)
    }

    /// The spec's stop signal (SIGTERM unless it says otherwise) to the process group, SIGKILL after the
    /// spec's grace period (or the supervisor's); returns once it has exited.
    public func stop(_ name: String) {
        lock.lock()
        guard let entry = entries[name] else { lock.unlock(); return }
        entry.wantsRunning = false
        entry.generation += 1
        let pid = entry.pid
        let exited = entry.exited
        let signal = entry.spec.stopSignal
        let grace = entry.spec.stopGrace ?? stopGracePeriod
        if pid == nil { entry.status = .stopped }
        lock.unlock()

        guard let pid, let exited else { return }
        kill(-pid, signal)
        if exited.wait(timeout: .now() + grace) == .timedOut {
            kill(-pid, SIGKILL)
            exited.wait()
        }
    }

    public func stopAll() {
        lock.lock()
        let names = Array(entries.keys)
        lock.unlock()
        let group = DispatchGroup()
        for name in names {
            DispatchQueue.global().async(group: group) { self.stop(name) }
        }
        group.wait()
    }

    public func status(_ name: String) -> ProcessStatus {
        lock.lock()
        defer { lock.unlock() }
        return entries[name]?.status ?? .stopped
    }

    /// Names of every process ever started, sorted.
    public var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    // MARK: - Spawning

    private func spawnLocked(_ entry: Entry) throws {
        let pid: Int32
        do {
            pid = try Self.spawn(entry.spec)
        } catch {
            entry.status = .crashed(exitCode: 127)
            throw error
        }
        let exited = DispatchGroup()
        exited.enter()
        entry.pid = pid
        entry.status = .running(pid: pid)
        entry.exited = exited
        entry.spec.didSpawn?(pid)
        let generation = entry.generation
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // Sweep anything left in the group (e.g. php-fpm workers of a killed master).
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            self?.exited(entry: entry, pid: pid, waitStatus: status, generation: generation)
            exited.leave()
        }
        thread.name = "app.paddock.supervisor.\(entry.spec.name)"
        thread.start()
    }

    private func exited(entry: Entry, pid: Int32, waitStatus: Int32, generation: Int) {
        let signal = waitStatus & 0x7f
        let code = signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal

        lock.lock()
        defer { lock.unlock() }
        guard entry.pid == pid else { return }
        entry.pid = nil
        entry.exited = nil
        guard entry.wantsRunning, entry.generation == generation else {
            entry.status = .stopped
            return
        }
        entry.status = .crashed(exitCode: code)
        let now = Date()
        entry.failures = entry.failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        guard entry.failures.count < Self.maxFailures else { return }
        scheduleRestartLocked(entry, generation: generation)
    }

    private func scheduleRestartLocked(_ entry: Entry, generation: Int) {
        let delay = Self.backoff(afterFailures: entry.failures.count) * backoffScale
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard entry.wantsRunning, entry.generation == generation, entry.pid == nil else { return }
            do {
                try self.spawnLocked(entry)
            } catch {
                let now = Date()
                entry.failures = entry.failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
                if entry.failures.count < Self.maxFailures {
                    self.scheduleRestartLocked(entry, generation: generation)
                }
            }
        }
    }

    /// posix_spawn into a new process group, with stdin from /dev/null, stdout and stderr appended
    /// to the log file, default signal handling, and no other inherited descriptors.
    private static func spawn(_ spec: ProcessSpec) throws -> Int32 {
        try FileManager.default.createDirectory(at: spec.logFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, spec.logFile.path,
                                         O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let directory = spec.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var env = spec.inheritsEnvironment ? ProcessInfo.processInfo.environment : [:]
        env.merge(spec.environment) { _, new in new }
        let argv = [spec.executable.path] + spec.arguments
        let envp = env.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in
                posix_spawn(&pid, spec.executable.path, &actions, &attr, cArgv, cEnvp)
            }
        }
        guard rc == 0 else { throw SupervisorError.spawnFailed(name: spec.name, errno: rc) }
        return pid
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
