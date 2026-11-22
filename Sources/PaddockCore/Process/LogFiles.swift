import Darwin
import Foundation

/// Keeping the logs Paddock's processes write from growing without end: a log over `setAsideAbove` is renamed
/// `<name>.1` (replacing an older one) before its process opens it; a log a running process holds is never cut or
/// renamed, only noted once it passes `veryLargeAbove`.
public enum LogFiles {
    public static let setAsideAbove: UInt64 = 20 * 1024 * 1024
    public static let veryLargeAbove: UInt64 = 200 * 1024 * 1024

    public static func size(_ url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }

    /// `<name>.1`
    public static func previous(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".1") }

    /// Renames the log to `<name>.1` when it is over `setAsideAbove`. Only for a file no running process holds.
    @discardableResult
    public static func setAsideIfLarge(_ url: URL) -> Bool {
        guard let size = size(url), size > setAsideAbove else { return false }
        return rename(url.path, previous(url).path) == 0
    }

    /// A log this process itself holds open (the daemon's own stdout and stderr): when it is over `setAsideAbove`,
    /// renames it to `<name>.1` and moves every one of `descriptors` that writes to it onto a fresh file, so nothing
    /// goes on writing to the old one. False when the file is small or none of the descriptors writes to it.
    @discardableResult
    public static func rotateHeldLog(_ url: URL, descriptors: [Int32]) -> Bool {
        var file = stat()
        guard stat(url.path, &file) == 0, UInt64(file.st_size) > setAsideAbove else { return false }
        let holding = descriptors.filter { fd in
            var held = stat()
            return fstat(fd, &held) == 0 && held.st_dev == file.st_dev && held.st_ino == file.st_ino
        }
        guard !holding.isEmpty, rename(url.path, previous(url).path) == 0 else { return false }
        let fresh = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fresh >= 0 else { return false }
        for fd in holding { _ = dup2(fresh, fd) }
        close(fresh)
        return true
    }

    /// The notice for a log over `veryLargeAbove`, or nil.
    public static func veryLargeNotice(_ url: URL) -> String? {
        guard let size = size(url), size > veryLargeAbove else { return nil }
        return Messages.logVeryLarge(megabytes: Int(size / (1024 * 1024)), path: url.path)
    }
}
