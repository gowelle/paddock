import Foundation

/// A name and address as Mailpit gives them: `{"Name": "Ada", "Address": "ada@example.test"}`.
public struct MailAddress: Codable, Equatable, Sendable {
    public let name: String
    public let address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name", address = "Address"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
    }

    /// The name when there is one, else the address: what a list row shows.
    public var short: String { name.isEmpty ? address : name }
    /// `Ada <ada@example.test>`, or the bare address.
    public var full: String { name.isEmpty ? address : "\(name) <\(address)>" }
}

/// One row of the inbox.
public struct MailSummary: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public var read: Bool
    public let from: MailAddress?
    public let to: [MailAddress]
    public let subject: String
    public let created: Date?
    /// How many attachments it carries.
    public let attachments: Int
    public let snippet: String

    public init(id: String, read: Bool, from: MailAddress?, to: [MailAddress] = [], subject: String,
                created: Date? = nil, attachments: Int = 0, snippet: String = "") {
        self.id = id
        self.read = read
        self.from = from
        self.to = to
        self.subject = subject
        self.created = created
        self.attachments = attachments
        self.snippet = snippet
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", read = "Read", from = "From", to = "To", subject = "Subject", created = "Created",
             attachments = "Attachments", snippet = "Snippet"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        from = try c.decodeIfPresent(MailAddress.self, forKey: .from)
        to = try c.decodeIfPresent([MailAddress].self, forKey: .to) ?? []
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        created = try c.decodeIfPresent(String.self, forKey: .created).flatMap(MailDate.parse)
        attachments = try c.decodeIfPresent(Int.self, forKey: .attachments) ?? 0
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
    }
}

/// The newest messages and the counts, from `GET /api/v1/messages`.
public struct MailInbox: Decodable, Equatable, Sendable {
    /// Every message the mail service holds, and how many of them are unread: the whole mailbox, also when
    /// `messages` is a search's matches.
    public let total: Int
    public let unread: Int
    public let messages: [MailSummary]

    public init(total: Int, unread: Int, messages: [MailSummary]) {
        self.total = total
        self.unread = unread
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case total, unread, messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        messages = try c.decodeIfPresent([MailSummary].self, forKey: .messages) ?? []
    }
}

/// An attachment or an inline part (an image the HTML shows by `cid:`).
public struct MailPart: Decodable, Equatable, Identifiable, Sendable {
    public let partID: String
    public let fileName: String
    public let contentType: String
    /// What a `cid:` reference in the HTML names; empty for a plain attachment.
    public let contentID: String
    public let size: Int

    public var id: String { partID }

    public init(partID: String, fileName: String, contentType: String = "application/octet-stream",
                contentID: String = "", size: Int = 0) {
        self.partID = partID
        self.fileName = fileName
        self.contentType = contentType
        self.contentID = contentID
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case partID = "PartID", fileName = "FileName", contentType = "ContentType", contentID = "ContentID",
             size = "Size"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partID = try c.decode(String.self, forKey: .partID)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        contentID = try c.decodeIfPresent(String.self, forKey: .contentID) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}

/// One whole message, from `GET /api/v1/message/<id>` (asking for it marks it read in Mailpit).
public struct MailMessage: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let from: MailAddress?
    public let to, cc, bcc, replyTo: [MailAddress]
    public let subject: String
    public let date: Date?
    public let text: String
    public let html: String
    public let attachments: [MailPart]
    public let inline: [MailPart]

    public init(id: String, from: MailAddress?, to: [MailAddress] = [], cc: [MailAddress] = [],
                bcc: [MailAddress] = [], replyTo: [MailAddress] = [], subject: String, date: Date? = nil,
                text: String = "", html: String = "", attachments: [MailPart] = [], inline: [MailPart] = []) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.date = date
        self.text = text
        self.html = html
        self.attachments = attachments
        self.inline = inline
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", from = "From", to = "To", cc = "Cc", bcc = "Bcc", replyTo = "ReplyTo", subject = "Subject",
             date = "Date", text = "Text", html = "HTML", attachments = "Attachments", inline = "Inline"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func addresses(_ key: CodingKeys) throws -> [MailAddress] {
            try c.decodeIfPresent([MailAddress].self, forKey: key) ?? []
        }
        id = try c.decode(String.self, forKey: .id)
        from = try c.decodeIfPresent(MailAddress.self, forKey: .from)
        to = try addresses(.to)
        cc = try addresses(.cc)
        bcc = try addresses(.bcc)
        replyTo = try addresses(.replyTo)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date).flatMap(MailDate.parse)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        html = try c.decodeIfPresent(String.self, forKey: .html) ?? ""
        attachments = try c.decodeIfPresent([MailPart].self, forKey: .attachments) ?? []
        inline = try c.decodeIfPresent([MailPart].self, forKey: .inline) ?? []
    }
}

/// Mailpit's times: `2026-11-22T10:14:10.852+09:00`, with or without the fraction.
enum MailDate {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public enum MailError: Error, Equatable, Sendable {
    /// Nothing answered at the mail service's address.
    case unreachable
    /// It answered with an HTTP error.
    case badAnswer(status: Int)
    /// It answered with something that isn't what Mailpit sends.
    case unreadable

    /// One plain sentence for the window's error line.
    public var sentence: String {
        switch self {
        case .unreachable: return "Mail didn't answer."
        case .badAnswer(let status): return "Mail answered with an error (\(status))."
        case .unreadable: return "Mail gave an unexpected answer."
        }
    }
}

/// Reads caught mail from the mail service. `HTTPMailClient` in the app, a fake in tests.
public protocol MailClient: Sendable {
    func inbox(at base: URL, limit: Int) async throws -> MailInbox
    /// The messages matching `query` (Mailpit's search: words from the sender, recipients, subject and body),
    /// with the whole mailbox's counts.
    func search(at base: URL, query: String, limit: Int) async throws -> MailInbox
    /// Deletes the messages named; **an empty list deletes every message**.
    func delete(at base: URL, ids: [String]) async throws
    func setRead(at base: URL, ids: [String], read: Bool) async throws
    func message(at base: URL, id: String) async throws -> MailMessage
    /// The message exactly as it arrived, headers included.
    func source(at base: URL, id: String) async throws -> String
    func part(at base: URL, messageID: String, partID: String) async throws -> Data
}

/// The reading part of the mail service, and no more of it: what `paddock mcp` is given, so nothing it does can
/// delete a message or mark one. (Asking for a whole message still marks it read in Mailpit, as opening it does.)
public protocol MailReading: Sendable {
    func inbox(at base: URL, limit: Int) async throws -> MailInbox
    func search(at base: URL, query: String, limit: Int) async throws -> MailInbox
    func message(at base: URL, id: String) async throws -> MailMessage
}

extension HTTPMailClient: MailReading {}

/// Mailpit's HTTP API on loopback.
public struct HTTPMailClient: MailClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func inbox(at base: URL, limit: Int) async throws -> MailInbox {
        var components = URLComponents(url: MailRoutes.messages(base), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw MailError.unreadable }
        return try decode(MailInbox.self, from: try await get(url))
    }

    public func search(at base: URL, query: String, limit: Int) async throws -> MailInbox {
        var components = URLComponents(url: MailRoutes.search(base), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query),
                                  URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw MailError.unreadable }
        return try decode(MailInbox.self, from: try await get(url))
    }

    public func delete(at base: URL, ids: [String]) async throws {
        _ = try await send("DELETE", MailRoutes.messages(base), body: MailChange(ids: ids, read: nil))
    }

    public func setRead(at base: URL, ids: [String], read: Bool) async throws {
        _ = try await send("PUT", MailRoutes.messages(base), body: MailChange(ids: ids, read: read))
    }

    public func message(at base: URL, id: String) async throws -> MailMessage {
        try decode(MailMessage.self, from: try await get(MailRoutes.message(base, id: id)))
    }

    public func source(at base: URL, id: String) async throws -> String {
        let data = try await get(MailRoutes.message(base, id: id).appendingPathComponent("raw"))
        return String(decoding: data, as: UTF8.self)
    }

    public func part(at base: URL, messageID: String, partID: String) async throws -> Data {
        try await get(MailRoutes.part(base, messageID: messageID, partID: partID))
    }

    private func get(_ url: URL) async throws -> Data {
        try await perform(URLRequest(url: url))
    }

    private func send(_ method: String, _ url: URL, body: MailChange) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MailError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw MailError.unreadable }
        guard (200..<300).contains(http.statusCode) else { throw MailError.badAnswer(status: http.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MailError.unreadable
        }
    }
}

/// The body of a delete or a mark-read request: `{"IDs": ["…"], "Read": false}`.
struct MailChange: Encodable, Equatable {
    let ids: [String]
    let read: Bool?

    enum CodingKeys: String, CodingKey {
        case ids = "IDs", read = "Read"
    }
}

/// Where Mailpit answers what, under the mail service's address.
public enum MailRoutes {
    static func messages(_ base: URL) -> URL {
        base.appendingPathComponent("api/v1/messages")
    }

    static func search(_ base: URL) -> URL {
        base.appendingPathComponent("api/v1/search")
    }

    static func message(_ base: URL, id: String) -> URL {
        base.appendingPathComponent("api/v1/message").appendingPathComponent(id)
    }

    /// One attachment or inline part's bytes.
    public static func part(_ base: URL, messageID: String, partID: String) -> URL {
        message(base, id: messageID).appendingPathComponent("part").appendingPathComponent(partID)
    }
}

/// Makes a caught message's HTML safe to show: inline images point at the mail service, and a content
/// policy keeps everything else on the network out unless the reader asks for it. Scripts never run.
public enum MailHTML {
    /// True when the HTML asks for an image, stylesheet or font from somewhere on the network.
    public static func hasRemoteContent(_ html: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:src|srcset|background|poster)\s*=\s*["']?\s*(?:https?:)?//"#,
            #"(?i)url\(\s*["']?\s*(?:https?:)?//"#,
            #"(?i)<link\b[^>]*\bhref\s*=\s*["']?\s*(?:https?:)?//"#,
            #"(?i)@import\s+["']?\s*(?:https?:)?//"#,
        ]
        return patterns.contains { html.range(of: $0, options: .regularExpression) != nil }
    }

    /// The HTML to hand the web view: `cid:` references rewritten to the mail service's own part addresses,
    /// and a content policy put first in the document. With `allowRemote` false, only the mail service and
    /// `data:` may supply images; with it true, images, media, styles and fonts may come from anywhere.
    /// Either way no script runs, nothing is framed and no form is sent.
    public static func document(html: String, messageID: String, parts: [MailPart], base: URL,
                                allowRemote: Bool) -> String {
        var body = html
        for part in parts where !part.contentID.isEmpty {
            let address = MailRoutes.part(base, messageID: messageID, partID: part.partID).absoluteString
            body = body.replacingOccurrences(of: "cid:" + part.contentID, with: address, options: .caseInsensitive)
        }
        let head = "<head><meta http-equiv=\"Content-Security-Policy\" content=\""
            + policy(base: base, allowRemote: allowRemote) + "\"></head>"
        // After the doctype when there is one (so the page keeps its rendering mode), else first of all: the
        // parser then opens the document's head with the policy already in it.
        if let doctype = body.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            body.insert(contentsOf: head, at: doctype.upperBound)
            return body
        }
        return head + body
    }

    static func policy(base: URL, allowRemote: Bool) -> String {
        let common = "default-src 'none'; form-action 'none'; frame-src 'none'; "
        if allowRemote {
            return common + "img-src * data:; media-src *; style-src 'unsafe-inline' *; font-src * data:"
        }
        return common + "img-src \(origin(of: base)) data:; style-src 'unsafe-inline'; font-src data:"
    }

    private static func origin(of base: URL) -> String {
        var text = (base.scheme ?? "http") + "://" + (base.host ?? "127.0.0.1")
        if let port = base.port { text += ":\(port)" }
        return text
    }
}
