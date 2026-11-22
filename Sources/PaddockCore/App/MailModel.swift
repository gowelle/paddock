import Combine
import Foundation

/// Where the mail service stands, read from the daemon's status.
public enum MailEndpoint: Equatable, Sendable {
    /// No mail service has been added.
    case notAdded
    /// One is added but isn't running.
    case notRunning
    /// It answers at `base`; apps send to `smtpPort`.
    case running(base: URL, smtpPort: Int?)

    /// The first mail service in the list, by its state and `http` port.
    public static func find(in services: [ServiceStatus]) -> MailEndpoint {
        guard let mail = services.first(where: { $0.kind == "mail" }) else { return .notAdded }
        guard mail.state == .running, let port = mail.ports["http"],
              let base = URL(string: "http://127.0.0.1:\(port)") else { return .notRunning }
        return .running(base: base, smtpPort: mail.ports["smtp"])
    }
}

/// The ways to look at one message.
public enum MailBody: String, CaseIterable, Identifiable, Sendable {
    case html = "HTML", text = "Text", source = "Source"

    public var id: String { rawValue }
}

/// Everything the Mail window and the menu's Mail row show, and every action they take. The views hold no
/// logic. It reads the mail service only while something is watching.
@MainActor
public final class MailModel: ObservableObject {
    @Published public private(set) var endpoint: MailEndpoint = .notAdded
    /// The newest messages, newest first.
    @Published public private(set) var messages: [MailSummary] = []
    @Published public private(set) var unread = 0
    @Published public private(set) var total = 0
    /// The message chosen in the list.
    @Published public private(set) var selection: String?
    /// The chosen message, once it has loaded.
    @Published public private(set) var opened: MailMessage?
    @Published public private(set) var body: MailBody = .html
    /// The chosen message as it arrived, once asked for.
    @Published public private(set) var source: String?
    /// True once the reader asked to load the chosen message's remote content.
    @Published public private(set) var remoteAllowed = false
    /// One quiet line; cleared by the next read that works.
    @Published public private(set) var lastError: String?
    /// What the list is narrowed to; empty shows every message.
    @Published public private(set) var query = ""
    /// True while `Clear…` is asking whether to delete every message.
    @Published public private(set) var isAskingToClear = false

    /// How many messages the list holds.
    public static let listLimit = 100

    private let client: MailClient
    private let services: @MainActor () -> [ServiceStatus]
    private var watchers = 0
    private var refreshTask: Task<Void, Never>?

    /// `services` answers the daemon's current list of services (empty while it isn't running).
    public init(client: MailClient, services: @escaping @MainActor () -> [ServiceStatus]) {
        self.client = client
        self.services = services
    }

    // MARK: - Derived, for the views

    /// `Mail`, or `Mail (3 unread)`.
    public var menuTitle: String { unread > 0 ? "Mail (\(unread) unread)" : "Mail" }

    /// True when the menu should offer the Mail window: a mail service has been added.
    public var isAdded: Bool { endpoint != .notAdded }

    /// True while there is a mailbox to search and clear.
    public var isRunning: Bool {
        if case .running = endpoint { return true }
        return false
    }

    /// Clear… has something to delete.
    public var canClear: Bool { isRunning && total > 0 }

    /// `Delete all 3 caught messages?`
    public var clearQuestion: String {
        total == 1 ? "Delete the 1 caught message?" : "Delete all \(total) caught messages?"
    }

    /// The search as Mailpit gets it: nil when the field holds nothing but spaces.
    private var search: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What to say in place of the list when it has nothing to show; nil while it has messages.
    public var emptyListText: String? {
        switch endpoint {
        case .notAdded:
            return "Mail isn't added yet. Add it in Settings\u{2026} \u{2192} Services, or run: paddock service add mail"
        case .notRunning:
            return "Mail isn't running. Start it in Settings\u{2026} \u{2192} Services."
        case .running(_, let smtpPort):
            guard messages.isEmpty else { return nil }
            if let search { return "No mail matches \u{201C}\(search)\u{201D}." }
            let port = smtpPort.map { " port \($0)" } ?? ""
            return "No mail yet. Point your app's mailer at 127.0.0.1\(port) and what it sends appears here."
        }
    }

    /// The ways the opened message can be shown: only the parts it has, and always its source.
    public var bodies: [MailBody] {
        guard let opened else { return [] }
        var list: [MailBody] = []
        if !opened.html.isEmpty { list.append(.html) }
        if !opened.text.isEmpty { list.append(.text) }
        list.append(.source)
        return list
    }

    /// The opened message's HTML, ready for the web view; nil when it has none or mail isn't running.
    public var htmlDocument: String? {
        guard let opened, !opened.html.isEmpty, case .running(let base, _) = endpoint else { return nil }
        return MailHTML.document(html: opened.html, messageID: opened.id, parts: opened.inline + opened.attachments,
                                 base: base, allowRemote: remoteAllowed)
    }

    /// True when the opened message's HTML is on show with remote content it wasn't allowed to load.
    public var offersRemoteContent: Bool {
        guard let opened, body == .html, !remoteAllowed else { return false }
        return MailHTML.hasRemoteContent(opened.html)
    }

    // MARK: - Actions

    /// Reads the mail service's state and, while it runs, the inbox.
    public func refresh() async {
        let found = MailEndpoint.find(in: services())
        if found != endpoint { endpoint = found }
        guard case .running(let base, _) = found else {
            clear()
            return
        }
        let asked = search
        do {
            let inbox: MailInbox
            if let asked {
                inbox = try await client.search(at: base, query: asked, limit: Self.listLimit)
            } else {
                inbox = try await client.inbox(at: base, limit: Self.listLimit)
            }
            // An answer for a search the reader has since changed is dropped; the newer one is on its way.
            guard endpoint == found, search == asked else { return }
            if inbox.messages != messages { messages = inbox.messages }
            if inbox.unread != unread { unread = inbox.unread }
            if inbox.total != total { total = inbox.total }
            if let selection, !inbox.messages.contains(where: { $0.id == selection }) { close() }
            lastError = nil
        } catch {
            show(error)
        }
    }

    /// Narrows the list to the messages matching `text`; an empty text shows them all again.
    public func search(for text: String) async {
        guard text != query else { return }
        query = text
        await refresh()
    }

    /// Deletes one message; the one open is closed first.
    public func delete(_ id: String) async {
        guard case .running(let base, _) = endpoint else { return }
        do {
            // Never an empty list here: to the mail service that means every message.
            try await client.delete(at: base, ids: [id])
            if selection == id { close() }
            await refresh()
        } catch {
            show(error, doing: "delete the message")
        }
    }

    /// Marks the open message unread again and closes it, so choosing it again reads it afresh.
    public func markOpenedUnread() async {
        guard let id = opened?.id, case .running(let base, _) = endpoint else { return }
        do {
            try await client.setRead(at: base, ids: [id], read: false)
            close()
            await refresh()
        } catch {
            show(error, doing: "mark the message unread")
        }
    }

    /// `Clear…`: asks first. Nothing is deleted until `confirmClear`.
    public func askToClear() {
        guard canClear else { return }
        isAskingToClear = true
    }

    public func cancelClear() {
        isAskingToClear = false
    }

    /// Deletes every caught message, and only as the answer to the question `askToClear` put.
    public func confirmClear() async {
        guard isAskingToClear, case .running(let base, _) = endpoint else { return }
        isAskingToClear = false
        do {
            try await client.delete(at: base, ids: [])
            close()
            await refresh()
        } catch {
            show(error, doing: "delete the mail")
        }
    }

    /// Chooses a message and loads it, which marks it read; nil closes the one open.
    public func select(_ id: String?) async {
        guard id != selection else { return }
        close()
        guard let id, case .running(let base, _) = endpoint else { return }
        selection = id
        do {
            let message = try await client.message(at: base, id: id)
            guard selection == id else { return }
            opened = message
            body = message.html.isEmpty ? (message.text.isEmpty ? .source : .text) : .html
            if let index = messages.firstIndex(where: { $0.id == id }), !messages[index].read {
                messages[index].read = true
                unread = max(0, unread - 1)
            }
            lastError = nil
            if body == .source { await loadSource() }
        } catch {
            guard selection == id else { return }
            show(error)
        }
    }

    /// Shows the opened message another way; its source is fetched the first time it is asked for.
    public func show(_ body: MailBody) async {
        guard opened != nil, bodies.contains(body) else { return }
        self.body = body
        if body == .source, source == nil { await loadSource() }
    }

    /// Lets the opened message load its remote images, styles and fonts. Scripts still never run.
    public func allowRemoteContent() {
        guard opened != nil else { return }
        remoteAllowed = true
    }

    /// An attachment's bytes, or nil (with the error line set) when they can't be read.
    public func data(for part: MailPart) async -> Data? {
        guard let opened, case .running(let base, _) = endpoint else { return nil }
        do {
            let data = try await client.part(at: base, messageID: opened.id, partID: part.partID)
            lastError = nil
            return data
        } catch {
            show(error)
            return nil
        }
    }

    // MARK: - Watching

    /// Called when the menu or the Mail window appears; the first watcher starts the reading.
    public func beginWatching() {
        watchers += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private

    private func loadSource() async {
        guard let id = opened?.id, case .running(let base, _) = endpoint else { return }
        do {
            let text = try await client.source(at: base, id: id)
            guard opened?.id == id else { return }
            source = text
            lastError = nil
        } catch {
            guard opened?.id == id else { return }
            show(error)
        }
    }

    private func close() {
        selection = nil
        opened = nil
        source = nil
        remoteAllowed = false
        body = .html
    }

    /// Nothing to show while mail isn't running.
    private func clear() {
        if !messages.isEmpty { messages = [] }
        if unread != 0 { unread = 0 }
        if total != 0 { total = 0 }
        if selection != nil { close() }
        if lastError != nil { lastError = nil }
        if isAskingToClear { isAskingToClear = false }
    }

    /// `Paddock couldn't delete the message: Mail didn't answer.`
    private func show(_ error: Error, doing action: String = "read the mail") {
        let sentence = (error as? MailError)?.sentence ?? MailError.unreadable.sentence
        lastError = "Paddock couldn't \(action): " + sentence
    }
}
