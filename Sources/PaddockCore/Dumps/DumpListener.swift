import Foundation
import Network

/// How PHP is told where its dumps go: the two variables Symfony VarDumper reads. With them, `dump()` and
/// `dd()` send to a dump server at that address and show nothing in the page; when nothing answers there,
/// VarDumper itself falls back to showing them where it always did.
public enum DumpDestination {
    public static let formatVariable = "VAR_DUMPER_FORMAT"
    public static let serverVariable = "VAR_DUMPER_SERVER"
    /// The port the Dumps window listens on: the one Symfony's own dump server uses, so a project already set
    /// up for that needs nothing more.
    public static let defaultPort = 9912

    public static func isPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    /// The variables for a listener on `port`; none without one.
    public static func environment(port: Int?) -> [String: String] {
        guard let port, isPort(port) else { return [:] }
        return [formatVariable: "server", serverVariable: "127.0.0.1:\(port)"]
    }
}

public enum DumpListenerError: Error, Equatable {
    /// Another program is listening on the port.
    case portInUse(Int)
    case failed(String)
}

/// Listens on 127.0.0.1 for what VarDumper's dump server client sends: one line of base64 per dump, any number
/// of them on a connection. Only this Mac can reach it. It hands each line on as it arrives and keeps nothing.
public final class DumpListener: @unchecked Sendable {
    /// A line longer than this is not a dump Paddock shows: the connection is dropped.
    public static let lineLimit = 32 * 1024 * 1024

    public let port: Int
    private let receive: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "app.paddock.dumps")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// `receive` is called off the main thread with each line (without its line end).
    public init(port: Int = DumpDestination.defaultPort, receive: @escaping @Sendable (Data) -> Void) {
        self.port = port
        self.receive = receive
    }

    deinit { stop() }

    /// Starts listening; returns once it is, or throws why it can't.
    public func start() throws {
        guard DumpDestination.isPort(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw DumpListenerError.failed("\(port) is not a port to listen on")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw DumpListenerError.failed(error.localizedDescription)
        }
        let started = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.settle(nil)
                started.signal()
            case .failed(let error), .waiting(let error):
                outcome.settle(error)
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw DumpListenerError.failed("it did not start in time")
        }
        if let error = outcome.error {
            listener.cancel()
            if case .posix(let code) = error, code == .EADDRINUSE { throw DumpListenerError.portInUse(port) }
            throw DumpListenerError.failed(error.localizedDescription)
        }
        queue.sync { self.listener = listener }
    }

    /// Stops listening and drops every connection. PHP then finds nothing there and shows dumps as usual.
    public func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var stored: NWError?
        var error: NWError? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        func settle(_ error: NWError?) {
            lock.lock()
            if !settled {
                settled = true
                stored = error
            }
            lock.unlock()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        read(connection, buffered: Data())
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, finished, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { self.receive(Data(line)) }
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            if finished || error != nil || buffer.count > Self.lineLimit {
                connection.cancel()
                return
            }
            self.read(connection, buffered: buffer)
        }
    }
}
