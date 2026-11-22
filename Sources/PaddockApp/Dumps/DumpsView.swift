import AppKit
import PaddockCore
import SwiftUI

/// The Dumps window: what sites `dump()` while it is open, newest first. Plain; `DumpsModel` holds the logic.
struct DumpsView: View {
    static let windowID = "dumps"
    static let size = CGSize(width: 760, height: 600)

    @EnvironmentObject private var dumps: DumpsModel
    /// False only for a snapshot, which shows the window without opening a port.
    var listens = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(state: dumps.isListening ? .running : .stopped)
                    .frame(width: 14, height: 14)
                Text(dumps.statusLine)
                Spacer()
                Button("Clear") { dumps.clear() }
                    .disabled(dumps.dumps.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.line).frame(height: 1)

            if let text = dumps.emptyText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(dumps.dumps) { dump in DumpCard(dump: dump) }
                    }
                    .padding(12)
                }
            }
            if let notice = dumps.notice {
                Rectangle().fill(Theme.line).frame(height: 1)
                ErrorLine(text: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
        // Listening lasts as long as the window is open (not only while it is in front): closing it is what
        // sends dumps back to the page.
        .onAppear { if listens { Task { await dumps.open() } } }
        .onDisappear { if listens { Task { await dumps.close() } } }
    }
}

/// One dump: when, during what and from where, then the value.
private struct DumpCard: View {
    @EnvironmentObject private var dumps: DumpsModel
    let dump: Dump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let source = dump.source {
                    Text(verbatim: source).fontWeight(.semibold)
                        .help(dump.file ?? source)
                }
                if let origin = dump.origin {
                    Text(verbatim: origin)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let time = dump.time {
                    Text(DumpFormat.time(time)).foregroundStyle(Theme.inkMuted)
                }
                Button("Copy") { dumps.copy(dump) }
                    .controlSize(.small)
            }
            .font(.caption)
            DumpNodeView(dump: dump, node: dump.root, depth: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

/// One line of a dump and, unfolded, what is nested in it.
private struct DumpNodeView: View {
    @EnvironmentObject private var dumps: DumpsModel
    let dump: Dump
    let node: DumpNode
    let depth: Int

    var body: some View {
        let unfolded = dumps.isUnfolded(node, in: dump, depth: depth)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if node.isFoldable {
                    Button {
                        dumps.toggle(node, in: dump, depth: depth)
                    } label: {
                        Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkMuted)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                // Folded, the line ends with what closes it, so it still reads as a whole.
                line(node.head + (unfolded || !node.isFoldable ? "" : " \u{2026}" + (node.tail ?? "")))
            }
            if unfolded {
                ForEach(Array(node.body.enumerated()), id: \.offset) { _, text in
                    line(text).padding(.leading, 14)
                }
                ForEach(node.children) { child in
                    DumpNodeView(dump: dump, node: child, depth: depth + 1)
                        .padding(.leading, 14)
                }
                if let tail = node.tail {
                    line(tail).padding(.leading, 14)
                }
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(node.kind == .ellipsis ? Theme.inkMuted : (node.kind == .string ? Theme.pasture : Theme.ink))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum DumpFormat {
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
