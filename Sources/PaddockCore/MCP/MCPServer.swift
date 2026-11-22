import Foundation

/// The Model Context Protocol, as much of it as offering tools takes: JSON-RPC 2.0, one message per line, over
/// whatever lines it is given (the `paddock mcp` command gives it standard input and output). It answers
/// `initialize`, `ping`, `tools/list` and `tools/call`; a notification is never answered.
public struct MCPServer: Sendable {
    /// The protocol versions this speaks, newest first.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let name = "paddock"
    static let instructions = "Paddock serves this Mac's local PHP sites at <folder>.test. Use these tools to see "
        + "its sites, PHP versions, services, logs and caught mail, and to make small changes to one site or service."

    private enum Code {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    private let tools: MCPTools

    public init(tools: MCPTools) {
        self.tools = tools
    }

    /// Answers every line `readLine` gives, in order, until it gives nil.
    public func run(readLine: () -> String?, write: (String) -> Void) async {
        while let line = readLine() {
            if let answer = await handle(line: line) { write(answer) }
        }
    }

    /// One message in, at most one out, on one line: nil for a notification and for an empty line.
    public func handle(line: String) async -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return failure(id: .null, Code.parseError, "That line isn't JSON.")
        }
        guard case .object(let members) = message else {
            return failure(id: .null, Code.invalidRequest, "A message must be a JSON object.")
        }
        // A string or a number names a request; anything without one is a notification (or a reply: ignored).
        let id: JSONValue?
        switch members["id"] {
        case .string?, .number?: id = members["id"]
        default: id = nil
        }
        guard let method = members["method"]?.string else {
            guard let id else { return nil }
            // A reply to something this server never asked has a result or an error and no method.
            if members["result"] != nil || members["error"] != nil { return nil }
            return failure(id: id, Code.invalidRequest, "A request names a method.")
        }
        guard let id else { return nil }
        let params = members["params"] ?? .object([:])

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return success(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(Self.name), "version": .string(String(PaddockBuild.number))]),
                "instructions": .string(Self.instructions),
            ]))
        case "ping":
            return success(id: id, .object([:]))
        case "tools/list":
            return success(id: id, .object(["tools": .array(tools.definitions.map(Self.describe))]))
        case "tools/call":
            guard let name = params["name"]?.string else {
                return failure(id: id, Code.invalidParams, "tools/call names a tool.")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard let result = await tools.call(name, arguments: arguments == .null ? .object([:]) : arguments) else {
                return failure(id: id, Code.invalidParams, "Unknown tool: \(name)")
            }
            return success(id: id, .object([
                "content": .array([.object(["type": "text", "text": .string(result.text)])]),
                "isError": .bool(result.isError),
            ]))
        default:
            return failure(id: id, Code.methodNotFound, "Method not found: \(method)")
        }
    }

    private static func describe(_ tool: MCPToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(tool.readOnly),
                "destructiveHint": false,
                "idempotentHint": .bool(tool.idempotent),
                "openWorldHint": false,
            ]),
        ])
    }

    private func success(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compact
    }

    private func failure(id: JSONValue, _ code: Int, _ message: String) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]).compact
    }
}
