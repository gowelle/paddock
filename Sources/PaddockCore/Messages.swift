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

    /// `Paddock can't start: port 80 is in use by nginx (pid 123).`, plus a `sudo kill` hint on a second
    /// line for each holder that has a known pid and belongs to someone else. Paddock never runs it.
    public static func portsBlocked(_ holders: [PortHolder]) -> String {
        guard !holders.isEmpty else { return "Paddock can't start: its ports are in use." }
        let clauses = holders.map { holder -> String in
            var who: String
            switch (holder.command, holder.pid) {
            case (let command?, let pid?): who = "\(command) (pid \(pid))"
            case (let command?, nil): who = command
            case (nil, let pid?): who = "another program (pid \(pid))"
            case (nil, nil): who = "another program"
            }
            return "port \(holder.port) is in use by \(who)"
        }
        var text = "Paddock can't start: " + clauses.joined(separator: "; ") + "."
        for holder in holders where !holder.ownedByCurrentUser {
            if let pid = holder.pid { text += "\nStop it with: sudo kill \(pid)" }
        }
        return text
    }

    /// The menu bar's one-line form: `Can't start: port 80 in use by nginx`.
    public static func cantStart(_ holder: PortHolder) -> String {
        "Can't start: port \(holder.port) in use by \(holder.command ?? "another program")"
    }

    /// A site name as the user may have typed it: `My App`, `myapp.test` -> `my-app`, `myapp`.
    public static func siteName(_ typed: String, tld: String) -> String {
        var name = typed
        if name.lowercased().hasSuffix("." + tld) { name.removeLast(tld.count + 1) }
        return SiteName.normalize(name) ?? name
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
