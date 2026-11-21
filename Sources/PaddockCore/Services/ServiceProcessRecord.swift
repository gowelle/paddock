import Darwin
import Foundation

/// What Paddock wrote about a service process it started (`run/svc/<id>/pid`), so a daemon restarted after
/// a crash can recognise that process as its own orphan, and nothing else as one: same pid, same process
/// group, same start time (a reused pid starts at another time) and the same program, inside the folders
/// that program may come from.
public struct ServiceProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let pgid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int64
    public let executable: String

    public init(pid: Int32, pgid: Int32, startSeconds: Int64, startMicroseconds: Int64, executable: String) {
        self.pid = pid
        self.pgid = pgid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executable = executable
    }

    /// The record of a live process of this user, or nil if there is none (or macOS won't say).
    public static func live(pid: Int32) -> ServiceProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let executable = PortCheck.executablePath(pid: pid) else { return nil }
        let pgid = getpgid(pid)
        guard pgid > 0 else { return nil }
        return ServiceProcessRecord(pid: pid, pgid: pgid, startSeconds: Int64(info.pbi_start_tvsec),
                                    startMicroseconds: Int64(info.pbi_start_tvusec), executable: executable)
    }

    public static func read(from file: URL) -> ServiceProcessRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ServiceProcessRecord.self, from: data)
    }

    /// Written in one step: a reader never sees half a record.
    public func write(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// True only for a true orphan of a daemon that died: a live process matching every field, leading its
    /// own process group, whose parent is launchd (pid 1), running a program inside one of `allowedDirectories`.
    /// While the daemon that started it is alive it is that daemon's child, so never an orphan.
    public func isOurLiveProcess(allowedDirectories: [String]) -> Bool {
        Self.isInside(executable, allowedDirectories) && identity(belongs: { _ in true }) == .orphan
    }

    /// What the record's process is now.
    public enum Identity: Equatable, Sendable {
        /// No process has the pid, or the one that has it started at another time (the pid was reused).
        case gone
        /// The very process recorded, now an orphan of a daemon that died: every field matches, it leads its
        /// own group, its parent is launchd (pid 1), and `belongs` agrees.
        case orphan
        /// The process recorded (same pid and start time) still runs, but is not provably an orphan of ours
        /// (its parent lives, it runs another program, or `belongs` says no): it must be left alone.
        case runningButNotOurs
    }

    /// While the daemon that started the process is alive it is that daemon's child, so never an orphan.
    /// `belongs` adds a check of the caller's own (say, the process's working folder).
    public func identity(belongs: (Int32) -> Bool) -> Identity {
        guard let now = Self.live(pid: pid), now.startSeconds == startSeconds,
              now.startMicroseconds == startMicroseconds else { return .gone }
        guard pid == pgid, now == self, Self.parent(of: pid) == 1, belongs(pid) else { return .runningButNotOurs }
        return .orphan
    }

    /// When the record's leader is gone but its group lives on: the remaining members, if there are any and
    /// every one is an orphan (parent launchd) running a program inside `allowedDirectories`; else nil (also
    /// when the group can't be listed whole). A process group id is never reused while the group has members,
    /// so these are the leader's own.
    public func orphanedGroupMembers(allowedDirectories: [String]) -> [Int32]? {
        orphanedGroupMembers { member in
            PortCheck.executablePath(pid: member).map { Self.isInside($0, allowedDirectories) } ?? false
        }
    }

    /// As above, with `belongs` deciding for each member instead of the folders its program must be in.
    public func orphanedGroupMembers(belongs: (Int32) -> Bool) -> [Int32]? {
        guard pid == pgid, Self.live(pid: pid) == nil else { return nil }
        guard let members = Self.members(ofGroup: pgid), !members.isEmpty, members.allSatisfy({ member in
            belongs(member) && Self.parent(of: member) == 1 && getpgid(member) == pgid
        }) else { return nil }
        return members
    }

    static func isInside(_ program: String, _ directories: [String]) -> Bool {
        let path = URL(fileURLWithPath: program).standardizedFileURL.path
        return directories.contains { path.hasPrefix(URL(fileURLWithPath: $0).standardizedFileURL.path + "/") }
    }

    /// A process's parent pid, if macOS says.
    static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// Every pid in a process group, or nil when macOS won't list the whole group: the list grows from
    /// `initialCapacity` until it fits (a full buffer may have been cut short), up to `maximumCapacity`.
    /// Nothing is ever decided on a partial list.
    static func members(ofGroup pgid: Int32, initialCapacity: Int = 256, maximumCapacity: Int = 1 << 16) -> [Int32]? {
        var capacity = max(1, initialCapacity)
        while capacity <= maximumCapacity {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), $0.baseAddress, Int32($0.count))
            }
            guard bytes >= 0 else { return nil }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count < capacity { return Array(pids.prefix(count)).filter { $0 > 0 } }
            capacity *= 2
        }
        return nil
    }

    /// Stops the record's process group: `signal`, then SIGKILL after `grace`. Returns once it is gone (or
    /// after a few more seconds). Only call it after `isOurLiveProcess`.
    func stopGroup(signal: Int32, grace: TimeInterval) {
        func groupAlive() -> Bool { kill(-pgid, 0) == 0 }
        kill(-pgid, signal)
        let deadline = Date().addingTimeInterval(grace)
        while groupAlive() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard groupAlive() else { return }
        kill(-pgid, SIGKILL)
        let end = Date().addingTimeInterval(5)
        while groupAlive() && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    }
}

/// What macOS says about a live process: its program and its working folder (nil when it won't say).
public struct ServiceProcessInspector: Sendable {
    public var executable: @Sendable (Int32) -> String?
    public var workingDirectory: @Sendable (Int32) -> String?

    public init(executable: @escaping @Sendable (Int32) -> String?,
                workingDirectory: @escaping @Sendable (Int32) -> String?) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public static let live = ServiceProcessInspector(executable: { PortCheck.executablePath(pid: $0) },
                                                     workingDirectory: { currentDirectory(of: $0) })

    /// A process's working folder (`proc_pidinfo` `PROC_PIDVNODEPATHINFO`), if macOS says.
    static func currentDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
