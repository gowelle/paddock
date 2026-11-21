import Foundation

/// Puts Paddock's `bin/` first on PATH for new zsh sessions, with one marked line in `~/.zshrc`.
public enum ShellPath {
    static let marker = "# Added by Paddock"
    static let line = #"export PATH="$HOME/Library/Application Support/Paddock/bin:$PATH"  "# + marker

    public static var defaultRCFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    public static func isConfigured(rcFile: URL = defaultRCFile) -> Bool {
        guard let text = try? String(contentsOf: rcFile, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Appends the line unless the marker is already there; creates the file if missing and leaves
    /// existing content alone. Appends in place, so a symlinked rc file stays a symlink.
    public static func configure(rcFile: URL = defaultRCFile) throws {
        guard !isConfigured(rcFile: rcFile) else { return }
        let fm = FileManager.default
        let existing = (try? Data(contentsOf: rcFile)) ?? Data()
        var addition = Data()
        if let last = existing.last, last != UInt8(ascii: "\n") { addition.append(UInt8(ascii: "\n")) }
        addition.append(Data((line + "\n").utf8))
        if !fm.fileExists(atPath: rcFile.path) {
            try addition.write(to: rcFile)
            return
        }
        let handle = try FileHandle(forWritingTo: rcFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: addition)
    }
}
