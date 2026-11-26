import AppKit
import PaddockCore
import SwiftUI

/// The Logs window: the logs there are on the left, the chosen one's end on the right, growing as it is written.
/// Plain; `LogsModel` holds the logic.
struct LogsView: View {
    static let windowID = "logs"
    static let size = CGSize(width: 980, height: 600)

    @EnvironmentObject private var logs: LogsModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            LogList()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 340, maxHeight: .infinity)
            LogDetail()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 420)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
        // The list of logs comes from the daemon's status, so both are read while the window shows.
        .background(VisibilityReporter { visible in
            if visible {
                model.beginWatching()
                logs.beginWatching()
            } else {
                model.endWatching()
                logs.endWatching()
            }
        })
    }
}

/// Every log, by group.
struct LogList: View {
    @EnvironmentObject private var logs: LogsModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(logs.sections) { section in
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(section.sources) { source in
                        Button {
                            Task { await logs.select(source.id) }
                        } label: {
                            LogListRow(title: source.title, selected: source.id == logs.selection)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(Theme.surface)
    }
}

private struct LogListRow: View {
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Theme.onHoney : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.honey : Color.clear))
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
    }
}

/// The chosen log: a filter, pause and Reveal in Finder, then its entries with the newest kept in sight.
struct LogDetail: View {
    @EnvironmentObject private var logs: LogsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: Binding(get: { logs.filter }, set: { logs.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                Toggle("Errors only", isOn: Binding(
                    get: { logs.problemsOnly },
                    set: { logs.setProblemsOnly($0) }))
                    .toggleStyle(.button)
                    .help("Show only the entries that are errors")
                Toggle("Pause", isOn: Binding(
                    get: { logs.isPaused },
                    set: { paused in Task { await logs.setPaused(paused) } }))
                    .toggleStyle(.button)
                    .help("Stop adding new lines while you read")
                Button("Reveal in Finder") { logs.revealSelected() }
                    .disabled(logs.selected == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.line).frame(height: 1)

            if let text = logs.emptyText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entries
            }
        }
    }

    private var entries: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logs.shown) { entry in
                        LogEntryRow(entry: entry, expanded: logs.isExpanded(entry)) { logs.toggle(entry) }
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Theme.surface)
            // New lines: keep the newest in sight, unless the reader paused to read.
            .onChange(of: logs.arrivals) { _ in
                if !logs.isPaused, let last = logs.shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = logs.shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// One entry: its first line, and under it (folded until asked for) what belongs to it.
private struct LogEntryRow: View {
    let entry: LogEntry
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if entry.detail.isEmpty {
                    Color.clear.frame(width: 12, height: 1)
                } else {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkMuted)
                    .help(expanded ? "Fold" : "Show the \(entry.detail.count) lines under this")
                }
                Text(verbatim: entry.text)
                    .font(.system(.caption, design: .monospaced).weight(entry.isProblem ? .semibold : .regular))
                    .foregroundStyle(entry.isWarning ? Theme.honeyText : Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded {
                Text(verbatim: entry.detail.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        // A problem is marked by a bar and weight as well as by its word, never by colour alone.
        .overlay(alignment: .leading) {
            if entry.isProblem { Rectangle().fill(Theme.ink).frame(width: 3) }
        }
    }
}
