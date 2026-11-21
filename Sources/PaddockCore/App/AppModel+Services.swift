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
    public let canStart: Bool
    public let canStop: Bool
    /// It has a page (Mail's inbox) and runs.
    public let canOpen: Bool
    /// PostgreSQL, while it runs.
    public let canCreateDatabase: Bool
}

/// The `Remove and Delete Data…` question as the dialog presents it; confirming hands it back whole.
public struct DataDeletionRequest: Identifiable, Equatable, Sendable {
    public var id: UUID { token }
    public let serviceID: String
    /// The service's name (`PostgreSQL 18`).
    public let name: String
    public let title: String
    /// That the data folder is deleted for good.
    public let message: String
    /// Issued with the question; confirms only that question, once.
    public let token: UUID

    public init(serviceID: String, name: String, title: String, message: String, token: UUID) {
        self.serviceID = serviceID
        self.name = name
        self.title = title
        self.message = message
        self.token = token
    }
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
    /// Why this Mac can't run it (the add would be refused with this); nil when it can.
    public let unavailableReason: String?
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
                              canStart: startable, canStop: stoppable, canOpen: running && service.openURL != nil,
                              canCreateDatabase: running && service.kind == "postgres")
        }
    }

    /// Every series of every kind, newest first within a kind.
    public var catalog: [CatalogRow] {
        catalogEntries.flatMap { entry in
            entry.series.map { series in
                CatalogRow(kind: entry.kind, version: series.series, title: "\(entry.displayName) \(series.version)",
                           licence: entry.licence, isAdding: isAdding(kind: entry.kind, version: series.series),
                           unavailableReason: series.unavailableReason)
            }
        }
    }

    public func isAdding(kind: String, version: String?) -> Bool {
        isBusy(.serviceAdd(kind: kind, version: version))
    }

    /// The question `Remove and Delete Data…` asks, while it is shown: its title names the service.
    public var deleteDataQuestion: String? { dataDeletionRequest?.title }

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

    /// `Remove and Delete Data…`: issues the question, with a token only its confirmation can use.
    public func askToRemoveAndDeleteData(_ id: String) {
        let folder = status?.services.first { $0.id == id }.map { Messages.displayName($0.dataPath, limit: 256) ?? "?" }
        let name = serviceName(id)
        let request = DataDeletionRequest(
            serviceID: id, name: name, title: "Remove \(name) and delete its data?",
            message: "Its data folder\(folder.map { ", \($0)," } ?? "") will be deleted. The data can't be recovered.",
            token: UUID())
        dataDeletionGrant = request
        dataDeletionRequest = request
    }

    /// The dialog went away by itself (as it does after any button): hides the question, nothing more.
    public func hideDataDeletionQuestion() {
        dataDeletionRequest = nil
    }

    /// Cancel, Escape, or the tab or window going away: the question's token can no longer delete anything.
    public func cancelRemoveAndDeleteData() {
        dataDeletionRequest = nil
        dataDeletionGrant = nil
    }

    /// The user confirmed `request`, as the dialog presented it. Deletes only for the question the model issued
    /// last, not yet used or cancelled (checked and used up at once, whatever has hidden the dialog); the removal
    /// runs in the returned task. Nil, doing nothing, otherwise.
    @discardableResult
    public func confirmRemoveAndDeleteData(_ request: DataDeletionRequest) -> Task<Void, Never>? {
        guard let grant = dataDeletionGrant, grant == request else { return nil }
        dataDeletionGrant = nil
        dataDeletionRequest = nil
        return Task { await self.remove(request.serviceID, deleteData: true) }
    }

    /// Removes the service, keeping its data unless `deleteData`, which needs the question about this very service
    /// still open (used up here).
    public func removeService(_ id: String, deleteData: Bool) async {
        if deleteData {
            guard dataDeletionGrant?.serviceID == id else { return }
            dataDeletionGrant = nil
            dataDeletionRequest = nil
        }
        await remove(id, deleteData: deleteData)
    }

    private func remove(_ id: String, deleteData: Bool) async {
        let name = serviceName(id)
        if case .removed(let path, _)? = await act(.serviceRemove(name: id, deleteData: deleteData)) {
            showNotice(Messages.serviceRemoved(name, dataPath: path, deletedData: deleteData))
        }
        await refresh()
    }

    /// Fetches the service's full `.env` lines (secrets included) now and puts them on the pasteboard, marked
    /// concealed when they hold a secret; they are kept nowhere else.
    public func copyEnv(_ id: String) async {
        let service = status?.services.first { $0.id == id }
        let name = service?.name ?? id
        if case .envLines(let lines)? = await act(.serviceEnv(id: id), timeout: 30) {
            copyText?(lines.joined(separator: "\n") + "\n", !(service?.secretEnvNames ?? []).isEmpty)
            showNotice("Copied the .env lines of \(name).")
        }
    }

    public func openService(_ id: String) {
        guard let row = serviceRows.first(where: { $0.id == id }), row.canOpen,
              let page = status?.services.first(where: { $0.id == id })?.openURL, let url = URL(string: page) else { return }
        openItem?(url)
    }

    /// Creates a database in a running PostgreSQL; a name the daemon would refuse is refused here first.
    public func createDatabase(in id: String, named database: String) async {
        // One action per service, whatever the name typed: creating any database there clears its earlier error.
        let key = "create database in \(id)"
        guard Self.isValidDatabaseName(database) else {
            showError(Messages.serviceError(.invalidParameter(parameter: "database", value: database)), from: key)
            return
        }
        if case .databaseCreated(let created, let existed, _)? = await act(
            .serviceCreateDatabase(name: id, database: database), timeout: 120, errorKey: key) {
            showNotice(Messages.databaseCreated(created, in: serviceName(id), alreadyExisted: existed))
        }
        await refresh()
    }

    // MARK: - Pieces

    private func serviceAction(_ request: Request, timeout: TimeInterval = 600) async {
        _ = await act(request, timeout: timeout)
        await refresh()
    }
}
