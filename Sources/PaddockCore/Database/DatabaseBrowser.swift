import Foundation

/// The database servers Paddock can add and read.
public enum DatabaseEngine: String, CaseIterable, Sendable {
    case postgres
    case mysql

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        }
    }

    /// PDO's driver name.
    var driver: String {
        switch self {
        case .postgres: return "pgsql"
        case .mysql: return "mysql"
        }
    }

    /// A database every server has: used while listing the others.
    var maintenanceDatabase: String {
        switch self {
        case .postgres: return "postgres"
        case .mysql: return "mysql"
        }
    }
}

/// Why the browser can't answer, as the sentence shown to the owner.
public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case noService
    case notRunning(String)
    case noPHP
    case invalidDatabaseName(String)
    case notReadOnly
    case failed(String)

    public var description: String {
        switch self {
        case .noService:
            return "No PostgreSQL or MySQL service is added. Add one with: paddock service add postgres"
        case .notRunning(let name):
            return "\(name) isn't running. Start it in Settings\u{2026} \u{2192} Services, or run: paddock service start \(name)"
        case .noPHP:
            return MultiCall.noPHPMessage
        case .invalidDatabaseName(let name):
            return "Paddock can't connect to a database named \(Self.shown(name)): use letters, digits, underscores, dots and dashes."
        case .notReadOnly:
            return "Only read-only queries can be run here."
        case .failed(let sentence):
            return sentence
        }
    }

    private static func shown(_ text: String) -> String {
        "\u{201C}" + text.replacingOccurrences(of: "\n", with: " ") + "\u{201D}"
    }
}

/// One added database service, reduced to what a connection needs.
public struct DatabaseService: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let engine: DatabaseEngine
    public let port: Int
    public let isRunning: Bool

    /// Nil for a service that isn't PostgreSQL or MySQL (or has no main port yet).
    public init?(_ service: ServiceStatus) {
        guard let engine = DatabaseEngine(rawValue: service.kind), let port = service.ports["main"] else { return nil }
        self.id = service.id
        self.name = service.name
        self.engine = engine
        self.port = port
        self.isRunning = service.state == .running
    }

    /// For tests and previews.
    public init(id: String, name: String, engine: DatabaseEngine, port: Int, isRunning: Bool) {
        self.id = id
        self.name = name
        self.engine = engine
        self.port = port
        self.isRunning = isRunning
    }

    public var title: String { "\(name) (\(engine.displayName))" }
}

public struct DatabaseTable: Identifiable, Equatable, Sendable, Decodable {
    /// Nil for MySQL, whose tables belong to the chosen database rather than a schema.
    public let schema: String?
    public let name: String
    /// `table` or `view`.
    public let kind: String

    public init(schema: String?, name: String, kind: String) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { schema.map { "\($0).\(name)" } ?? name }
    public var displayName: String { id }
    public var isView: Bool { kind == "view" }
}

public struct DatabaseColumn: Identifiable, Equatable, Sendable, Decodable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let defaultValue: String?
    public let primary: Bool
    /// A value Paddock never reads as text or writes: bytea, binary, the BLOB family, geometry.
    public let binary: Bool
    /// Computed by the database (a generated or identity expression).
    public let generated: Bool
    /// Assigned by the database on insert; shown, but never typed.
    public let identity: Bool

    public init(name: String, type: String, nullable: Bool, defaultValue: String?,
                primary: Bool, binary: Bool = false, generated: Bool = false, identity: Bool = false) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.primary = primary
        self.binary = binary
        self.generated = generated
        self.identity = identity
    }

    public var id: String { name }

    /// A field the owner may type into.
    public var isEditable: Bool { !binary && !generated && !identity }

    /// What an untouched field of a new row shows, and therefore leaves to the database.
    public var insertPlaceholder: String {
        if defaultValue != nil { return "default" }
        return nullable ? "NULL" : "required"
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, nullable, primary, binary, generated, identity
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(String.self, forKey: .type)
        nullable = try values.decode(Bool.self, forKey: .nullable)
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue)
        primary = try values.decode(Bool.self, forKey: .primary)
        binary = try values.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        generated = try values.decodeIfPresent(Bool.self, forKey: .generated) ?? false
        identity = try values.decodeIfPresent(Bool.self, forKey: .identity) ?? false
    }
}

/// A result set: column names in order, and rows whose values are text (nil for SQL NULL).
public struct DatabaseRows: Equatable, Sendable, Decodable {
    public let columns: [String]
    public let rows: [[String?]]
    public let truncated: Bool

    public init(columns: [String], rows: [[String?]], truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }

    public var isEmpty: Bool { rows.isEmpty }

    public func value(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }
}

/// What the app's Databases window and the `paddock db` commands call. A fake in tests.
public protocol DatabaseBrowsing: Sendable {
    func databases(for service: DatabaseService) throws -> [String]
    func tables(for service: DatabaseService, database: String) throws -> [DatabaseTable]
    func columns(for service: DatabaseService, database: String, table: DatabaseTable) throws -> [DatabaseColumn]
    func rows(for service: DatabaseService, database: String, table: DatabaseTable,
              search: String?, limit: Int) throws -> DatabaseRows
    func query(for service: DatabaseService, database: String, sql: String, limit: Int) throws -> DatabaseRows
}

public extension DatabaseBrowsing {
    /// The table's first rows, with no search.
    func rows(for service: DatabaseService, database: String, table: DatabaseTable,
              limit: Int = DatabaseBrowser.defaultRowLimit) throws -> DatabaseRows {
        try rows(for: service, database: database, table: table, search: nil, limit: limit)
    }
}

/// Reads a database service through the bundled PHP's PDO drivers. Read-only: the SQL console opens a
/// read-only transaction, and writes are refused before PHP runs.
public struct DatabaseBrowser: DatabaseBrowsing, Sendable {
    private let bridge: PHPDatabaseBridge

    public init(php: URL, runner: CommandRunner = SystemCommandRunner()) {
        bridge = PHPDatabaseBridge(php: php, runner: runner)
    }

    /// Nil when no PHP build is installed (the browser needs one).
    public init?(paths: Paths = .current, runner: CommandRunner = SystemCommandRunner()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.phpRoot.path)) ?? []
        guard let newest = names.compactMap({ PHPVersion($0) }).max() else { return nil }
        let php = paths.phpDir(newest).appendingPathComponent("php")
        guard FileManager.default.isExecutableFile(atPath: php.path) else { return nil }
        self.init(php: php, runner: runner)
    }

    public static let defaultRowLimit = 50

    public func databases(for service: DatabaseService) throws -> [String] {
        try ask("databases", service: service, database: service.engine.maintenanceDatabase, as: [String].self)
    }

    public func tables(for service: DatabaseService, database: String) throws -> [DatabaseTable] {
        try ask("tables", service: service, database: database, as: [DatabaseTable].self)
    }

    public func columns(for service: DatabaseService, database: String,
                        table: DatabaseTable) throws -> [DatabaseColumn] {
        try ask("columns", service: service, database: database, schema: table.schema, table: table.name,
                as: [DatabaseColumn].self)
    }

    public func rows(for service: DatabaseService, database: String,
                     table: DatabaseTable, search: String? = nil,
                     limit: Int = DatabaseBrowser.defaultRowLimit) throws -> DatabaseRows {
        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ask("rows", service: service, database: database, schema: table.schema, table: table.name,
                       search: term?.isEmpty == false ? term : nil, limit: Self.clamp(limit),
                       as: DatabaseRows.self)
    }

    public func query(for service: DatabaseService, database: String,
                      sql: String, limit: Int = DatabaseBrowser.defaultRowLimit) throws -> DatabaseRows {
        guard ReadOnlySQL.allows(sql) else { throw DatabaseError.notReadOnly }
        return try ask("query", service: service, database: database, sql: sql, limit: Self.clamp(limit),
                       as: DatabaseRows.self)
    }

    private func ask<Answer: Decodable>(_ action: String, service: DatabaseService, database: String,
                                        schema: String? = nil, table: String? = nil, sql: String? = nil,
                                        search: String? = nil, limit: Int? = nil,
                                        key: [String: String?]? = nil, changes: [String: String?]? = nil,
                                        expected: [String: String?]? = nil, values: [String: String?]? = nil,
                                        as: Answer.Type, inFile: Bool = false) throws -> Answer {
        guard service.isRunning else { throw DatabaseError.notRunning(service.name) }
        try Self.validate(database: database)
        let request = DatabaseRequest(action: action, driver: service.engine.driver, host: "127.0.0.1",
                                      port: service.port, user: "root", password: "", database: database,
                                      schema: schema, table: table, sql: sql, limit: limit, search: search,
                                      key: key, changes: changes, expected: expected, values: values)
        return try bridge.run(request, as: Answer.self, inFile: inFile)
    }

    private static func clamp(_ limit: Int) -> Int { min(1000, max(1, limit)) }

    /// A name safe in a DSN and inside Paddock's own quoting. Paddock-created databases always pass.
    static func validate(database: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !database.isEmpty, database.utf8.count <= 64,
              let first = database.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains(first),
              database.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw DatabaseError.invalidDatabaseName(database)
        }
    }
}

/// Writes go through the same bundled PHP, one row at a time; the SQL console's read-only rule is untouched.
extension DatabaseBrowser: DatabaseWriting {
    public func row(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?]) throws -> [String: String?] {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        return try ask("row", service: service, database: database, schema: table.schema, table: table.name,
                       key: key, as: [String: String?].self)
    }

    public func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                       values: [String: String?]) throws {
        _ = try ask("insert", service: service, database: database, schema: table.schema, table: table.name,
                    values: values, as: DatabaseWriteResult.self, inFile: true)
    }

    public func update(for service: DatabaseService, database: String, table: DatabaseTable,
                       key: [String: String?], changes: [String: String?],
                       expected: [String: String?]) throws {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        guard !changes.isEmpty else { throw DatabaseError.failed("Nothing was changed.") }
        _ = try ask("update", service: service, database: database, schema: table.schema, table: table.name,
                    key: key, changes: changes, expected: expected,
                    as: DatabaseWriteResult.self, inFile: true)
    }

    public func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                       key: [String: String?], expected: [String: String?]) throws {
        guard !key.isEmpty else { throw DatabaseError.failed("No row was named.") }
        _ = try ask("delete", service: service, database: database, schema: table.schema, table: table.name,
                    key: key, expected: expected, as: DatabaseWriteResult.self, inFile: true)
    }
}

/// The read-only rule the SQL console applies before PHP sees a query. The PHP program applies it again,
/// and opens a read-only transaction, so neither layer relies on the other alone.
public enum ReadOnlySQL {
    static let keywords: Set<String> = ["SELECT", "WITH", "SHOW", "DESCRIBE", "EXPLAIN", "TABLE", "VALUES"]

    public static func allows(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let statement = trimmed.hasSuffix(";")
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        guard !statement.contains(";") else { return false }
        let body = strippingLeadingComments(statement)
        guard let first = body.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first,
              keywords.contains(first.uppercased()) else { return false }
        // A statement may begin with a read and still change rows (`WITH x AS (…) DELETE FROM users`,
        // `SELECT … FOR UPDATE`). The read-only transaction also refuses these; catching them here gives
        // the reader the plain reason instead of a database error.
        return !containsWriteWord(body)
    }

    /// The words a read may not hold, wherever they stand (`FOR UPDATE` included).
    private static let writeWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "TRUNCATE", "DROP", "ALTER", "CREATE",
        "GRANT", "REVOKE", "CALL", "DO", "COPY", "RENAME", "LOAD",
    ]

    /// Whether `text` holds one of `writeWords` as a word of its own; strings, quoted names and comments
    /// are looked over, so `SELECT 'delete'` is not mistaken for a delete.
    private static func containsWriteWord(_ text: String) -> Bool {
        let characters = Array(text)
        var index = 0
        var word = ""
        func finishWord() -> Bool {
            defer { word = "" }
            return !word.isEmpty && writeWords.contains(word.uppercased())
        }
        while index < characters.count {
            let c = characters[index]
            if c == "'" || c == "\"" || c == "`" {
                if finishWord() { return true }
                let quote = c
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == quote {
                        if end + 1 < characters.count, characters[end + 1] == quote { end += 2; continue }
                        break
                    }
                    end += 1
                }
                index = min(end + 1, characters.count)
                continue
            }
            if c == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                if finishWord() { return true }
                var end = index + 2
                while end < characters.count, characters[end] != "\n" { end += 1 }
                index = end
                continue
            }
            if c == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                if finishWord() { return true }
                var end = index + 2
                while end + 1 < characters.count, !(characters[end] == "*" && characters[end + 1] == "/") {
                    end += 1
                }
                index = min(end + 2, characters.count)
                continue
            }
            if c.isLetter || c.isNumber || c == "_" || c == "$" {
                word.append(c)
            } else if finishWord() {
                return true
            }
            index += 1
        }
        return finishWord()
    }

    private static func strippingLeadingComments(_ text: String) -> String {
        var s = Substring(text)
        while true {
            s = s.drop(while: { $0.isWhitespace })
            if s.hasPrefix("--") {
                guard let newline = s.firstIndex(of: "\n") else { return "" }
                s = s[s.index(after: newline)...]
                continue
            }
            if s.hasPrefix("/*") {
                guard let end = s.range(of: "*/") else { return "" }
                s = s[end.upperBound...]
                continue
            }
            return String(s)
        }
    }
}
