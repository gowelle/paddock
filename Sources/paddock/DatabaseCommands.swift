import ArgumentParser
import Foundation
import PaddockCore

/// `paddock db …`: read a PostgreSQL or MySQL service Paddock runs. Read-only.
struct DatabaseGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Browse a PostgreSQL or MySQL service (read-only).",
        discussion: """
            Lists the databases in the services Paddock runs, their tables and columns, and rows from a \
            table. `query` runs one read-only statement. Nothing here changes a database.
            """,
        subcommands: [
            DatabaseList.self, DatabaseTables.self, DatabaseColumns.self, DatabaseRowsCommand.self,
            DatabaseQuery.self,
        ],
        defaultSubcommand: DatabaseList.self)
}

/// The `--service` option every subcommand but `list` takes.
struct DatabaseServiceOption: ParsableArguments {
    @Option(name: .long, help: "The service's id or name, when more than one database service is running.")
    var service: String?
}

extension CLI {
    /// The database browser, or the reason it can't exist (no PHP installed).
    static func databaseBrowser() throws -> DatabaseBrowser {
        guard let browser = DatabaseBrowser(paths: paths) else {
            throw failure(DatabaseError.noPHP.description)
        }
        return browser
    }

    /// The database service meant: the named one, or the only one running (then added) database service.
    static func databaseService(_ typed: String?, in status: EngineStatus) throws -> DatabaseService {
        let all = status.services.compactMap(DatabaseService.init)
        guard !all.isEmpty else { throw failure(DatabaseError.noService.description) }
        if let typed {
            let wanted = typed.trimmingCharacters(in: .whitespaces).lowercased()
            guard let service = all.first(where: { $0.id == wanted })
                    ?? all.first(where: { $0.name.lowercased() == wanted }) else {
                throw failure("No database service is named \(typed). Added: "
                             + all.map(\.id).joined(separator: ", ") + ".")
            }
            return service
        }
        let running = all.filter(\.isRunning)
        let candidates = running.isEmpty ? all : running
        if candidates.count == 1 { return candidates[0] }
        let list = candidates.map { "\($0.id)\($0.isRunning ? "" : " (not running)")" }.joined(separator: ", ")
        throw failure("More than one database service is \(running.isEmpty ? "added" : "running"): \(list). "
                      + "Use --service <id>.")
    }

    /// The table named on the command line: `users`, or `public.users` for PostgreSQL.
    static func databaseTable(_ typed: String, in service: DatabaseService) -> DatabaseTable {
        if service.engine == .postgres, let dot = typed.firstIndex(of: "."), dot != typed.startIndex {
            let schema = String(typed[..<dot])
            let name = String(typed[typed.index(after: dot)...])
            if !name.isEmpty { return DatabaseTable(schema: schema, name: name, kind: "table") }
        }
        return DatabaseTable(schema: nil, name: typed, kind: "table")
    }
}

struct DatabaseList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List the database services and their databases.")

    func run() throws {
        let services = try CLI.send(.status, timeout: 30).services.compactMap(DatabaseService.init)
        guard !services.isEmpty else { throw CLI.failure(DatabaseError.noService.description) }

        let browser = try CLI.databaseBrowser()
        for (index, service) in services.enumerated() {
            if index > 0 { print("") }
            print(service.isRunning
                  ? "\(service.title) — running on port \(service.port)"
                  : "\(service.title) — not running")
            guard service.isRunning else { continue }
            do {
                let databases = try browser.databases(for: service)
                if databases.isEmpty {
                    print("  No databases.")
                } else {
                    for name in databases { print("  \(name)") }
                }
            } catch {
                CLI.printError("  \(error)")
            }
        }
    }
}

struct DatabaseTables: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tables", abstract: "List a database's tables and views.")
    @OptionGroup var common: DatabaseServiceOption
    @Argument(help: "The database's name.") var database: String

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        let service = try CLI.databaseService(common.service, in: status)
        let tables = try CLI.databaseBrowser().tables(for: service, database: database)
        guard !tables.isEmpty else {
            print("No tables or views in \(database).")
            return
        }
        print(DatabaseOutput.table(["TABLE", "KIND"], tables.map { [$0.displayName, $0.kind] }))
    }
}

struct DatabaseColumns: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "columns", abstract: "List a table's columns.")
    @OptionGroup var common: DatabaseServiceOption
    @Argument(help: "The database's name.") var database: String
    @Argument(help: "The table's name, such as users or public.users.") var table: String

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        let service = try CLI.databaseService(common.service, in: status)
        let target = CLI.databaseTable(table, in: service)
        let columns = try CLI.databaseBrowser().columns(for: service, database: database, table: target)
        guard !columns.isEmpty else {
            print("No columns found for \(target.displayName).")
            return
        }
        print(DatabaseOutput.table(["COLUMN", "TYPE", "NULL", "DEFAULT", "KEY"], columns.map { column in
            [column.name, column.type, column.nullable ? "yes" : "no",
             column.defaultValue.map(DatabaseOutput.oneLine) ?? "", column.primary ? "primary" : ""]
        }))
    }
}

struct DatabaseRowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rows", abstract: "Show rows from a table (at most 20 unless --limit says otherwise).")
    @OptionGroup var common: DatabaseServiceOption
    @Argument(help: "The database's name.") var database: String
    @Argument(help: "The table's name, such as users or public.users.") var table: String
    @Option(name: .long, help: "Only rows with this text in any column.") var search: String?
    @Option(name: .long, help: "How many rows to show (default 20, at most 1000).") var limit = 20

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        let service = try CLI.databaseService(common.service, in: status)
        let target = CLI.databaseTable(table, in: service)
        let rows = try CLI.databaseBrowser().rows(for: service, database: database, table: target,
                                                  search: search, limit: limit)
        DatabaseOutput.write(rows)
    }
}

struct DatabaseQuery: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query", abstract: "Run one read-only SQL query.")
    @OptionGroup var common: DatabaseServiceOption
    @Argument(help: "The database's name.") var database: String
    @Argument(help: "The SQL to run. Only SELECT, WITH, SHOW, DESCRIBE, EXPLAIN, TABLE and VALUES are allowed.")
    var sql: String
    @Option(name: .long, help: "How many rows to show (default 20, at most 1000).") var limit = 20

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        let service = try CLI.databaseService(common.service, in: status)
        let rows = try CLI.databaseBrowser().query(for: service, database: database, sql: sql, limit: limit)
        DatabaseOutput.write(rows)
    }
}

/// Plain terminal output for `paddock db`.
enum DatabaseOutput {
    static func write(_ rows: DatabaseRows) {
        guard !rows.columns.isEmpty else {
            print("The query returned no columns.")
            return
        }
        let table = rows.rows.map { row in
            rows.columns.indices.map { column in oneLine(row.indices.contains(column) ? row[column] : nil) }
        }
        print(DatabaseOutput.table(rows.columns, table))
        if rows.truncated { print("(more rows not shown; use --limit to see more)") }
    }

    /// One line, so a multi-line value doesn't break the table.
    static func oneLine(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return value
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Aligned columns, two spaces apart.
    static func table(_ headers: [String], _ rows: [[String]]) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([line(headers)] + rows.map(line)).joined(separator: "\n")
    }
}
