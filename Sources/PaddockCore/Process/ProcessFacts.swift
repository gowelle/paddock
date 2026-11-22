import Darwin
import Foundation

/// What macOS says of a process through `sysctl` `KERN_PROC_PID` (`kinfo_proc`): its user, group and start time.
/// Unlike `proc_pidinfo`, this works for another user's process too.
public struct ProcessFacts: Equatable, Sendable {
    public let pid: Int32
    public let uid: uid_t
    public let pgid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int64

    public init(pid: Int32, uid: uid_t, pgid: Int32, startSeconds: Int64, startMicroseconds: Int64) {
        self.pid = pid
        self.uid = uid
        self.pgid = pgid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Nil when there is no such process (or macOS won't say).
    public static func of(pid: Int32) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessFacts(pid: pid, uid: info.kp_eproc.e_ucred.cr_uid, pgid: info.kp_eproc.e_pgid,
                            startSeconds: Int64(start.tv_sec), startMicroseconds: Int64(start.tv_usec))
    }
}

/// Where a site task's leftover checks learn about processes, and how they signal one: the system's, or a test's.
public struct ProcessSource: Sendable {
    public var members: @Sendable (Int32) -> [Int32]?
    public var facts: @Sendable (Int32) -> ProcessFacts?
    /// A process's working folder; nil when macOS won't say (another user's process).
    public var directory: @Sendable (Int32) -> String?
    public var signal: @Sendable (Int32, Int32) -> Int32

    public init(members: @escaping @Sendable (Int32) -> [Int32]?, facts: @escaping @Sendable (Int32) -> ProcessFacts?,
                directory: @escaping @Sendable (Int32) -> String?, signal: @escaping @Sendable (Int32, Int32) -> Int32) {
        self.members = members
        self.facts = facts
        self.directory = directory
        self.signal = signal
    }

    public static let live = ProcessSource(
        members: { ServiceProcessRecord.members(ofGroup: $0) }, facts: { ProcessFacts.of(pid: $0) },
        directory: { ServiceProcessInspector.live.workingDirectory($0) }, signal: { kill($0, $1) })
}
