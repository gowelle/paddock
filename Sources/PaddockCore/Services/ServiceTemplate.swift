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
/// `{port.<name>}`, `{socket}`, `{php}` and `{resources}`. Only `{` + a lowercase name + `}` is a
/// placeholder; any other brace (`${APP_NAME}`, JSON) is plain text.
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

    /// Renders every part of a command; each argument stays a single argument whatever it contains.
    public static func render(_ command: RecipeCommand, context: ServiceTemplateContext) throws -> RecipeCommand {
        RecipeCommand(executable: try render(command.executable, context: context),
                      arguments: try command.arguments.map { try render($0, context: context) },
                      environment: try command.environment.mapValues { try render($0, context: context) },
                      stdin: try command.stdin.map { try render($0, context: context) })
    }

    /// Whether `template` uses `{socket}`.
    static func mentionsSocket(_ template: String) -> Bool { template.contains("{socket}") }

    private static func isPlaceholderName(_ name: Substring) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-"
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
        case "resources": return context.resources
        case "php":
            guard let php = context.php else { throw TemplateError.unavailable("php") }
            return php
        default:
            if name.hasPrefix("port."), let port = context.ports[String(name.dropFirst("port.".count))] {
                return String(port)
            }
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
