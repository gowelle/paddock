import Foundation

/// Runs an external program and returns its exit status and combined stdout/stderr.
/// Everything that changes the owner's system goes through this, so tests can substitute a fake.
public protocol CommandRunner: Sendable {
    /// `environment` nil inherits this process's environment; otherwise the program gets exactly it.
    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String)
}

extension CommandRunner {
    /// Runs with this process's environment.
    public func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        try run(executable, arguments, environment: nil)
    }
}

/// Runs the real program.
public struct SystemCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]?) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting: a full pipe would block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
