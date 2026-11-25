import Foundation

/// What a tool answered: text for the agent, and whether it is a failure.
public struct MCPToolResult: Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    /// `value` as JSON; a value too large to send is a failure instead.
    static func ok(_ value: JSONValue) -> MCPToolResult {
        let text = value.compact
        guard text.utf8.count <= MCPTools.resultLimit else { return failure("The answer was too large.") }
        return MCPToolResult(text: text, isError: false)
    }

    static func failure(_ sentence: String) -> MCPToolResult {
        MCPToolResult(text: sentence, isError: true)
    }
}

/// Why a tool can't answer, as the one sentence the agent is told.
struct MCPFailure: Error, Equatable {
    let sentence: String

    init(_ sentence: String) { self.sentence = sentence }
}

/// One tool: what the agent is told about it, and what it does.
struct MCPToolDefinition: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    /// It changes nothing.
    let readOnly: Bool
    /// Calling it again with the same arguments changes nothing more.
    let idempotent: Bool
    let run: @Sendable (MCPTools, JSONValue) async throws -> MCPToolResult
}

/// The tools `paddock mcp` offers an agent. It reaches the daemon, the logs and the mail service only through
/// what it is given, and sends the daemon only the requests its tools name: nothing that approves a command,
/// changes what macOS trusts, removes anything or answers a secret.
public struct MCPTools: Sendable {
    public struct Options: Sendable {
        /// Leave out every tool that changes something.
        public var readOnly: Bool
        /// Offer the log tools. Logs hold whatever the owner's applications wrote, for every site.
        public var logs: Bool

        public init(readOnly: Bool = false, logs: Bool = true) {
            self.readOnly = readOnly
            self.logs = logs
        }
    }

    /// The most one answer's text may be, in bytes.
    public static let resultLimit = 64 * 1024

    let options: Options
    let send: @Sendable (Request) throws -> Response
    let logSections: @Sendable (EngineStatus) -> [LogSection]
    let mail: any MailReading
    let doctor: Doctor

    /// `send` asks the daemon (`PaddockClient.send`); `logSections` lists the logs there are
    /// (`LogCatalog.sections`); `mail` reads the mail service.
    public init(options: Options = Options(),
                send: @escaping @Sendable (Request) throws -> Response,
                logSections: @escaping @Sendable (EngineStatus) -> [LogSection],
                mail: any MailReading,
                doctor: Doctor = Doctor()) {
        self.options = options
        self.send = send
        self.logSections = logSections
        self.mail = mail
        self.doctor = doctor
    }

    /// The tools on offer, given the options.
    var definitions: [MCPToolDefinition] {
        var tools = Self.seeing
        if !options.logs { tools.removeAll { $0.name.hasPrefix("logs_") } }
        if !options.readOnly { tools += Self.doing }
        return tools
    }

    public var toolNames: [String] { definitions.map(\.name) }

    /// Runs a tool. Nil when there is no tool by that name on offer.
    public func call(_ name: String, arguments: JSONValue) async -> MCPToolResult? {
        guard let tool = definitions.first(where: { $0.name == name }) else { return nil }
        do {
            return try await tool.run(self, arguments)
        } catch let failure as MCPFailure {
            return .failure(failure.sentence)
        } catch {
            return .failure("Paddock couldn't do that: \(error.localizedDescription)")
        }
    }
}

// MARK: - Arguments

extension JSONValue {
    /// A text argument that must be there and not be empty.
    func text(_ key: String) throws -> String {
        guard let value = self[key], value != .null else { throw MCPFailure("The argument \"\(key)\" is missing.") }
        guard let text = value.string else { throw MCPFailure("The argument \"\(key)\" must be text.") }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPFailure("The argument \"\(key)\" is empty.")
        }
        return text
    }

    func optionalText(_ key: String) throws -> String? {
        guard let value = self[key], value != .null else { return nil }
        guard let text = value.string else { throw MCPFailure("The argument \"\(key)\" must be text.") }
        return text
    }

    func optionalWholeNumber(_ key: String) throws -> Int? {
        guard let value = self[key], value != .null else { return nil }
        guard let number = value.int else { throw MCPFailure("The argument \"\(key)\" must be a whole number.") }
        return number
    }

    func flag(_ key: String) throws -> Bool {
        guard let value = self[key], value != .null else { throw MCPFailure("The argument \"\(key)\" is missing.") }
        guard let flag = value.bool else { throw MCPFailure("The argument \"\(key)\" must be true or false.") }
        return flag
    }
}

/// A tool's input schema: an object of `properties`, of which `required` must be given.
func mcpSchema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    .object(["type": "object", "properties": .object(properties), "required": .strings(required),
             "additionalProperties": false])
}
