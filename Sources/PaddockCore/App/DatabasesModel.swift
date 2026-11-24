import Combine
import Foundation

/// Everything the Databases window and the menu's Databases row show, and every action they take. The views
/// hold no logic. It reads the daemon's service list only while something is watching, and a database only
/// when something is chosen. Read-only: `DatabaseBrowser` refuses writes.
@MainActor
public final class DatabasesModel: ObservableObject {
    /// The PostgreSQL and MySQL services the daemon knows, running or not.
    @Published public private(set) var services: [DatabaseService] = []
    /// The service chosen on the left.
    @Published public private(set) var selection: DatabaseService.ID?
    @Published public private(set) var databases: [String] = []
    /// The database chosen under the service.
    @Published public private(set) var database: String?
    @Published public private(set) var tables: [DatabaseTable] = []
    /// The table chosen under the database.
    @Published public private(set) var table: DatabaseTable?
    @Published public private(set) var columns: [DatabaseColumn] = []
    /// The chosen table's first rows, once they have loaded.
    @Published public private(set) var rows: DatabaseRows?
    /// The table's search text; the server looks for it in every column of the whole table.
    @Published public private(set) var rowSearch = ""
    /// The SQL console's text.
    @Published public private(set) var query = ""
    /// The SQL console's last result, kept while another statement is typed.
    @Published public private(set) var queryRows: DatabaseRows?
    /// True while any database read is on its way.
    @Published public private(set) var isBusy = false
    @Published public private(set) var isRunningQuery = false
    /// One quiet line; cleared by the next read that works.
    @Published public private(set) var lastError: String?

    /// How many rows a table and a query show.
    public nonisolated static let rowLimit = DatabaseBrowser.defaultRowLimit

    private let browser: DatabaseBrowsing?
    private let availableServices: @MainActor () -> [ServiceStatus]
    private var watchers = 0
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loads = 0
    /// The service whose databases have been read; nil makes the next refresh read them again.
    private var loadedService: String?

    /// `browser` nil when no PHP build is installed; `availableServices` answers the daemon's service list
    /// (empty while it isn't running).
    public init(browser: DatabaseBrowsing?, services: @escaping @MainActor () -> [ServiceStatus]) {
        self.browser = browser
        availableServices = services
    }

    // MARK: - Derived, for the views

    public var selectedService: DatabaseService? { services.first { $0.id == selection } }

    /// True when the menu should offer the Databases window: a database service has been added.
    public var isAdded: Bool { !services.isEmpty }

    public var isRunning: Bool { selectedService?.isRunning ?? false }

    public var canReload: Bool { isRunning && !isBusy }

    /// One read-only statement, with a database to run it in.
    public var canRunQuery: Bool {
        isRunning && database != nil && !isRunningQuery && ReadOnlySQL.allows(query)
    }

    /// `shop.users`, or the database alone while no table is chosen.
    public var title: String {
        guard let database else { return "Databases" }
        guard let table else { return database }
        return "\(database).\(table.displayName)"
    }

    /// The trimmed search text, or nil when the table isn't being searched.
    public var searchTerm: String? {
        let trimmed = rowSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True while the chosen table is narrowed by a search.
    public var isSearching: Bool { searchTerm != nil }

    /// What to say in place of the rows when there are none to show; nil while a table's rows are on show.
    public var detailText: String? {
        if services.isEmpty {
            return "No database service is added. Add PostgreSQL or MySQL in Settings\u{2026} \u{2192} Services."
        }
        guard let service = selectedService else { return "Choose a database service." }
        guard service.isRunning else { return DatabaseError.notRunning(service.name).description }
        guard let database else { return isBusy ? "Reading\u{2026}" : "No databases to browse in \(service.name)." }
        if table == nil {
            if isBusy { return "Reading\u{2026}" }
            return tables.isEmpty ? "No tables in \(database)." : "Choose a table to see its rows."
        }
        guard rows == nil else { return nil }
        if lastError != nil { return nil }
        return isBusy ? "Reading\u{2026}" : "No rows to show."
    }

    /// The line shown when the chosen table's rows came back empty.
    public var noRowsText: String? {
        guard let rows, rows.rows.isEmpty, table != nil else { return nil }
        guard let term = searchTerm else { return "This table has no rows." }
        return "No rows match \u{201C}\(term)\u{201D}."
    }

    /// `3 rows`, or `First 50 rows.` when the table has more than the window holds.
    public var rowCountText: String? {
        guard let rows else { return nil }
        if isSearching {
            if rows.rows.isEmpty { return "No matches" }
            if rows.truncated { return "First \(Self.rowLimit) matches." }
            return rows.rows.count == 1 ? "1 match" : "\(rows.rows.count) matches"
        }
        if rows.truncated { return "First \(Self.rowLimit) rows." }
        return rows.rows.count == 1 ? "1 row" : "\(rows.rows.count) rows"
    }

    // MARK: - Actions

    /// Reads the daemon's database services and, when one is chosen, keeps its databases up to date.
    public func refresh() async {
        let found = availableServices().compactMap(DatabaseService.init)
        let kept = selection.flatMap { id in found.contains { $0.id == id } ? id : nil }
        let firstRunning = found.first(where: \.isRunning)?.id
        let chosen = kept ?? firstRunning ?? found.first?.id
        if found != services { services = found }
        if chosen != selection {
            selection = chosen
            clearBelowService()
            loadedService = nil
            await loadDatabases()
            return
        }
        guard let service = selectedService else { return }
        if !service.isRunning {
            guard loadedService != nil else { return }
            clearBelowService()
            loadedService = nil
        } else if loadedService != service.id, !isBusy {
            clearBelowService()
            await loadDatabases()
        }
    }

    /// Chooses a database service on the left and reads its databases.
    public func select(service id: DatabaseService.ID) async {
        guard id != selection, services.contains(where: { $0.id == id }) else { return }
        selection = id
        clearBelowService()
        loadedService = nil
        await loadDatabases()
    }

    /// Chooses a database and reads its tables.
    public func select(database name: String) async {
        guard name != database else { return }
        database = name
        tables = []
        table = nil
        columns = []
        rows = nil
        queryRows = nil
        lastError = nil
        clearSearch()
        await loadTables()
    }

    /// Chooses a table and reads its columns and first rows; nil shows the tables' names alone.
    public func select(table wanted: DatabaseTable?) async {
        guard wanted?.id != table?.id else { return }
        table = wanted
        columns = []
        rows = nil
        lastError = nil
        clearSearch()
        guard let wanted, let service = selectedService, let database else { return }
        await loadTable(wanted, service: service, database: database)
    }

    /// Narrows the chosen table to rows holding `text`, looked for by the database in every column. Typing is
    /// collected for a moment, so a word costs one read rather than one per letter.
    public func setRowSearch(_ text: String) {
        guard text != rowSearch else { return }
        rowSearch = text
        searchTask?.cancel()
        searchTask = nil
        guard let table, let service = selectedService, let database, service.isRunning else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadRows(table, service: service, database: database)
        }
    }

    /// Reads everything on show again: the databases, the tables, and the chosen table's rows.
    public func reload() async {
        guard let service = selectedService, service.isRunning, !isBusy else { return }
        let keptDatabase = database
        let keptTable = table
        lastError = nil
        await loadDatabases()
        guard database != nil else { return }
        // A newly chosen database already had its tables read by `loadDatabases`.
        if database == keptDatabase { await loadTables() }
        if let keptTable, let fresh = tables.first(where: { $0.id == keptTable.id }), let database {
            await loadTable(fresh, service: service, database: database)
        }
    }

    public func setQuery(_ text: String) {
        query = text
    }

    /// Runs the console's one statement, read-only. A write is refused before PHP is started.
    public func runQuery() async {
        guard !isRunningQuery, let service = selectedService, let database, service.isRunning else { return }
        guard ReadOnlySQL.allows(query) else {
            queryRows = nil
            lastError = DatabaseError.notReadOnly.description
            return
        }
        guard let browser else {
            lastError = DatabaseError.noPHP.description
            return
        }
        let sql = query
        isRunningQuery = true
        defer { isRunningQuery = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try browser.query(for: service, database: database, sql: sql, limit: Self.rowLimit)
            }.value
            guard selection == service.id, self.database == database, query == sql else { return }
            queryRows = result
            lastError = nil
        } catch {
            guard selection == service.id, self.database == database else { return }
            show(error)
        }
    }

    // MARK: - Watching

    /// Called when the menu or the Databases window appears; the first watcher starts the reading.
    public func beginWatching() {
        watchers += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private

    private func loadDatabases() async {
        guard let service = selectedService else { return }
        guard service.isRunning else {
            clearBelowService()
            loadedService = nil
            return
        }
        guard let browser else {
            lastError = DatabaseError.noPHP.description
            loadedService = service.id
            return
        }
        beginLoad()
        defer { endLoad() }
        do {
            let names = try await Task.detached(priority: .userInitiated) {
                try browser.databases(for: service)
            }.value
            guard selection == service.id else { return }
            loadedService = service.id
            if databases != names { databases = names }
            lastError = nil
            if let database, names.contains(database) { return }
            // Prefer a database of the owner's own to the server's maintenance one.
            let chosen = names.first { $0 != service.engine.maintenanceDatabase } ?? names.first
            database = chosen
            tables = []
            table = nil
            columns = []
            rows = nil
            queryRows = nil
            clearSearch()
            if chosen != nil { await loadTables() }
        } catch {
            guard selection == service.id else { return }
            show(error)
        }
    }

    private func loadTables() async {
        guard let service = selectedService, let database, service.isRunning else { return }
        guard let browser else {
            lastError = DatabaseError.noPHP.description
            return
        }
        beginLoad()
        defer { endLoad() }
        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try browser.tables(for: service, database: database)
            }.value
            guard selection == service.id, self.database == database else { return }
            tables = found
            if let table, let fresh = found.first(where: { $0.id == table.id }) {
                self.table = fresh
            } else if table != nil {
                table = nil
                columns = []
                rows = nil
            }
            lastError = nil
        } catch {
            guard selection == service.id, self.database == database else { return }
            show(error)
        }
    }

    private func loadTable(_ wanted: DatabaseTable, service: DatabaseService, database: String) async {
        guard let browser else {
            lastError = DatabaseError.noPHP.description
            return
        }
        guard service.isRunning else {
            lastError = DatabaseError.notRunning(service.name).description
            return
        }
        let term = searchTerm
        beginLoad()
        defer { endLoad() }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let columns = try browser.columns(for: service, database: database, table: wanted)
                let rows = try browser.rows(for: service, database: database, table: wanted, search: term,
                                            limit: DatabasesModel.rowLimit)
                return (columns, rows)
            }.value
            guard selection == service.id, self.database == database, table?.id == wanted.id,
                  searchTerm == term else { return }
            columns = loaded.0
            rows = loaded.1
            lastError = nil
        } catch {
            guard selection == service.id, self.database == database, table?.id == wanted.id else { return }
            show(error)
        }
    }

    /// Reads just the chosen table's rows again, for a new search. Columns and anything else stay.
    private func loadRows(_ wanted: DatabaseTable, service: DatabaseService, database: String) async {
        guard let browser else {
            lastError = DatabaseError.noPHP.description
            return
        }
        guard service.isRunning else {
            lastError = DatabaseError.notRunning(service.name).description
            return
        }
        let term = searchTerm
        beginLoad()
        defer { endLoad() }
        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try browser.rows(for: service, database: database, table: wanted, search: term,
                                 limit: DatabasesModel.rowLimit)
            }.value
            guard selection == service.id, self.database == database, table?.id == wanted.id,
                  searchTerm == term else { return }
            rows = found
            lastError = nil
        } catch {
            guard selection == service.id, self.database == database, table?.id == wanted.id else { return }
            show(error)
        }
    }

    private func beginLoad() {
        loads += 1
        if !isBusy { isBusy = true }
    }

    private func endLoad() {
        loads = max(0, loads - 1)
        if loads == 0, isBusy { isBusy = false }
    }

    /// Everything under the service, gone: another service may hold other names.
    private func clearBelowService() {
        if !databases.isEmpty { databases = [] }
        if database != nil { database = nil }
        if !tables.isEmpty { tables = [] }
        if table != nil { table = nil }
        if !columns.isEmpty { columns = [] }
        if rows != nil { rows = nil }
        if queryRows != nil { queryRows = nil }
        if lastError != nil { lastError = nil }
        clearSearch()
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        if !rowSearch.isEmpty { rowSearch = "" }
    }

    private func show(_ error: Error) {
        lastError = (error as? DatabaseError)?.description
            ?? "Paddock couldn't read the database: \(error.localizedDescription)"
    }
}
