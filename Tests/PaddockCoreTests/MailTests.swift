import XCTest
@testable import PaddockCore

/// A mail service stand-in: answers from what it is given and records what it is asked.
private final class FakeMail: MailClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var inboxAnswer: Result<MailInbox, MailError> = .success(MailInbox(total: 0, unread: 0, messages: []))
    var messageAnswers: [String: MailMessage] = [:]
    var sourceAnswer: Result<String, MailError> = .success("Subject: Hello\r\n\r\nBody")
    var partAnswer: Result<Data, MailError> = .success(Data("bytes".utf8))

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    private func record(_ request: String) {
        lock.lock()
        asked.append(request)
        lock.unlock()
    }

    func inbox(at base: URL, limit: Int) async throws -> MailInbox {
        record("inbox \(base.absoluteString) \(limit)")
        return try inboxAnswer.get()
    }

    func message(at base: URL, id: String) async throws -> MailMessage {
        record("message \(id)")
        guard let message = messageAnswers[id] else { throw MailError.badAnswer(status: 404) }
        return message
    }

    func source(at base: URL, id: String) async throws -> String {
        record("source \(id)")
        return try sourceAnswer.get()
    }

    func part(at base: URL, messageID: String, partID: String) async throws -> Data {
        record("part \(messageID) \(partID)")
        return try partAnswer.get()
    }
}

private func mailService(state: ServiceState = .running, http: Int = 8025) -> ServiceStatus {
    ServiceStatus(id: "mail", name: "mail", kind: "mail", version: "1.34.0", displayName: "Mail", state: state,
                  ports: ["smtp": 1025, "http": http], env: [], openURL: "http://127.0.0.1:\(http)",
                  dataPath: "/tmp/mail", autostart: true, mainPort: 1025)
}

private let base = URL(string: "http://127.0.0.1:8025")!

final class MailpitDecodingTests: XCTestCase {
    func testInboxDecodesMailpitsAnswerIncludingNullLists() throws {
        let json = """
        {"total":1,"unread":1,"count":1,"messages_count":1,"messages_unread":1,"start":0,"tags":[],"messages":[
          {"ID":"6sO5","MessageID":"x@mailpit","Read":false,
           "From":{"Name":"Paddock Shop","Address":"orders@shop.test"},
           "To":[{"Name":"Ada Customer","Address":"ada@example.test"},{"Name":"","Address":"ops@shop.test"}],
           "Cc":[{"Name":"","Address":"accounts@shop.test"}],"Bcc":null,"ReplyTo":[],
           "Subject":"Your order #1042 has shipped","Created":"2026-11-22T10:14:10.852+09:00",
           "Username":"","Tags":[],"Size":2216,"Attachments":1,"Snippet":"Your order has shipped"}]}
        """
        let inbox = try JSONDecoder().decode(MailInbox.self, from: Data(json.utf8))
        XCTAssertEqual(inbox.total, 1)
        XCTAssertEqual(inbox.unread, 1)
        let message = try XCTUnwrap(inbox.messages.first)
        XCTAssertEqual(message.id, "6sO5")
        XCTAssertFalse(message.read)
        XCTAssertEqual(message.from, MailAddress(name: "Paddock Shop", address: "orders@shop.test"))
        XCTAssertEqual(message.to.map(\.short), ["Ada Customer", "ops@shop.test"])
        XCTAssertEqual(message.subject, "Your order #1042 has shipped")
        XCTAssertEqual(message.attachments, 1)
        // 2026-11-22 01:14:10.852 UTC.
        XCTAssertEqual(try XCTUnwrap(message.created).timeIntervalSince1970, 1_795_310_050.852, accuracy: 0.001)
    }

    func testMessageDecodesItsPartsAndABsentSender() throws {
        let json = """
        {"ID":"6sO5","From":null,"To":null,"Cc":null,"Bcc":[],"ReplyTo":[],"Subject":"Hi",
         "Date":"2026-11-22T10:14:10+09:00","Text":"Hello","HTML":"<p>Hello</p>","Size":10,
         "Inline":[{"PartID":"1.2.2","FileName":"logo","ContentType":"image/png","ContentID":"logo@shop.test","Size":70}],
         "Attachments":[{"PartID":"2","FileName":"invoice-1042.csv","ContentType":"text/csv","ContentID":"","Size":23}]}
        """
        let message = try JSONDecoder().decode(MailMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.from)
        XCTAssertEqual(message.to, [])
        XCTAssertEqual(message.text, "Hello")
        XCTAssertEqual(message.inline, [MailPart(partID: "1.2.2", fileName: "logo", contentType: "image/png",
                                                 contentID: "logo@shop.test", size: 70)])
        XCTAssertEqual(message.attachments.map(\.fileName), ["invoice-1042.csv"])
        XCTAssertNotNil(message.date)
    }

    func testAnAddressShowsItsNameOrItsAddress() {
        XCTAssertEqual(MailAddress(name: "Ada", address: "ada@example.test").full, "Ada <ada@example.test>")
        XCTAssertEqual(MailAddress(address: "ops@shop.test").full, "ops@shop.test")
        XCTAssertEqual(MailAddress(address: "ops@shop.test").short, "ops@shop.test")
    }
}

final class MailHTMLTests: XCTestCase {
    private let logo = MailPart(partID: "1.2.2", fileName: "logo", contentType: "image/png",
                                contentID: "logo@shop.test")

    func testInlineImagesPointAtTheMailService() {
        let html = MailHTML.document(html: #"<img src="cid:logo@shop.test"><img src="CID:logo@shop.test">"#,
                                     messageID: "6sO5", parts: [logo], base: base, allowRemote: false)
        XCTAssertFalse(html.lowercased().contains("cid:"))
        XCTAssertEqual(html.components(separatedBy: "http://127.0.0.1:8025/api/v1/message/6sO5/part/1.2.2").count, 3)
    }

    func testThePolicyComesFirstAndBlocksTheNetworkUntilAllowed() {
        let blocked = MailHTML.document(html: "<html><head><title>x</title></head><body>Hi</body></html>",
                                        messageID: "1", parts: [], base: base, allowRemote: false)
        XCTAssertTrue(blocked.hasPrefix("<head><meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(blocked.contains("default-src 'none'"))
        XCTAssertTrue(blocked.contains("img-src http://127.0.0.1:8025 data:;"))
        XCTAssertFalse(blocked.contains("img-src *"))

        let allowed = MailHTML.document(html: "<p>Hi</p>", messageID: "1", parts: [], base: base, allowRemote: true)
        XCTAssertTrue(allowed.contains("img-src * data:"))
        // Scripts stay off either way: nothing in either policy lets one run.
        XCTAssertFalse(allowed.contains("script-src"))
        XCTAssertTrue(allowed.contains("default-src 'none'"))
    }

    func testThePolicyGoesAfterADoctypeSoThePageKeepsItsMode() {
        let html = MailHTML.document(html: "\n<!DOCTYPE html><html><body>Hi</body></html>", messageID: "1",
                                     parts: [], base: base, allowRemote: false)
        XCTAssertTrue(html.hasPrefix("\n<!DOCTYPE html><head><meta http-equiv=\"Content-Security-Policy\""))
    }

    func testRemoteContentIsNoticed() {
        XCTAssertTrue(MailHTML.hasRemoteContent(#"<img src="https://example.com/track.gif">"#))
        XCTAssertTrue(MailHTML.hasRemoteContent("<img src=//example.com/a.png>"))
        XCTAssertTrue(MailHTML.hasRemoteContent("<div style=\"background:url('http://example.com/a.png')\">"))
        XCTAssertTrue(MailHTML.hasRemoteContent(#"<link rel="stylesheet" href="https://example.com/a.css">"#))
        XCTAssertFalse(MailHTML.hasRemoteContent(#"<img src="cid:logo@shop.test"><a href="https://shop.test">x</a>"#))
        XCTAssertFalse(MailHTML.hasRemoteContent(#"<img src="data:image/png;base64,AAAA">"#))
    }
}

final class MailEndpointTests: XCTestCase {
    func testTheEndpointFollowsTheMailServicesState() {
        XCTAssertEqual(MailEndpoint.find(in: []), .notAdded)
        XCTAssertEqual(MailEndpoint.find(in: [mailService(state: .stopped)]), .notRunning)
        XCTAssertEqual(MailEndpoint.find(in: [mailService(state: .portInUse(holder: "Herd"))]), .notRunning)
        XCTAssertEqual(MailEndpoint.find(in: [mailService(http: 8026)]),
                       .running(base: URL(string: "http://127.0.0.1:8026")!, smtpPort: 1025))
    }
}

@MainActor
final class MailModelTests: XCTestCase {
    private let unreadMail = MailSummary(id: "a", read: false, from: MailAddress(address: "orders@shop.test"),
                                         subject: "Shipped")
    private let readMail = MailSummary(id: "b", read: true, from: MailAddress(address: "ops@shop.test"),
                                       subject: "Report")

    private func model(_ mail: FakeMail, services: [ServiceStatus] = [mailService()]) -> MailModel {
        MailModel(client: mail, services: { services })
    }

    func testRefreshReadsTheInboxWhileMailRuns() async {
        let mail = FakeMail()
        mail.inboxAnswer = .success(MailInbox(total: 2, unread: 1, messages: [unreadMail, readMail]))
        let model = model(mail)
        await model.refresh()
        XCTAssertEqual(model.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(model.unread, 1)
        XCTAssertEqual(model.menuTitle, "Mail (1 unread)")
        XCTAssertNil(model.emptyListText)
        XCTAssertEqual(mail.requests, ["inbox http://127.0.0.1:8025 100"])
    }

    func testNothingIsAskedWhileMailIsNotAddedOrNotRunning() async {
        let mail = FakeMail()
        let none = model(mail, services: [])
        await none.refresh()
        XCTAssertFalse(none.isAdded)
        XCTAssertEqual(none.emptyListText?.hasPrefix("Mail isn't added yet."), true)

        let stopped = model(mail, services: [mailService(state: .stopped)])
        await stopped.refresh()
        XCTAssertTrue(stopped.isAdded)
        XCTAssertEqual(stopped.emptyListText, "Mail isn't running. Start it in Settings\u{2026} \u{2192} Services.")
        XCTAssertEqual(mail.requests, [])
    }

    func testAnEmptyInboxSaysWhereToSendMail() async {
        let model = model(FakeMail())
        await model.refresh()
        XCTAssertEqual(model.emptyListText,
                       "No mail yet. Point your app's mailer at 127.0.0.1 port 1025 and what it sends appears here.")
        XCTAssertEqual(model.menuTitle, "Mail")
    }

    func testSelectingAMessageOpensItAndCountsItRead() async {
        let mail = FakeMail()
        mail.inboxAnswer = .success(MailInbox(total: 2, unread: 1, messages: [unreadMail, readMail]))
        mail.messageAnswers["a"] = MailMessage(id: "a", from: unreadMail.from, subject: "Shipped", text: "Hello",
                                               html: #"<img src="https://example.com/t.gif">"#)
        let model = model(mail)
        await model.refresh()
        await model.select("a")
        XCTAssertEqual(model.opened?.id, "a")
        XCTAssertEqual(model.body, .html)
        XCTAssertEqual(model.bodies, [.html, .text, .source])
        XCTAssertEqual(model.unread, 0)
        XCTAssertEqual(model.messages.first?.read, true)
        XCTAssertTrue(model.offersRemoteContent)
        XCTAssertEqual(model.htmlDocument?.contains("img-src http://127.0.0.1:8025 data:;"), true)

        model.allowRemoteContent()
        XCTAssertFalse(model.offersRemoteContent)
        XCTAssertEqual(model.htmlDocument?.contains("img-src * data:"), true)
    }

    func testAnotherMessageStartsWithRemoteContentBlockedAgain() async {
        let mail = FakeMail()
        mail.inboxAnswer = .success(MailInbox(total: 2, unread: 0, messages: [readMail, unreadMail]))
        mail.messageAnswers["a"] = MailMessage(id: "a", from: nil, subject: "A", html: "<p>A</p>")
        mail.messageAnswers["b"] = MailMessage(id: "b", from: nil, subject: "B", text: "Plain only")
        let model = model(mail)
        await model.refresh()
        await model.select("a")
        model.allowRemoteContent()
        await model.select("b")
        XCTAssertFalse(model.remoteAllowed)
        XCTAssertEqual(model.body, .text)
        XCTAssertEqual(model.bodies, [.text, .source])
        XCTAssertNil(model.htmlDocument)
    }

    func testTheSourceIsFetchedOnceWhenAskedFor() async {
        let mail = FakeMail()
        mail.inboxAnswer = .success(MailInbox(total: 1, unread: 0, messages: [readMail]))
        mail.messageAnswers["b"] = MailMessage(id: "b", from: nil, subject: "B", text: "Plain")
        let model = model(mail)
        await model.refresh()
        await model.select("b")
        XCTAssertNil(model.source)
        await model.show(.source)
        await model.show(.text)
        await model.show(.source)
        XCTAssertEqual(model.source, "Subject: Hello\r\n\r\nBody")
        XCTAssertEqual(mail.requests.filter { $0 == "source b" }.count, 1)
        // A message has no HTML part to show.
        await model.show(.html)
        XCTAssertEqual(model.body, .source)
    }

    func testAFailedReadSaysSoAndTheNextGoodOneClearsIt() async {
        let mail = FakeMail()
        mail.inboxAnswer = .failure(.unreachable)
        let model = model(mail)
        await model.refresh()
        XCTAssertEqual(model.lastError, "Paddock couldn't read the mail: Mail didn't answer.")
        mail.inboxAnswer = .success(MailInbox(total: 0, unread: 0, messages: []))
        await model.refresh()
        XCTAssertNil(model.lastError)
    }

    func testAMessageThatLeftTheInboxIsClosed() async {
        let mail = FakeMail()
        mail.inboxAnswer = .success(MailInbox(total: 1, unread: 0, messages: [readMail]))
        mail.messageAnswers["b"] = MailMessage(id: "b", from: nil, subject: "B", text: "Plain")
        let model = model(mail)
        await model.refresh()
        await model.select("b")
        mail.inboxAnswer = .success(MailInbox(total: 0, unread: 0, messages: []))
        await model.refresh()
        XCTAssertNil(model.selection)
        XCTAssertNil(model.opened)
    }

    func testAnAttachmentsBytesComeFromTheOpenedMessage() async {
        let mail = FakeMail()
        let invoice = MailPart(partID: "2", fileName: "invoice.csv")
        mail.inboxAnswer = .success(MailInbox(total: 1, unread: 0, messages: [readMail]))
        mail.messageAnswers["b"] = MailMessage(id: "b", from: nil, subject: "B", text: "Plain", attachments: [invoice])
        let model = model(mail)
        await model.refresh()
        await model.select("b")
        let data = await model.data(for: invoice)
        XCTAssertEqual(data, Data("bytes".utf8))
        XCTAssertTrue(mail.requests.contains("part b 2"))

        mail.partAnswer = .failure(.badAnswer(status: 404))
        let missing = await model.data(for: invoice)
        XCTAssertNil(missing)
        XCTAssertEqual(model.lastError, "Paddock couldn't read the mail: Mail answered with an error (404).")
    }
}
