import Foundation

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
    /// application if known, else the command), each listing its ports once. A `sudo kill` hint follows on
    /// its own line, once per distinct pid, only for someone else's process that belongs to no known
    /// application. Paddock never runs it.
    public static func portsBlocked(_ holders: [PortHolder]) -> String {
        guard !holders.isEmpty else { return "Paddock can't start: its ports are in use." }
        let clauses = owners(holders).map { owner -> String in
            let who = owner.who + (owner.onlyPid.map { " (pid \($0))" } ?? "")
            return "\(portList(owner.ports)) \(Set(owner.ports).count == 1 ? "is" : "are") in use by \(who)"
        }
        var text = "Paddock can't start: " + clauses.joined(separator: "; ") + "."
        var hinted = Set<Int32>()
        for holder in holders where !holder.ownedByCurrentUser && holder.appName == nil {
            if let pid = holder.pid, hinted.insert(pid).inserted { text += "\nStop it with: sudo kill \(pid)" }
        }
        return text
    }

    /// The menu bar's one-line form, for the first owner: `Can't start: ports 80 and 443 in use by Herd`.
    public static func cantStart(_ holders: [PortHolder]) -> String {
        guard let first = owners(holders).first else { return "Can't start: ports in use" }
        return "Can't start: \(portList(first.ports)) in use by \(first.who)"
    }

    public static let portHelperMissing = "Can't find paddock-ports next to paddockd."

    /// `paddock status` when the engine runs but launchd's port helper isn't installed (or is outdated).
    public static let finishSetup = "Paddock needs to finish setup. Run: paddock start"

    /// `paddock stop` on the real system: the launchd entry keeps 80 and 443 until uninstall.
    public static let stoppedKeepingPorts =
        "Paddock stopped. Ports 80 and 443 stay reserved for Paddock until you uninstall it."

    /// A PHP install cut short because the daemon is shutting down; nothing of it was kept.
    public static func phpInstallCancelled(_ version: PHPVersion) -> String {
        "Installing PHP \(version) was cancelled because Paddock is shutting down."
    }

    /// A Unix socket under Paddock's folder would be longer than macOS allows (103 bytes).
    public static func socketPathTooLong(_ path: String) -> String {
        "Paddock's folder path is too long for macOS sockets: \(path)"
    }

    /// `port 80`, `ports 80 and 443`, `ports 80, 443 and 8080`.
    static func portList(_ ports: [Int]) -> String {
        let sorted = Array(Set(ports)).sorted().map(String.init)
        guard let last = sorted.last else { return "its ports" }
        if sorted.count == 1 { return "port \(last)" }
        return "ports \(sorted.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Holders grouped by who they are, in first-seen order. `onlyPid` is set for an owner with no
    /// known application and exactly one known pid.
    private static func owners(_ holders: [PortHolder]) -> [(who: String, ports: [Int], onlyPid: Int32?)] {
        var order: [String] = []
        var groups: [String: (holders: [PortHolder], ports: [Int])] = [:]
        for holder in holders {
            let key: String
            if let app = holder.appName { key = "app:" + app }
            else if let command = holder.command { key = "command:" + command }
            else if let pid = holder.pid { key = "pid:\(pid)" }
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
            return (first.appName ?? first.command ?? "another program", group.ports, onlyPid)
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
