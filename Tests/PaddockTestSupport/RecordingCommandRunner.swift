import Foundation
import PaddockCore

/// A `CommandRunner` that never runs anything: it records each call and answers from `handler`.
public final class RecordingCommandRunner: CommandRunner, @unchecked Sendable {
    public struct Call: Equatable {
        public let executable: String
        public let arguments: [String]
        /// The environment the program was given; nil means it inherits this process's.
        public let environment: [String: String]?

        public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var recordedTimeouts: [TimeInterval?] = []
    private let handler: @Sendable (String, [String]) -> (status: Int32, output: String)

    public init(handler: @escaping @Sendable (String, [String]) -> (status: Int32, output: String) = { _, _ in (0, "") }) {
        self.handler = handler
    }

    public var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The time limit each call was given, in order (nil: none).
    public var timeouts: [TimeInterval?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }

    public func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]?) throws -> (status: Int32, output: String) {
        try run(executable, arguments, environment: environment, timeout: nil)
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?,
                    timeout: TimeInterval?) throws -> (status: Int32, output: String) {
        lock.lock()
        recorded.append(Call(executable: executable, arguments: arguments, environment: environment))
        recordedTimeouts.append(timeout)
        lock.unlock()
        return handler(executable, arguments)
    }

    /// A fake macOS trust store: `verify-cert` succeeds once `add-trusted-cert` was accepted.
    /// With `accepts: false` the user "declines" and trust never takes effect.
    public static func fakeKeychain(accepts: Bool = true, initiallyTrusted: Bool = false) -> RecordingCommandRunner {
        let trusted = LockedFlag(initiallyTrusted)
        return RecordingCommandRunner { _, arguments in
            switch arguments.first {
            case "verify-cert": return trusted.value ? (0, "") : notTrusted
            case "add-trusted-cert":
                if accepts { trusted.value = true; return (0, "") }
                return (1, "User canceled the authorization")
            case "remove-trusted-cert": trusted.value = false; return (0, "")
            default: return (1, "unexpected")
            }
        }
    }
}

/// What `security verify-cert` answers for a root macOS doesn't trust.
public let notTrusted: (status: Int32, output: String) = (1, "Cert Verify Result: CSSMERR_TP_NOT_TRUSTED")

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); defer { lock.unlock() }; flag = newValue }
    }
}

/// A fake launchd for `launchctl print/bootout/bootstrap/kickstart`: tracks whether the job is loaded.
/// `bootstrapFailures` bootstraps fail (status 5) before one succeeds; `bootoutStatus` is what bootout
/// exits with (it still unloads the job unless `bootoutUnloads` is false).
public final class FakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var isLoaded: Bool
    private var failuresLeft: Int
    private let bootoutStatus: Int32
    private let bootoutUnloads: Bool

    public init(loaded: Bool = false, bootstrapFailures: Int = 0, bootoutStatus: Int32 = 0,
                bootoutUnloads: Bool = true) {
        isLoaded = loaded
        failuresLeft = bootstrapFailures
        self.bootoutStatus = bootoutStatus
        self.bootoutUnloads = bootoutUnloads
    }

    public var loaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return isLoaded
    }

    /// The answer for a `launchctl` call, or nil for any other program.
    public func answer(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        guard executable == "/bin/launchctl" else { return nil }
        lock.lock(); defer { lock.unlock() }
        switch arguments.first {
        case "print": return (isLoaded ? 0 : 113, "")
        case "bootout":
            if bootoutUnloads { isLoaded = false }
            return (bootoutStatus, bootoutStatus == 0 ? "" : "Boot-out failed: 5: Input/output error")
        case "bootstrap":
            if failuresLeft > 0 {
                failuresLeft -= 1
                return (5, "Bootstrap failed: 5: Input/output error")
            }
            isLoaded = true
            return (0, "")
        default: return (0, "")
        }
    }

    /// A runner that answers only launchctl; anything else fails.
    public func runner() -> RecordingCommandRunner {
        RecordingCommandRunner { [self] exe, args in answer(exe, args) ?? (1, "unexpected") }
    }
}

/// A thread-safe counter for fakes and closures.
public final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    public init() {}
    /// Returns the count before this call, then adds one.
    public func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count - 1 }
}

/// A value shared between a test and the closures it hands out.
public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    public init(_ value: T) { stored = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
