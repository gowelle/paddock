import Foundation

/// Why a process of a task's recorded group isn't provably left from that task's earlier run.
public enum LeftoverReason: Equatable, Sendable {
    case notInSiteFolder, startedEarlier, anotherUser, anotherBoot, runByPaddock
}

/// Why a task's command can't be approved (`Messages.commandProblem`).
public enum CommandProblem: Equatable, Sendable {
    /// A character that would show other than it runs, by position (Unicode scalars, from 1) and code point.
    case character(position: Int, codePoint: UInt32)
    /// Characters not in NFC.
    case decomposed
    /// A space at the start or the end.
    case edgeSpace
    /// A ninth space in a row, at this position.
    case spaceRun(position: Int)
}

/// The plain sentences Paddock's clients print. Pure functions, so they can be tested without a daemon.
public enum Messages {
    public static let notRunning = "Paddock isn't running."
    public static let daemonNotRunning = notRunning + " Start it with: paddock start"
    public static let didNotAnswer = "Paddock didn't answer in time."

    public static func unexpectedAnswer(_ error: Error) -> String {
        "Paddock gave an unexpected answer: \(error)"
    }

    public static let minimumPHP = "Paddock supports PHP 8.1 and later."
    public static let notASite =
        "This folder isn't a Paddock site. Run this inside a site folder, or link it first with: paddock link"

    public static let trusted = "Paddock's certificate is trusted."

    public static func needsTrust(host: String) -> String {
        "\(host) is served over HTTPS, but macOS doesn't trust Paddock's certificate yet. Run: paddock trust"
    }

    public static let trustDisabled = "Certificate trust is turned off for this Paddock home."
    public static let certificateNotReady =
        "Paddock's web server hasn't created its certificate yet. Try again in a moment with: paddock trust"

    public static func securedWithoutTrust(host: String) -> String {
        "\(host) is now served over HTTPS. Certificate trust is turned off for this Paddock home, so browsers will warn."
    }

    public static let stillNotTrusted =
        "macOS still doesn't trust Paddock's certificate. Run paddock trust again and approve the macOS prompt."

    public static func phpNotAvailable(_ version: PHPVersion) -> String {
        "PHP \(version) isn't available for Intel Macs yet."
    }

    /// `Paddock can't start: ports 80 and 443 are in use by Herd.` One clause per distinct owner (the
    /// application if known, else the command, else the well-known system server), each listing its ports
    /// once; a holder `lsof` can't see carries its `Server` header in brackets, and is only "probably" a
    /// known server when no header confirmed it. A known server's stop command follows the sentence; a
    /// `sudo kill` hint follows on its own line, once per distinct pid, only for someone else's process that
    /// belongs to no known application. Paddock never runs either. Text from other programs is shown only
    /// as `printable`.
    public static func portsBlocked(_ holders: [PortHolder]) -> String {
        guard !holders.isEmpty else { return "Paddock can't start: its ports are in use." }
        let clauses = owners(holders).map { owner -> String in
            let who = owner.who + (owner.onlyPid.map { " (pid \($0))" } ?? "")
            return "\(portList(owner.ports)) \(Set(owner.ports).count == 1 ? "is" : "are") "
                + "\(owner.probable ? "probably " : "")in use by \(who)"
        }
        var text = "Paddock can't start: " + clauses.joined(separator: "; ") + "."
        var commands: [String] = []
        for command in holders.compactMap({ $0.stopCommand.flatMap { printable($0) } })
        where !commands.contains(command) {
            commands.append(command)
            text += " Stop it with: \(command)"
        }
        var hinted = Set<Int32>()
        for holder in holders where !holder.ownedByCurrentUser && holder.appName == nil {
            if let pid = holder.pid, hinted.insert(pid).inserted { text += "\nStop it with: sudo kill \(pid)" }
        }
        return text
    }

    /// The menu bar's one-line form, for the first owner: `Can't start: ports 80 and 443 in use by Herd`.
    public static func cantStart(_ holders: [PortHolder]) -> String {
        guard let first = owners(holders).first else { return "Can't start: ports in use" }
        return "Can't start: \(portList(first.ports)) \(first.probable ? "probably " : "")in use by \(first.who)"
    }

    public static let portHelperMissing = "Can't find paddock-ports next to paddockd."

    /// `paddock status` when the engine runs but launchd's port helper isn't installed (or is outdated).
    public static let finishSetup = "Paddock needs to finish setup. Run: paddock start"

    /// `paddock status`'s opening lines: whether Paddock serves (or why not), then, when secured sites
    /// need macOS to trust Paddock's certificate (again), what to run.
    public static func statusSummary(_ status: EngineStatus) -> [String] {
        var lines: [String]
        if status.running && !status.portHelperInstalled {
            lines = [finishSetup]
        } else if status.running {
            lines = ["Paddock is running."]
        } else if !status.blockedBy.isEmpty {
            lines = [portsBlocked(status.blockedBy)]
        } else {
            lines = ["Paddock is stopped."]
        }
        if status.needsTrust {
            lines.append(securedSitesNeedTrust)
        } else if status.hasReplacedRootsToClean {
            lines.append(olderCertificateStillTrusted)
        }
        return lines + status.notices
    }

    public static let securedSitesNeedTrust = "Secured sites need your approval once: run paddock trust"
    public static let olderCertificateStillTrusted = "An older Paddock certificate is still trusted: run paddock trust"

    /// `paddock stop` on the real system: the launchd entry keeps 80 and 443 until uninstall.
    public static let stoppedKeepingPorts =
        "Paddock stopped. Ports 80 and 443 stay reserved for Paddock until you uninstall it."

    /// The privileged script's port-helper steps failed (they removed what they created).
    public static func portsSetupFailed(_ detail: String) -> String {
        "Couldn't set up ports 80 and 443: \(detail)"
    }

    /// The privileged script's port-helper removal failed; `resolverRestored` if the resolver step before
    /// it put the owner's file back.
    public static func portsReleaseFailed(_ detail: String, resolverRestored: Bool) -> String {
        (resolverRestored ? "Paddock restored your .test DNS setting but couldn't release ports 80 and 443: "
                          : "Couldn't release ports 80 and 443: ")
            + "\(detail). Run paddock uninstall again."
    }

    /// Uninstall removed the port helper but would not write a saved resolver copy that doesn't look like one.
    public static func portsReleasedResolverLeft(_ path: String) -> String {
        "Paddock released ports 80 and 443, but its saved copy of your original resolver file doesn't look "
            + "like a resolver file, so \(path) was left as it is."
    }

    /// The running program isn't inside Paddock.app (a repository or debug build) on the real system, so
    /// it changes nothing there: not the LaunchAgent, the daemon, setup, trust or the shell file.
    public static let developmentBuild = "This is a development build of Paddock, so it won't change your "
        + "installed Paddock or this Mac's setup. Run the app from /Applications, or set PADDOCK_HOME to use "
        + "a test folder."

    /// The LaunchAgent belongs to another install of Paddock that is still there.
    public static func anotherCopyInstalled(path: String) -> String {
        "Another copy of Paddock is installed at \(path). Open that copy, or run paddock uninstall from it first."
    }

    /// Uninstall finished, but removing the certificate's trust did not complete.
    public static let uninstalledButStillTrusted = "Paddock is uninstalled, but its certificate is still trusted "
        + "in your keychain. Remove \"Paddock Local Authority - Root\" in Keychain Access if you want it gone."

    /// The daemon answering runs from another install of Paddock, so this one doesn't restart it.
    public static func anotherCopyRunning(path: String?) -> String {
        "Another copy of Paddock is running" + (path.map { " from \($0)" } ?? "")
            + ". Quit it, or open that copy instead."
    }

    /// `sudo paddock …` on the real system.
    public static let runningAsRoot =
        "Don't run Paddock with sudo. Run it as yourself; it asks for your password when it needs it."

    /// A PHP install cut short because the daemon is shutting down; nothing of it was kept.
    public static func phpInstallCancelled(_ version: PHPVersion) -> String {
        "Installing PHP \(version) was cancelled because Paddock is shutting down."
    }

    /// A Unix socket under Paddock's folder would be longer than macOS allows (103 bytes).
    public static func socketPathTooLong(_ path: String) -> String {
        "Paddock's folder path is too long for macOS sockets: \(path)"
    }

    /// The names a holder is shown by, each made `printable` (nil if nothing printable is left).
    private struct Shown {
        let port: Int
        let pid: Int32?
        let appName, command, serviceName, serverHeader: String?

        init(_ holder: PortHolder) {
            port = holder.port
            pid = holder.pid
            appName = holder.appName.flatMap { displayName($0) }
            command = holder.command.flatMap { displayName($0) }
            serviceName = holder.serviceName.flatMap { displayName($0) }
            serverHeader = holder.serverHeader.flatMap { printable($0) }
        }
    }

    /// A name from another program (an application or process name, a path) as Paddock shows it: the
    /// first line only (up to any line or paragraph break), terminal escape sequences removed, Unicode
    /// control, format (bidirectional overrides among them), separator, private-use and unassigned
    /// characters dropped, whitespace collapsed to single spaces, at most `limit` characters (grapheme
    /// clusters); nil if nothing is left. Legitimate names such as `Café` are kept as they are.
    public static func displayName(_ text: String, limit: Int = 64) -> String? {
        let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
        let line = text.unicodeScalars.prefix { !breaks.contains($0) }
        var kept = String.UnicodeScalarView()
        var iterator = withoutEscapeSequences(line).makeIterator()
        while let scalar = iterator.next() {
            let properties = scalar.properties
            if properties.isWhitespace {
                if let last = kept.last, last != " " { kept.append(" ") }
                continue
            }
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                continue
            default:
                kept.append(scalar)
            }
        }
        let trimmed = String(String(kept).trimmingCharacters(in: .whitespaces).prefix(limit))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The scalars with terminal escape sequences (CSI, OSC, two-character ones) taken out.
    private static func withoutEscapeSequences<S: Sequence>(_ scalars: S) -> [Unicode.Scalar]
        where S.Element == Unicode.Scalar {
        var out: [Unicode.Scalar] = []
        var iterator = scalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else { out.append(scalar); continue }
            switch iterator.next() {
            case "[":  // CSI: parameters, then one final byte in 0x40-0x7E.
                while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
            case "]":  // OSC: up to BEL or ESC.
                while let next = iterator.next(), next != "\u{07}", next != "\u{1B}" {}
            default: break  // A two-character sequence: both dropped.
            }
        }
        return out
    }

    /// Text from another program that must be plain ASCII (a `Server` header, a command) as Paddock shows it:
    /// only what comes before the first line break, terminal escape sequences removed, only printable
    /// ASCII (0x20-0x7E) kept, runs of spaces collapsed, at most `limit` characters; nil if nothing is left.
    public static func printable(_ text: String, limit: Int = 64) -> String? {
        let line = text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
        var kept = ""
        for scalar in withoutEscapeSequences(line) {
            guard (0x20...0x7E).contains(scalar.value) else { continue }
            if scalar == " " && (kept.isEmpty || kept.hasSuffix(" ")) { continue }
            kept.unicodeScalars.append(scalar)
        }
        let trimmed = String(kept.trimmingCharacters(in: .whitespaces).prefix(limit))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `port 80`, `ports 80 and 443`, `ports 80, 443 and 8080`.
    static func portList(_ ports: [Int]) -> String {
        let sorted = Array(Set(ports)).sorted().map(String.init)
        guard let last = sorted.last else { return "its ports" }
        if sorted.count == 1 { return "port \(last)" }
        return "ports \(sorted.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Holders grouped by who they are, in first-seen order. `onlyPid` is set for an owner with no
    /// known application and exactly one known pid; `probable` for a known server no header confirmed.
    private static func owners(_ holders: [PortHolder])
        -> [(who: String, ports: [Int], onlyPid: Int32?, probable: Bool)] {
        var order: [String] = []
        var groups: [String: (holders: [Shown], ports: [Int])] = [:]
        for raw in holders {
            let holder = Shown(raw)
            let key: String
            if let app = holder.appName { key = "app:" + app }
            else if let command = holder.command { key = "command:" + command }
            else if let pid = holder.pid { key = "pid:\(pid)" }
            else if let service = holder.serviceName { key = "service:" + service }
            else if let header = holder.serverHeader { key = "header:" + header }
            else { key = "unknown" }
            if groups[key] == nil { order.append(key) }
            groups[key, default: ([], [])].holders.append(holder)
            groups[key]!.ports.append(holder.port)
        }
        return order.map { key in
            let group = groups[key]!
            let first = group.holders[0]
            let pids = Set(group.holders.compactMap(\.pid))
            let onlyPid = first.appName == nil && pids.count == 1 ? pids.first : nil
            var who = first.appName ?? first.command ?? first.serviceName ?? "another program"
            let header = first.pid == nil ? group.holders.lazy.compactMap(\.serverHeader).first : nil
            if let header { who += " (\(header))" }
            let probable = first.appName == nil && first.command == nil && first.pid == nil
                && first.serviceName != nil && header == nil
            return (who, group.ports, onlyPid, probable)
        }
    }

    /// A site name as the user may have typed it: `My App`, `myapp.test` -> `my-app`, `myapp`.
    public static func siteName(_ typed: String, tld: String) -> String {
        normalizedSiteName(typed, tld: tld) ?? withoutTLD(typed, tld: tld)
    }

    /// Like `siteName`, but nil when nothing usable is left (`!!!.test`).
    public static func normalizedSiteName(_ typed: String, tld: String) -> String? {
        SiteName.normalize(withoutTLD(typed, tld: tld))
    }

    private static func withoutTLD(_ typed: String, tld: String) -> String {
        var name = typed
        if name.lowercased().hasSuffix("." + tld.lowercased()) { name.removeLast(tld.count + 1) }
        return name
    }

    // MARK: - Services

    /// Replaces the `.env` lines that name a service's Unix socket when its path would be too long.
    public static let unixSocketDisabled = "# Unix socket disabled: Paddock's folder path is too long"

    /// The `.env` lines `paddock service add` prints: the status's (which never hold a secret), then for each
    /// secret a comment saying how to get it, safe to paste into `.env` as it is.
    public static func addedEnvLines(_ status: ServiceStatus) -> [String] {
        status.env + (status.secretEnvNames ?? []).map { secretEnvComment($0, id: status.id) }
    }

    /// `# MEILISEARCH_KEY: run "paddock service env meilisearch-1-57"`
    public static func secretEnvComment(_ name: String, id: String) -> String {
        "# \(name): run \"paddock service env \(id)\""
    }

    /// What `paddock service remove` prints (and the app shows).
    public static func serviceRemoved(_ name: String, dataPath: String, deletedData: Bool) -> String {
        deletedData ? "Removed \(name) and deleted its data." : "Removed \(name). Its data is still at \(dataPath)."
    }

    /// A log a running process holds has grown very large (it is never cut while it runs).
    public static func logVeryLarge(megabytes: Int, path: String) -> String {
        "Its log is very large (\(megabytes) MB): \(path). Restart it to start a fresh log."
    }

    /// A service whose saved key was gone while its data stayed got a new one.
    public static func serviceNewKey(name: String, id: String) -> String {
        "\(name) has a new key because its saved key was missing. Update your project's .env: paddock service env \(id)."
    }

    /// What `paddock service create-db` prints.
    public static func databaseCreated(_ database: String, in name: String, alreadyExisted: Bool) -> String {
        alreadyExisted ? "\(database) already exists in \(name)." : "Created database \(database) in \(name)."
    }

    /// Re-adding a service whose data folder is still there (it was removed without deleting its data).
    public static func existingServiceData(_ name: String) -> String {
        "Found existing data for \(name); using it."
    }

    /// Who holds a port, as one short name: `Herd`, `nc (pid 412)`, `another program`. Names from other
    /// programs are shown only as `displayName`/`printable` makes them.
    public static func portHolder(_ holders: [PortHolder]) -> String {
        guard let owner = owners(holders).first else { return "another program" }
        return owner.who + (owner.onlyPid.map { " (pid \($0))" } ?? "")
    }

    public static func serviceError(_ error: ServiceError) -> String {
        switch error {
        case .unknownKind(let kind, let available):
            return "Paddock has no service called \"\(printable(kind) ?? "?")\". "
                + (available.isEmpty ? "None are available." : "Available: \(available.joined(separator: ", ")).")
        case .unknownVersion(let kind, let version, let available):
            return "\(kind) \(printable(version) ?? "?") isn't available. Available: "
                + "\(available.joined(separator: ", "))."
        case .unknownService(let name):
            return "No service named \"\(printable(name) ?? "?")\". See: paddock service list"
        case .portInUse(let name, let port, let holder):
            return "\(name) can't start: port \(port) is in use by \(holder)."
        case .noFreePort(let name, let preferred):
            return "\(name) can't be added: no port from \(preferred) to \(preferred + ServicePorts.searchLimit) is free."
        case .initialiseFailed(let name, let output):
            return "Couldn't set up \(name):\n\(output)"
        case .initialiseTimedOut(let name, let seconds, let output):
            return "Setting up \(name) took longer than \(seconds) seconds, so Paddock stopped it."
                + (output.isEmpty ? "" : " Its output:\n\(output)")
        case .notLoopback(let name, let address):
            return "\(name) tried to listen on \(address), which is not this Mac only. Paddock stopped it."
        case .dataMismatch(let name, let found, let expected):
            return "\(name) can't start: its data was last used by \(found), and Paddock won't run \(expected) on it."
        case .rollbackFailed(let name, let id, let version, let previous, let newFailure, let oldFailure):
            return "\(name) \(version) didn't start: \(newFailure)\n\(name) couldn't go back to \(previous): version "
                + "\(version) may have upgraded its data. Run paddock service update \(id) to try \(version) again.\n"
                + oldFailure
        case .unsafeRecipe(let name, let reason):
            return "\(name) can't start: \(reason)."
        case .updateFailed(let name, let version, let previous, let log):
            return "\(name) \(version) didn't start, so Paddock went back to \(previous)."
                + (log.isEmpty ? "" : " The end of its log:\n\(log)")
        case .installFailed(let name, let reason):
            switch reason {
            case .checksumMismatch(let file):
                return "Couldn't install \(name): the download \(file) isn't the file Paddock expects (checksum mismatch)."
            case .downloadFailed(let why): return "Couldn't download \(name): \(why)"
            case .notAvailable(let file): return "Couldn't install \(name): \(file) isn't on this Mac."
            case .unpackFailed(let why): return "Couldn't unpack \(name): \(why)"
            }
        case .notReady(let name, let log):
            return "\(name) didn't start." + (log.isEmpty ? "" : " The end of its log:\n\(log)")
        case .unavailable(let name, let reason):
            return "\(name) isn't available: \(reason)"
        case .cancelled(let name):
            return "Adding \(name) was cancelled because Paddock is shutting down."
        case .needsNewerMacOS(let name, let minimum):
            // `15.0` reads as macOS 15.
            let shown = minimum.hasSuffix(".0") ? String(minimum.dropLast(2)) : minimum
            return "\(name) needs macOS \(shown) or later."
        case .noAction(let name, let action):
            return action == RecipeAction.createDatabase ? "\(name) doesn't have databases." : "\(name) can't do \(action)."
        case .actionFailed(let name, let action, let output):
            let what = action == RecipeAction.createDatabase ? "create the database" : "do \(action)"
            return "Couldn't \(what) in \(name):" + (output.isEmpty ? "" : "\n\(output)")
        case .invalidParameter(let parameter, let value):
            return parameter == "database" ? "Database names can use letters, numbers and underscores."
                : "\"\(printable(value) ?? "?")\" isn't a valid \(parameter)."
        case .actionCancelled(let name, let action):
            let what = action == RecipeAction.createDatabase ? "Creating the database" : "Running \(action)"
            return "\(what) in \(name) was cancelled."
        case .notRunning(let name, let id):
            return "\(name) isn't running. Start it with: paddock service start \(id)"
        }
    }

    /// `running`, `port 1025 in use by Herd`…
    public static func serviceState(_ state: ServiceState) -> String {
        switch state {
        case .running: return "running"
        case .starting: return "starting"
        case .stopped: return "stopped"
        case .crashed: return "crashed"
        case .portInUse(let holder): return "port in use by \(holder)"
        case .unavailable(let reason): return "unavailable: \(reason)"
        }
    }

    /// `1025 (smtp), 8025 (http)`: the main port first.
    public static func servicePorts(_ status: ServiceStatus) -> String {
        status.ports.sorted { a, b in
            if a.value == status.mainPort { return true }
            if b.value == status.mainPort { return false }
            return a.value < b.value
        }.map { "\($0.value) (\($0.key))" }.joined(separator: ", ")
    }

    /// Columns: service name, state, ports; then each service's notes, one line each, after a blank line (up to
    /// the 120 characters a recipe's note may have).
    public static func serviceTable(_ services: [ServiceStatus]) -> String {
        let rows = table([["SERVICE", "STATE", "PORTS"]]
                         + services.map { [$0.name, serviceState($0.state), servicePorts($0)] })
        let notes = services.flatMap { service in (service.notes ?? []).map { "\(service.name): \(printable($0, limit: 120) ?? "")" } }
        return notes.isEmpty ? rows : rows + "\n\n" + notes.joined(separator: "\n")
    }

    /// Columns: kind, name, series (newest first), licence, the newest series' download size (`none` for a
    /// service that downloads nothing); then, after a blank line, why a series can't run on this Mac.
    public static func catalogTable(_ entries: [CatalogEntry]) -> String {
        var reasons: [String] = []
        for reason in entries.flatMap({ $0.series.compactMap(\.unavailableReason) }) where !reasons.contains(reason) {
            reasons.append(reason)
        }
        let rows = table([["KIND", "SERVICE", "SERIES", "LICENCE", "DOWNLOAD"]] + entries.map { entry in
            let bytes = entry.series.first.map(\.downloadBytes) ?? entry.downloadBytes
            return [entry.kind, entry.displayName, entry.series.map(\.series).joined(separator: ", "), entry.licence,
                    bytes.map { $0 == 0 ? "none" : "\(max(1, Int((Double($0) / 1_000_000).rounded()))) MB" } ?? "?"]
        })
        return reasons.isEmpty ? rows : rows + "\n\n" + reasons.joined(separator: "\n")
    }

    /// Left-aligned columns two spaces apart; the last column is not padded.
    private static func table(_ rows: [[String]]) -> String {
        guard let columns = rows.first?.count, columns > 0 else { return "" }
        let widths = (0..<columns).map { column in rows.map { $0[column].count }.max()! + 2 }
        return rows.map { row in
            (0..<columns).map { $0 == columns - 1 ? row[$0] : row[$0].padding(toLength: widths[$0], withPad: " ",
                                                                                startingAt: 0) }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Site tasks

    /// Why a command wouldn't show exactly as it runs: nil when it is plain text. In order: a space at either
    /// end; characters not in NFC (an accent typed as a separate mark: Paddock never changes the bytes it shows,
    /// hashes and runs, so it asks for them to be retyped); then, by position (in Unicode scalars, from 1), the
    /// first control, format (bidirectional overrides among them), surrogate, private-use or unassigned character,
    /// line or paragraph separator, combining mark (which can lay one character over another), default-ignorable
    /// code point (Hangul fillers, variation selectors…), braille blank, whitespace other than the ASCII space, or
    /// a ninth space in a row.
    public static func commandProblem(in command: String) -> CommandProblem? {
        let scalars = Array(command.unicodeScalars)
        if scalars.first == " " || scalars.last == " " { return .edgeSpace }
        if Array(command.precomposedStringWithCanonicalMapping.unicodeScalars) != scalars { return .decomposed }
        var spaces = 0
        for (index, scalar) in scalars.enumerated() {
            let position = index + 1
            if scalar == " " {
                spaces += 1
                if spaces > 8 { return .spaceRun(position: position) }
                continue
            }
            spaces = 0
            let properties = scalar.properties
            if properties.isWhitespace || properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800 {
                return .character(position: position, codePoint: scalar.value)
            }
            switch properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control, .surrogate, .privateUse, .unassigned,
                 .lineSeparator, .paragraphSeparator, .spaceSeparator:
                return .character(position: position, codePoint: scalar.value)
            default:
                continue
            }
        }
        return nil
    }

    /// Whether a command shows exactly as it runs (`commandProblem` finds nothing). A command that doesn't can't
    /// be approved: the user would approve text they can't see.
    public static func isShowable(_ command: String) -> Bool { commandProblem(in: command) == nil }

    /// A task's command as Paddock shows it: exactly as written when it `isShowable`, else what `displayName`
    /// leaves of it.
    public static func shownCommand(_ command: String) -> String {
        isShowable(command) ? command : (displayName(command, limit: SiteTasksFile.maximumRunLength) ?? "?")
    }

    /// `paddock status`'s line for a site whose `paddock.json` nobody approved yet.
    public static func tasksWaitingForApproval(site: String) -> String {
        "\(site): paddock.json has tasks waiting for your approval. Review them with: paddock tasks on --show"
    }

    public static func tasksChanged(site: String) -> String {
        "\(site): paddock.json changed since you approved it; the approved version keeps running. "
            + "Review the change with: paddock tasks on --show"
    }

    /// An approval for this path whose folder is not the one approved (deleted and made again, or another folder
    /// moved into its place): nothing of it runs or forwards.
    public static let tasksFolderReplaced =
        "This folder was replaced since its tasks were approved. Review and approve again."

    /// `tasksApprove` named another folder than the site has now.
    public static let tasksFolderChanged = "This site now points at a different folder. Review and approve again."

    public static func tasksFileRemoved(site: String) -> String {
        "\(site): paddock.json is gone; the approved tasks keep running. Stop them with: paddock tasks off"
    }

    public static func tasksFileBroken(site: String, reason: String) -> String {
        "\(site): paddock.json can't be used (\(reason)); the approved version keeps running."
    }

    public static func tasksFileInvalid(site: String, reason: String) -> String {
        "\(site): paddock.json can't be used: \(reason)."
    }

    public static func commandNotShowable(task: String, problem: CommandProblem) -> String {
        switch problem {
        case .character(let position, let codePoint):
            return "The command of task \"\(task)\" has a character that cannot be shown, at position \(position) "
                + "(U+\(String(format: "%04X", codePoint))), so Paddock won't approve it. Make it plain text in paddock.json."
        case .decomposed:
            return "Paddock won't approve the command of task \"\(task)\". This command contains decomposed characters "
                + "(for example an accent typed separately). Retype that part."
        case .edgeSpace:
            return "Paddock won't approve the command of task \"\(task)\": it starts or ends with a space."
        case .spaceRun(let position):
            return "Paddock won't approve the command of task \"\(task)\": it has more than 8 spaces in a row at "
                + "position \(position)."
        }
    }

    /// The notice of a site whose tasks run with the basic environment, and why.
    public static func tasksUseBasicEnvironment(_ reason: ShellEnvironment.FallbackReason) -> String {
        let why: String
        switch reason {
        case .timedOut: why = "your shell took longer than \(Int(ShellEnvironment.timeout)) seconds to start"
        case .shellFailed: why = "your shell exited with an error"
        case .tooLarge: why = "its environment is larger than \(ShellEnvironment.maximumEnvironmentBytes / 1024) KB"
        case .markerMissing: why = "your shell didn't print its environment"
        }
        return "Paddock couldn't read your shell's environment (\(why)), so tasks run with a basic PATH. "
            + "Check your shell's startup files, then run: paddock tasks on"
    }

    /// A task that kept finishing by itself.
    public static func taskKeepsFinishing(task: String) -> String {
        "\(task) keeps finishing by itself, so Paddock stopped restarting it. Tasks are for commands that keep running."
    }

    /// The warning of a task listening beyond this Mac (it keeps running); nil for an address only this Mac can
    /// reach. A port Paddock doesn't know is left out.
    public static func listening(_ address: ListeningAddress) -> String? {
        guard !address.isLoopback else { return nil }
        let port = address.port.map { " (port \($0))" } ?? ""
        if address.isEverywhere {
            return "Listening on all network interfaces\(port). Add --host=127.0.0.1 or similar to keep it on this Mac."
        }
        return "Listening on \(printable(address.host) ?? "?")\(port), which other devices can reach."
    }

    /// The line in a task's log when the site's code changed.
    public static let taskRestartingForChange = "The site's code changed; restarting."

    /// `paddock tasks stop` (or `off`) after a few seconds.
    public static func waitingForTask(_ task: String) -> String { "Waiting for \(task) to finish…" }

    /// What `paddock tasks restart --force` stopped, and what it left (and why).
    public static func leftoversStopped(task: String, stopped: [Int32], left: [(Int32, LeftoverReason)]) -> String {
        let leftList = left.map { "\($0.0) (\(leftoverReason($0.1)))" }.joined(separator: ", ")
        if stopped.isEmpty {
            guard !left.isEmpty else { return "Found no processes left from an earlier run of \(task)." }
            return "Found no processes left from an earlier run of \(task) that are provably that task's. "
                + "Left \(left.count): \(leftList)."
        }
        var text = "Stopped \(stopped.count) process\(stopped.count == 1 ? "" : "es") left from an earlier run of \(task): "
            + stopped.map(String.init).joined(separator: ", ") + "."
        if !left.isEmpty { text += " Left \(left.count) that aren't provably that task's: \(leftList)." }
        return text
    }

    static func leftoverReason(_ reason: LeftoverReason) -> String {
        switch reason {
        case .notInSiteFolder: return "not in the site's folder"
        case .startedEarlier: return "started before the task's record"
        case .anotherUser: return "another user's process; Paddock can't inspect or stop it"
        case .anotherBoot: return "the record is from another boot"
        case .runByPaddock: return "run by Paddock"
        }
    }

    public static func taskRestarting(status: Int32) -> String {
        "exited with status \(status); Paddock restarts it in a moment"
    }

    public static func taskGaveUp(status: Int32, task: String) -> String {
        "exited with status \(status) \(Supervisor.maxFailures) times within a minute, so Paddock stopped restarting it. "
            + "See: paddock tasks logs \(task)"
    }

    public static func taskCouldNotRun(shell: String) -> String { "Paddock couldn't run \(shell)" }

    /// Lines Paddock adds to a task's own log.
    public static func taskCutShort(after seconds: Int, allowed: Int) -> String {
        "Paddock was shutting down, so it stopped this task after \(seconds) seconds instead of waiting the "
            + "\(allowed) its stopSeconds allow."
    }

    public static let taskSiteGone = "The site's folder is gone, so Paddock stopped this task."

    /// `running (pid 12)`, `stopped by you`…; with `task`, a state the user must clear names how.
    public static func taskState(_ state: TaskState, task: String? = nil) -> String {
        switch state {
        case .running(let pid): return "running (pid \(pid))"
        case .starting: return "starting"
        case .stopped(let reason):
            switch reason {
            case .byYou?: return "stopped by you"
            case .exited?: return "stopped: it keeps finishing by itself"
            case .notAutostart?: return "stopped (doesn't start with Paddock)"
            case .unknown?, nil: return "stopped"
            }
        case .stopping: return "stopping"
        case .crashed(let reason): return "crashed: \(reason)"
        case .waitingForApproval: return "waiting for your approval"
        case .alreadyRunning(let pid): return "already running (pid \(pid)), not started by this Paddock"
        case .leftFromEarlierRun:
            return "already running (processes left from an earlier run), not started by this Paddock"
                + (task.map { "; run: paddock tasks restart \($0) --force" } ?? "")
        }
    }

    /// `paddock status`'s lines about sites' tasks: each site's tasks and their states, and a line for each site
    /// whose `paddock.json` needs looking at.
    public static func siteTasksLines(_ sites: [Site]) -> [String] {
        var lines: [String] = []
        for site in sites {
            guard let tasks = site.tasks else {
                if let notice = site.notice { lines.append("\(site.name): \(notice)") }
                continue
            }
            switch tasks.approval {
            case .none: break
            case .needsApproval: lines.append(tasksWaitingForApproval(site: site.name))
            case .invalid(let reason): lines.append(tasksFileInvalid(site: site.name, reason: reason))
            case .approved, .changed:
                for task in tasks.tasks { lines.append("\(site.name)/\(task.name): \(taskState(task.state, task: task.name))") }
                lines += routeLines(tasks, site: site).map { "\(site.name): \($0)" }
                if tasks.approval == .changed, let notice = tasks.notice { lines.append(notice) }
            }
        }
        return lines
    }

    /// Columns: task, state, command; then which tasks restart when code changes, the site's routes (`routes`,
    /// as `routeLines` gives them), each task's warning and the site's notice, one line each.
    public static func taskTable(_ status: SiteTasksStatus, routes: [String] = []) -> String {
        var lines = [table([["TASK", "STATE", "COMMAND"]]
                           + status.tasks.map { [$0.name, taskState($0.state, task: $0.name), $0.run] })]
        lines += status.tasks.filter(\.restartOnChange).map { "\($0.name): restarts when code changes" }
        lines += routes
        lines += status.tasks.compactMap { task in task.warning.map { "\(task.name): \($0)" } }
        if let notice = status.notice { lines.append(notice) }
        return lines.joined(separator: "\n")
    }

    /// `paddock tasks` outside a site folder, when no site has a `paddock.json`.
    public static let noSiteHasTasks =
        "No site has a paddock.json yet. Start one in a Laravel project with: paddock tasks init"

    /// `paddock tasks init` in a project that isn't Laravel: an example follows.
    public static func tasksExample(site: String, path: String) -> String {
        "\(site) isn't a Laravel project, so here is an example to start from. Save it as \(path):"
    }

    public static func tasksFileWritten(path: String) -> String {
        "Wrote \(path). Review and approve its tasks with: paddock tasks on"
    }

    public static func nothingToApprove(path: String) -> String { "\(path) has no tasks or proxy paths to approve." }

    /// What approving shows: every task with its command, then every proxy line, as the site's own address.
    public static func approvalLines(_ pending: [PendingTask], site: Site) -> [String] {
        pending.map { line in
            if let port = line.port { return forward(site, prefix: line.name, port: port) }
            return "\(line.name): \(line.run ?? "")"
        }
    }

    /// `forward https://shop.test/app → 127.0.0.1:8080`
    public static func forward(_ site: Site, prefix: String, port: Int) -> String {
        "forward \(site.secured ? "https" : "http")://\(site.host)\(prefix) → 127.0.0.1:\(port)"
    }

    /// A site's routes in effect, shortest prefix first.
    public static func routeLines(_ status: SiteTasksStatus, site: Site) -> [String] {
        status.routes.sorted { $0.key < $1.key }.map { forward(site, prefix: $0.key, port: $0.value) }
    }

    /// Caddy's answer on a route whose port nothing listens on.
    public static func nothingListening(port: Int, prefix: String) -> String {
        "Paddock: nothing is listening on port \(port) for \(prefix) (is the task running?)"
    }

    /// For `paddock tasks on` and the example file: how forwarding paths match.
    public static let forwardingIgnoresCase = "Forwarding paths (\"proxy\") match whatever the upper and lower case: "
        + "/app also forwards /App."

    public static func forwardingPathNoLongerAccepted(_ path: String) -> String {
        "A forwarding path in the approved file is no longer accepted: \(printable(path, limit: 120) ?? "?"). "
            + "Edit paddock.json and approve again."
    }

    public static func routeOnPaddocksPort(prefix: String, port: Int) -> String {
        "The route \(prefix) isn't used: port \(port) is Paddock's own."
    }

    /// A withdrawal (or other change) whose reload failed: what Caddy serves still forwards.
    public static func forwardingStillActive(_ reason: String) -> String {
        "Forwarding for this site is still active until Paddock can reload the web server: "
            + "\(printable(reason, limit: 200) ?? "it refused the change")"
    }

    public static func proxyRoutesNotApplied(_ reason: String) -> String {
        "Paddock couldn't apply this site's forwarding: \(printable(reason, limit: 200) ?? "the web server refused it")"
    }

    public static func taskError(_ error: SiteTaskError) -> String {
        switch error {
        case .unknownSite(let name):
            return "Paddock doesn't serve a site named \(printable(name) ?? "?")."
        case .noTasksFile(let site):
            return "\(site) has no paddock.json. Start one with: paddock tasks init"
        case .invalid(let site, let reason):
            return "\(site)'s paddock.json can't be used: \(reason)."
        case .notApproved(let site):
            return "\(site)'s tasks aren't approved yet. Review and approve them with: paddock tasks on"
        case .unknownTask(let site, let task):
            return "\(site) has no task named \"\(printable(task) ?? "?")\". See: paddock tasks"
        case .notShowable(_, let task, let problem):
            return commandNotShowable(task: task, problem: problem)
        case .stillStopping(let task):
            return "\(task) is still stopping."
        case .leftoverProcesses(_, let task):
            return "\(task) is already running (processes left from an earlier run), not started by this Paddock. "
                + "Stop them with: paddock tasks restart \(task) --force"
        case .folderChanged:
            return tasksFolderChanged
        case .changedSinceShown(let site):
            return "\(site)'s paddock.json changed after it was shown, so Paddock approved nothing. "
                + "Review it again with: paddock tasks on --show"
        case .alreadyRunning(_, let task, let pid):
            return "\(task) is already running (pid \(pid)), not started by this Paddock. Stop that process first."
        case .couldNotStart(_, let task, let reason):
            return "Couldn't start \(task): \(reason)."
        case .fileExists(_, let path):
            return "\(path) already exists; Paddock never overwrites it."
        case .notLaravel(let site):
            return "\(site) isn't a Laravel project, so Paddock has no starter paddock.json for it."
        case .couldNotWrite(_, let reason):
            return "Couldn't write paddock.json: \(reason)"
        case .shuttingDown:
            return "Paddock is shutting down."
        }
    }

    /// Columns: site name, URL, PHP version, secured.
    public static func siteTable(_ sites: [Site]) -> String {
        let header = ["SITE", "URL", "PHP", "SECURED"]
        let rows = sites.map { [$0.name, $0.url, $0.php.description, $0.secured ? "yes" : "no"] }
        let all = [header] + rows
        let widths = (0..<3).map { column in all.map { $0[column].count }.max()! + 2 }
        return all.map { row in
            (0..<3).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined() + row[3]
        }.joined(separator: "\n")
    }
}
