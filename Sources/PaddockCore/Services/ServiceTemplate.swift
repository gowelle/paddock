import Foundation

/// The values a recipe's templates are rendered with, for one instance.
public struct ServiceTemplateContext: Equatable, Sendable {
    /// The recipe's unpacked binaries, `services/bin/<kind>/<version>`.
    public var bin: String
    public var data: String
    public var config: String
    public var run: String
    public var log: String
    public var name: String
    public var id: String
    /// Port name -> the instance's port.
    public var ports: [String: Int]
    /// The instance's Unix socket; nil (rendered as nothing) when it has none or its path is too long.
    public var socket: String?
    /// Paddock's default PHP binary; nil when none is installed.
    public var php: String?
    public var resources: String
    /// An action's bound parameters (`database` -> `shop`); empty everywhere else.
    public var parameters: [String: String] = [:]

    public init(bin: String, data: String, config: String, run: String, log: String, name: String, id: String,
                ports: [String: Int], socket: String?, php: String?, resources: String) {
        self.bin = bin
        self.data = data
        self.config = config
        self.run = run
        self.log = log
        self.name = name
        self.id = id
        self.ports = ports
        self.socket = socket
        self.php = php
        self.resources = resources
    }
}

public enum TemplateError: Error, Equatable {
    /// `{name}` is not a placeholder Paddock knows (or a port the recipe doesn't have).
    case unknown(String)
    /// The placeholder is known but has no value here (`{php}` with no PHP installed).
    case unavailable(String)
}

/// Renders recipe templates: `{bin}`, `{data}`, `{config}`, `{run}`, `{log}`, `{name}`, `{id}`,
/// `{port.<name>}`, `{socket}`, `{socketDir}`, `{php}`, `{resources}`, and in an action its bound parameters
/// (`{database}`). Only `{` + a name starting with a lowercase letter + `}` is a placeholder; any other brace
/// (`${APP_NAME}`, JSON) is plain text. A bound value is inserted as it is, never rendered again.
public enum ServiceTemplate {
    public static func render(_ template: String, context: ServiceTemplateContext) throws -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}"),
                  isPlaceholderName(rest[afterOpen..<close]) else {
                output.append("{")
                rest = rest[afterOpen...]
                continue
            }
            output += try value(of: String(rest[afterOpen..<close]), context: context)
            rest = rest[rest.index(after: close)...]
        }
        return output + rest
    }

    /// Renders every part of a command; each argument stays a single argument whatever it contains, and
    /// `ifSocket` arguments are kept only when the context has a socket.
    public static func render(_ command: RecipeCommand, context: ServiceTemplateContext) throws -> RenderedCommand {
        var arguments: [String] = []
        for argument in command.arguments {
            switch argument {
            case .plain(let template):
                arguments.append(try render(template, context: context))
            case .ifSocket(let templates):
                let rendered = try templates.map { try render($0, context: context) }
                if context.socket != nil { arguments += rendered }
            }
        }
        return RenderedCommand(executable: try render(command.executable, context: context), arguments: arguments,
                               environment: try command.environment.mapValues { try render($0, context: context) },
                               stdin: try command.stdin.map { try render($0, context: context) })
    }

    /// Renders a config file. Without a usable socket (none, or its path too long for macOS) every line that
    /// uses `{socket}` or `{socketDir}` is left out, as `.env` lines are, so a server is never handed an empty
    /// socket setting (Valkey's `unixsocket ""` would fail). Lines end at `\n`.
    public static func renderFile(_ template: String, context: ServiceTemplateContext) throws -> String {
        guard context.socket == nil else { return try render(template, context: context) }
        // By UTF-16 unit, so `\r\n` (one Character) ends a line too.
        let kept = template.components(separatedBy: "\n").filter { !mentionsSocket($0) }
        return try render(kept.joined(separator: "\n"), context: context)
    }

    /// The placeholder names `template` uses (`port.main`, `data`…), whether known or not.
    static func placeholders(in template: String) -> [String] {
        var names: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}"), isPlaceholderName(rest[afterOpen..<close]) else {
                rest = rest[afterOpen...]
                continue
            }
            names.append(String(rest[afterOpen..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    /// Whether `template` uses `{socket}` or `{socketDir}`.
    static func mentionsSocket(_ template: String) -> Bool {
        template.contains("{socket}") || template.contains("{socketDir}")
    }

    private static func isPlaceholderName(_ name: Substring) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_"
                || $0 == "-"
        }
    }

    private static func value(of name: String, context: ServiceTemplateContext) throws -> String {
        switch name {
        case "bin": return context.bin
        case "data": return context.data
        case "config": return context.config
        case "run": return context.run
        case "log": return context.log
        case "name": return context.name
        case "id": return context.id
        case "socket": return context.socket ?? ""
        // For programs that take the socket's folder (PostgreSQL's `unix_socket_directories`).
        case "socketDir": return context.socket == nil ? "" : context.run
        case "resources": return context.resources
        case "php":
            guard let php = context.php else { throw TemplateError.unavailable("php") }
            return php
        default:
            if name.hasPrefix("port."), let port = context.ports[String(name.dropFirst("port.".count))] {
                return String(port)
            }
            if let value = context.parameters[name] { return value }
            throw TemplateError.unknown(name)
        }
    }
}

/// Finds wildcard listen addresses in rendered recipe text. Services listen on this Mac only.
public enum ServiceLoopback {
    /// The wildcard `text` contains (`0.0.0.0`, `::` or `[::]` as an address, `*` as a host, or an
    /// address-less `:port`), or nil when it has none.
    public static func wildcard(in text: String) -> String? {
        if text.contains("0.0.0.0") { return "0.0.0.0" }
        if text.contains("[::]") { return "[::]" }
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " \t='\",;"))
            .filter { !$0.isEmpty }
        // `listen_addresses='*'` and `--host=*` split into a key and `*`.
        for token in tokens {
            if token == "::" || token.hasPrefix(":::") { return "::" }
            if token == "*" || token.hasPrefix("*:") { return token }
            // `--addr :8080` listens everywhere.
            if token.hasPrefix(":"), token.count > 1, token.dropFirst().allSatisfy(\.isNumber) { return token }
        }
        return nil
    }
}
