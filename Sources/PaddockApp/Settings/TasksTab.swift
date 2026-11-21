import PaddockCore
import SwiftUI

/// Each site's own commands from its `paddock.json` (queue worker, scheduler…) and the approval prompt. Plain;
/// the model holds the logic.
struct TasksTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.taskSites) { section in
                        SiteTasksView(section: section)
                        Divider()
                    }
                    if model.taskSites.isEmpty {
                        Caption("No sites yet.").padding(12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tableSurface()
            if let notice = model.taskNotice { Caption(notice) }
            DismissibleErrorLine()
        }
        .padding(20)
        .sheet(isPresented: Binding(get: { model.approvalSite != nil }, set: { if !$0 { model.dismissApproval() } })) {
            ApprovalSheet()
                .environmentObject(model)
        }
    }
}

/// One site: what needs the user (approval, a broken file, no file yet), its tasks, and its forwarding.
struct SiteTasksView: View {
    @EnvironmentObject private var model: AppModel
    let section: SiteTasksSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: section.site).fontWeight(.semibold)
                Text(verbatim: section.folder)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if section.canCreateStarterFile {
                    Button("Create paddock.json") { Task { await model.createStarterFile(site: section.site) } }
                        .disabled(model.isBusy(.tasksInit(site: section.site)))
                }
                if section.canRevoke {
                    Button("Turn Off") { Task { await model.revokeTasks(site: section.site) } }
                        .disabled(model.isBusy(.tasksRevoke(site: section.site)))
                }
            }
            if let problem = section.problem { Caption(problem) }
            if section.needsApproval {
                HStack {
                    Text(verbatim: "paddock.json has commands waiting for your approval.")
                    Spacer()
                    Button("Review…") { Task { await model.showApproval(site: section.site) } }
                }
            }
            ForEach(section.tasks) { task in
                TaskRowView(task: task)
            }
            ForEach(section.routes, id: \.self) { route in
                Text(verbatim: route)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = section.notice { Caption(notice) }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(12)
    }
}

/// One task: name and state, the whole command (wrapped, never cut), and its actions.
struct TaskRowView: View {
    @EnvironmentObject private var model: AppModel
    let task: TaskRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: task.name).fontWeight(.medium)
                Text(verbatim: task.stateText).foregroundStyle(Theme.inkMuted)
                Spacer()
                if task.canStop {
                    Button("Stop") { Task { await model.stopTask(site: task.site, task: task.name) } }
                }
                if task.canStart {
                    Button("Start") { Task { await model.startTask(site: task.site, task: task.name) } }
                }
                if task.canStop {
                    Button("Restart") { Task { await model.restartTask(site: task.site, task: task.name) } }
                }
                // Nothing has run (or been logged) before the file is approved.
                if task.canStart || task.canStop {
                    Button("Open Log") { model.openTaskLog(site: task.site, task: task.name) }
                }
            }
            .disabled(isBusy)
            Text(verbatim: task.command)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if task.restartsOnChange { Caption("restarts when code changes") }
            if let warning = task.warning { Caption(warning) }
        }
        .padding(.leading, 8)
    }

    private var isBusy: Bool {
        [Request.taskStart(site: task.site, task: task.name), .taskStop(site: task.site, task: task.name),
         .taskRestart(site: task.site, task: task.name)].contains(where: model.isBusy)
    }
}

/// Every command and forwarding line the site's `paddock.json` would run, exactly as the daemon reported them, in
/// full; or why there is nothing to approve. `Approve` approves exactly what is shown; it is never the default
/// button.
struct ApprovalSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Approve the tasks of \(model.approvalSite ?? "")?")
                .font(.headline)
            switch model.approvalState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading paddock.json…")
                }
            case .ready(let shown):
                Text(verbatim: shown.heading)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(shown.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.system(.body, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 360)
                .tableSurface()
                Caption(shown.isChange
                        ? "The approved version keeps running until you approve this one."
                        : "Paddock runs these commands in the site's folder whenever it runs, until you turn them off.")
            case .nothingToApprove(let reason), .failed(let reason):
                Text(verbatim: reason)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.approvalError { VerbatimErrorText(text: error) }
            HStack {
                Spacer()
                switch model.approvalState {
                case .loading, .ready:
                    Button("Not Now") { model.dismissApproval() }
                        .keyboardShortcut(.cancelAction)
                    // No default-action shortcut: Return must not approve.
                    Button("Approve") {
                        if let site = model.approvalSite { Task { await model.approveTasks(site: site) } }
                    }
                    .disabled(!model.canApprove || approving)
                case .nothingToApprove, .failed:
                    Button("Close") { model.dismissApproval() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
    }

    /// An approval of what is shown is in flight.
    private var approving: Bool {
        guard let shown = model.shownApproval else { return false }
        return model.isBusy(shown.approveRequest)
    }
}
