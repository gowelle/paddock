import XCTest
@testable import PaddockCore

final class ServiceTemplateTests: XCTestCase {
    private let context = ServiceTemplateContext(
        bin: "/h/services/bin/sample/1", data: "/h/services/sample/data", config: "/h/services/sample/config",
        run: "/h/run/svc/sample", log: "/h/log/service-sample.log", name: "Sample", id: "sample",
        ports: ["main": 4001, "http": 4002], socket: "/h/run/svc/sample/s.sock", php: "/h/bin/php-versions/8.5/default/php",
        resources: "/Applications/Paddock.app/Contents/Resources")

    func testEveryPlaceholder() throws {
        let cases: [(String, String)] = [
            ("{bin}/x", "/h/services/bin/sample/1/x"),
            ("{data}", "/h/services/sample/data"),
            ("{config}/a.conf", "/h/services/sample/config/a.conf"),
            ("{run}", "/h/run/svc/sample"),
            ("{log}", "/h/log/service-sample.log"),
            ("{name}", "Sample"),
            ("{id}", "sample"),
            ("127.0.0.1:{port.main}", "127.0.0.1:4001"),
            ("{port.http}", "4002"),
            ("{socket}", "/h/run/svc/sample/s.sock"),
            ("{php}", "/h/bin/php-versions/8.5/default/php"),
            ("{resources}/x", "/Applications/Paddock.app/Contents/Resources/x"),
            ("{id}-{port.main}-{id}", "sample-4001-sample"),
            ("no placeholders", "no placeholders"),
            // Not placeholders: shell-style variables, JSON, wildcards, a lone brace.
            ("${APP_NAME}", "${APP_NAME}"),
            ("{\"a\": 1}", "{\"a\": 1}"),
            ("{ }", "{ }"),
            ("a{b", "a{b"),
        ]
        for (template, expected) in cases {
            XCTAssertEqual(try ServiceTemplate.render(template, context: context), expected, template)
        }
    }

    func testUnknownPlaceholderThrows() {
        XCTAssertThrowsError(try ServiceTemplate.render("{nope}", context: context)) {
            XCTAssertEqual($0 as? TemplateError, .unknown("nope"))
        }
        XCTAssertThrowsError(try ServiceTemplate.render("{port.smtp}", context: context)) {
            XCTAssertEqual($0 as? TemplateError, .unknown("port.smtp"))
        }
    }

    func testMissingSocketRendersEmptyAndMissingPHPThrows() throws {
        var bare = context
        bare.socket = nil
        bare.php = nil
        XCTAssertEqual(try ServiceTemplate.render("[{socket}]", context: bare), "[]")
        XCTAssertThrowsError(try ServiceTemplate.render("{php}", context: bare)) {
            XCTAssertEqual($0 as? TemplateError, .unavailable("php"))
        }
    }

    func testValuesWithSpacesStaySingleArguments() throws {
        var spaced = context
        spaced.data = "/Users/me/Library/Application Support/Paddock/services/sample/data"
        let command = RecipeCommand(executable: "{bin}/sample", arguments: ["--data", "{data}", "--name={name} x"],
                                    environment: ["DIR": "{data}"], stdin: "path {data}\n")
        let rendered = try ServiceTemplate.render(command, context: spaced)
        XCTAssertEqual(rendered.executable, "/h/services/bin/sample/1/sample")
        XCTAssertEqual(rendered.arguments, ["--data", spaced.data, "--name=Sample x"])
        XCTAssertEqual(rendered.environment, ["DIR": spaced.data])
        XCTAssertEqual(rendered.stdin, "path \(spaced.data)\n")
    }

    /// `{"ifSocket": [...]}` arguments are kept only when the instance has a usable socket.
    func testSocketArgumentsAreDroppedWithoutASocket() throws {
        let command = RecipeCommand(executable: "{bin}/s",
                                    arguments: ["--port", "{port.main}", .ifSocket(["--socket", "{socket}"]), "end"])
        XCTAssertEqual(try ServiceTemplate.render(command, context: context).arguments,
                       ["--port", "4001", "--socket", "/h/run/svc/sample/s.sock", "end"])
        var bare = context
        bare.socket = nil
        XCTAssertEqual(try ServiceTemplate.render(command, context: bare).arguments, ["--port", "4001", "end"])
    }

    /// `{socketDir}` is the run folder while the socket is usable (PostgreSQL takes a folder), and nothing
    /// otherwise (`unix_socket_directories=` then makes no socket at all).
    func testSocketDirIsTheRunFolderOnlyWithAUsableSocket() throws {
        XCTAssertEqual(try ServiceTemplate.render("unix_socket_directories={socketDir}", context: context),
                       "unix_socket_directories=/h/run/svc/sample")
        var bare = context
        bare.socket = nil
        XCTAssertEqual(try ServiceTemplate.render("unix_socket_directories={socketDir}", context: bare),
                       "unix_socket_directories=")
        XCTAssertEqual(try ServiceTemplate.render("{run}/.s.PGSQL.{port.main}", context: context), "/h/run/svc/sample/.s.PGSQL.4001")
    }

    /// A config file's lines that use `{socket}` or `{socketDir}` are left out when the instance has no
    /// usable socket, as `.env` lines are: a server is never handed an empty socket setting.
    func testConfigFileLinesNamingTheSocketAreDroppedWithoutASocket() throws {
        let file = "port {port.main}\nunixsocket \"{socket}\"\nsocket_dir={socketDir}\nunixsocketperm 700\n"
        XCTAssertEqual(try ServiceTemplate.renderFile(file, context: context),
                       "port 4001\nunixsocket \"/h/run/svc/sample/s.sock\"\nsocket_dir=/h/run/svc/sample\nunixsocketperm 700\n")
        var bare = context
        bare.socket = nil
        XCTAssertEqual(try ServiceTemplate.renderFile(file, context: bare), "port 4001\nunixsocketperm 700\n")
        XCTAssertEqual(try ServiceTemplate.renderFile("{socket}", context: bare), "")
        XCTAssertEqual(try ServiceTemplate.renderFile("a\r\nb {socket}\r\nc", context: bare), "a\r\nc")
    }

    /// `{secret.<name>}` is the instance's saved secret; one it doesn't have yet is unavailable.
    func testSecretsRenderFromTheContext() throws {
        var keyed = context
        keyed.secrets = ["master_key": "abc_DEF-123"]
        XCTAssertEqual(try ServiceTemplate.render("MEILI_MASTER_KEY={secret.master_key}", context: keyed),
                       "MEILI_MASTER_KEY=abc_DEF-123")
        XCTAssertThrowsError(try ServiceTemplate.render("{secret.master_key}", context: context)) {
            XCTAssertEqual($0 as? TemplateError, .unavailable("secret.master_key"))
        }
    }

    /// An action's parameters render only where they are bound; anywhere else they are unknown.
    func testParametersRenderOnlyWhenBound() throws {
        XCTAssertThrowsError(try ServiceTemplate.render("{database}", context: context)) {
            XCTAssertEqual($0 as? TemplateError, .unknown("database"))
        }
        var bound = context
        bound.parameters = ["database": "shop_1"]
        XCTAssertEqual(try ServiceTemplate.render("-U root {database}", context: bound), "-U root shop_1")
        // A bound value is inserted as it is, never rendered again.
        bound.parameters = ["database": "{data}"]
        XCTAssertEqual(try ServiceTemplate.render("{database}", context: bound), "{data}")
    }
}
