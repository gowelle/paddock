import Foundation

/// The changes an agent may make: to one site or one service, each undone by the same tool. Nothing here
/// approves a command, changes what macOS trusts, removes anything, downloads anything or changes what is served.
extension MCPTools {
    static let doing: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "site_php",
            description: "Pins one site to an installed PHP version, or with no version puts it back on the default.",
            inputSchema: mcpSchema([
                "site": .object(["type": "string", "description": "The site's name: shop or shop.test."]),
                "version": .object(["type": .strings(["string", "null"]),
                                    "description": "An installed PHP version, such as 8.4. Leave out for the default."]),
            ], required: ["site"]),
            readOnly: false, idempotent: true,
            run: { tools, arguments in try tools.setSitePHP(arguments) }),
        MCPToolDefinition(
            name: "xdebug",
            description: "Switches Xdebug on or off for one installed PHP version, and restarts that version's PHP.",
            inputSchema: mcpSchema([
                "version": .object(["type": "string", "description": "An installed PHP version, such as 8.4."]),
                "on": .object(["type": "boolean"]),
            ], required: ["version", "on"]),
            readOnly: false, idempotent: true,
            run: { tools, arguments in try tools.setXdebug(arguments) }),
        MCPToolDefinition(
            name: "service_control",
            description: "Starts, stops or restarts one added service (a database, cache, search or mail service). "
                + "It cannot add, update or remove one.",
            inputSchema: mcpSchema([
                "name": .object(["type": "string", "description": "The service's id or name, from status."]),
                "action": .object(["type": "string", "enum": .strings(actions)]),
            ], required: ["name", "action"]),
            readOnly: false, idempotent: false,
            run: { tools, arguments in try tools.controlService(arguments) }),
        MCPToolDefinition(
            name: "database_create",
            description: "Creates a database in a running database service. One already there is left as it is.",
            inputSchema: mcpSchema([
                "service": .object(["type": "string", "description": "The database service's id or name, from status."]),
                "database": .object(["type": "string", "description": "The new database's name."]),
            ], required: ["service", "database"]),
            readOnly: false, idempotent: true,
            run: { tools, arguments in try tools.createDatabase(arguments) }),
        MCPToolDefinition(
            name: "task_control",
            description: "Starts, stops or restarts one of a site's tasks. Only tasks the owner has approved run; "
                + "approving a site's paddock.json is the owner's to do, in Paddock or with: paddock tasks approve",
            inputSchema: mcpSchema([
                "site": .object(["type": "string", "description": "The site's name: shop or shop.test."]),
                "task": .object(["type": "string", "description": "The task's name, from the site tool."]),
                "action": .object(["type": "string", "enum": .strings(actions)]),
            ], required: ["site", "task", "action"]),
            readOnly: false, idempotent: false,
            run: { tools, arguments in try tools.controlTask(arguments) }),
    ]

    private static let actions = ["start", "stop", "restart"]
    private static let done = ["start": "started", "stop": "stopped", "restart": "restarted"]

    private func action(_ arguments: JSONValue) throws -> String {
        let action = try arguments.text("action").lowercased()
        guard Self.actions.contains(action) else {
            throw MCPFailure("The argument \"action\" must be start, stop or restart.")
        }
        return action
    }

    /// An installed PHP version, as typed.
    private func installedVersion(_ typed: String, in status: EngineStatus) throws -> PHPVersion {
        guard let version = PHPVersion(typed.trimmingCharacters(in: .whitespaces)), status.installedPHP.contains(version) else {
            let installed = status.installedPHP.map { "\($0)" }.joined(separator: ", ")
            throw MCPFailure("PHP \(Self.shown(typed)) isn't installed. Installed: \(installed.isEmpty ? "none" : installed).")
        }
        return version
    }

    /// The added service `typed` names: its id or its name, in any case.
    private func service(_ typed: String, in status: EngineStatus) throws -> ServiceStatus {
        let wanted = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if let service = status.services.first(where: { $0.id == wanted })
            ?? status.services.first(where: { $0.name.lowercased() == wanted }) {
            return service
        }
        let ids = status.services.map(\.id).joined(separator: ", ")
        throw MCPFailure("No added service is named \(Self.shown(typed)). Added: \(ids.isEmpty ? "none" : ids).")
    }

    private func setSitePHP(_ arguments: JSONValue) throws -> MCPToolResult {
        let typed = try arguments.text("site"), wanted = try arguments.optionalText("version")
        let status = try currentStatus()
        let site = try site(named: typed, in: status)
        let after: EngineStatus, message: String
        if let wanted {
            let version = try installedVersion(wanted, in: status)
            after = try self.status(in: ask(.isolate(site: site.name, version: version)))
            message = "\(site.host) now runs PHP \(version)."
        } else {
            after = try self.status(in: ask(.unisolate(site: site.name)))
            message = "\(site.host) is back on the default PHP."
        }
        return .ok(.object(["message": .string(message),
                            "site": Self.json(after.sites.first { $0.name == site.name } ?? site)]))
    }

    private func setXdebug(_ arguments: JSONValue) throws -> MCPToolResult {
        let typed = try arguments.text("version"), on = try arguments.flag("on")
        let version = try installedVersion(typed, in: try currentStatus())
        let after = try status(in: ask(.xdebug(version: version, enabled: on)))
        return .ok(.object(["message": .string("Xdebug is \(on ? "on" : "off") for PHP \(version)."),
                            "xdebug": .strings(after.xdebug.map { "\($0)" })]))
    }

    private func controlService(_ arguments: JSONValue) throws -> MCPToolResult {
        let typed = try arguments.text("name"), action = try action(arguments)
        let service = try service(typed, in: try currentStatus())
        let request: Request
        switch action {
        case "start": request = .serviceStart(name: service.id)
        case "stop": request = .serviceStop(name: service.id)
        default: request = .serviceRestart(name: service.id)
        }
        let after = try status(in: ask(request))
        return .ok(.object(["message": .string("\(service.name) was \(Self.done[action] ?? action)."),
                            "service": Self.json(after.services.first { $0.id == service.id } ?? service)]))
    }

    private func createDatabase(_ arguments: JSONValue) throws -> MCPToolResult {
        let typed = try arguments.text("service"), database = try arguments.text("database")
        let service = try service(typed, in: try currentStatus())
        guard case .databaseCreated(let created, let alreadyExisted, _) =
                try ask(.serviceCreateDatabase(name: service.id, database: database)) else {
            throw MCPFailure(Messages.unexpectedAnswer(ClientError.badResponse("an answer for another request")))
        }
        let message = alreadyExisted ? "\(service.name) already had a database named \(created)."
            : "Created the database \(created) in \(service.name)."
        return .ok(.object(["message": .string(message), "database": .string(created),
                            "alreadyExisted": .bool(alreadyExisted)]))
    }

    private func controlTask(_ arguments: JSONValue) throws -> MCPToolResult {
        let typedSite = try arguments.text("site"), task = try arguments.text("task"), action = try action(arguments)
        let site = try site(named: typedSite, in: try currentStatus())
        let request: Request
        switch action {
        case "start": request = .taskStart(site: site.name, task: task)
        case "stop": request = .taskStop(site: site.name, task: task)
        default: request = .taskRestart(site: site.name, task: task)
        }
        let after = try status(in: ask(request))
        let now = after.sites.first { $0.name == site.name } ?? site
        var message = "\(Messages.displayName(task) ?? "The task") was \(Self.done[action] ?? action)."
        if now.tasks?.approval == .changed {
            message += " paddock.json has changed since it was approved; the approved version is what runs until "
                + "the owner approves the new one."
        }
        return .ok(.object(["message": .string(message), "site": Self.json(now, withTasks: true)]))
    }
}
