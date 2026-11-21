import Foundation

public enum ResolverError: Error, Equatable {
    /// The owner dismissed the password prompt.
    case cancelled
    case failed(String)
    /// Another program rewrote the file while the password prompt was open; nothing was written.
    case changedDuringInstall
    /// The saved original (from user-writable state or the backup file) doesn't look like a resolver
    /// file, so Paddock won't write it back as root; the file was left alone.
    case savedCopyRejected

    /// The plain sentence for this failure.
    public var message: String {
        switch self {
        case .cancelled: return "The password prompt was dismissed."
        case .failed(let output): return output
        case .changedDuringInstall: return "Another program changed the resolver file meanwhile, so Paddock left it alone."
        case .savedCopyRejected:
            return "Paddock's saved copy of your original resolver file doesn't look like a resolver file, "
                + "so Paddock left the file alone."
        }
    }
}

/// What `restore()` did.
public enum ResolverRestoreOutcome: Equatable, Sendable {
    /// Wrote the saved original file back.
    case restored
    /// There was no original, so the file was deleted.
    case removed
    /// The file isn't Paddock's any more, so it was left untouched.
    case changedByAnotherProgram
    /// There is no Paddock resolver file and nothing saved to put back (including a file already put
    /// back by an earlier, partly failed run).
    case notInstalled
}

/// Points macOS's `.test` DNS at Paddock's responder through `/etc/resolver/<tld>`.
/// Only the CLI (and the app) call `install()`, because it asks for the owner's password.
public struct Resolver: Sendable {
    public let file: URL
    let settings: Settings
    let store: StateStore
    let runner: CommandRunner

    static let osascript = "/usr/bin/osascript"
    static let prompt = "Paddock needs your password to route .test domains to this Mac."

    public init(file: URL? = nil, settings: Settings, store: StateStore, runner: CommandRunner) {
        self.file = file ?? Self.defaultFile(settings: settings)
        self.settings = settings
        self.store = store
        self.runner = runner
    }

    public static func defaultFile(settings: Settings) -> URL {
        URL(fileURLWithPath: "/etc/resolver/\(settings.tld)")
    }

    public var desiredContents: String { Self.desiredContents(settings: settings) }

    static func desiredContents(settings: Settings) -> String {
        "nameserver 127.0.0.1\nport \(settings.dnsPort)\n"
    }

    /// True iff the resolver file is exactly Paddock's. Reading needs no privileges.
    public func isInstalled() -> Bool { currentContents() == desiredContents }

    /// Writes the resolver file with one password prompt, unless it is already Paddock's.
    /// The privileged script re-checks the file after the prompt and does nothing if another
    /// program changed it meanwhile (`ResolverError.changedDuringInstall`).
    ///
    /// The owner's original is kept safe before the prompt, in two places: `previousResolver` in state
    /// and `backup/resolver-<tld>.orig` (never overwritten once it exists). If the prompt is dismissed,
    /// the script fails or the file changed meanwhile, whatever this call saved is rolled back.
    public func install() throws {
        let current = currentContents()
        if current == desiredContents { return }
        var savedState = false
        var savedBackup = false
        if let current {
            savedBackup = saveBackup(current)
            if store.load().previousResolver == nil {
                try store.update { $0.previousResolver = current }
                savedState = true
            }
        }
        func rollBack() {
            if savedState { _ = try? store.update { $0.previousResolver = nil } }
            if savedBackup { try? FileManager.default.removeItem(at: backupFile) }
        }
        let script = Self.guardedScript(destination: file, expected: current,
                                        action: .write(desiredContents))
        let result: PrivilegedResult
        do {
            result = try runPrivileged(script)
        } catch {
            rollBack()
            throw error
        }
        if result == .changed {
            rollBack()
            throw ResolverError.changedDuringInstall
        }
    }

    /// Puts the saved original back (or deletes the file if there was none), unless the file
    /// is no longer Paddock's, in which case it is left alone. The privileged script re-checks that
    /// after the prompt, so a file rewritten while the dialog was open is never overwritten.
    ///
    /// The original comes from state, or from the backup file if state has none. It is written as root
    /// but comes from user-writable files, so it is only written if `isSafeToRestore` accepts it;
    /// otherwise this throws `ResolverError.savedCopyRejected` and leaves the file alone.
    @discardableResult
    public func restore() throws -> ResolverRestoreOutcome {
        let saved = store.load().previousResolver ?? (try? String(contentsOf: backupFile, encoding: .utf8))
        guard let current = currentContents() else { return .notInstalled }
        guard current == desiredContents else {
            // Nothing saved, or the original is already back (a re-run after a partial failure): nothing to do.
            if saved == nil || current == saved {
                forgetSavedCopy()
                return .notInstalled
            }
            return .changedByAnotherProgram
        }
        if let saved, !Self.isSafeToRestore(saved) { throw ResolverError.savedCopyRejected }
        let script = Self.guardedScript(destination: file, expected: desiredContents,
                                        action: saved.map { .write($0) } ?? .remove)
        if try runPrivileged(script) == .changed { return .changedByAnotherProgram }
        forgetSavedCopy()
        return saved == nil ? .removed : .restored
    }

    /// Only text made of resolver(5) lines (`nameserver`, `port`, `search_order`, `timeout`, `domain`,
    /// `search`, `options`, or blank) and under 1 KB is ever written back as root.
    static func isSafeToRestore(_ text: String) -> Bool {
        let keywords: Set<String> = ["nameserver", "port", "search_order", "timeout", "domain", "search", "options"]
        guard text.utf8.count < 1024 else { return false }
        return text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { return true }
            return keywords.contains(String(first))
        }
    }

    /// `backup/resolver-<tld>.orig` in the Paddock home.
    var backupFile: URL { store.paths.backup.appendingPathComponent("resolver-\(settings.tld).orig") }

    /// Writes the backup unless one exists. True if this call wrote it.
    private func saveBackup(_ text: String) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backupFile.path) else { return false }
        do {
            try fm.createDirectory(at: backupFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: backupFile, options: .withoutOverwriting)
            return true
        } catch {
            return false
        }
    }

    private func forgetSavedCopy() {
        if store.load().previousResolver != nil { _ = try? store.update { $0.previousResolver = nil } }
        try? FileManager.default.removeItem(at: backupFile)
    }

    private func currentContents() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    private enum PrivilegedResult { case done, changed }

    private func runPrivileged(_ shell: String) throws -> PrivilegedResult {
        let result = try runner.run(Self.osascript, ["-e", Self.appleScript(shell: shell)])
        guard result.status != 0 else {
            return result.output.contains(Self.changedMarker) ? .changed : .done
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("User canceled") || output.contains("(-128)") { throw ResolverError.cancelled }
        throw ResolverError.failed(output)
    }

    // MARK: - Script building

    /// `'…'` with embedded single quotes written as `'\''`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// For use inside an AppleScript string literal.
    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum Action {
        case write(String)
        case remove
    }

    /// Printed (with exit 0) by the privileged script when the destination no longer matches.
    static let changedMarker = "PADDOCK_CHANGED"

    /// A root shell script that acts only if `destination` still is what Paddock saw before the
    /// prompt: absent (`expected == nil`) or a regular file with exactly `expected`. Contents travel
    /// base64-encoded inside the script, so there is no staged file to swap, and writes go to a
    /// root-made temp file in the same directory, then `mv` into place with mode 644 (atomic).
    static func guardedScript(destination: URL, expected: String?, action: Action) -> String {
        let dest = shellQuote(destination.path)
        let dir = shellQuote(destination.deletingLastPathComponent().path)
        let unchanged: String
        if let expected {
            unchanged = "[ -f \"$D\" ] && [ ! -L \"$D\" ] && printf %s \(shellQuote(base64(expected))) "
                + "| /usr/bin/base64 -D | /usr/bin/cmp -s - \"$D\""
        } else {
            unchanged = "[ ! -e \"$D\" ] && [ ! -L \"$D\" ]"
        }
        let act: String
        switch action {
        case .remove:
            act = "/bin/rm -f \"$D\""
        case .write(let text):
            act = "T=$(/usr/bin/mktemp \"$DIR/.paddock.XXXXXX\") || exit 1; "
                + "if printf %s \(shellQuote(base64(text))) | /usr/bin/base64 -D > \"$T\" "
                + "&& /bin/chmod 644 \"$T\" && /bin/mv -f \"$T\" \"$D\"; then exit 0; "
                + "else /bin/rm -f \"$T\"; exit 1; fi"
        }
        return "D=\(dest); DIR=\(dir); /bin/mkdir -p \"$DIR\" || exit 1; "
            + "if \(unchanged); then \(act); else echo \(changedMarker); fi"
    }

    private static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static func appleScript(shell: String) -> String {
        "do shell script \"\(appleScriptEscape(shell))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }
}
