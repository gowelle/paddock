import Darwin
import XCTest
@testable import PaddockCore

/// The real Mail service (Mailpit, from the bundled catalog; the download is cached in Vendor/services/) on
/// free high ports: a message sent with Paddock's PHP over raw SMTP is read back from Mailpit's API, survives
/// a stop and start, and Mailpit listens on 127.0.0.1 only.
final class MailServiceTests: XCTestCase {
    private var home: ServiceHome!
    private var manager: ServiceManager?

    override func setUpWithError() throws {
        home = try ServiceHome()
    }

    override func tearDown() {
        manager?.stopAll()
        manager = nil
        home?.cleanUp()
    }

    private var php: URL { TestSupport.repoVendor.appendingPathComponent("php/8.5/default/php") }

    func testMailCatchesAMessageSentOverSMTPAndKeepsIt() async throws {
        guard FileManager.default.isExecutableFile(atPath: php.path) else {
            throw XCTSkip("Vendored PHP missing; run Scripts/fetch-vendor.sh")
        }
        let bundled = try XCTUnwrap(try ServiceCatalog.bundled().recipe(kind: "mail", version: nil))
        let recipe = try await ServiceDownloadCache.localRecipe(bundled)
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: [recipe]),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        self.manager = manager

        let instance = try await manager.add(kind: "mail", version: nil)
        XCTAssertEqual(instance.id, "mail")
        XCTAssertEqual(instance.name, "Mail")
        let smtp = try XCTUnwrap(instance.ports["smtp"])
        let http = try XCTUnwrap(instance.ports["http"])
        XCTAssertGreaterThanOrEqual(smtp, home.portBase + 1025, "never the conventional 1025")
        XCTAssertGreaterThanOrEqual(http, home.portBase + 8025, "never the conventional 8025")
        let status = try XCTUnwrap(manager.statuses().first)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.mainPort, smtp)
        XCTAssertEqual(status.env, ["MAIL_MAILER=smtp", "MAIL_HOST=127.0.0.1", "MAIL_PORT=\(smtp)",
                                    "MAIL_USERNAME=null", "MAIL_PASSWORD=null", "MAIL_ENCRYPTION=null"])
        XCTAssertEqual(status.openURL, "http://127.0.0.1:\(http)")

        // Only loopback listeners, and only the two ports.
        let pid = try XCTUnwrap(manager.processes["service-mail"].flatMap(TestSupport.pid(from:)))
        XCTAssertEqual(Set(try assertListensOnThisMacOnly(processGroup: pid)), ["127.0.0.1:\(smtp)", "127.0.0.1:\(http)"])

        try sendMail(port: smtp, subject: "Hello from Paddock")
        XCTAssertTrue(waitFor(10) { (try? self.subjects(port: http)) == ["Hello from Paddock"] },
                      "\(String(describing: try? subjects(port: http)))")

        manager.stop("mail")
        XCTAssertFalse(PortCheck.acceptsIPv4(port: smtp))
        try manager.start("mail")
        XCTAssertEqual(try subjects(port: http), ["Hello from Paddock"], "the message is kept across a restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.serviceData("mail")
            .appendingPathComponent("mailpit.db").path), "its database is in the instance's data folder")
    }

    /// A raw SMTP conversation from Paddock's PHP over fsockopen (PHP's mail() would need sendmail).
    private func sendMail(port: Int, subject: String) throws {
        let script = home.root.appendingPathComponent("smtp.php")
        try Data(#"""
        <?php
        $fp = fsockopen('127.0.0.1', (int)$argv[1], $errno, $errstr, 5);
        if (!$fp) { fwrite(STDERR, "connect: $errstr\n"); exit(1); }
        stream_set_timeout($fp, 5);
        function expect($fp, $code) {
            do {
                $line = fgets($fp, 1024);
                if ($line === false) { fwrite(STDERR, "no answer, expected $code\n"); exit(2); }
            } while (isset($line[3]) && $line[3] === '-');
            if (substr($line, 0, 3) !== $code) { fwrite(STDERR, "expected $code, got $line"); exit(3); }
        }
        function say($fp, $text, $code) { fwrite($fp, $text . "\r\n"); expect($fp, $code); }
        expect($fp, '220');
        say($fp, 'EHLO paddock.test', '250');
        say($fp, 'MAIL FROM:<app@paddock.test>', '250');
        say($fp, 'RCPT TO:<you@paddock.test>', '250');
        say($fp, 'DATA', '354');
        fwrite($fp, "From: app@paddock.test\r\nTo: you@paddock.test\r\nSubject: {$argv[2]}\r\n\r\nIt works.\r\n.\r\n");
        expect($fp, '250');
        say($fp, 'QUIT', '221');
        echo "sent\n";
        """#.utf8).write(to: script)
        let process = Process()
        process.executableURL = php
        process.arguments = ["-n", script.path, "\(port)", subject]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertEqual(text, "sent\n")
    }

    /// The subjects of the messages Mailpit holds, from its API.
    private func subjects(port: Int) throws -> [String] {
        let url = URL(string: "http://127.0.0.1:\(port)/api/v1/messages")!
        let data = try Data(contentsOf: url)
        struct List: Decodable {
            struct Message: Decodable { let Subject: String }
            let messages: [Message]
        }
        return try JSONDecoder().decode(List.self, from: data).messages.map(\.Subject)
    }
}
