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
        guard Self.isInside(executable, allowedDirectories), pid == pgid, let now = Self.live(pid: pid), now == self,
              Self.parent(of: pid) == 1 else { return false }
        return true
    }

    /// When the record's leader is gone but its group lives on: the remaining members, if there are any and
    /// every one is an orphan (parent launchd) running a program inside `allowedDirectories`; else nil. A
    /// process group id is never reused while the group has members, so these are the leader's own.
    public func orphanedGroupMembers(allowedDirectories: [String]) -> [Int32]? {
        guard pid == pgid, Self.live(pid: pid) == nil else { return nil }
        let members = Self.members(ofGroup: pgid)
        guard !members.isEmpty, members.allSatisfy({ member in
            guard let program = PortCheck.executablePath(pid: member) else { return false }
            return Self.isInside(program, allowedDirectories) && Self.parent(of: member) == 1 && getpgid(member) == pgid
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

    /// The pids in a process group.
    static func members(ofGroup pgid: Int32) -> [Int32] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
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
