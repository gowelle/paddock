import Foundation

/// The CLI's exact lines for a doctor report, so the format is tested without running the program.
public enum DoctorText {
    /// With `site`, that site's global and own checks under one heading; without it, Paddock's checks
    /// once and then each site, a healthy site as one line.
    ///
    /// `site` names a site by its `site` name or its `host`; when no report matches (a full report
    /// with no such site, or a report with no sites at all), the first report is used, then the bare
    /// name.
    public static func lines(for report: DoctorReport, site: String? = nil) -> [String] {
        var lines: [String] = []
        if let site {
            let one = report.sites.first { $0.site == site || $0.host == site } ?? report.sites.first
            if let one {
                lines.append(heading(one))
            } else {
                lines.append(site)
            }
            lines.append("")
            for check in report.global + (one?.checks ?? []) {
                append(check, to: &lines)
            }
        } else {
            lines.append("Paddock")
            lines.append("")
            for check in report.global { append(check, to: &lines) }
            for one in report.sites {
                lines.append("")
                if one.checks.contains(where: { $0.outcome == .failed }) {
                    lines.append(heading(one))
                    for check in one.checks { append(check, to: &lines) }
                } else {
                    lines.append("\(one.host): OK.")
                }
            }
        }
        lines.append("")
        lines.append(summary(report))
        return lines
    }

    private static func heading(_ site: DoctorReport.SiteReport) -> String {
        "\(site.host) — PHP \(site.php), \(site.url)"
    }

    private static func append(_ check: DoctorCheck, to lines: inout [String]) {
        switch check.outcome {
        case .passed:
            lines.append("  ✓ \(sentence(check.title))")
        case .failed:
            lines.append("  ✗ \(sentence(check.title))")
            lines.append("      \(sentence(check.detail))")
            if let fix = check.fix { lines.append("      Fix: \(fix)") }
        case .skipped:
            lines.append("  - \(sentence(check.title))")
            lines.append("      \(sentence(check.detail))")
        case .info:
            lines.append("  i \(sentence(check.title))")
            lines.append("      \(sentence(check.detail))")
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    private static func summary(_ report: DoctorReport) -> String {
        switch report.failures.count {
        case 0: return "Everything checks out."
        case 1: return "1 check needs attention."
        case let count: return "\(count) checks need attention."
        }
    }
}
