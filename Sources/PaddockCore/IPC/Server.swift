import Darwin
import Foundation

public enum IPCServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(String)
    case socketPathTooLong(String)
    case system(String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): return "another daemon is already answering on \(path)"
        case .socketPathTooLong(let path): return "socket path is too long for a unix socket: \(path)"
        case .system(let message): return message
        }
    }
}

/// Serves `Request`/`Response` pairs on a Unix socket: one newline-terminated JSON request and one
/// newline-terminated JSON response per connection. Connections are handled concurrently.
public final class IPCServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: @Sendable (Request) async -> Response
    private let requestTimeout: TimeInterval

    /// Called on the connection's thread after the reply was written (or the write failed).
    public var didRespond: (@Sendable (Request) -> Void)?

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false

    /// `requestTimeout` bounds how long a client may take to send its request and to accept the reply.
    public init(socket: URL, requestTimeout: TimeInterval = 10,
                handler: @escaping @Sendable (Request) async -> Response) {
        socketURL = socket
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    deinit { stop() }

    /// Binds the socket (mode 0600) and starts accepting. Removes a stale socket file left by a dead
    /// daemon; throws if a live one answers on it.
    public func start() throws {
        let path = socketURL.path
        guard Wire.socketAddress(path) != nil else { throw IPCServerError.socketPathTooLong(path) }
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else { return }

        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            if let live = Wire.connect(to: path) {
                close(live)
                throw IPCServerError.alreadyRunning(path)
            }
            unlink(path)
        }

        var addr = Wire.socketAddress(path)!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCServerError.system("socket: \(String(cString: strerror(errno)))") }
        // Create the file owner-only from the start rather than chmod-ing afterwards.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindError = errno
        umask(oldMask)
        guard bound == 0 else {
            close(fd)
            throw IPCServerError.system("bind \(path): \(String(cString: strerror(bindError)))")
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw IPCServerError.system("listen: \(message)")
        }
        listenFD = fd
        stopping = false
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "app.paddock.ipc.accept"
        thread.start()
    }

    /// Stops accepting and removes the socket file. Requests already being handled finish.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD >= 0 else { return }
        stopping = true
        unlink(socketURL.path)
        // The accept loop notices `stopping` within its poll interval and closes the descriptor.
        listenFD = -1
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while !isStopping {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            guard ready > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global().async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        Wire.setTimeout(fd, seconds: requestTimeout)

        let data: Data
        switch Wire.readLine(fd, limit: Wire.maxRequestBytes) {
        case .line(let line): data = line
        case .tooLarge: return reply(fd, .error(code: ErrorCode.internal, message: "Request too large"))
        case .timedOut: return reply(fd, .error(code: ErrorCode.internal, message: "Timed out waiting for a request"))
        case .closed: return
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return reply(fd, .error(code: ErrorCode.internal, message: "Malformed request"))
        }

        let response = Self.blockingResult { await self.handler(request) }
        reply(fd, response)
        didRespond?(request)
    }

    private func reply(_ fd: Int32, _ response: Response) {
        let data = (try? JSONEncoder().encode(response))
            ?? Data(#"{"error":{"code":"internal","message":"Could not encode the response"}}"#.utf8)
        Wire.writeLine(fd, data)
    }

    /// Runs an async body from a plain thread and waits for its result.
    private static func blockingResult(_ body: @escaping @Sendable () async -> Response) -> Response {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Response?
    }
}
