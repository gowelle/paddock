import Foundation

/// What an engine's service manager is built from.
public struct ServiceSetup: Sendable {
    public var catalog: ServiceCatalog
    /// Moves every preferred port up (development homes only; `ServicePorts.portBase`).
    public var portBase: Int?
    public var session: URLSession
    public var portCheck: ServicePortCheck
    /// Replaces every recipe's readiness deadline (tests); nil uses each recipe's.
    public var readyTimeout: TimeInterval?

    public init(catalog: ServiceCatalog, portBase: Int? = nil, session: URLSession = .shared,
                portCheck: ServicePortCheck = .live, readyTimeout: TimeInterval? = nil) {
        self.catalog = catalog
        self.portBase = portBase
        self.session = session
        self.portCheck = portCheck
        self.readyTimeout = readyTimeout
    }

    /// The daemon's: the bundled catalog and conventional ports, unless a development home's
    /// `PADDOCK_SERVICES_CATALOG` and `PADDOCK_SERVICE_PORT_BASE` say otherwise.
    public static func from(environment: [String: String]) -> ServiceSetup {
        ServiceSetup(catalog: .forDaemon(environment: environment), portBase: ServicePorts.portBase(environment: environment))
    }
}

extension Engine {
    /// Starts every service whose "start with Paddock" is on, whatever the web side is doing. Queued with
    /// the other requests, so shutting down waits for it (and makes its readiness waits give up). Also
    /// clears install staging an interrupted add left, before anything can install.
    public func startAutostartServices() async {
        await mutations.withLock {
            guard !self.isShuttingDown else { return }
            let services = self.services
            _ = try? await ServiceManager.offPool {
                services.installer.removeStaleStaging()
                services.startAutostart()
            }
        }
    }

    /// Answers a service request. Called from the serialized request path.
    func performService(_ request: Request) async -> Response {
        let services = self.services
        do {
            switch request {
            case .serviceAdd(let kind, let version):
                return try await downloading(kind) { _ = try await services.add(kind: kind, version: version) }
            case .serviceUpdate(let name):
                return try await downloading(name) { _ = try await services.update(name) }
            case .serviceRemove(let name, let deleteData):
                let data = try await ServiceManager.offPool { try services.remove(name, deleteData: deleteData) }
                return .removed(dataPath: data.path, status: status())
            case .serviceStart(let name):
                try await ServiceManager.offPool { try services.start(name) }
            case .serviceStop(let name):
                guard services.instance(named: name) != nil else { throw ServiceError.unknownService(name) }
                try await ServiceManager.offPool { services.stop(name) }
            case .serviceRestart(let name):
                try await ServiceManager.offPool { try services.restart(name) }
            case .serviceCatalog:
                return .catalog(services.catalogEntries())
            default:
                return .error(code: ErrorCode.internal, message: "not a service request")
            }
        } catch let error as ServiceError {
            return Self.response(for: error)
        } catch {
            return .error(code: ErrorCode.serviceFailed, message: error.localizedDescription)
        }
        return .ok(status())
    }

    /// Runs an add or update in its own task, registered like a PHP install, so shutting down cancels
    /// its download.
    private func downloading(_ name: String, _ body: @escaping @Sendable () async throws -> Void) async throws -> Response {
        let work = Task<Void, Error> { try await body() }
        setInstallInProgress(work)
        defer { setInstallInProgress(nil) }
        do {
            try await work.value
        } catch is CancellationError {
            throw ServiceError.cancelled(name: name)
        }
        return .ok(status())
    }

    static func response(for error: ServiceError) -> Response {
        let code: String
        switch error {
        case .unknownKind, .unknownVersion: code = ErrorCode.unknownServiceKind
        case .unknownService: code = ErrorCode.unknownService
        case .portInUse, .noFreePort: code = ErrorCode.servicePortInUse
        case .unavailable: code = ErrorCode.serviceUnavailable
        case .dataMismatch: code = ErrorCode.serviceUnavailable
        case .initialiseFailed, .initialiseTimedOut, .installFailed, .notReady, .notLoopback, .updateFailed,
             .rollbackFailed, .unsafeRecipe:
            code = ErrorCode.serviceFailed
        case .cancelled: code = ErrorCode.serviceCancelled
        }
        return .error(code: code, message: Messages.serviceError(error))
    }
}
