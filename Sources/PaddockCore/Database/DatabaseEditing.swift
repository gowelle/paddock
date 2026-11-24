import Foundation

/// Writes to a database service, one row at a time. Values are column → text maps; nil is SQL NULL.
/// Separate from `DatabaseBrowsing` so the CLI's reader cannot grow writes by accident.
public protocol DatabaseWriting: Sendable {
    /// The row as the database holds it now, whole (not clipped to the grid's 4096 characters), binary
    /// columns left out.
    func row(for service: DatabaseService, database: String, table: DatabaseTable,
             key: [String: String?]) throws -> [String: String?]

    /// One row; columns absent from `values` take their database default.
    func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                values: [String: String?]) throws

    /// The changed columns of one row. `expected` holds the row as it was read; the database refuses the
    /// write if the row moved since.
    func update(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], changes: [String: String?],
                expected: [String: String?]) throws

    /// One row, refused when it changed since `expected` was read.
    func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], expected: [String: String?]) throws
}

/// What a write answered: rows touched. One is the only acceptable count for a single-row write.
public struct DatabaseWriteResult: Decodable, Equatable, Sendable {
    public let affected: Int
}

/// The columns that name one row: every primary key column, in table order.
public struct DatabaseRowKey: Equatable, Sendable {
    public let columns: [String]
    public let values: [String: String?]

    /// Nil when the table has no primary key, a key column is missing from the result, or a key value is NULL.
    public init?(columns: [DatabaseColumn], names: [String], row: [String?]) {
        let primary = columns.filter(\.primary)
        guard !primary.isEmpty else { return nil }
        var values: [String: String?] = [:]
        for column in primary {
            guard let index = names.firstIndex(of: column.name),
                  row.indices.contains(index), let value = row[index] else { return nil }
            values[column.name] = value
        }
        self.columns = primary.map(\.name)
        self.values = values
    }

    /// `id = 42, country = France`, for the delete dialog.
    public var description: String {
        columns.map { name in
            let value = values[name].flatMap { $0 } ?? "NULL"
            return "\(name) = \(value)"
        }.joined(separator: ", ")
    }
}

/// One row on its way into the database: the values it opened with, what has been typed, and which fields
/// stand for NULL. The model owns one; the views only read it.
public struct DatabaseEditDraft: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case update, insert }

    public let mode: Mode
    public let columns: [DatabaseColumn]
    /// Nil when adding a row.
    public let key: DatabaseRowKey?
    private var original: [String: String?]
    private var text: [String: String]
    private var nulls: Set<String>
    private var touched: Set<String>

    private init(mode: Mode, columns: [DatabaseColumn], key: DatabaseRowKey?,
                 original: [String: String?], text: [String: String], nulls: Set<String>, touched: Set<String>) {
        self.mode = mode
        self.columns = columns
        self.key = key
        self.original = original
        self.text = text
        self.nulls = nulls
        self.touched = touched
    }

    /// An existing row: `original` is what the database returned, whole, plus the display text of any column
    /// the row read leaves out (binary columns).
    public static func update(columns: [DatabaseColumn], key: DatabaseRowKey,
                              original: [String: String?]) -> DatabaseEditDraft {
        var text: [String: String] = [:]
        var nulls = Set<String>()
        for column in columns {
            if let value = original[column.name] ?? nil {
                text[column.name] = value
            } else if column.isEditable && column.nullable {
                nulls.insert(column.name)
            }
        }
        return DatabaseEditDraft(mode: .update, columns: columns, key: key, original: original,
                                 text: text, nulls: nulls, touched: [])
    }

    public static func insert(columns: [DatabaseColumn]) -> DatabaseEditDraft {
        DatabaseEditDraft(mode: .insert, columns: columns, key: nil, original: [:],
                          text: [:], nulls: [], touched: [])
    }

    // MARK: - Reading

    public func text(for column: String) -> String { text[column] ?? "" }
    public func isNull(_ column: String) -> Bool { nulls.contains(column) }
    public func isTouched(_ column: String) -> Bool { touched.contains(column) }

    /// What an untouched or read-only field shows: the typed text, NULL, or the original value.
    public func shownValue(_ column: String) -> String? {
        if nulls.contains(column) { return nil }
        if let value = text[column] { return value }
        return original[column] ?? nil
    }

    public func placeholder(for column: DatabaseColumn) -> String {
        mode == .insert ? column.insertPlaceholder : ""
    }

    /// What the database's row held for a column, nil for a value that was NULL or absent.
    private func originalValue(_ column: String) -> String? { original[column] ?? nil }

    // MARK: - Writing

    public mutating func type(_ value: String, into column: String) {
        guard columns.contains(where: { $0.name == column && $0.isEditable }) else { return }
        text[column] = value
        nulls.remove(column)
        touched.insert(column)
    }

    public mutating func setNull(_ isNull: Bool, column: String) {
        guard columns.contains(where: { $0.name == column && $0.isEditable && $0.nullable }) else { return }
        if isNull {
            nulls.insert(column)
            text[column] = ""
        } else {
            nulls.remove(column)
        }
        touched.insert(column)
    }

    /// Whether saving would change the database: any change on update; the row itself on insert.
    public var hasChanges: Bool {
        switch mode {
        case .insert:
            return true
        case .update:
            return columns.contains { column in
                guard column.isEditable, touched.contains(column.name) else { return false }
                if nulls.contains(column.name) { return originalValue(column.name) != nil }
                return text[column.name] != originalValue(column.name)
            }
        }
    }

    /// What an UPDATE sends: only the fields that differ from the row as it was read.
    public var changes: [String: String?] {
        guard mode == .update else { return [:] }
        var changes: [String: String?] = [:]
        for column in columns where column.isEditable && touched.contains(column.name) {
            let new: String? = nulls.contains(column.name) ? nil : (text[column.name] ?? "")
            if new != originalValue(column.name) { changes[column.name] = new }
        }
        return changes
    }

    /// What an INSERT sends: only the fields the owner touched; every other column takes its default.
    public var values: [String: String?] {
        guard mode == .insert else { return [:] }
        var values: [String: String?] = [:]
        for column in columns where column.isEditable && touched.contains(column.name) {
            values[column.name] = nulls.contains(column.name) ? nil : (text[column.name] ?? "")
        }
        return values
    }

    /// The row as it was read, for the write's own "has it moved?" check. Binary columns stay out.
    public var expected: [String: String?] {
        original.filter { name, _ in columns.contains { $0.name == name && !$0.binary } }
    }

    /// JSON and JSONB fields, touched, whose text is not valid JSON. Names them for the message.
    public func invalidJSONColumns() -> [String] {
        columns.filter { column in
            let type = column.type.lowercased()
            guard type == "json" || type == "jsonb",
                  column.isEditable, touched.contains(column.name), !nulls.contains(column.name) else {
                return false
            }
            return !DatabaseJSON.isValid(text[column.name] ?? "")
        }.map(\.name)
    }
}
