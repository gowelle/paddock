import Foundation
import PaddockCore

/// A `CommandRunner` that never runs anything: it records each call and answers from `handler`.
public final class RecordingCommandRunner: CommandRunner, @unchecked Sendable {
    public struct Call: Equatable {
        public let executable: String
        public let arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (String, [String]) -> (status: Int32, output: String)

    public init(handler: @escaping @Sendable (String, [String]) -> (status: Int32, output: String) = { _, _ in (0, "") }) {
        self.handler = handler
    }

    public var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        lock.lock()
        recorded.append(Call(executable: executable, arguments: arguments))
        lock.unlock()
        return handler(executable, arguments)
    }

    /// A fake macOS trust store: `verify-cert` succeeds once `add-trusted-cert` was accepted.
    /// With `accepts: false` the user "declines" and trust never takes effect.
    public static func fakeKeychain(accepts: Bool = true, initiallyTrusted: Bool = false) -> RecordingCommandRunner {
        let trusted = LockedFlag(initiallyTrusted)
        return RecordingCommandRunner { _, arguments in
            switch arguments.first {
            case "verify-cert": return (trusted.value ? 0 : 1, "")
            case "add-trusted-cert":
                if accepts { trusted.value = true; return (0, "") }
                return (1, "User canceled the authorization")
            case "remove-trusted-cert": trusted.value = false; return (0, "")
            default: return (1, "unexpected")
            }
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); defer { lock.unlock() }; flag = newValue }
    }
}
