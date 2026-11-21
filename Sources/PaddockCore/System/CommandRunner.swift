import Foundation

/// Runs an external program and returns its exit status and combined stdout/stderr.
/// Everything that changes the owner's system goes through this, so tests can substitute a fake.
public protocol CommandRunner: Sendable {
    /// `environment` nil inherits this process's environment; otherwise the program gets exactly it.
    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String)

    /// As above, but a program still running after `timeout` seconds is terminated and the call throws
    /// `CommandRunnerError.timedOut` (it did not complete). Nil waits for as long as it takes. For commands
    /// that may show a dialog nobody answers.
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
             timeout: TimeInterval?) throws -> (status: Int32, output: String)
}

extension CommandRunner {
    /// Runs with this process's environment.
    public func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        try run(executable, arguments, environment: nil)
    }

    /// Fakes that never block need no time limit of their own.
    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
                    timeout: TimeInterval?) throws -> (status: Int32, output: String) {
        try run(executable, arguments, environment: environment)
    }
}

public enum CommandRunnerError: Error, Equatable {
    /// The program was still running after `seconds` and was terminated.
    case timedOut(executable: String, seconds: TimeInterval)
}

extension CommandRunnerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .timedOut(let executable, let seconds):
            return "\(executable) didn't finish within \(Int(seconds)) seconds and was stopped"
        }
    }
}

/// Runs the real program.
public struct SystemCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]?) throws -> (status: Int32, output: String) {
        try run(executable, arguments, environment: environment, timeout: nil)
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
                    timeout: TimeInterval?) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Past the time limit: SIGTERM, then SIGKILL if it lingers. Ends the read below (the pipe closes).
        let timedOut = TimeoutFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        // Drain before waiting: a full pipe would block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let timeout, timedOut.isSet {
            throw CommandRunnerError.timedOut(executable: executable, seconds: timeout)
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
