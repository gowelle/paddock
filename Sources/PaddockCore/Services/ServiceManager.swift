import Darwin
import Foundation

public enum ServiceError: Error, Equatable, Sendable {
    /// No recipe of that kind; `available` lists the kinds there are.
    case unknownKind(String, available: [String])
    /// No such series or version of the kind; `available` lists its series.
    case unknownVersion(kind: String, version: String, available: [String])
    /// No added service has that id or name.
    case unknownService(String)
    /// A saved port is held by another program (named as Paddock shows names).
    case portInUse(name: String, port: Int, holder: String)
    case noFreePort(name: String, preferred: Int)
    /// An initialise step exited with an error; `output` is what it printed.
    case initialiseFailed(name: String, output: String)
    /// An initialise step ran past its recipe's deadline and was stopped.
    case initialiseTimedOut(name: String, seconds: Int, output: String)
    case installFailed(name: String, reason: ServiceInstallError)
    /// It exited, or didn't become ready in time; `log` is the end of its log.
    case notReady(name: String, log: String)
    /// It listened on an address other than 127.0.0.1 or [::1], and was stopped.
    case notLoopback(name: String, address: String)
    /// Its data was last used by another kind or series (`found`), not `expected`.
    case dataMismatch(name: String, found: String, expected: String)
    /// The new version didn't start; the previous one runs again.
    case updateFailed(name: String, version: String, previous: String, log: String)
    case unavailable(name: String, reason: String)
    /// Paddock began shutting down while the service was being added or updated.
    case cancelled(name: String)
}

/// How the manager finds out whether a port is free, and who holds one that isn't.
public struct ServicePortCheck: Sendable {
    /// Whether nothing accepts connections on 127.0.0.1 or [::1] on the port.
    public var isFree: @Sendable (Int) -> Bool
    /// Who holds each of the ports (none for free ones), named as for the web ports.
    public var holders: @Sendable ([Int]) -> [PortHolder]

    public init(isFree: @escaping @Sendable (Int) -> Bool, holders: @escaping @Sendable ([Int]) -> [PortHolder]) {
        self.isFree = isFree
        self.holders = holders
    }

    /// The same connection-based check and holder naming as the web ports.
    public static let live = ServicePortCheck(isFree: { !PortCheck.accepts(port: $0) },
                                              holders: { PortCheck.holders(of: $0) })
}

/// Downloads, initialises, supervises and reports on every added service, from its recipe alone.
///
/// Instances belong to a recipe series (`postgres` `18`); the newest patch of the series in the catalog is
/// taken at a start when its files are on this Mac, and only by `update` when it needs a download. An
/// instance runs from the recipe stored with its installed binaries, so it keeps working after the catalog
/// drops its version.
///
/// Changes (`start`, `stop`, `restart`, `remove`, `startAutostart`, `stopAll`, and the folder and state part
/// of `add` and `update`) run one at a time and may wait (a start waits until the service is ready).
/// `statuses` never waits for them: it reports the last known state. Adds and updates are serialized among
/// themselves; each one's download runs outside the change lock and stops when its task is cancelled.
public final class ServiceManager: @unchecked Sendable {
    public let catalog: ServiceCatalog
    let paths: Paths
    let store: StateStore
    let supervisor: Supervisor
    let installer: ServiceInstaller
    private let portCheck: ServicePortCheck
    private let phpBinary: @Sendable () -> URL?
    /// Moves every preferred port up (tests; `ServicePorts.portBase`).
    private let portBase: Int?
    /// Replaces every recipe's readiness deadline (tests).
    private let readyTimeout: TimeInterval?
    private let resources: URL
    /// Runs `lsof` for the loopback check.
    private let runner: CommandRunner
    private let log: @Sendable (String) -> Void

    private let operationLock = NSLock()
    private let adds = AsyncMutex()
    /// Serializes installs from local files (starts of several instances run side by side).
    private let installLock = NSLock()
    /// Guards `runtime`, `notices`, `cancelled` and `reportedIDs`; held only for an instant.
    private let runtimeLock = NSLock()
    /// What the manager last saw each instance do. The supervisor's own status refines it.
    private var runtime: [String: ServiceState] = [:]
    /// A sentence about an instance's last add or update, until it is stopped.
    private var notices: [String: String] = [:]
    /// Set while shutting down: readiness waits and initialise steps give up at once.
    private var cancelled = false
    /// Saved ids already reported as invalid (one log line each).
    private var reportedIDs: Set<String> = []

    /// Unix socket paths longer than this don't fit `sun_path` (104 bytes with the NUL).
    static let maximumSocketPath = 103
    static let pidFileName = "pid"
    static let dataVersionFileName = "data-version"

    /// `catalog` is validated (`ServiceCatalog.validate`); an invalid one is replaced by an empty one and logged.
    public init(paths: Paths, catalog: ServiceCatalog, store: StateStore, supervisor: Supervisor,
                downloader: ArtifactDownloader = ArtifactDownloader(), portCheck: ServicePortCheck = .live,
                phpBinary: @escaping @Sendable () -> URL? = { nil }, portBase: Int? = nil,
                readyTimeout: TimeInterval? = nil, resources: URL = Bundled.resources,
                runner: CommandRunner = SystemCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.log = log
        do {
            try ServiceCatalog.validate(catalog.recipes)
            self.catalog = catalog
        } catch {
            log("\(error)")
            self.catalog = ServiceCatalog(recipes: [])
        }
        self.store = store
        self.supervisor = supervisor
        installer = ServiceInstaller(paths: paths, downloader: downloader, environment: environment)
        self.portCheck = portCheck
        self.phpBinary = phpBinary
        self.portBase = portBase
        self.readyTimeout = readyTimeout
        self.resources = resources
        self.runner = runner
    }

    static func processName(_ id: String) -> String { "service-\(id)" }

    // MARK: - Instances

    /// The saved instances Paddock may act on: an id, kind or version read back from `state.json` that
    /// isn't one Paddock makes is ignored (and logged once), never used to build a path. A missing series is
    /// filled in from the catalog.
    func instances() -> [ServiceInstance] {
        store.load().services.compactMap { instance in
            guard Self.isSafe(instance) else {
                reportInvalid(instance.id)
                return nil
            }
            return withSeries(instance)
        }
    }

    private static func isSafe(_ instance: ServiceInstance) -> Bool {
        ServiceInstance.isValidID(instance.id) && ServiceInstance.isValidID(instance.kind)
            && ServiceCatalog.isSafeName(instance.version)
            && (instance.series.isEmpty || ServiceCatalog.isSafeName(instance.series))
    }

    private func reportInvalid(_ id: String) {
        runtimeLock.lock()
        let first = reportedIDs.insert(id).inserted
        runtimeLock.unlock()
        if first { log("ignoring the saved service \"\(Messages.printable(id) ?? "?")\": its name isn't one Paddock makes") }
    }

    /// The instance with its series: as saved, else the catalog's (or its installed recipe's) for that
    /// version, else the version's first component.
    private func withSeries(_ instance: ServiceInstance) -> ServiceInstance {
        guard instance.series.isEmpty else { return instance }
        var filled = instance
        filled.series = catalog.recipes(of: instance.kind).first { $0.version == instance.version }?.series
            ?? installer.installedRecipe(kind: instance.kind, version: instance.version)?.series
            ?? ServiceRecipe.leadingComponent(of: instance.version)
        return filled
    }

    /// The instance `name` names (id or name, any case).
    public func instance(named name: String) -> ServiceInstance? {
        ServiceInstance.find(name, in: instances())
    }

    private func find(_ name: String) throws -> ServiceInstance {
        guard let instance = instance(named: name) else { throw ServiceError.unknownService(name) }
        return instance
    }

    /// The newest recipe of the instance's series in the catalog.
    private func latest(_ instance: ServiceInstance) -> ServiceRecipe? {
        catalog.recipe(kind: instance.kind, series: instance.series)
    }

    /// The recipe stored with the instance's installed binaries.
    private func installedRecipe(_ instance: ServiceInstance) -> ServiceRecipe? {
        installer.installedRecipe(kind: instance.kind, version: instance.version)
    }

    /// The recipe that describes the instance for status, env and open: what it runs, else the catalog's.
    private func describingRecipe(_ instance: ServiceInstance) -> ServiceRecipe? {
        installedRecipe(instance)
            ?? catalog.recipes(of: instance.kind).first { $0.version == instance.version }
            ?? latest(instance)
    }

    // MARK: - Adding

    /// Resolves the recipe (newest of a series, or an exact version), chooses ports, installs the binaries if
    /// they aren't yet, chooses the ports again if one was taken meanwhile, creates the instance's folders,
    /// initialises its data (unless data for that id is already there and from the same kind and series,
    /// which is used as it is), saves it, starts it and waits until it is ready. A failure before the save
    /// leaves no instance and removes the folders it created (verified binaries stay); a failure to start
    /// after it leaves the instance, crashed, so it can be started again or removed.
    public func add(kind: String, version: String?) async throws -> ServiceInstance {
        let result: Result<ServiceInstance, Error> = await adds.withLock {
            do { return .success(try await self.addOne(kind: kind, version: version)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func addOne(kind: String, version: String?) async throws -> ServiceInstance {
        let recipe = try resolve(kind: kind, version: version)
        let identity = ServiceInstance.newIdentity(
            kind: recipe.kind, series: recipe.series, displayName: recipe.displayName, seriesInID: recipe.seriesInID,
            existing: Set(store.load().services.map(\.id)))
        guard ServiceInstance.isValidID(identity.id) else {
            throw ServiceError.unavailable(name: identity.name, reason: "its catalog entry has an unusable name")
        }
        if recipe.needsPHP && phpBinary() == nil {
            throw ServiceError.unavailable(name: identity.name, reason: "it runs on PHP, and no PHP is installed")
        }
        var ports = try choosePorts(recipe, name: identity.name)
        do {
            try await installer.install(recipe)
        } catch is CancellationError {
            throw ServiceError.cancelled(name: identity.name)
        } catch let error as ServiceInstallError {
            throw ServiceError.installFailed(name: identity.name, reason: error)
        }
        if Task.isCancelled { throw ServiceError.cancelled(name: identity.name) }
        // A download can take minutes: a port taken meanwhile is chosen again (nothing is saved yet).
        if ports.values.contains(where: { !portCheck.isFree($0) }) { ports = try choosePorts(recipe, name: identity.name) }

        let instance = ServiceInstance(id: identity.id, kind: recipe.kind, series: recipe.series, version: recipe.version,
                                       name: identity.name, ports: ports, autostart: true, createdAt: Date())
        try await Self.offPool { try self.create(instance, recipe: recipe) }
        try await Self.offPool { try self.start(instance.id) }
        return instance
    }

    private func choosePorts(_ recipe: ServiceRecipe, name: String) throws -> [String: Int] {
        do {
            return try ServicePorts.choose(for: ServicePorts.shifted(recipe, base: portBase),
                                           taken: Set(store.load().services.flatMap { $0.ports.values }),
                                           isFree: portCheck.isFree)
        } catch ServicePortError.noFreePort(_, let preferred) {
            throw ServiceError.noFreePort(name: name, preferred: preferred)
        }
    }

    /// The catalog's recipe: the newest when `version` is nil, else the series or version it names.
    private func resolve(kind: String, version: String?) throws -> ServiceRecipe {
        guard let newest = catalog.recipe(kind: kind, version: nil) else {
            throw ServiceError.unknownKind(kind, available: catalog.kinds().map(\.kind))
        }
        guard let recipe = catalog.recipe(kind: kind, version: version) else {
            var series: [String] = []
            for recipe in catalog.recipes(of: kind) where !series.contains(recipe.series) { series.append(recipe.series) }
            throw ServiceError.unknownVersion(kind: newest.kind, version: version ?? "", available: series)
        }
        return recipe
    }

    /// Creates the instance's folders and config files, runs the initialise steps when its data is new, and
    /// saves it. On failure removes what it created, never data that was already there.
    private func create(_ instance: ServiceInstance, recipe: ServiceRecipe) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let fm = FileManager.default
        let data = paths.serviceData(instance.id)
        let dataExisted = fm.fileExists(atPath: data.path)
        if dataExisted, let mismatch = dataMismatch(instance, recipe) { throw mismatch }
        var created: [URL] = []
        do {
            try fm.createDirectory(at: paths.services, withIntermediateDirectories: true)
            for folder in [paths.serviceHome(instance.id), data, paths.serviceConfig(instance.id)]
            where !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                created.append(folder)
            }
            try ensureRunFolder(instance.id)
            try fm.createDirectory(at: paths.log, withIntermediateDirectories: true)
            let context = try self.context(instance, recipe: recipe)
            try writeConfigFiles(recipe, context: context, id: instance.id)
            if dataExisted {
                let notice = Messages.existingServiceData(instance.name)
                setNotice(notice, for: instance.id)
                log(notice)
            } else {
                for step in recipe.initialise { try runStep(step, instance: instance, recipe: recipe, context: context) }
            }
            try store.update { $0.services.append(instance) }
        } catch {
            for folder in created.reversed() { try? fm.removeItem(at: folder) }
            try? fm.removeItem(at: paths.serviceRun(instance.id))
            setNotice(nil, for: instance.id)
            if let error = error as? ServiceError { throw error }
            if let error = error as? TemplateError {
                throw ServiceError.unavailable(name: instance.name, reason: "its recipe is broken (\(error))")
            }
            throw ServiceError.initialiseFailed(name: instance.name, output: error.localizedDescription)
        }
    }

    /// Runs one step through the bounded runner; its output goes to the service's log too.
    private func runStep(_ step: RecipeCommand, instance: ServiceInstance, recipe: ServiceRecipe,
                         context: ServiceTemplateContext) throws {
        let command = try ServiceTemplate.render(step, context: context)
        let outcome: ServiceStepRunner.Outcome
        do {
            outcome = try ServiceStepRunner.run(
                executable: command.executable, arguments: command.arguments,
                environment: Self.baseEnvironment(context).merging(command.environment) { $1 },
                directory: paths.serviceHome(instance.id), stdin: command.stdin, timeout: recipe.initialiseTimeout,
                isCancelled: { [weak self] in self?.isCancelled ?? true })
        } catch {
            throw ServiceError.initialiseFailed(name: instance.name,
                                                output: "\(command.executable) could not be run: \(error.localizedDescription)")
        }
        appendToLog(instance.id, Data(outcome.output.utf8))
        switch outcome.end {
        case .exited(0): return
        case .exited:
            throw ServiceError.initialiseFailed(name: instance.name, output: Self.lastLines(outcome.output, 30))
        case .timedOut:
            throw ServiceError.initialiseTimedOut(name: instance.name, seconds: Int(recipe.initialiseTimeout),
                                                  output: Self.lastLines(outcome.output, 30))
        case .cancelled:
            throw ServiceError.cancelled(name: instance.name)
        }
    }

    /// What every service program and step starts from; the recipe's own environment comes on top. Nothing
    /// of the daemon's environment (and no `PADDOCK_*` variable) reaches a service.
    static func baseEnvironment(_ context: ServiceTemplateContext) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": context.data, "TMPDIR": context.run,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    }

    // MARK: - Updating

    /// Downloads the newest version of the instance's series (or its own version again, if its binaries
    /// are gone) and switches to it: stops it, starts the new one, and only once that is ready records the
    /// new version and deletes the old binaries (unless another instance uses them). If the new one doesn't
    /// start, the old one is started again and `updateFailed` says so. Returns the instance as it is now;
    /// unchanged when it was up to date.
    public func update(_ name: String) async throws -> ServiceInstance {
        let result: Result<ServiceInstance, Error> = await adds.withLock {
            do { return .success(try await self.updateOne(name)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func updateOne(_ name: String) async throws -> ServiceInstance {
        let instance = try find(name)
        guard let latest = latest(instance) else {
            throw ServiceError.unavailable(name: instance.name,
                                           reason: "this copy of Paddock offers no \(instance.kind) \(instance.series)")
        }
        if installedRecipe(instance) != nil, !ServiceCatalog.isNewer(latest.version, than: instance.version) {
            return instance
        }
        do {
            try await installer.install(latest)
        } catch is CancellationError {
            throw ServiceError.cancelled(name: instance.name)
        } catch let error as ServiceInstallError {
            throw ServiceError.installFailed(name: instance.name, reason: error)
        }
        if Task.isCancelled { throw ServiceError.cancelled(name: instance.name) }
        return try await Self.offPool {
            self.operationLock.lock()
            defer { self.operationLock.unlock() }
            let current = try self.find(instance.id)
            self.stopLocked(current.id)
            if let error = self.startOne(current, forcing: latest) { throw error }
            return try self.find(instance.id)
        }
    }

    // MARK: - Running

    /// Starts an added service and waits until it is ready. Does nothing if it is running.
    public func start(_ name: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let instance = try find(name)
        if let error = startOne(instance) { throw error }
    }

    public func stop(_ name: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let instance = try? find(name) else { return }
        stopLocked(instance.id)
    }

    public func restart(_ name: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let instance = try find(name)
        stopLocked(instance.id)
        if let error = startOne(instance) { throw error }
    }

    /// At daemon start: stops what an earlier Paddock left running (only processes it can prove are its own),
    /// then starts every service whose "start with Paddock" is on, side by side; one that can't start (its
    /// port taken, say) is reported in its status and the log, and the others start anyway.
    public func startAutostart() {
        operationLock.lock()
        defer { operationLock.unlock() }
        let all = instances()
        for instance in all { reclaimOrphan(instance) }
        let wanted = all.filter(\.autostart)
        var errors = [ServiceError?](repeating: nil, count: wanted.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
            let error = startOne(wanted[index])
            lock.lock()
            errors[index] = error
            lock.unlock()
        }
        for (instance, error) in zip(wanted, errors) {
            if let error { log("service \(instance.id) did not start: \(Messages.serviceError(error))") }
        }
    }

    /// Stops every service, each with its own signal; for the daemon's exit.
    public func stopAll() {
        operationLock.lock()
        defer { operationLock.unlock() }
        supervisor.stopAll()
        for instance in instances() { removePIDRecord(instance.id) }
        runtimeLock.lock()
        for id in runtime.keys { runtime[id] = .stopped }
        notices = [:]
        cancelled = false
        runtimeLock.unlock()
    }

    /// Makes readiness waits and initialise steps in progress give up, so shutting down never waits for one.
    func cancelPendingWork() {
        runtimeLock.lock()
        cancelled = true
        runtimeLock.unlock()
    }

    private var isCancelled: Bool {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return cancelled
    }

    /// Stops it, forgets it and deletes its `config/` and run folder. Its data stays unless `deleteData`.
    /// Returns where its data is (or was).
    public func remove(_ name: String, deleteData: Bool) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        let instance = try find(name)
        stopLocked(instance.id)
        try store.update { $0.services.removeAll { $0.id == instance.id } }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.serviceConfig(instance.id))
        try? fm.removeItem(at: paths.serviceRun(instance.id))
        if deleteData, fm.fileExists(atPath: paths.serviceHome(instance.id).path) {
            try fm.removeItem(at: paths.serviceHome(instance.id))
        }
        runtimeLock.lock()
        runtime[instance.id] = nil
        notices[instance.id] = nil
        runtimeLock.unlock()
        return paths.serviceData(instance.id)
    }

    private func stopLocked(_ id: String) {
        stopProcess(id)
        setRuntime(.stopped, for: id)
        setNotice(nil, for: id)
    }

    private func stopProcess(_ id: String) {
        supervisor.stop(Self.processName(id))
        removePIDRecord(id)
    }

    /// Starts one instance and waits until it is ready. Takes the newest patch of its series first when that
    /// is installed or its files are on this Mac (never downloading); `forcing` (from `update`) names the
    /// recipe to switch to. A new version that fails to start gives way to the old one again.
    private func startOne(_ instance: ServiceInstance, forcing: ServiceRecipe? = nil) -> ServiceError? {
        let id = instance.id
        if forcing == nil, case .running = supervisor.status(Self.processName(id)) {
            setRuntime(.running, for: id)
            return nil
        }
        reclaimOrphan(instance)
        let current = installedRecipe(instance)
        var target = forcing ?? current
        if forcing == nil, let latest = latest(instance),
           current == nil || ServiceCatalog.isNewer(latest.version, than: instance.version),
           installer.isInstalled(latest) || installer.isLocallyAvailable(latest) {
            installLock.lock()
            do {
                try installer.installLocally(latest)
                target = latest
            } catch {
                log("could not install \(latest.kind) \(latest.version) from this Mac: \(error)")
            }
            installLock.unlock()
        }
        guard let target else {
            let reason = latest(instance) == nil
                ? "this copy of Paddock no longer offers \(instance.kind) \(instance.series), and its programs are gone"
                : "its programs are missing; download them with: paddock service update \(instance.id)"
            setRuntime(.unavailable(reason: reason), for: id)
            return .unavailable(name: instance.name, reason: reason)
        }

        guard let failure = launch(instance, target) else {
            if target.version != instance.version { commitVersion(instance, to: target) }
            return nil
        }
        // A new version that didn't start: the old one again.
        guard target.version != instance.version, let current, shouldFallBack(after: failure) else { return failure }
        let failedLog = Self.lastLines(logTail(id), 20)
        if let again = launch(instance, current) { return again }
        let error = ServiceError.updateFailed(name: instance.name, version: target.version,
                                              previous: current.version, log: failedLog)
        if forcing != nil { return error }
        let notice = Messages.serviceError(error)
        setNotice(notice, for: id)
        log(notice)
        return nil
    }

    /// Port and data problems aren't the new version's fault: no point starting the old one.
    private func shouldFallBack(after failure: ServiceError) -> Bool {
        switch failure {
        case .portInUse, .dataMismatch: return false
        default: return true
        }
    }

    /// Records the new version once it runs, and deletes the old binaries if no instance uses them.
    private func commitVersion(_ instance: ServiceInstance, to recipe: ServiceRecipe) {
        let old = instance.version
        do {
            try store.update { state in
                state.services = state.services.map { saved in
                    guard saved.id == instance.id else { return saved }
                    var updated = saved
                    updated.version = recipe.version
                    updated.series = recipe.series
                    return updated
                }
            }
        } catch {
            log("could not record \(instance.id) running \(recipe.version): \(error.localizedDescription)")
            return
        }
        log("\(instance.name) now runs \(recipe.kind) \(recipe.version)")
        if !instances().contains(where: { $0.kind == instance.kind && $0.version == old }) {
            installer.remove(kind: instance.kind, version: old)
        }
    }

    /// Checks, starts and waits for one version of an instance. Nil once it is ready and listening on this
    /// Mac only.
    private func launch(_ instance: ServiceInstance, _ recipe: ServiceRecipe) -> ServiceError? {
        let id = instance.id
        if let mismatch = dataMismatch(instance, recipe) {
            if case .dataMismatch(_, let found, let expected) = mismatch {
                setRuntime(.unavailable(reason: "its data is from \(found), not \(expected)"), for: id)
            }
            return mismatch
        }
        let held = portCheck.holders(instance.ports.values.sorted())
        if let port = held.first?.port {
            let holder = Messages.portHolder(held.filter { $0.port == port })
            setRuntime(.portInUse(holder: holder), for: id)
            return .portInUse(name: instance.name, port: port, holder: holder)
        }
        do {
            let context = try self.context(instance, recipe: recipe)
            let command = try ServiceTemplate.render(recipe.start, context: context)
            let files = try recipe.configFiles.map { try ServiceTemplate.render($0.contents, context: context) }
            let texts = [command.executable] + command.arguments + Array(command.environment.values)
                + files.flatMap { $0.components(separatedBy: .newlines) }
            if let wildcard = texts.lazy.compactMap(ServiceLoopback.wildcard(in:)).first {
                throw ServiceError.unavailable(name: instance.name,
                                               reason: "its recipe would listen on \(wildcard), not only on this Mac")
            }
            try ensureFolders(id)
            try writeConfigFiles(recipe, context: context, id: id)
            if let socket = context.socket { Self.removeStaleSocket(socket, inside: paths.serviceRun(id)) }
            let record = paths.serviceRun(id).appendingPathComponent(Self.pidFileName)
            try supervisor.start(ProcessSpec(
                name: Self.processName(id), executable: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                environment: Self.baseEnvironment(context).merging(command.environment) { $1 },
                logFile: paths.serviceLog(id), stopSignal: recipe.signalNumber,
                stopGrace: TimeInterval(recipe.stopGraceSeconds), inheritsEnvironment: false,
                didSpawn: { pid in try? ServiceProcessRecord.live(pid: pid)?.write(to: record) }))
            setRuntime(.starting, for: id)
            let target = try ServiceTemplate.render(recipe.ready.template, context: context)
            guard waitUntilReady(Self.processName(id), recipe.ready, target,
                                 timeout: readyTimeout ?? recipe.readyTimeout) else {
                stopProcess(id)
                setRuntime(.crashed, for: id)
                return .notReady(name: instance.name, log: Self.lastLines(logTail(id), 20))
            }
            if case .running(let pid) = supervisor.status(Self.processName(id)),
               let address = nonLoopbackListener(processGroup: pid) {
                stopProcess(id)
                setRuntime(.crashed, for: id)
                return .notLoopback(name: instance.name, address: address)
            }
            writeDataVersion(instance, recipe)
            setRuntime(.running, for: id)
            return nil
        } catch {
            stopProcess(id)
            if let error = error as? ServiceError, case .unavailable(_, let reason) = error {
                setRuntime(.unavailable(reason: reason), for: id)
                return error
            }
            setRuntime(.crashed, for: id)
            let reason = error is SupervisorError ? "\(recipe.start.executable) could not be run" : "\(error)"
            return .notReady(name: instance.name, log: reason)
        }
    }

    /// Polls the readiness probe until it passes, the process exits, the deadline passes, or shutting
    /// down cancels the wait.
    private func waitUntilReady(_ process: String, _ readiness: Readiness, _ target: String,
                                timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled { return false }
            guard case .running = supervisor.status(process) else { return false }
            if ServiceReadiness.probe(readiness, rendered: target) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// The first TCP listener of the process group that isn't on 127.0.0.1 or [::1] (`lsof`, at most 5
    /// seconds). A recipe can forget a bind flag (MySQL and Redis listen everywhere by default); this catches
    /// it on the real process. If `lsof` can't answer, the service is let through and that is logged.
    private func nonLoopbackListener(processGroup: Int32) -> String? {
        let result: (status: Int32, output: String)
        do {
            result = try runner.run("/usr/sbin/lsof", ["-a", "-g", "\(processGroup)", "-iTCP", "-sTCP:LISTEN",
                                                       "-nP", "-F", "n"], environment: nil, timeout: 5)
        } catch {
            log("could not check where process group \(processGroup) listens: \(error)")
            return nil
        }
        for line in result.output.split(separator: "\n") where line.hasPrefix("n") {
            let address = String(line.dropFirst())
            guard let colon = address.lastIndex(of: ":") else { continue }
            let host = address[..<colon]
            if host != "127.0.0.1" && host != "[::1]" { return Messages.printable(address) ?? address }
        }
        return nil
    }

    // MARK: - Orphans

    /// If the instance's pid record names a live process that is provably the one Paddock started (same pid,
    /// group and start time, a program under that kind's binaries or Paddock's PHP), it was left behind by a
    /// daemon that died: stop it (the recipe's signal to its group, grace, then SIGKILL) and wait for its
    /// ports. Any other record is stale and removed. Nothing that fails a check is ever signalled.
    private func reclaimOrphan(_ instance: ServiceInstance) {
        let file = paths.serviceRun(instance.id).appendingPathComponent(Self.pidFileName)
        guard let record = ServiceProcessRecord.read(from: file) else { return }
        if case .running(let pid) = supervisor.status(Self.processName(instance.id)), pid == record.pid { return }
        let kindBinaries = paths.serviceBin(kind: instance.kind, version: "-").deletingLastPathComponent().path
        if record.isOurLiveProcess(allowedDirectories: [kindBinaries, paths.phpRoot.path]) {
            let recipe = describingRecipe(instance)
            log("stopping \(instance.name) (pid \(record.pid)), left running by an earlier Paddock")
            record.stopGroup(signal: recipe?.signalNumber ?? SIGTERM, grace: TimeInterval(recipe?.stopGraceSeconds ?? 10))
            let deadline = Date().addingTimeInterval(5)
            while instance.ports.values.contains(where: { !portCheck.isFree($0) }) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func removePIDRecord(_ id: String) {
        try? FileManager.default.removeItem(at: paths.serviceRun(id).appendingPathComponent(Self.pidFileName))
    }

    // MARK: - The data's version

    private struct DataVersion: Codable {
        let kind: String
        let series: String
        let version: String
    }

    private func dataVersionFile(_ id: String) -> URL {
        paths.serviceHome(id).appendingPathComponent(Self.dataVersionFileName)
    }

    /// Records which kind, series and version last ran on the instance's data.
    private func writeDataVersion(_ instance: ServiceInstance, _ recipe: ServiceRecipe) {
        let record = DataVersion(kind: recipe.kind, series: recipe.series, version: recipe.version)
        try? JSONEncoder().encode(record).write(to: dataVersionFile(instance.id), options: .atomic)
    }

    /// `dataMismatch` when the instance's data was last used by another kind or series than `recipe`.
    private func dataMismatch(_ instance: ServiceInstance, _ recipe: ServiceRecipe) -> ServiceError? {
        guard let data = try? Data(contentsOf: dataVersionFile(instance.id)),
              let found = try? JSONDecoder().decode(DataVersion.self, from: data) else { return nil }
        guard found.kind != recipe.kind || found.series != recipe.series else { return nil }
        return .dataMismatch(name: instance.name, found: "\(found.kind) \(found.version)",
                             expected: "\(recipe.kind) \(recipe.series)")
    }

    // MARK: - Reporting

    /// Every added service and its last known state. Never waits for a change in progress.
    public func statuses() -> [ServiceStatus] {
        instances().map(status(of:))
    }

    /// The catalog as clients see it, saying which series would download when added.
    public func catalogEntries() -> [CatalogEntry] {
        catalog.kinds(needsDownload: { [installer] recipe in
            !recipe.assets.isEmpty && !installer.isInstalled(recipe) && !installer.isLocallyAvailable(recipe)
        })
    }

    /// The `.env` lines of an added service.
    public func env(_ name: String) throws -> [String] {
        let instance = try find(name)
        guard let recipe = describingRecipe(instance) else {
            throw ServiceError.unavailable(name: instance.name, reason: "Paddock no longer knows how to run it")
        }
        return envLines(recipe, context: try context(instance, recipe: recipe))
    }

    /// Each service process the supervisor runs -> its status, as in `EngineStatus.processes`.
    public var processes: [String: String] {
        var result: [String: String] = [:]
        for name in supervisor.names { result[name] = supervisor.status(name).description }
        return result
    }

    private func status(of instance: ServiceInstance) -> ServiceStatus {
        let recipe = describingRecipe(instance)
        let latest = latest(instance)
        let context = recipe.flatMap { try? self.context(instance, recipe: $0) }
        let env = recipe.flatMap { recipe in context.map { envLines(recipe, context: $0) } } ?? []
        let openURL = recipe?.openURL.flatMap { template in context.flatMap { try? ServiceTemplate.render(template, context: $0) } }
        runtimeLock.lock()
        let known = runtime[instance.id]
        let notice = notices[instance.id]
        runtimeLock.unlock()
        let state: ServiceState
        if known == .starting {
            state = .starting
        } else {
            switch supervisor.status(Self.processName(instance.id)) {
            case .running: state = .running
            case .crashed: state = .crashed
            case .stopped:
                if let known, known != .running {
                    state = known
                } else if installedRecipe(instance) == nil && latest == nil {
                    state = .unavailable(reason: "this copy of Paddock no longer offers \(instance.kind) "
                                         + "\(instance.series), and its programs are gone")
                } else {
                    state = .stopped
                }
            }
        }
        let update = latest.flatMap { ServiceCatalog.isNewer($0.version, than: instance.version) ? $0.version : nil }
        return ServiceStatus(
            id: instance.id, name: instance.name, kind: instance.kind, version: instance.version,
            displayName: recipe?.displayName ?? instance.kind, state: state, ports: instance.ports, env: env,
            openURL: openURL, dataPath: paths.serviceData(instance.id).path, autostart: instance.autostart,
            mainPort: recipe?.ports.first.flatMap { instance.ports[$0.name] }, notice: notice,
            updateAvailable: update, series: instance.series)
    }

    // MARK: - Templates and folders

    /// The template values for an instance. `{socket}` is empty when the recipe has no socket or its path
    /// would be too long for macOS; the service then runs on TCP only.
    func context(_ instance: ServiceInstance, recipe: ServiceRecipe) throws -> ServiceTemplateContext {
        var context = ServiceTemplateContext(
            bin: paths.serviceBin(kind: recipe.kind, version: recipe.version).path,
            data: paths.serviceData(instance.id).path, config: paths.serviceConfig(instance.id).path,
            run: paths.serviceRun(instance.id).path, log: paths.serviceLog(instance.id).path,
            name: instance.name, id: instance.id, ports: instance.ports, socket: nil, php: phpBinary()?.path,
            resources: resources.path)
        if let template = recipe.socket {
            let path = try ServiceTemplate.render(template, context: context)
            if !path.isEmpty, path.utf8.count <= Self.maximumSocketPath { context.socket = path }
        }
        return context
    }

    /// The recipe's `.env` lines; without a usable socket, those naming it give way to one comment line.
    private func envLines(_ recipe: ServiceRecipe, context: ServiceTemplateContext) -> [String] {
        let socketDisabled = recipe.socket != nil && context.socket == nil
        var lines = recipe.env.filter { !(socketDisabled && ServiceTemplate.mentionsSocket($0)) }
            .compactMap { try? ServiceTemplate.render($0, context: context) }
        if socketDisabled { lines.append(Messages.unixSocketDisabled) }
        return lines
    }

    /// Writes the recipe's config files (each only inside the instance's `config/`).
    private func writeConfigFiles(_ recipe: ServiceRecipe, context: ServiceTemplateContext, id: String) throws {
        let config = paths.serviceConfig(id).standardizedFileURL
        for file in recipe.configFiles {
            let target = URL(fileURLWithPath: try ServiceTemplate.render(file.path, context: context)).standardizedFileURL
            guard target.path.hasPrefix(config.path + "/") else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try ServiceTemplate.render(file.contents, context: context).utf8).write(to: target, options: .atomic)
        }
    }

    /// Unlinks a leftover Unix socket before a start: only a socket, and only inside the instance's run
    /// folder. A folder, a regular file or anything elsewhere is left alone.
    static func removeStaleSocket(_ path: String, inside run: URL) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(run.standardizedFileURL.path + "/") else { return }
        var info = stat()
        guard lstat(standardized, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(standardized)
    }

    /// `run/svc/<id>`, owner-only like the rest of `run/`.
    private func ensureRunFolder(_ id: String) throws {
        let fm = FileManager.default
        let svc = paths.serviceRun(id).deletingLastPathComponent()
        for folder in [paths.run, svc, paths.serviceRun(id)] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    private func ensureFolders(_ id: String) throws {
        let fm = FileManager.default
        for folder in [paths.serviceData(id), paths.serviceConfig(id), paths.log] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try ensureRunFolder(id)
    }

    private func setRuntime(_ state: ServiceState, for id: String) {
        runtimeLock.lock()
        runtime[id] = state
        runtimeLock.unlock()
    }

    private func setNotice(_ notice: String?, for id: String) {
        runtimeLock.lock()
        notices[id] = notice
        runtimeLock.unlock()
    }

    private func appendToLog(_ id: String, _ data: Data) {
        let file = paths.serviceLog(id)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The last 64 KB of a service's log.
    func logTail(_ id: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: paths.serviceLog(id)) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
            .suffix(count).joined(separator: "\n")
    }

    /// Runs blocking work off the cooperative thread pool.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
        }
    }
}
