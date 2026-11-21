import Foundation

public enum ResolverError: Error, Equatable {
    /// The owner dismissed the password prompt.
    case cancelled
    case failed(String)
}

/// What `restore()` did.
public enum ResolverRestoreOutcome: Equatable, Sendable {
    /// Wrote the saved original file back.
    case restored
    /// There was no original, so the file was deleted.
    case removed
    /// The file isn't Paddock's any more, so it was left untouched.
    case changedByAnotherProgram
    /// There is no resolver file.
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

    /// Saves any file that isn't Paddock's (once), then writes the resolver file with one password prompt.
    public func install() throws {
        let current = currentContents()
        if current == desiredContents { return }
        if let current, store.load().previousResolver == nil {
            try store.update { $0.previousResolver = current }
        }
        try withStagedFile(desiredContents) { staged in
            try runPrivileged(Self.installShellScript(staged: staged, target: file))
        }
    }

    /// Puts the saved original back (or deletes the file if there was none), unless the file
    /// is no longer Paddock's, in which case it is left alone.
    @discardableResult
    public func restore() throws -> ResolverRestoreOutcome {
        guard let current = currentContents() else { return .notInstalled }
        guard current == desiredContents else { return .changedByAnotherProgram }
        if let previous = store.load().previousResolver {
            try withStagedFile(previous) { staged in
                try runPrivileged(Self.installShellScript(staged: staged, target: file))
            }
            try store.update { $0.previousResolver = nil }
            return .restored
        }
        try runPrivileged("rm -f \(Self.shellQuote(file.path))")
        return .removed
    }

    private func currentContents() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    /// The privileged script copies a file the user wrote, so the contents never pass through quoting.
    private func withStagedFile(_ contents: String, _ body: (URL) throws -> Void) throws {
        let staged = store.paths.home.appendingPathComponent("resolver.pending")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: staged, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staged) }
        try body(staged)
    }

    private func runPrivileged(_ shell: String) throws {
        let result = try runner.run(Self.osascript, ["-e", Self.appleScript(shell: shell)])
        guard result.status != 0 else { return }
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

    static func installShellScript(staged: URL, target: URL) -> String {
        let directory = shellQuote(target.deletingLastPathComponent().path)
        let destination = shellQuote(target.path)
        return "mkdir -p \(directory) && cp \(shellQuote(staged.path)) \(destination) && chmod 644 \(destination)"
    }

    static func appleScript(shell: String) -> String {
        "do shell script \"\(appleScriptEscape(shell))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }
}
