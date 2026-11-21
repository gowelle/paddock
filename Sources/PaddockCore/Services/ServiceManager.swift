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
    /// The new version didn't start (`newFailure`), and the previous one didn't start again either
    /// (`oldFailure`): the new one may have upgraded the data.
    case rollbackFailed(name: String, id: String, version: String, previous: String, newFailure: String,
                        oldFailure: String)
    /// What the recipe renders to would run a program, or use a path, outside the service's own folders.
    case unsafeRecipe(name: String, reason: String)
    case unavailable(name: String, reason: String)
    /// Paddock began shutting down while the service was being added or updated.
    case cancelled(name: String)
    /// Its binaries need a newer macOS than this Mac runs (`minimum`, as the recipe says it).
    case needsNewerMacOS(name: String, minimum: String)
    /// Its recipe has no such action (`RecipeAction.names`).
    case noAction(name: String, action: String)
    /// The action ran and failed; `output` is what it printed.
    case actionFailed(name: String, action: String, output: String)
    /// A value given for an action's parameter isn't one Paddock accepts.
    case invalidParameter(parameter: String, value: String)
    /// The request needs the service running.
    case notRunning(name: String, id: String)
    /// The action was stopped because the service stopped or Paddock is shutting down.
    case actionCancelled(name: String, action: String)
}

/// How an action ended when it didn't fail.
public enum ServiceActionResult: Equatable, Sendable {
    case done
    /// It had nothing to do (the database was there already).
    case alreadyDone
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
    /// Seconds after readiness at which the loopback check runs again, for listeners opened late.
    private let lateLoopbackChecks: [TimeInterval]
    /// The macOS this runs on (tests pretend to be older).
    private let macOSVersion: OperatingSystemVersion
    /// What a lock file's process is (tests pretend macOS won't say).
    private let processInspector: ServiceProcessInspector
    private let log: @Sendable (String) -> Void

    private let operationLock = NSLock()
    private let adds = AsyncMutex()
    /// Serializes installs from local files (starts of several instances run side by side).
    private let installLock = NSLock()
    /// Guards `runtime`, `notices`, `cancelled` and `reported`; held only for an instant.
    private let runtimeLock = NSLock()
    /// What the manager last saw each instance do. The supervisor's own status refines it.
    private var runtime: [String: ServiceState] = [:]
    /// A sentence about an instance's last add or update, until it is stopped.
    private var notices: [String: String] = [:]
    /// Set while shutting down: readiness waits and initialise steps give up at once.
    private var cancelled = false
    /// Problems already logged (one line each): invalid saved instances, invalid stored recipes.
    private var reported: Set<String> = []
    /// Called (tests) right after a service's process was started, before its readiness is checked.
    var processStartedForTesting: (@Sendable (String) -> Void)?
    /// Actions running now, by instance id (`runtimeLock`).
    private var inFlight: [String: [ActionFlight]] = [:]

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
                lateLoopbackChecks: [TimeInterval] = [5, 30],
                macOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                processInspector: ServiceProcessInspector = .live,
                installerWillSwap: (@Sendable (URL) -> Void)? = nil,
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
        installer = ServiceInstaller(paths: paths, downloader: downloader, environment: environment,
                                     willSwap: installerWillSwap)
        self.portCheck = portCheck
        self.phpBinary = phpBinary
        self.portBase = portBase
        self.readyTimeout = readyTimeout
        self.resources = resources
        self.runner = runner
        self.lateLoopbackChecks = lateLoopbackChecks
        self.macOSVersion = macOSVersion
        self.processInspector = processInspector
    }

    // MARK: - Actions

    /// Creates `database` in a running service with its recipe's `createDatabase` action. The name is
    /// checked here (`isValidDatabaseName`) and against the recipe's own pattern before anything runs; a
    /// database already there is `.alreadyDone`, not an error. The command runs outside the change lock:
    /// stopping, removing or updating the service, or shutting down, cancels it instead of waiting for it.
    public func createDatabase(_ name: String, database: String) throws -> ServiceActionResult {
        guard Self.isValidDatabaseName(database) else {
            throw ServiceError.invalidParameter(parameter: "database", value: database)
        }
        operationLock.lock()
        let prepared: PreparedAction
        do {
            prepared = try prepare(RecipeAction.createDatabase, on: try find(name), parameters: ["database": database])
        } catch {
            operationLock.unlock()
            throw error
        }
        operationLock.unlock()
        defer { finish(prepared) }
        return try run(prepared)
    }

    /// 1 to 63 ASCII letters, digits and underscores (PostgreSQL's limit; fine for MySQL too).
    public static func isValidDatabaseName(_ name: String) -> Bool {
        (1...63).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    /// An action ready to run: everything checked and rendered while the change lock was held.
    private struct PreparedAction {
        let name: String
        let instance: ServiceInstance
        let recipe: ServiceRecipe
        let action: RecipeAction
        let command: RenderedCommand
        let context: ServiceTemplateContext
        let probe: ReadyProbe
        let flight: ActionFlight
    }

    /// Resolves one of the recipe's actions for a running instance (the caller holds `operationLock`): every
    /// parameter the action declares must be given and match its pattern (and never start with `-` or hold a
    /// control character); no other value is bound. The command is rendered and checked like every other,
    /// and the action is recorded as in flight, so a stop of the instance or a shutdown can cancel it.
    private func prepare(_ actionName: String, on instance: ServiceInstance,
                         parameters: [String: String]) throws -> PreparedAction {
        guard let recipe = installedRecipe(instance) else {
            throw ServiceError.unavailable(name: instance.name, reason: nothingToRun(instance))
        }
        guard let action = recipe.actions[actionName] else {
            throw ServiceError.noAction(name: instance.name, action: actionName)
        }
        var bound: [String: String] = [:]
        for parameter in action.parameters {
            let value = parameters[parameter.name] ?? ""
            guard Self.isAcceptableParameter(value), Self.wholly(value, matches: parameter.pattern) else {
                throw ServiceError.invalidParameter(parameter: parameter.name, value: value)
            }
            bound[parameter.name] = value
        }
        guard case .running = supervisor.status(Self.processName(instance.id)) else {
            throw ServiceError.notRunning(name: instance.name, id: instance.id)
        }
        var context = try self.context(instance, recipe: recipe)
        context.parameters = bound
        let command = try ServiceTemplate.render(action.command, context: context)
        try checkRendered(command, template: action.command, instance: instance, recipe: recipe)
        let probe = try makeProbe(instance, recipe, context: context)
        let flight = ActionFlight()
        runtimeLock.lock()
        inFlight[instance.id, default: []].append(flight)
        runtimeLock.unlock()
        return PreparedAction(name: actionName, instance: instance, recipe: recipe, action: action, command: command,
                              context: context, probe: probe, flight: flight)
    }

    /// Runs a prepared action without the change lock: waits until the service is ready (a postmaster in
    /// crash recovery accepts connections before it accepts queries), then runs the command through the
    /// bounded step runner in the instance's folder; its output goes to the service's log.
    private func run(_ prepared: PreparedAction) throws -> ServiceActionResult {
        let instance = prepared.instance
        let flight = prepared.flight
        let cancelled = { [weak self] in flight.isCancelled || (self?.isCancelled ?? true) }
        let failed = { (output: String) in
            ServiceError.actionFailed(name: instance.name, action: prepared.name, output: output)
        }
        guard waitUntilReady(Self.processName(instance.id), prepared.probe,
                             timeout: readyTimeout ?? prepared.recipe.readyTimeout, isCancelled: cancelled) else {
            if cancelled() { throw ServiceError.actionCancelled(name: instance.name, action: prepared.name) }
            throw ServiceError.unavailable(name: instance.name, reason: "it isn't ready to accept connections")
        }
        let outcome = try runRendered(prepared.command, id: instance.id, context: prepared.context,
                                      timeout: prepared.action.timeout, isCancelled: cancelled, couldNotRun: failed)
        switch outcome.end {
        case .exited(0):
            return .done
        case .exited:
            if let marker = try prepared.action.alreadyDone.map({ try ServiceTemplate.render($0, context: prepared.context) }),
               !marker.isEmpty, outcome.output.contains(marker) {
                return .alreadyDone
            }
            if cancelled() { throw ServiceError.actionCancelled(name: instance.name, action: prepared.name) }
            throw failed(Self.lastLines(outcome.output, 30))
        case .timedOut:
            throw failed("It took longer than \(Int(prepared.action.timeout)) seconds, so Paddock stopped it.\n"
                         + Self.lastLines(outcome.output, 30))
        case .cancelled:
            throw ServiceError.actionCancelled(name: instance.name, action: prepared.name)
        }
    }

    private func finish(_ prepared: PreparedAction) {
        runtimeLock.lock()
        inFlight[prepared.instance.id]?.removeAll { $0 === prepared.flight }
        if inFlight[prepared.instance.id]?.isEmpty == true { inFlight[prepared.instance.id] = nil }
        runtimeLock.unlock()
        prepared.flight.done()
    }

    /// Cancels the actions in flight for `id` (every instance when nil) and waits, briefly, until they end.
    private func cancelActions(of id: String?) {
        runtimeLock.lock()
        let flights = id.map { inFlight[$0] ?? [] } ?? inFlight.values.flatMap { $0 }
        runtimeLock.unlock()
        for flight in flights { flight.cancel() }
        for flight in flights { flight.wait(timeout: 10) }
    }

    /// Not empty, not an option (`-h`), no control characters: whatever a recipe's pattern allows.
    static func isAcceptableParameter(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{7F}" }
    }

    /// Whether the whole of `value` matches `pattern` (never just a part, nor up to a trailing newline).
    static func wholly(_ value: String, matches pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: whole)?.range == whole
    }

    /// `15.0` -> [15, 0]; nil unless it is one to three numbers joined by dots.
    static func versionNumbers(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    /// Whether this Mac's macOS is at least `minimum` (a recipe's `minimumMacOS`).
    private func runsOn(minimum: String) -> Bool {
        guard let wanted = Self.versionNumbers(minimum) else { return false }
        let have = [macOSVersion.majorVersion, macOSVersion.minorVersion, macOSVersion.patchVersion]
        for (index, number) in wanted.enumerated() where have[index] != number { return have[index] > number }
        return true
    }

    static func processName(_ id: String) -> String { "service-\(id)" }

    // MARK: - Instances

    /// The saved instances Paddock may act on: an id, kind, version, series or name read back from
    /// `state.json` that isn't one Paddock makes is ignored (and logged once), never used to build a path or
    /// shown. A missing series is filled in from the catalog.
    func instances() -> [ServiceInstance] {
        store.load().services.compactMap { instance in
            guard Self.isSafe(instance) else {
                reportOnce("instance:\(instance.id)", "ignoring the saved service \"\(Messages.printable(instance.id) ?? "?")\": "
                           + "its name isn't one Paddock makes")
                return nil
            }
            return withSeries(instance)
        }
    }

    private static func isSafe(_ instance: ServiceInstance) -> Bool {
        ServiceInstance.isValidID(instance.id) && ServiceInstance.isValidID(instance.kind)
            && ServiceCatalog.isSafeName(instance.version)
            && (instance.series.isEmpty || ServiceCatalog.isSafeName(instance.series))
            && ServiceInstance.isValidName(instance.name)
            && (instance.skippedVersion.map(ServiceCatalog.isSafeName) ?? true)
    }

    private func reportOnce(_ key: String, _ message: String) {
        runtimeLock.lock()
        let first = reported.insert(key).inserted
        runtimeLock.unlock()
        if first { log(message) }
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

    /// The recipe the instance's installed binaries run with. The catalog's recipe of exactly that version
    /// comes first when its downloads are exactly the installed ones (the same build, described anew: lock
    /// files, readiness, notes; or an install made before recipes were stored), so later catalog changes
    /// don't strand the instance. Otherwise the stored one, validated; an invalid stored recipe is never
    /// used (and logged once). Nil when there is nothing safe to run. Reading (status, env) only computes it;
    /// a start, holding the change lock, passes `storing` to keep the stored description up to date.
    private func installedRecipe(_ instance: ServiceInstance, storing: Bool = false) -> ServiceRecipe? {
        let stored = installer.storedRecipe(kind: instance.kind, version: instance.version)
        if case .invalid(let reason) = stored {
            reportOnce("recipe:\(instance.kind)/\(instance.version)",
                       "not using the stored recipe of \(instance.kind) \(instance.version): \(reason)")
        }
        if let recipe = catalog.recipes(of: instance.kind).first(where: { $0.version == instance.version }),
           installer.isInstalled(recipe) {
            if storing, stored != .valid(recipe) {
                do { try installer.storeRecipe(recipe) } catch {
                    log("could not store the recipe of \(recipe.kind) \(recipe.version): \(error.localizedDescription)")
                }
            }
            return recipe
        }
        if case .valid(let recipe) = stored { return recipe }
        return nil
    }

    /// Why an instance has nothing to run.
    private func nothingToRun(_ instance: ServiceInstance) -> String {
        if installer.hasInstall(kind: instance.kind, version: instance.version) {
            return "the stored recipe of \(instance.kind) \(instance.version) isn't valid, and this copy of Paddock "
                + "doesn't offer that version"
        }
        return latest(instance) == nil
            ? "this copy of Paddock no longer offers \(instance.kind) \(instance.series), and its programs are gone"
            : "its programs are missing; download them with: paddock service update \(instance.id)"
    }

    /// The recipe that describes the instance for status, env and open: what it runs, else the catalog's.
    private func describingRecipe(_ instance: ServiceInstance) -> ServiceRecipe? {
        installedRecipe(instance) ?? latest(instance)
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
        // An instance saved under a name Paddock wouldn't use would be ignored from then on: refuse it now.
        guard ServiceInstance.isValidID(identity.id), ServiceInstance.isValidName(identity.name) else {
            throw ServiceError.unavailable(name: recipe.displayName, reason: "its catalog entry would give it an unusable name")
        }
        if let minimum = recipe.minimumMacOS, !runsOn(minimum: minimum) {
            throw ServiceError.needsNewerMacOS(name: identity.name, minimum: minimum)
        }
        if recipe.needsPHP && phpBinary() == nil {
            throw ServiceError.unavailable(name: identity.name, reason: Self.noPHP)
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
            try ensureSecrets(instance, recipe)
            let context = try self.context(instance, recipe: recipe)
            try writeConfigFiles(recipe, context: context, id: instance.id)
            if dataExisted {
                let notice = Messages.existingServiceData(instance.name)
                setNotice(notice, for: instance.id)
                log(notice)
            } else {
                for step in recipe.initialise { try runStep(step, instance: instance, recipe: recipe, context: context) }
                // Data that never becomes ready still says which series made it.
                writeDataVersion(instance, recipe)
            }
            try store.update { $0.services.append(instance) }
        } catch {
            for folder in created.reversed() { try? fm.removeItem(at: folder) }
            try? fm.removeItem(at: paths.serviceRun(instance.id))
            setNotice(nil, for: instance.id)
            if let error = error as? ServiceError { throw error }
            if error as? TemplateError == .unavailable("php") {
                throw ServiceError.unavailable(name: instance.name, reason: Self.noPHP)
            }
            if let error = error as? TemplateError {
                throw ServiceError.unavailable(name: instance.name, reason: "its recipe is broken (\(error))")
            }
            throw ServiceError.initialiseFailed(name: instance.name, output: error.localizedDescription)
        }
    }

    /// Runs one initialise step through the bounded runner; its output goes to the service's log too.
    private func runStep(_ step: RecipeCommand, instance: ServiceInstance, recipe: ServiceRecipe,
                         context: ServiceTemplateContext) throws {
        let outcome = try runBounded(step, instance: instance, recipe: recipe, context: context,
                                     timeout: recipe.initialiseTimeout,
                                     couldNotRun: { ServiceError.initialiseFailed(name: instance.name, output: $0) })
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

    /// Renders and checks one initialise step and runs it (`runRendered`).
    private func runBounded(_ step: RecipeCommand, instance: ServiceInstance, recipe: ServiceRecipe,
                            context: ServiceTemplateContext, timeout: TimeInterval,
                            couldNotRun: (String) -> ServiceError) throws -> ServiceStepRunner.Outcome {
        let command = try ServiceTemplate.render(step, context: context)
        try checkRendered(command, template: step, instance: instance, recipe: recipe)
        return try runRendered(command, id: instance.id, context: context, timeout: timeout,
                               isCancelled: { [weak self] in self?.isCancelled ?? true }, couldNotRun: couldNotRun)
    }

    /// Runs a rendered, checked command through the bounded step runner in the instance's folder, with the
    /// service environment; its output goes to the service's log. A program that can't be run at all is
    /// `couldNotRun`.
    private func runRendered(_ command: RenderedCommand, id: String, context: ServiceTemplateContext,
                             timeout: TimeInterval, isCancelled: @escaping () -> Bool,
                             couldNotRun: (String) -> ServiceError) throws -> ServiceStepRunner.Outcome {
        let outcome: ServiceStepRunner.Outcome
        do {
            outcome = try ServiceStepRunner.run(
                executable: command.executable, arguments: command.arguments,
                environment: environment(for: command, context: context, id: id),
                directory: paths.serviceHome(id), stdin: command.stdin, timeout: timeout, isCancelled: isCancelled)
        } catch {
            throw couldNotRun("\(command.executable) could not be run: \(error.localizedDescription)")
        }
        appendToLog(id, Data(outcome.output.utf8))
        return outcome
    }

    /// What every service program and step starts from; the recipe's own environment comes on top. Nothing
    /// of the daemon's environment (and no `PADDOCK_*` variable) reaches a service. `HOME` is the instance's
    /// folder, not its data folder: `initdb` and `mysqld --initialize` want an empty data folder, and tools
    /// write dotfiles to `HOME`.
    private func baseEnvironment(_ context: ServiceTemplateContext, id: String) -> [String: String] {
        ["PATH": Self.basePATH, "HOME": paths.serviceHome(id).path, "TMPDIR": context.run,
         "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    }

    static let basePATH = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let noPHP = "it runs on PHP, and no PHP is installed"

    /// The base environment with the command's own on top; a recipe's PATH comes before the base PATH, so
    /// its programs are found first and the system's still are.
    private func environment(for command: RenderedCommand, context: ServiceTemplateContext, id: String) -> [String: String] {
        var environment = baseEnvironment(context, id: id)
        for (name, value) in command.environment {
            environment[name] = name == "PATH" ? "\(value):\(Self.basePATH)" : value
        }
        return environment
    }

    // MARK: - What a recipe renders to

    /// Checked immediately before anything is spawned, whatever validation said about the templates: the
    /// program (symlinks resolved) must be inside the recipe's installed binaries, or be exactly Paddock's PHP
    /// for a `{php}` recipe; path variables must stay in the instance's folders (PATH also in its binaries).
    private func checkRendered(_ command: RenderedCommand, template: RecipeCommand, instance: ServiceInstance,
                               recipe: ServiceRecipe) throws {
        let bin = paths.serviceBin(kind: recipe.kind, version: recipe.version)
        if template.executable == "{php}" {
            guard let php = phpBinary(), let wanted = Self.realPath(php.path),
                  Self.realPath(command.executable) == wanted else {
                throw ServiceError.unsafeRecipe(name: instance.name, reason: "its program isn't Paddock's PHP")
            }
        } else if !Self.resolves(command.executable, inside: bin) {
            throw ServiceError.unsafeRecipe(name: instance.name, reason: "its program \(URL(fileURLWithPath: command.executable).lastPathComponent) "
                                            + "is not inside its own installed files")
        }
        let own = [paths.serviceHome(instance.id), paths.serviceRun(instance.id)]
        for (name, value) in command.environment {
            let allowed: [URL]
            switch name {
            case "HOME", "TMPDIR", "PHPRC", "PHP_INI_SCAN_DIR": allowed = own
            case "PATH": allowed = [paths.serviceConfig(instance.id), bin]
            default: continue
            }
            let entries = ServiceCatalog.folderListVariables[name] != nil
                ? value.split(separator: ":", omittingEmptySubsequences: false).map(String.init) : [value]
            for entry in entries where !allowed.contains(where: { Self.isUnder(entry, folder: $0, orAt: true) }) {
                throw ServiceError.unsafeRecipe(name: instance.name, reason: "\(name) would point outside its own folders")
            }
        }
    }

    /// Whether `path`, symlinks resolved, is inside `folder` (also resolved). False when either is missing.
    static func resolves(_ path: String, inside folder: URL) -> Bool {
        guard let resolved = realPath(path), let root = realPath(folder.path) else { return false }
        return resolved.hasPrefix(root + "/")
    }

    /// Whether `path`, standardized (`..` removed; it need not exist), is inside `folder`, or is it with `orAt`.
    static func isUnder(_ path: String, folder: URL, orAt: Bool = false) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        return standardized.hasPrefix(root + "/") || (orAt && standardized == root)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
        // Up to date unless newer, or the same version with a download it doesn't have yet (an add-on).
        if installedRecipe(instance) != nil, !ServiceCatalog.isNewer(latest.version, than: instance.version),
           latest.version != instance.version || installer.isInstalled(latest) {
            return instance
        }
        // The same version gaining a download is installed into the folder the service runs from: stop it
        // first, so its binaries are never swapped under a running server (a new version installs beside).
        let sameVersion = latest.version == instance.version
        let wasRunning: Bool = sameVersion ? try await Self.offPool {
            self.operationLock.lock()
            defer { self.operationLock.unlock() }
            guard let current = self.instance(named: instance.id) else { return false }
            let running: Bool
            if case .running = self.supervisor.status(Self.processName(current.id)) { running = true } else { running = false }
            self.stopLocked(current.id)
            return running
        } : false
        do {
            try await installer.install(latest)
        } catch {
            // Nothing was swapped: the old install runs again as it was.
            if wasRunning {
                _ = try? await Self.offPool {
                    self.operationLock.lock()
                    defer { self.operationLock.unlock() }
                    if let current = self.instance(named: instance.id), let failure = self.startOne(current) {
                        self.log("\(current.name) did not start again: \(Messages.serviceError(failure))")
                    }
                }
            }
            if error is CancellationError { throw ServiceError.cancelled(name: instance.name) }
            if let error = error as? ServiceInstallError { throw ServiceError.installFailed(name: instance.name, reason: error) }
            throw error
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
        persistSeries(all)
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

    /// Saves series filled in for instances saved before series existed.
    private func persistSeries(_ instances: [ServiceInstance]) {
        let filled = Dictionary(instances.map { ($0.id, $0.series) }, uniquingKeysWith: { first, _ in first })
        let missing = store.load().services.contains { $0.series.isEmpty && filled[$0.id] != nil }
        guard missing else { return }
        do {
            try store.update { state in
                state.services = state.services.map { saved in
                    guard saved.series.isEmpty, let series = filled[saved.id] else { return saved }
                    var updated = saved
                    updated.series = series
                    return updated
                }
            }
        } catch {
            log("could not save the services' series: \(error.localizedDescription)")
        }
    }

    /// Stops every service, each with its own signal; for the daemon's exit.
    public func stopAll() {
        operationLock.lock()
        defer { operationLock.unlock() }
        cancelActions(of: nil)
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
        removeConfig(instance.id, keepingSecrets: !deleteData)
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
        cancelActions(of: id)
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
        let current = installedRecipe(instance, storing: true)
        var target = forcing ?? current
        if forcing == nil, let latest = latest(instance), latest.version != instance.skippedVersion,
           current == nil || ServiceCatalog.isNewer(latest.version, than: instance.version)
               || (latest.version == instance.version && !installer.isInstalled(latest)),
           installer.isInstalled(latest) || installer.canInstallLocally(latest) {
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
            let reason = nothingToRun(instance)
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
        if let again = launch(instance, current) {
            let error = ServiceError.rollbackFailed(name: instance.name, id: id, version: target.version,
                                                    previous: current.version, newFailure: Messages.serviceError(failure),
                                                    oldFailure: Messages.serviceError(again))
            log(Messages.serviceError(error))
            return error
        }
        // Back on the old version: don't try this one again by itself, and drop its binaries if unused.
        remember(skipped: target.version, for: id)
        if !instances().contains(where: { $0.kind == target.kind && $0.version == target.version }) {
            installer.remove(kind: target.kind, version: target.version)
        }
        let error = ServiceError.updateFailed(name: instance.name, version: target.version,
                                              previous: current.version, log: failedLog)
        log(Messages.serviceError(error))
        return forcing != nil ? error : nil
    }

    private func remember(skipped version: String?, for id: String) {
        _ = try? store.update { state in
            state.services = state.services.map { saved in
                guard saved.id == id else { return saved }
                var updated = saved
                updated.skippedVersion = version
                return updated
            }
        }
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
                    updated.skippedVersion = nil
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
            try ensureSecrets(instance, recipe)
            let context = try self.context(instance, recipe: recipe)
            let command = try ServiceTemplate.render(recipe.start, context: context)
            try checkRendered(command, template: recipe.start, instance: instance, recipe: recipe)
            if let socket = context.socket, !Self.isUnder(socket, folder: paths.serviceRun(id)) {
                throw ServiceError.unsafeRecipe(name: instance.name, reason: "its socket would be outside its run folder")
            }
            let files = try recipe.configFiles.map { try ServiceTemplate.renderFile($0.contents, context: context) }
            let texts = [command.executable] + command.arguments + Array(command.environment.values)
                + files.flatMap { $0.components(separatedBy: .newlines) }
            if let wildcard = texts.lazy.compactMap(ServiceLoopback.wildcard(in:)).first {
                throw ServiceError.unavailable(name: instance.name,
                                               reason: "its recipe would listen on \(wildcard), not only on this Mac")
            }
            try ensureFolders(id)
            try writeConfigFiles(recipe, context: context, id: id)
            if let socket = context.socket { Self.removeStaleSocket(socket, inside: paths.serviceRun(id)) }
            try removeStaleLocks(instance, recipe, context: context)
            let record = paths.serviceRun(id).appendingPathComponent(Self.pidFileName)
            let probe = try makeProbe(instance, recipe, context: context)
            let spawns = SpawnCounter()
            var spec = ProcessSpec(
                name: Self.processName(id), executable: URL(fileURLWithPath: command.executable),
                arguments: command.arguments, environment: environment(for: command, context: context, id: id),
                logFile: paths.serviceLog(id), stopSignal: recipe.signalNumber,
                stopGrace: TimeInterval(recipe.stopGraceSeconds), inheritsEnvironment: false,
                didSpawn: { [weak self] pid in
                    try? ServiceProcessRecord.live(pid: pid)?.write(to: record)
                    // The first spawn is this launch, checked below; later ones are the supervisor's restarts.
                    if spawns.next() > 1 { self?.checkAfterRestart(instance, recipe, probe, processGroup: pid) }
                })
            spec.workingDirectory = paths.serviceHome(id)
            // Starting from before the process exists, so status never says running before readiness was checked.
            setRuntime(.starting, for: id)
            try supervisor.start(spec)
            processStartedForTesting?(id)
            guard waitUntilReady(Self.processName(id), probe, timeout: readyTimeout ?? recipe.readyTimeout,
                                 isCancelled: { [weak self] in self?.isCancelled ?? true }) else {
                stopProcess(id)
                setRuntime(.crashed, for: id)
                let tail = Self.lastLines(logTail(id), 20)
                // A known cause in the log: say what it means, beside the log and in the status.
                guard let hint = recipe.logHints.first(where: { tail.contains($0.contains) })?.hint else {
                    return .notReady(name: instance.name, log: tail)
                }
                setNotice(hint, for: id)
                return .notReady(name: instance.name, log: tail + "\n\n" + hint)
            }
            if case .running(let pid) = supervisor.status(Self.processName(id)) {
                if let address = checkListeners(instance, processGroup: pid) {
                    stopProcess(id)
                    setRuntime(.crashed, for: id)
                    return .notLoopback(name: instance.name, address: address)
                }
                scheduleLateListenerChecks(instance, processGroup: pid)
            }
            writeDataVersion(instance, recipe)
            setRuntime(.running, for: id)
            return nil
        } catch {
            stopProcess(id)
            if error as? TemplateError == .unavailable("php") {
                setRuntime(.unavailable(reason: Self.noPHP), for: id)
                return .unavailable(name: instance.name, reason: Self.noPHP)
            }
            if let error = error as? ServiceError, case .unavailable(_, let reason) = error {
                setRuntime(.unavailable(reason: reason), for: id)
                return error
            }
            if let error = error as? ServiceError, case .unsafeRecipe = error {
                setRuntime(.unavailable(reason: Messages.serviceError(error)), for: id)
                return error
            }
            setRuntime(.crashed, for: id)
            let reason = error is SupervisorError ? "\(recipe.start.executable) could not be run" : "\(error)"
            return .notReady(name: instance.name, log: reason)
        }
    }

    /// A readiness probe, rendered (and, for a command, checked) once per launch.
    struct ReadyProbe: Sendable {
        let readiness: Readiness
        /// The rendered port, path or URL; unused for a command.
        let target: String
        let command: RenderedCommand?
        let environment: [String: String]
        let directory: URL
    }

    private func makeProbe(_ instance: ServiceInstance, _ recipe: ServiceRecipe,
                           context: ServiceTemplateContext) throws -> ReadyProbe {
        guard let template = recipe.ready.command else {
            return ReadyProbe(readiness: recipe.ready, target: try ServiceTemplate.render(recipe.ready.template, context: context),
                              command: nil, environment: [:], directory: paths.serviceHome(instance.id))
        }
        let command = try ServiceTemplate.render(template, context: context)
        try checkRendered(command, template: template, instance: instance, recipe: recipe)
        return ReadyProbe(readiness: recipe.ready, target: command.executable, command: command,
                          environment: environment(for: command, context: context, id: instance.id),
                          directory: paths.serviceHome(instance.id))
    }

    /// Seconds one readiness command may take.
    static let readyCommandLimit: TimeInterval = 5

    /// One attempt of the probe: a connection, or the readiness command exiting 0 within `limit` seconds
    /// (at most `readyCommandLimit`).
    private func probeOnce(_ probe: ReadyProbe, limit: TimeInterval, isCancelled: @escaping () -> Bool) -> Bool {
        guard let command = probe.command else { return ServiceReadiness.probe(probe.readiness, rendered: probe.target) }
        let outcome = try? ServiceStepRunner.run(
            executable: command.executable, arguments: command.arguments, environment: probe.environment,
            directory: probe.directory, stdin: nil, timeout: max(0.5, min(Self.readyCommandLimit, limit)), killGrace: 1,
            isCancelled: isCancelled)
        return outcome?.end == .exited(0)
    }

    /// Polls the readiness probe until it passes, the process exits (or, with `processGroup`, is replaced),
    /// the deadline passes, or `isCancelled` says so.
    private func waitUntilReady(_ process: String, _ probe: ReadyProbe, timeout: TimeInterval, processGroup: Int32? = nil,
                                isCancelled: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled() { return false }
            guard case .running(let pid) = supervisor.status(process), processGroup == nil || pid == processGroup else {
                return false
            }
            if probeOnce(probe, limit: deadline.timeIntervalSinceNow, isCancelled: isCancelled) { return true }
            Thread.sleep(forTimeInterval: probe.command == nil ? 0.1 : 0.2)
        }
        return false
    }

    // MARK: - Lock files

    /// Before a start (after any orphan was reclaimed): the recipe's lock files (a pid on the first line,
    /// like PostgreSQL's `postmaster.pid`). Paddock removes one only when its pid is a live process that is
    /// provably not this instance's server: another user's (services run as this user), or one whose
    /// program is outside this kind's installed binaries, or one running them in another folder than this
    /// instance's (a server runs in its instance's folder, PostgreSQL in its data folder). Anything else
    /// is left alone: a dead, empty or unreadable lock for the service itself to handle (PostgreSQL removes
    /// it, and checks its shared memory too); this instance's own server, or a process macOS won't describe,
    /// refuses the start. Only a regular file is ever removed, never through a symlink, and only inside the
    /// instance's own data and run folders; a lock that is not a regular file refuses the start.
    private func removeStaleLocks(_ instance: ServiceInstance, _ recipe: ServiceRecipe,
                                  context: ServiceTemplateContext) throws {
        let own = [paths.serviceData(instance.id), paths.serviceRun(instance.id)]
        let binaries = paths.serviceBin(kind: instance.kind, version: "-").deletingLastPathComponent()
        let instanceFolder = Self.realPath(paths.serviceHome(instance.id).path) ?? paths.serviceHome(instance.id).path
        for template in recipe.lockFiles {
            let path = URL(fileURLWithPath: try ServiceTemplate.render(template, context: context)).standardizedFileURL
            guard own.contains(where: { Self.isUnder(path.path, folder: $0) }) else {
                throw ServiceError.unsafeRecipe(name: instance.name, reason: "its lock file would be outside its own folders")
            }
            // Its folder (symlinks resolved) must be inside them too; no folder, no lock.
            guard let folder = Self.realPath(path.deletingLastPathComponent().path) else { continue }
            guard own.contains(where: { root in
                Self.realPath(root.path).map { folder == $0 || folder.hasPrefix($0 + "/") } ?? false
            }) else {
                throw ServiceError.unsafeRecipe(name: instance.name, reason: "its lock file would be outside its own folders")
            }
            var info = stat()
            guard lstat(path.path, &info) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw ServiceError.unavailable(name: instance.name, reason: "its lock file \(path.lastPathComponent) is "
                                               + "not a plain file, so Paddock left it alone (\(path.path))")
            }
            // Dead, empty, not a pid, unreadable: the service's own business.
            guard let pid = Self.lockOwner(path.path) else { continue }
            if kill(pid, 0) != 0 {
                guard errno == EPERM else { continue }
                // Another user's process: not a service of this user's.
            } else {
                guard let program = processInspector.executable(pid) else {
                    throw ServiceError.unavailable(name: instance.name, reason: "its lock file \(path.lastPathComponent) "
                                                   + "names process \(pid), and macOS won't say what it runs; remove "
                                                   + "\(path.path) if that isn't \(instance.name)")
                }
                if Self.resolves(program, inside: binaries) {
                    guard let directory = processInspector.workingDirectory(pid) else {
                        throw ServiceError.unavailable(name: instance.name, reason: "its lock file "
                                                       + "\(path.lastPathComponent) names process \(pid), and macOS won't "
                                                       + "say where it runs; remove \(path.path) if that isn't \(instance.name)")
                    }
                    let resolved = Self.realPath(directory) ?? directory
                    if resolved == instanceFolder || resolved.hasPrefix(instanceFolder + "/") {
                        throw ServiceError.unavailable(name: instance.name, reason: "another copy of it is already "
                                                       + "running (process \(pid)) on its data; Paddock left it alone")
                    }
                }
            }
            guard unlink(path.path) == 0 || errno == ENOENT else {
                throw ServiceError.unavailable(name: instance.name,
                                               reason: "its stale lock file \(path.path) couldn't be removed")
            }
            log("removed the stale lock file \(path.lastPathComponent) of \(instance.name) (process \(pid) is not it)")
        }
    }

    /// The pid on a lock file's first line (read without following a symlink), if it has one.
    static func lockOwner(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        let first = String(decoding: buffer[0..<n], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first
        return first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The first TCP listener of the process group that isn't on 127.0.0.1 or [::1] (`lsof`, at most 5
    /// seconds). A recipe can forget a bind flag (MySQL and Redis listen everywhere by default); this catches
    /// it on the real process. If `lsof` can't answer, the service is let through, and its notice says so.
    private func checkListeners(_ instance: ServiceInstance, processGroup: Int32) -> String? {
        do {
            return try Self.listeningAddresses(processGroup: processGroup, runner: runner).first { !Self.isLoopback($0) }
        } catch {
            let notice = "Paddock couldn't check what \(instance.name) is listening on."
            setNotice(notice, for: instance.id)
            log("\(notice) (\(error))")
            return nil
        }
    }

    /// The same check again a few seconds after readiness, off the request queue: some servers open more
    /// listeners later (MySQL's X plugin, SeaweedFS's gRPC ports). A late violation stops the service.
    private func scheduleLateListenerChecks(_ instance: ServiceInstance, processGroup: Int32) {
        for delay in lateLoopbackChecks {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.lateListenerCheck(instance, processGroup: processGroup)
            }
        }
    }

    /// After the supervisor restarted a service on its own: once the new process is ready (or the recipe's
    /// readiness deadline passes), the same listener checks as after a launch, tied to the new process: a
    /// later restart or stop makes them do nothing.
    private func checkAfterRestart(_ instance: ServiceInstance, _ recipe: ServiceRecipe, _ probe: ReadyProbe,
                                   processGroup: Int32) {
        let name = Self.processName(instance.id)
        let timeout = readyTimeout ?? recipe.readyTimeout
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            _ = self.waitUntilReady(name, probe, timeout: timeout, processGroup: processGroup,
                                    isCancelled: { [weak self] in self?.isCancelled ?? true })
            guard case .running(let pid) = self.supervisor.status(name), pid == processGroup else { return }
            self.lateListenerCheck(instance, processGroup: processGroup)
            self.scheduleLateListenerChecks(instance, processGroup: processGroup)
        }
    }

    private func lateListenerCheck(_ instance: ServiceInstance, processGroup: Int32) {
        let name = Self.processName(instance.id)
        guard case .running(let pid) = supervisor.status(name), pid == processGroup,
              let address = checkListeners(instance, processGroup: processGroup) else { return }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard case .running(let current) = supervisor.status(name), current == processGroup else { return }
        stopProcess(instance.id)
        setRuntime(.crashed, for: instance.id)
        let message = Messages.serviceError(.notLoopback(name: instance.name, address: address))
        setNotice(message, for: instance.id)
        log(message)
    }

    /// Every TCP listening address of a process group, as `lsof -F n` names them (`127.0.0.1:5432`,
    /// `*:3306`). Shared with the tests' loopback assertion.
    static func listeningAddresses(processGroup: Int32, runner: CommandRunner) throws -> [String] {
        let result = try runner.run("/usr/sbin/lsof", ["-a", "-g", "\(processGroup)", "-iTCP", "-sTCP:LISTEN", "-nP",
                                                       "-F", "n"], environment: nil, timeout: 5)
        return result.output.split(separator: "\n").filter { $0.hasPrefix("n") }
            .map { Messages.printable(String($0.dropFirst()), limit: 128) ?? "?" }
    }

    /// Whether an `lsof` address is on this Mac only.
    static func isLoopback(_ address: String) -> Bool {
        guard let colon = address.lastIndex(of: ":") else { return false }
        let host = address[..<colon]
        return host == "127.0.0.1" || host == "[::1]"
    }

    // MARK: - Orphans

    /// If the instance's pid record names a live process that is provably the one Paddock started and now an
    /// orphan (same pid, group and start time, leading its group, parent launchd, a program under that kind's
    /// binaries, or Paddock's PHP for a `{php}` recipe), or names a group whose leader is gone and whose
    /// remaining members all are such orphans, it was left behind by a daemon that died: stop it (the recipe's signal to its group, grace, then SIGKILL) and wait for its
    /// ports. Any other record is stale and removed. Nothing that fails a check is ever signalled.
    private func reclaimOrphan(_ instance: ServiceInstance) {
        let file = paths.serviceRun(instance.id).appendingPathComponent(Self.pidFileName)
        guard let record = ServiceProcessRecord.read(from: file) else { return }
        if case .running(let pid) = supervisor.status(Self.processName(instance.id)), pid == record.pid { return }
        let recipe = describingRecipe(instance)
        // Paddock's PHP folder only for recipes that run `{php}`.
        let allowed = [paths.serviceBin(kind: instance.kind, version: "-").deletingLastPathComponent().path]
            + (recipe?.start.executable == "{php}" ? [paths.phpRoot.path] : [])
        let leaderless = record.orphanedGroupMembers(allowedDirectories: allowed)
        if record.isOurLiveProcess(allowedDirectories: allowed) || leaderless != nil {
            log("stopping \(instance.name) (process group \(record.pgid)), left running by an earlier Paddock")
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
            !recipe.assets.isEmpty && !installer.isInstalled(recipe) && !installer.canInstallLocally(recipe)
        }, downloadBytes: { [installer] recipe in
            // Only what would be fetched: not an asset that is a file on this Mac (Paddock's own builds).
            ServiceCatalog.downloadBytes(recipe.assets.filter { !installer.isLocal($0) })
        })
    }

    /// The `.env` lines of an added service.
    public func env(_ name: String) throws -> [String] {
        let instance = try find(name)
        guard let recipe = describingRecipe(instance) else {
            throw ServiceError.unavailable(name: instance.name, reason: "Paddock no longer knows how to run it")
        }
        return envLines(recipe, context: try context(instance, recipe: recipe), includingSecrets: true)
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
        // Every client gets the status on every poll: a secret's line is left out (`secretEnvNames` names it);
        // `serviceEnv` answers it to a client that asks.
        let env = recipe.flatMap { recipe in context.map { envLines(recipe, context: $0, includingSecrets: false) } } ?? []
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
                    state = .unavailable(reason: nothingToRun(instance))
                } else {
                    state = .stopped
                }
            }
        }
        let update = latest.flatMap { ServiceCatalog.isNewer($0.version, than: instance.version) ? $0.version : nil }
        let skipped = instance.skippedVersion.flatMap { $0 == update ? $0 : nil }
            .map { "Version \($0) didn't start last time; run paddock service update \(instance.id) to try again." }
        return ServiceStatus(
            id: instance.id, name: instance.name, kind: instance.kind, version: instance.version,
            displayName: recipe?.displayName ?? instance.kind, state: state, ports: instance.ports, env: env,
            openURL: openURL, dataPath: paths.serviceData(instance.id).path, autostart: instance.autostart,
            mainPort: recipe?.ports.first.flatMap { instance.ports[$0.name] }, notice: notice ?? skipped,
            updateAvailable: update, series: instance.series, notes: recipe?.notes,
            secretEnvNames: recipe.map(Self.secretEnvNames).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Templates and folders

    /// The template values for an instance. `{socket}` is empty when the recipe has no socket or its path
    /// would be too long for macOS; the service then runs on TCP only.
    func context(_ instance: ServiceInstance, recipe: ServiceRecipe) throws -> ServiceTemplateContext {
        // Config files quote these paths (`dir "…"`, `'…'`): a quote, backslash or control character in one
        // could break a setting or add one. Not possible in a normal macOS home; it guards a hand-set one.
        for folder in [paths.serviceBin(kind: recipe.kind, version: recipe.version), paths.serviceData(instance.id),
                       paths.serviceConfig(instance.id), paths.serviceRun(instance.id)]
        where !Self.isSafeInConfigFiles(folder.path) {
            throw ServiceError.unavailable(name: instance.name, reason: "Paddock's folder path contains a character "
                                           + "services can't handle: \(folder.path)")
        }
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
        if !recipe.secrets.isEmpty {
            context.secrets = (try? ServiceSecrets.load(from: paths.serviceConfig(instance.id))) ?? [:]
        }
        return context
    }

    /// Makes the recipe's secrets the instance doesn't have yet (the caller holds the change lock). A secrets
    /// file Paddock can't use makes the service unavailable rather than being replaced: its data may be
    /// protected by the values in it.
    private func ensureSecrets(_ instance: ServiceInstance, _ recipe: ServiceRecipe) throws {
        guard !recipe.secrets.isEmpty else { return }
        do {
            _ = try ServiceSecrets.ensure(recipe.secrets, in: paths.serviceConfig(instance.id))
        } catch ServiceSecretsError.damaged(let path) {
            throw ServiceError.unavailable(name: instance.name, reason: "its secrets file \(path) isn't one Paddock "
                                           + "can use; Paddock left it alone")
        } catch {
            throw ServiceError.unavailable(name: instance.name, reason: "Paddock couldn't make its secrets "
                                           + "(\(error.localizedDescription))")
        }
    }

    /// Deletes the instance's config folder, all but its secrets when `keepingSecrets` (data that is kept
    /// may be protected by them; adding the service again uses them).
    private func removeConfig(_ id: String, keepingSecrets: Bool) {
        let fm = FileManager.default
        let config = paths.serviceConfig(id)
        guard keepingSecrets, fm.fileExists(atPath: ServiceSecrets.file(in: config).path) else {
            try? fm.removeItem(at: config)
            return
        }
        for item in (try? fm.contentsOfDirectory(atPath: config.path)) ?? [] where item != ServiceSecrets.fileName {
            try? fm.removeItem(at: config.appendingPathComponent(item))
        }
    }

    /// The `.env` variables whose values are secrets (`MEILISEARCH_KEY`): the status leaves their lines out;
    /// `paddock service env` prints them.
    static func secretEnvNames(_ recipe: ServiceRecipe) -> [String] {
        recipe.env.filter(isSecretLine).compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
    }

    /// An `.env` line template that names a secret.
    private static func isSecretLine(_ template: String) -> Bool {
        ServiceTemplate.placeholders(in: template).contains { $0.hasPrefix("secret.") }
    }

    /// No `"`, `'`, `\\` or control character (a path config files can quote as it is).
    static func isSafeInConfigFiles(_ path: String) -> Bool {
        !path.unicodeScalars.contains {
            $0 == "\"" || $0 == "'" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) || $0 == "\u{7F}"
        }
    }

    /// The recipe's `.env` lines (those naming a secret only `includingSecrets`); without a usable socket, those
    /// naming it give way to one comment line.
    private func envLines(_ recipe: ServiceRecipe, context: ServiceTemplateContext, includingSecrets: Bool) -> [String] {
        let socketDisabled = recipe.socket != nil && context.socket == nil
        var lines = recipe.env.filter { !(socketDisabled && ServiceTemplate.mentionsSocket($0)) }
            .filter { includingSecrets || !Self.isSecretLine($0) }
            .compactMap { try? ServiceTemplate.render($0, context: context) }
        if socketDisabled { lines.append(Messages.unixSocketDisabled) }
        return lines
    }

    /// Writes the recipe's config files (each only inside the instance's `config/`), without the lines that
    /// name the socket when it has none (`ServiceTemplate.renderFile`).
    private func writeConfigFiles(_ recipe: ServiceRecipe, context: ServiceTemplateContext, id: String) throws {
        let config = paths.serviceConfig(id).standardizedFileURL
        for file in recipe.configFiles {
            let target = URL(fileURLWithPath: try ServiceTemplate.render(file.path, context: context)).standardizedFileURL
            guard target.path.hasPrefix(config.path + "/") else {
                throw ServiceError.unsafeRecipe(name: context.name, reason: "its config file would be outside its config folder")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try ServiceTemplate.renderFile(file.contents, context: context).utf8).write(to: target, options: .atomic)
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

    private func setRuntime(_ state: ServiceState?, for id: String) {
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

/// Counts a launch's spawns (the first is the launch itself, later ones are the supervisor's restarts).
private final class SpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// One action in flight: whether it was asked to stop, and a way to wait until it has.
private final class ActionFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let group = DispatchGroup()

    init() { group.enter() }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func done() { group.leave() }

    func wait(timeout: TimeInterval) { _ = group.wait(timeout: .now() + timeout) }
}
