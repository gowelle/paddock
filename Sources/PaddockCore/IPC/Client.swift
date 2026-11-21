import Darwin
import Foundation

public enum ClientError: Error, Equatable {
    /// The socket is absent, or nothing is listening on it.
    case daemonNotRunning
    case timedOut
    case badResponse(String)
    case io(String)
    /// A development build may only read from the real home's daemon (`Request.isReadOnly`).
    case developmentBuild
}

/// Sends one request to `paddockd` over its Unix socket and waits for the reply.
public struct PaddockClient: Sendable {
    private let socketPath: String
    /// Only read-only requests leave this client: a development build talking to the real home's daemon.
    let readOnly: Bool

    /// `readOnly` defaults to: this process is a development build (`SystemIntegration`) and `paths` is the
    /// owner's real home.
    public init(paths: Paths = .current, readOnly: Bool? = nil) {
        socketPath = paths.daemonSocket.path
        self.readOnly = readOnly ?? (paths.isSystemHome && SystemIntegration.thisProcessIsDevelopmentBuild)
    }

    /// Throws `ClientError.developmentBuild`, sending nothing, for a request that isn't read-only from a
    /// read-only client.
    public func send(_ request: Request, timeout: TimeInterval = 600) throws -> Response {
        if readOnly && !request.isReadOnly { throw ClientError.developmentBuild }
        guard let fd = Wire.connect(to: socketPath) else {
            if errno == ENOENT || errno == ECONNREFUSED || errno == ENOTSOCK || errno == ENAMETOOLONG {
                throw ClientError.daemonNotRunning
            }
            throw ClientError.io("connect: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        Wire.setTimeout(fd, seconds: timeout)
        guard Wire.writeLine(fd, try JSONEncoder().encode(request)) else {
            throw ClientError.io("could not send the request")
        }
        switch Wire.readLine(fd, limit: Wire.maxResponseBytes) {
        case .line(let data):
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw ClientError.badResponse(error.localizedDescription)
            }
        case .timedOut: throw ClientError.timedOut
        case .tooLarge: throw ClientError.badResponse("response too large")
        case .closed: throw ClientError.io("the daemon closed the connection without answering")
        }
    }

    /// True when the daemon answers `status`.
    public var daemonIsRunning: Bool {
        if case .ok? = try? send(.status, timeout: 5) { return true }
        return false
    }
}
