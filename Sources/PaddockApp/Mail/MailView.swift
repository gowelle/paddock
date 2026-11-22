import AppKit
import PaddockCore
import SwiftUI

/// The Mail window: the mail the mail service caught, and the one being read. Plain; `MailModel` holds the logic.
struct MailView: View {
    static let windowID = "mail"

    @EnvironmentObject private var mail: MailModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                MailList()
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                MailDetail()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = mail.lastError {
                Rectangle().fill(Theme.line).frame(height: 1)
                ErrorLine(text: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        // The mail service's state comes from the daemon's status, so both are read while the window shows.
        .background(VisibilityReporter { visible in
            if visible {
                model.beginWatching()
                mail.beginWatching()
            } else {
                model.endWatching()
                mail.endWatching()
            }
        })
    }

    static let size = CGSize(width: 900, height: 560)
}

/// The caught messages, newest first.
struct MailList: View {
    @EnvironmentObject private var mail: MailModel

    var body: some View {
        Group {
            if let text = mail.emptyListText {
                Caption(text)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mail.messages) { message in
                            Button {
                                Task { await mail.select(message.id) }
                            } label: {
                                MailRow(message: message, selected: message.id == mail.selection)
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Theme.surface)
    }
}

private struct MailRow: View {
    let message: MailSummary
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread: a honey dot with its darker edge. Read: the same space, empty.
            Circle()
                .fill(message.read ? Color.clear : Theme.honey)
                .overlay(Circle().strokeBorder(message.read ? Color.clear : edge, lineWidth: 2))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityLabel(message.read ? "" : "Unread")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.from?.short ?? "Unknown sender")
                        .fontWeight(message.read ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if message.attachments > 0 {
                        Image(systemName: "paperclip").font(.caption)
                    }
                    if let created = message.created {
                        Text(MailFormat.listTime(created))
                            .font(.caption)
                            .foregroundStyle(selected ? Theme.onHoney : Theme.inkMuted)
                    }
                }
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .fontWeight(message.read ? .regular : .semibold)
                    .lineLimit(1)
                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.caption)
                        .foregroundStyle(selected ? Theme.onHoney : Theme.inkMuted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Theme.onHoney : Theme.ink)
        .background(selected ? Theme.honey : Color.clear)
        .contentShape(Rectangle())
    }

    /// On the honey of a selected row the dot's edge is the row's own text colour.
    private var edge: Color { selected ? Theme.onHoney : Theme.honeyText }
}

/// The message being read: who and when, the ways to look at it, and its attachments.
struct MailDetail: View {
    @EnvironmentObject private var mail: MailModel

    var body: some View {
        if let message = mail.opened {
            VStack(alignment: .leading, spacing: 0) {
                MailHeader(message: message)
                    .padding(16)
                Rectangle().fill(Theme.line).frame(height: 1)
                if mail.offersRemoteContent {
                    HStack {
                        Caption("Remote images and styles in this message are blocked.")
                        Spacer()
                        Button("Load Remote Content") { mail.allowRemoteContent() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !message.attachments.isEmpty {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    MailAttachments(parts: message.attachments)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        } else {
            Caption(mail.selection == nil ? "Choose a message to read it." : "Opening\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mail.body {
        case .html:
            if let document = mail.htmlDocument {
                MailWebView(document: document)
            }
        case .text:
            PlainText(text: mail.opened?.text ?? "")
        case .source:
            if let source = mail.source {
                PlainText(text: source)
            } else {
                Caption("Loading\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MailHeader: View {
    @EnvironmentObject private var mail: MailModel
    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.title3.weight(.heavy))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let date = message.date {
                    Text(MailFormat.fullTime(date)).font(.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                line("From", message.from.map { [$0] } ?? [])
                line("To", message.to)
                line("Cc", message.cc)
                line("Bcc", message.bcc)
                line("Reply-To", message.replyTo)
            }
            if mail.bodies.count > 1 {
                Picker("View", selection: Binding(
                    get: { mail.body },
                    set: { body in Task { await mail.show(body) } })) {
                    ForEach(mail.bodies) { body in Text(body.rawValue).tag(body) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func line(_ label: String, _ addresses: [MailAddress]) -> some View {
        if !addresses.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 56, alignment: .trailing)
                Text(addresses.map(\.full).joined(separator: ", "))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The text part or the source, in the monospaced face, selectable.
private struct PlainText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.surface)
    }
}

/// One button per attachment; each asks where to save it.
private struct MailAttachments: View {
    @EnvironmentObject private var mail: MailModel
    let parts: [MailPart]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(parts) { part in
                    Button {
                        Task { await save(part) }
                    } label: {
                        Label("\(name(part)) (\(MailFormat.size(part.size)))", systemImage: "paperclip")
                    }
                    .help("Save \(name(part))\u{2026}")
                }
            }
        }
    }

    private func name(_ part: MailPart) -> String {
        part.fileName.isEmpty ? "Attachment \(part.partID)" : part.fileName
    }

    private func save(_ part: MailPart) async {
        guard let data = await mail.data(for: part) else { return }
        let panel = NSSavePanel()
        // Only the last path component: a file name from an email never chooses the folder.
        panel.nameFieldStringValue = (name(part) as NSString).lastPathComponent
        panel.canCreateDirectories = true
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// How the Mail window writes times and sizes.
enum MailFormat {
    /// The time for today's mail, the date for older mail.
    static func listTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    static func fullTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
