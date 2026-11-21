import Darwin
import Foundation

/// Runs one recipe step (an initialise step, and later steps such as creating a database) so that it can
/// never wedge or kill the daemon: the step runs in its own process group with exactly the given
/// environment; output (stdout and stderr together) is read as it comes, keeping the last 64 KB (or what the caller asks for); stdin is
/// written alongside the reading, and a step that exits without reading it costs nothing (no SIGPIPE).
/// At the deadline, or as soon as `isCancelled` says so, the whole group gets SIGTERM and, after
/// `killGrace`, SIGKILL. A step that exits but leaves something holding its output is given a moment to
/// finish writing, then its group is killed.
enum ServiceStepRunner {
    struct Outcome: Equatable {
        enum End: Equatable {
            case exited(Int32)
            case timedOut
            case cancelled
        }

        let end: End
        let output: String
        /// The step's pid, which is also its process group.
        let pid: Int32
    }

    static let outputLimit = 64 * 1024
    /// How long output is still read after the step itself exited.
    static let drainAfterExit: TimeInterval = 1

    static func run(executable: String, arguments: [String], environment: [String: String], directory: URL,
                    stdin: String?, timeout: TimeInterval, killGrace: TimeInterval = 2,
                    keepingLast limit: Int = outputLimit, isCancelled: () -> Bool) throws -> Outcome {
        var output: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var input: [Int32] = [-1, -1]
        if stdin != nil, pipe(&input) != 0 {
            close(output[0]); close(output[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

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
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in posix_spawn(&pid, executable, &actions, &attr, cArgv, cEnvp) }
        }
        close(output[1])
        if stdin != nil { close(input[0]) }
        guard rc == 0 else {
            close(output[0])
            if stdin != nil { close(input[1]) }
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
        }

        let readFD = output[0]
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        var writeFD: Int32 = -1
        var pending = [UInt8]()
        if let stdin {
            writeFD = input[1]
            _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
            _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
            pending = Array(stdin.utf8)
            if pending.isEmpty { close(writeFD); writeFD = -1 }
        }

        var collected = [UInt8]()
        var outputOpen = true
        var exitStatus: Int32?
        var end: Outcome.End?
        let deadline = Date().addingTimeInterval(timeout)
        var killAt: Date?
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 16384)

        func stop(_ reason: Outcome.End) {
            guard end == nil else { return }
            end = reason
            kill(-pid, SIGTERM)
            killAt = Date().addingTimeInterval(killGrace)
        }

        while exitStatus == nil || outputOpen {
            // Writing stdin and reading output together, never blocking on either.
            var fds = [pollfd]()
            if outputOpen { fds.append(pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)) }
            if writeFD >= 0 { fds.append(pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)) }
            if !fds.isEmpty { _ = poll(&fds, nfds_t(fds.count), 100) } else { usleep(50_000) }
            for fd in fds where fd.revents != 0 {
                if fd.fd == readFD {
                    let n = read(readFD, &buffer, buffer.count)
                    if n > 0 {
                        collected += buffer[0..<n]
                        if collected.count > limit { collected.removeFirst(collected.count - limit) }
                    } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                        outputOpen = false
                    }
                } else if fd.fd == writeFD {
                    let n = pending.withUnsafeBytes { write(writeFD, $0.baseAddress!, min($0.count, 65536)) }
                    if n > 0 {
                        pending.removeFirst(n)
                    } else if n < 0 && errno != EAGAIN && errno != EINTR {
                        pending = [] // The step doesn't want it (EPIPE): fine.
                    }
                    if pending.isEmpty {
                        close(writeFD)
                        writeFD = -1
                    }
                }
            }

            if exitStatus == nil {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    let signal = status & 0x7f
                    exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                    exitedAt = Date()
                    if writeFD >= 0 { close(writeFD); writeFD = -1 }
                }
            }

            let now = Date()
            if end == nil, exitStatus == nil {
                if isCancelled() { stop(.cancelled) } else if now >= deadline { stop(.timedOut) }
            }
            if let killAt, now >= killAt { kill(-pid, SIGKILL) }
            // Exited, but something still holds the output: a moment to finish writing (never past the
            // deadline, nor after being stopped), then the group goes and reading ends.
            if let exitedAt, outputOpen {
                let allowed = end != nil ? 0.2 : min(drainAfterExit, max(0, deadline.timeIntervalSince(exitedAt)))
                if now.timeIntervalSince(exitedAt) >= allowed {
                    kill(-pid, SIGKILL)
                    outputOpen = false
                }
            }
        }
        // Whatever is left of the group (a grandchild) goes with the step.
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        close(readFD)
        if writeFD >= 0 { close(writeFD) }
        let text = String(decoding: collected, as: UTF8.self)
        return Outcome(end: end ?? .exited(exitStatus ?? 0), output: text, pid: pid)
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
