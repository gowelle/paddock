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

    /// True only if a live process matches every field and its program is inside one of `allowedDirectories`.
    public func isOurLiveProcess(allowedDirectories: [String]) -> Bool {
        let inside = allowedDirectories.contains { directory in
            let prefix = URL(fileURLWithPath: directory).standardizedFileURL.path + "/"
            return URL(fileURLWithPath: executable).standardizedFileURL.path.hasPrefix(prefix)
        }
        guard inside, let now = Self.live(pid: pid) else { return false }
        return now == self
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
