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
    /// Like `savedCopyRejected`, but the port helper's launchd entry was removed in the same run.
    case savedCopyRejectedPortsReleased(path: String)
    /// The file Paddock would replace isn't one it could safely write back on uninstall, so it was left
    /// alone and no password was asked for.
    case cannotRestoreLater(path: String)
    /// The privileged script found something else answering on port 80 or 443 and changed nothing.
    case portsBusy
    /// The port helper's install steps failed; they removed what they created and the resolver was not
    /// touched.
    case portsSetupFailed(String)
    /// The port helper's removal failed. `resolverRestored`: the resolver step before it in the same
    /// script put the owner's file back.
    case portsReleaseFailed(String, resolverRestored: Bool)

    /// The plain sentence for this failure.
    public var message: String {
        switch self {
        case .cancelled: return "The password prompt was dismissed."
        case .failed(let output): return output
        case .changedDuringInstall: return "Another program changed the resolver file meanwhile, so Paddock left it alone."
        case .savedCopyRejected:
            return "Paddock's saved copy of your original resolver file doesn't look like a resolver file, "
                + "so Paddock left the file alone."
        case .savedCopyRejectedPortsReleased(let path):
            return Messages.portsReleasedResolverLeft(path)
        case .cannotRestoreLater(let path):
            return "\(path) has contents Paddock can't safely restore later, so Paddock left it alone."
        case .portsBusy: return "Paddock can't start: its ports are in use."
        case .portsSetupFailed(let detail): return Messages.portsSetupFailed(detail)
        case .portsReleaseFailed(let detail, let restored): return Messages.portsReleaseFailed(detail, resolverRestored: restored)
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
    ///
    /// `fragment` (the port helper's install steps) runs in the same privileged script, so there is
    /// still one password prompt. The resolver file is re-checked at the very top of that script, so a
    /// file changed while the prompt was open stops everything before the port helper is touched. The
    /// fragment runs alone when the resolver file already is Paddock's. If it reports the ports busy
    /// this throws `ResolverError.portsBusy` and the resolver was not touched. An existing file that
    /// `isSafeToRestore` rejects is never replaced: this throws `ResolverError.cannotRestoreLater`
    /// before any prompt.
    public func install(preceding fragment: String? = nil) throws {
        let current = currentContents()
        if current == desiredContents {
            guard let fragment else { return }
            switch try runPrivileged(Self.privilegedScript([fragment]), prompt: Self.installPrompt) {
            case .portsBusy: throw ResolverError.portsBusy
            case .done, .changed: return
            }
        }
        if let current, !Self.isSafeToRestore(current) { throw ResolverError.cannotRestoreLater(path: file.path) }
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
        let script = Self.installScript(destination: file, expected: current, contents: desiredContents,
                                        preceding: fragment)
        let result: PrivilegedResult
        do {
            result = try runPrivileged(script, prompt: Self.installPrompt)
        } catch {
            rollBack()
            throw error
        }
        switch result {
        case .done: return
        case .portsBusy:
            rollBack()
            throw ResolverError.portsBusy
        case .changed:
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
    /// otherwise the file is left alone and this throws `ResolverError.savedCopyRejected`, or
    /// `savedCopyRejectedPortsReleased` after running `fragment` alone.
    ///
    /// `fragment` (the port helper's removal) runs after the resolver step in the same privileged script,
    /// and also on its own when the resolver step is skipped because the file isn't Paddock's.
    @discardableResult
    public func restore(then fragment: String? = nil) throws -> ResolverRestoreOutcome {
        let saved = store.load().previousResolver ?? (try? String(contentsOf: backupFile, encoding: .utf8))
        let current = currentContents()
        guard let current, current == desiredContents else {
            let outcome: ResolverRestoreOutcome
            // No file, nothing saved, or the original is already back (a re-run after a partial failure).
            if current == nil || saved == nil || current == saved {
                outcome = .notInstalled
            } else {
                outcome = .changedByAnotherProgram
            }
            if let fragment {
                _ = try runPrivileged(Self.privilegedScript([fragment]), prompt: Self.uninstallPrompt)
            }
            if outcome == .notInstalled && current != nil { forgetSavedCopy() }
            return outcome
        }
        if let saved, !Self.isSafeToRestore(saved) {
            // Never write it as root, but don't leave the ports reserved because of it.
            guard let fragment else { throw ResolverError.savedCopyRejected }
            _ = try runPrivileged(Self.privilegedScript([fragment]), prompt: Self.uninstallPrompt)
            throw ResolverError.savedCopyRejectedPortsReleased(path: file.path)
        }
        let script = Self.privilegedScript([
            Self.guardedScript(destination: file, expected: desiredContents,
                               action: saved.map { .write($0) } ?? .remove, failure: .resolverRestore),
            fragment,
        ])
        if try runPrivileged(script, prompt: Self.uninstallPrompt, resolverStepFirst: true) == .changed {
            return .changedByAnotherProgram
        }
        forgetSavedCopy()
        return saved == nil ? .removed : .restored
    }

    /// Only text made of resolver(5) lines (`nameserver`, `port`, `search_order`, `timeout`, `domain`,
    /// `search`, `options`, `#` comments, or blank) and under 1 KB is ever written back as root.
    static func isSafeToRestore(_ text: String) -> Bool {
        let keywords: Set<String> = ["nameserver", "port", "search_order", "timeout", "domain", "search", "options"]
        guard text.utf8.count < 1024 else { return false }
        return text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { return true }
            return first.hasPrefix("#") || keywords.contains(String(first))
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

    private enum PrivilegedResult { case done, changed, portsBusy }

    /// The only environment the privileged `osascript` gets.
    static let privilegedEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// `resolverStepFirst`: the script's resolver step comes before a port-removal step, so a removal
    /// failure after it means the owner's file was put back (unless the step reported it changed).
    private func runPrivileged(_ shell: String, prompt: String,
                               resolverStepFirst: Bool = false) throws -> PrivilegedResult {
        let result = try runner.run(Self.osascript, ["-e", Self.appleScript(shell: shell, prompt: prompt)],
                                    environment: Self.privilegedEnvironment)
        guard result.status != 0 else {
            if result.output.contains(PortHelper.busyMarker) { return .portsBusy }
            return result.output.contains(Self.changedMarker) ? .changed : .done
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("User canceled") || output.contains("(-128)") { throw ResolverError.cancelled }
        switch PrivilegedStage.failed(in: output) {
        case let (.portsInstall, detail)?: throw ResolverError.portsSetupFailed(detail)
        case let (.portsRemoval, detail)?:
            throw ResolverError.portsReleaseFailed(
                detail, resolverRestored: resolverStepFirst && !output.contains(Self.changedMarker))
        case let (_, detail)?: throw ResolverError.failed(detail)
        case nil: throw ResolverError.failed(output)
        }
    }

    // MARK: - Script building

    static let installPrompt =
        "Paddock needs your password once to serve sites on ports 80 and 443 and to route .test domains to this Mac."
    static let uninstallPrompt =
        "Paddock needs your password to release ports 80 and 443 and put your .test DNS setting back."

    /// `'…'` with embedded single quotes written as `'\''`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Steps of one privileged script, in order, skipping absent ones.
    static func joined(_ steps: String?...) -> String {
        steps.compactMap { $0 }.joined(separator: "; ")
    }

    /// Empties the temp-file variables and removes whatever they name if the root shell is interrupted,
    /// so no half-written file is left in `/Library` or `/etc/resolver`.
    static let trapLine = "HT=; PT=; T=; trap '/bin/rm -f ${HT:+\"$HT\"} ${PT:+\"$PT\"} ${T:+\"$T\"}; exit 130' HUP INT TERM"

    /// A whole privileged script: the trap, then the steps.
    static func privilegedScript(_ steps: [String?]) -> String {
        ([trapLine] + steps.compactMap { $0 }).joined(separator: "; ")
    }

    /// The install script: with a port-helper fragment, the resolver file is checked first (changed:
    /// marker, exit 0, nothing touched), then the fragment, then the guarded write as always.
    static func installScript(destination: URL, expected: String?, contents: String,
                              preceding fragment: String?) -> String {
        privilegedScript([
            fragment.map { _ in unchangedOrStop(destination: destination, expected: expected) },
            fragment,
            guardedScript(destination: destination, expected: expected, action: .write(contents),
                          failure: .resolverWrite),
        ])
    }

    /// The shell command `do shell script` runs: a root `/bin/sh` started with an empty environment
    /// (only a fixed `PATH`), whatever environment the privileges hop passes along.
    static func rootShellCommand(_ script: String) -> String {
        "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " + shellQuote(script)
    }

    /// For use inside an AppleScript string literal.
    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum Action {
        case write(String)
        case remove
    }

    /// Printed (with exit 0) by the privileged script when the destination no longer matches; also on
    /// stderr, so it is still seen if a later step fails.
    static let changedMarker = "PADDOCK_CHANGED"

    private static var reportChanged: String { "echo \(changedMarker); echo \(changedMarker) >&2" }

    /// `D=…; DIR=…;` and the test that the file still is what Paddock saw: absent, or a regular file with
    /// exactly `expected`.
    private static func unchangedTest(destination: URL, expected: String?) -> (setup: String, test: String) {
        let setup = "D=\(shellQuote(destination.path)); DIR=\(shellQuote(destination.deletingLastPathComponent().path))"
        guard let expected else { return (setup, "[ ! -e \"$D\" ] && [ ! -L \"$D\" ]") }
        return (setup, "[ -f \"$D\" ] && [ ! -L \"$D\" ] && printf %s \(shellQuote(base64(expected))) "
            + "| /usr/bin/base64 -D | /usr/bin/cmp -s - \"$D\"")
    }

    /// Stops the whole script (changed marker, exit 0) unless the file still is what Paddock saw.
    static func unchangedOrStop(destination: URL, expected: String?) -> String {
        let check = unchangedTest(destination: destination, expected: expected)
        return "\(check.setup); if \(check.test); then :; else \(reportChanged); exit 0; fi"
    }

    /// A root shell script that acts only if `destination` still is what Paddock saw before the
    /// prompt: absent (`expected == nil`) or a regular file with exactly `expected`. Contents travel
    /// base64-encoded inside the script, so there is no staged file to swap, and writes go to a
    /// root-made temp file in the same directory, then `mv` into place with mode 644 (atomic). It exits
    /// only on failure (with `failure`'s marker on stderr), so steps after it in the same script still run.
    static func guardedScript(destination: URL, expected: String?, action: Action,
                              failure: PrivilegedStage = .resolverWrite) -> String {
        let check = unchangedTest(destination: destination, expected: expected)
        let fail = { (detail: String) in failure.report(detail) + "; exit 1" }
        let act: String
        switch action {
        case .remove:
            act = "/bin/rm -f \"$D\" || { \(fail("could not remove " + destination.path)); }"
        case .write(let text):
            act = "T=$(/usr/bin/mktemp \"$DIR/.paddock.XXXXXX\") || { \(fail("could not create a file in " + destination.deletingLastPathComponent().path)); }; "
                + "if printf %s \(shellQuote(base64(text))) | /usr/bin/base64 -D > \"$T\" "
                + "&& /bin/chmod 644 \"$T\" && /bin/mv -f \"$T\" \"$D\"; then :; "
                + "else /bin/rm -f \"$T\"; \(fail("could not write " + destination.path)); fi"
        }
        return "\(check.setup); /bin/mkdir -p \"$DIR\" || { \(fail("could not create " + destination.deletingLastPathComponent().path)); }; "
            + "if \(check.test); then \(act); else \(reportChanged); fi"
    }

    private static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static func appleScript(shell: String, prompt: String = installPrompt) -> String {
        "do shell script \"\(appleScriptEscape(rootShellCommand(shell)))\" with prompt \"\(appleScriptEscape(prompt))\" "
            + "with administrator privileges"
    }
}

/// Which part of a privileged script failed. Each failure writes its marker and a short detail to stderr
/// before exiting, so the caller can say what went wrong in plain words.
enum PrivilegedStage: String, CaseIterable {
    case portsInstall = "PADDOCK_FAILED_PORTS_INSTALL"
    case portsRemoval = "PADDOCK_FAILED_PORTS_REMOVAL"
    case resolverWrite = "PADDOCK_FAILED_RESOLVER_WRITE"
    case resolverRestore = "PADDOCK_FAILED_RESOLVER_RESTORE"

    /// Shell that writes `<marker> <detail>` to stderr.
    func report(_ detail: String) -> String {
        "echo \(Resolver.shellQuote(rawValue + " " + detail)) >&2"
    }

    /// The first stage marker in `output` and the rest of its line, without osascript's ` (1)` suffix.
    static func failed(in output: String) -> (PrivilegedStage, String)? {
        let found = allCases.compactMap { stage in output.range(of: stage.rawValue).map { (stage, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
        guard let (stage, range) = found else { return nil }
        var detail = String(output[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" })
            .trimmingCharacters(in: .whitespaces)
        if let suffix = detail.range(of: #" \(-?\d+\)$"#, options: .regularExpression) {
            detail.removeSubrange(suffix)
        }
        return (stage, detail)
    }
}
