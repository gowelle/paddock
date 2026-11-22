import ArgumentParser
import Foundation
import PaddockCore

/// `paddock mcp`: Paddock for an AI agent, over the Model Context Protocol on standard input and output. The
/// agent's program starts this and stops it; it runs until its input ends.
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Paddock to an AI agent over the Model Context Protocol (stdin/stdout).",
        discussion: """
            An agent can see Paddock's sites, PHP versions, services, site tasks, logs and caught mail, and \
            make small changes to one site or service. It cannot approve a site's tasks, change what macOS \
            trusts, remove anything, read a service's secrets or change what is served.

            Add it to an MCP client with the command "paddock" and the argument "mcp".
            """)

    @Flag(name: .long, help: "Offer only the tools that change nothing.")
    var readOnly = false

    @Flag(name: .long, help: "Leave out the log tools. Logs hold whatever your applications wrote, for every site.")
    var noLogs = false

    func run() throws {
        let client = CLI.client, paths = CLI.paths
        let tools = MCPTools(
            options: .init(readOnly: readOnly, logs: !noLogs),
            send: { try client.send($0, timeout: 120) },
            logSections: { LogCatalog.sections(paths: paths, status: $0) },
            mail: HTTPMailClient())
        let server = MCPServer(tools: tools)
        // Standard output carries the protocol and nothing else.
        let output = FileHandle.standardOutput
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await server.run(readLine: { readLine(strippingNewline: true) },
                             write: { output.write(Data(($0 + "\n").utf8)) })
            finished.signal()
        }
        finished.wait()
    }
}
