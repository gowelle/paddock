import Foundation

/// A request from a client (CLI or menu bar app) to the daemon.
public enum Request: Codable, Equatable, Sendable {
    case status, start, stop, restart
    case park(path: String), forget(path: String)
    case link(name: String, path: String), unlink(name: String)
    case secure(site: String), unsecure(site: String)
    case isolate(site: String, version: PHPVersion), unisolate(site: String)
    case use(version: PHPVersion)
    case installPHP(version: PHPVersion), removePHP(version: PHPVersion)
    case trust
    case shutdown
    /// Adds a service from the catalog (newest version when `version` is nil), starts it and waits until
    /// it is ready. May download first, so it can take minutes.
    case serviceAdd(kind: String, version: String?)
    /// Answered with `.removed`. Keeps the service's data unless `deleteData`.
    case serviceRemove(name: String, deleteData: Bool)
    case serviceStart(name: String), serviceStop(name: String), serviceRestart(name: String)
    /// Answered with `.catalog`.
    case serviceCatalog
    /// Downloads the newest version of the service's series and switches to it (back to the old one if
    /// the new one doesn't start).
    case serviceUpdate(name: String)
    /// Creates a database in a running service (answered with `.databaseCreated`); one already there is not
    /// an error.
    case serviceCreateDatabase(name: String, database: String)
    /// Approves the site's `paddock.json` as it is now, provided its hash is `hash` (what the user was shown),
    /// and starts its tasks.
    case tasksApprove(site: String, hash: String)
    /// Stops the site's tasks and withdraws the approval.
    case tasksRevoke(site: String)
    /// Start, stop or restart one approved task. A stop is remembered (across restarts) until a start.
    case taskStart(site: String, task: String), taskStop(site: String, task: String), taskRestart(site: String, task: String)
    /// Writes the starter `paddock.json` for a Laravel site that has none; never overwrites.
    case tasksInit(site: String)
    /// Restarts the task after stopping only the processes an earlier run left in its group (answered with the
    /// status; the task's warning says what was stopped).
    case taskForceRestart(site: String, task: String)
    /// The status, after reading the site's `paddock.json` again (nothing else changes).
    case tasksStatus(site: String)
    /// A service's full `.env` lines, its secrets' values included (answered with `.envLines`); changes nothing.
    /// `status` leaves those lines out, so a secret is sent only to a client that asks for it.
    case serviceEnv(id: String)
}

extension Request {
    /// True for requests that only read (and so may be sent even from a development build to the real
    /// home's daemon). Every case must be classified here: no `default`.
    public var isReadOnly: Bool {
        switch self {
        case .status, .serviceCatalog, .tasksStatus:
            return true
        case .start, .stop, .restart, .shutdown, .park, .forget, .link, .unlink, .secure, .unsecure,
             .isolate, .unisolate, .use, .installPHP, .removePHP, .trust,
             .serviceAdd, .serviceRemove, .serviceStart, .serviceStop, .serviceRestart, .serviceUpdate,
             .serviceCreateDatabase, .tasksApprove, .tasksRevoke, .taskStart, .taskStop, .taskRestart, .tasksInit,
             .taskForceRestart,
             // Only reads, but answers secrets: a development build may not fetch them from the real home.
             .serviceEnv:
            return false
        }
    }
}

extension Request {
    /// The site task requests that change something; they run outside the queue of other changes.
    var isSiteTaskChange: Bool {
        switch self {
        case .tasksApprove, .tasksRevoke, .taskStart, .taskStop, .taskRestart, .tasksInit, .taskForceRestart:
            return true
        default:
            return false
        }
    }
}

public enum Response: Codable, Equatable, Sendable {
    case ok(EngineStatus)
    case error(code: String, message: String)
    /// The services Paddock can add (`serviceCatalog`).
    case catalog([CatalogEntry])
    /// A service was removed (`serviceRemove`); its data is (or was, if deleted) at `dataPath`.
    case removed(dataPath: String, status: EngineStatus)
    /// `serviceCreateDatabase` worked: `database` was created, or was there already.
    case databaseCreated(database: String, alreadyExisted: Bool, status: EngineStatus)
    /// A service's full `.env` lines, secrets included (`serviceEnv`).
    case envLines([String])
}

/// The `code` values of `Response.error`.
public enum ErrorCode {
    public static let unknownSite = "unknown_site"
    public static let notADirectory = "not_a_directory"
    public static let phpNotInstalled = "php_not_installed"
    public static let phpInUse = "php_in_use"
    public static let phpNotAvailable = "php_not_available"
    public static let portsBlocked = "ports_blocked"
    /// A site is served over HTTPS but macOS does not trust Paddock's certificate authority.
    public static let needsTrust = "needs_trust"
    public static let trustDisabled = "trust_disabled"
    /// No added service has that name.
    public static let unknownService = "unknown_service"
    /// The catalog has no such kind (or version) of service.
    public static let unknownServiceKind = "unknown_service_kind"
    /// A service's port is held by another program.
    public static let servicePortInUse = "service_port_in_use"
    /// A service could not be downloaded, initialised or started.
    public static let serviceFailed = "service_failed"
    /// Paddock can't run that service here.
    public static let serviceUnavailable = "service_unavailable"
    /// Adding or updating a service was cut short because Paddock is shutting down.
    public static let serviceCancelled = "service_cancelled"
    /// A value in the request isn't one Paddock accepts (a database name with a dash).
    public static let invalidArgument = "invalid_argument"
    /// The site (or `paddock tasks`' task) has no task by that name.
    public static let unknownTask = "unknown_task"
    /// The site's tasks need approving first.
    public static let tasksNotApproved = "tasks_not_approved"
    /// The site's `paddock.json` breaks a rule, or has a command that can't be shown.
    public static let tasksInvalid = "tasks_invalid"
    /// The site has no `paddock.json`.
    public static let noTasksFile = "no_tasks_file"
    /// `paddock.json` changed after it was shown, so what was shown was not approved.
    public static let tasksChanged = "tasks_changed"
    /// The site already has a `paddock.json` (init never overwrites).
    public static let tasksFileExists = "tasks_file_exists"
    /// A process an earlier Paddock left running, not provably its own, holds the task.
    public static let taskAlreadyRunning = "task_already_running"
    public static let `internal` = "internal"
}

/// Wire format: one JSON value per line, in each direction.
enum Wire {
    /// Largest request the server reads, in bytes.
    static let maxRequestBytes = 64 * 1024
    /// Largest response the client reads, in bytes.
    static let maxResponseBytes = 4 * 1024 * 1024

    static func socketAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // sun_path is 104 bytes on macOS, including the terminating NUL.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Connects a new unix stream socket to `path`; nil on failure with errno set.
    static func connect(to path: String) -> Int32? {
        guard var addr = socketAddress(path) else { errno = ENAMETOOLONG; return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let saved = errno
            close(fd)
            errno = saved
            return nil
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    enum ReadResult {
        case line(Data)
        case tooLarge
        case closed
        case timedOut
    }

    /// Reads up to and excluding the first newline, giving up after `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .closed
            }
            if n == 0 { return data.isEmpty ? .closed : .line(data) }
            if let newline = buffer[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count > limit ? .tooLarge : .line(data)
            }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { return .tooLarge }
        }
    }

    /// Writes everything, newline-terminated. False if the peer is gone or too slow.
    @discardableResult
    static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        let bytes = [UInt8](payload) + [UInt8(ascii: "\n")]
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}
