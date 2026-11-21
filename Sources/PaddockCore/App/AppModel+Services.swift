import Foundation

/// One added service as the Services section shows it.
public struct ServiceRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// As `paddock service list` says it: `running`, `port in use by Herd`…
    public let stateText: String
    /// `1025 (smtp), 8025 (http)`: the main port first.
    public let portText: String
    /// Its last add's notice and its recipe's notes, one sentence each.
    public let notes: [String]
    /// Its `.env` lines as `paddock service add` prints them: a secret only as a comment saying how to get it.
    public let envText: String
    public let canStart: Bool
    public let canStop: Bool
    /// It has a page (Mail's inbox) and runs.
    public let canOpen: Bool
    /// PostgreSQL, while it runs.
    public let canCreateDatabase: Bool
}

/// One entry of `Add Service…`: a series of a kind of service.
public struct CatalogRow: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind) \(version)" }
    public let kind: String
    /// The series to ask for (`18`).
    public let version: String
    /// `PostgreSQL 18.7.0`
    public let title: String
    public let licence: String
    /// An add of it is in flight.
    public let isAdding: Bool
}

extension AppModel {
    // MARK: - Derived

    public var serviceRows: [ServiceRow] {
        (status?.services ?? []).map { service in
            let running = service.state == .running
            let stoppable: Bool
            switch service.state {
            case .running, .starting: stoppable = true
            default: stoppable = false
            }
            let startable: Bool
            switch service.state {
            case .stopped, .crashed, .portInUse: startable = true
            default: startable = false
            }
            let notes = ([service.notice].compactMap { $0 } + (service.notes ?? []))
                .compactMap { Messages.printable($0, limit: 200) }
            return ServiceRow(id: service.id, name: service.name, stateText: Messages.serviceState(service.state),
                              portText: Messages.servicePorts(service), notes: notes,
                              envText: Messages.addedEnvLines(service).joined(separator: "\n"),
                              canStart: startable, canStop: stoppable, canOpen: running && service.openURL != nil,
                              canCreateDatabase: running && service.kind == "postgres")
        }
    }

    /// Every series of every kind, newest first within a kind.
    public var catalog: [CatalogRow] {
        catalogEntries.flatMap { entry in
            entry.series.map { series in
                CatalogRow(kind: entry.kind, version: series.series, title: "\(entry.displayName) \(series.version)",
                           licence: entry.licence, isAdding: isAdding(kind: entry.kind, version: series.series))
            }
        }
    }

    public func isAdding(kind: String, version: String?) -> Bool {
        isBusy(.serviceAdd(kind: kind, version: version))
    }

    /// The question `Remove and Delete Data…` asks, while it is being asked.
    public var deleteDataQuestion: String? {
        dataDeletionAsked.map { id in "Remove \(serviceName(id)) and delete its data? This can't be undone." }
    }

    /// The rule the daemon applies (`ServiceManager.isValidDatabaseName`).
    public static func isValidDatabaseName(_ name: String) -> Bool {
        ServiceManager.isValidDatabaseName(name)
    }

    private func serviceName(_ id: String) -> String {
        status?.services.first { $0.id == id }?.name ?? id
    }

    // MARK: - Actions

    /// Lists what can be added (a read; the menu calls it when it appears).
    public func loadCatalog() async {
        if case .catalog(let entries)? = await send(.serviceCatalog, timeout: 30) { catalogEntries = entries }
    }

    /// Downloads (if needed), sets up and starts a service. It may take minutes: the add has its own request,
    /// so polling and other actions go on meanwhile, and `isAdding` says it is in flight.
    public func addService(kind: String, version: String?) async {
        await serviceAction(.serviceAdd(kind: kind, version: version), timeout: 3600)
    }

    public func startService(_ id: String) async { await serviceAction(.serviceStart(name: id)) }
    public func stopService(_ id: String) async { await serviceAction(.serviceStop(name: id)) }
    public func restartService(_ id: String) async { await serviceAction(.serviceRestart(name: id)) }

    /// `Remove and Delete Data…`: asks first; only the answer (`removeService(id, deleteData: true)`) deletes.
    public func askToRemoveAndDeleteData(_ id: String) {
        dataDeletionAsked = id
    }

    public func cancelRemoveAndDeleteData() {
        dataDeletionAsked = nil
    }

    /// Removes the service, keeping its data unless `deleteData`, which needs the user's confirmation of
    /// `askToRemoveAndDeleteData` for this very service (used up here).
    public func removeService(_ id: String, deleteData: Bool) async {
        if deleteData {
            guard dataDeletionAsked == id else { return }
            dataDeletionAsked = nil
        }
        let name = serviceName(id)
        guard let response = await send(.serviceRemove(name: id, deleteData: deleteData)) else { return }
        if case .removed(let path, _) = response {
            serviceNotice = Messages.serviceRemoved(name, dataPath: path, deletedData: deleteData)
        }
        finish(response)
        await refresh()
    }

    /// Fetches the service's full `.env` lines (secrets included) now and puts them on the pasteboard; they are
    /// kept nowhere else.
    public func copyEnv(_ id: String) async {
        let name = serviceName(id)
        guard let response = await send(.serviceEnv(id: id), timeout: 30) else { return }
        if case .envLines(let lines) = response {
            copyText?(lines.joined(separator: "\n") + "\n")
            serviceNotice = "Copied the .env lines of \(name)."
        }
        finish(response)
    }

    public func openService(_ id: String) {
        guard let row = serviceRows.first(where: { $0.id == id }), row.canOpen,
              let page = status?.services.first(where: { $0.id == id })?.openURL, let url = URL(string: page) else { return }
        openItem?(url)
    }

    /// Creates a database in a running PostgreSQL; a name the daemon would refuse is refused here first.
    public func createDatabase(in id: String, named database: String) async {
        guard Self.isValidDatabaseName(database) else {
            lastError = Messages.serviceError(.invalidParameter(parameter: "database", value: database))
            return
        }
        guard let response = await send(.serviceCreateDatabase(name: id, database: database), timeout: 120) else { return }
        if case .databaseCreated(let created, let existed, _) = response {
            serviceNotice = Messages.databaseCreated(created, in: serviceName(id), alreadyExisted: existed)
        }
        finish(response)
        await refresh()
    }

    // MARK: - Pieces

    private func serviceAction(_ request: Request, timeout: TimeInterval = 600) async {
        guard let response = await send(request, timeout: timeout) else { return }
        finish(response)
        await refresh()
    }

    /// An answer's error goes to the error line; any other answer clears it.
    func finish(_ response: Response) {
        if case .error(_, let message) = response {
            lastError = message
        } else {
            lastError = nil
        }
    }
}
