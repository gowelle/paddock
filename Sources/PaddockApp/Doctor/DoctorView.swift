import AppKit
import PaddockCore
import SwiftUI

/// The Doctor window: a site picker, "Check again", and the last report as a checklist with fixes.
struct DoctorView: View {
    static let windowID = "doctor"
    static let size = CGSize(width: 560, height: 620)

    @EnvironmentObject private var doctor: DoctorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Site", selection: Binding(
                    get: { doctor.target },
                    set: { name in
                        doctor.target = name
                        Task { await doctor.check() }
                    })) {
                        Text("All sites").tag(String?.none)
                        ForEach(doctor.sites) { site in
                            Text(site.host).tag(Optional(site.name))
                        }
                    }
                    .fixedSize()
                Button("Check again") { Task { await doctor.check() } }
                    .disabled(doctor.isChecking)
                if doctor.isChecking { ProgressView().controlSize(.small) }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let report = doctor.report {
                        if doctor.target != nil, let one = report.sites.first {
                            ReportHeading(report: one)
                            CheckRows(checks: report.global)
                            CheckRows(checks: one.checks)
                        } else {
                            CheckRows(checks: report.global)
                            ForEach(Array(report.sites.enumerated()), id: \.offset) { _, one in
                                ReportHeading(report: one)
                                CheckRows(checks: one.checks)
                            }
                        }
                        if report.isHealthy {
                            Text("Everything checks out.")
                                .font(.callout)
                                .foregroundStyle(Theme.pasture)
                        }
                    } else if doctor.isChecking {
                        Text("Checking…").foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
        .task {
            if doctor.report == nil { await doctor.check() }
        }
    }
}

private struct ReportHeading: View {
    let report: DoctorReport.SiteReport

    var body: some View {
        Text("\(report.host) — PHP \(report.php.description), \(report.url)")
            .font(Theme.heading(15))
            .padding(.top, 4)
    }
}

private struct CheckRows: View {
    let checks: [DoctorCheck]

    var body: some View {
        ForEach(checks) { check in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    OutcomeSymbol(outcome: check.outcome)
                    Text(check.title).font(.callout)
                }
                if check.outcome != .passed {
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                }
                if let fix = check.fix {
                    Text(fix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.honeyText)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
        }
    }
}

private struct OutcomeSymbol: View {
    let outcome: DoctorCheck.Outcome

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
    }

    private var icon: String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .passed: return Theme.pasture
        case .failed: return .red
        case .skipped: return Theme.inkMuted
        case .info: return .blue
        }
    }
}
