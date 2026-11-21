import Darwin
import Foundation

public enum ServiceError: Error, Equatable, Sendable {
    /// No recipe of that kind; `available` lists the kinds there are.
    case unknownKind(String, available: [String])
    case unknownVersion(kind: String, version: String, available: [String])
    /// No added service has that id or name.
    case unknownService(String)
    /// A saved port is held by another program (named as Paddock shows names).
    case portInUse(name: String, port: Int, holder: String)
    case noFreePort(name: String, preferred: Int)
    /// An initialise step failed; `output` is what it printed.
    case initialiseFailed(name: String, output: String)
    case installFailed(name: String, reason: ServiceInstallError)
    /// It exited, or didn't become ready in time; `log` is the end of its log.
    case notReady(name: String, log: String)
    case unavailable(name: String, reason: String)
    /// Paddock began shutting down while the service was being added.
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
/// Changes (`start`, `stop`, `restart`, `remove`, `startAutostart`, `stopAll`, and the folder and state part
/// of `add`) run one at a time and may wait (a start waits until the service is ready). `statuses` never
/// waits for them: it reports the last known state. Adds are serialized among themselves; each one's
/// download runs outside the change lock and stops when its task is cancelled.
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
    private let readyTimeout: TimeInterval
    private let resources: URL
    private let log: @Sendable (String) -> Void

    private let operationLock = NSLock()
    private let adds = AsyncMutex()
    /// Guards `runtime`, `notices` and `cancelled`; held only for an instant.
    private let runtimeLock = NSLock()
    /// What the manager last saw each instance do. The supervisor's own status refines it.
    private var runtime: [String: ServiceState] = [:]
    /// A sentence about an instance's last add (existing data reused), until it is stopped.
    private var notices: [String: String] = [:]
    /// Set while shutting down: readiness waits give up at once.
    private var cancelled = false

    /// How long an initialise step may run.
    static let initialiseTimeout: TimeInterval = 600
    /// Unix socket paths longer than this don't fit `sun_path` (104 bytes with the NUL).
    static let maximumSocketPath = 103

    public init(paths: Paths, catalog: ServiceCatalog, store: StateStore, supervisor: Supervisor,
                downloader: ArtifactDownloader = ArtifactDownloader(), portCheck: ServicePortCheck = .live,
                phpBinary: @escaping @Sendable () -> URL? = { nil }, portBase: Int? = nil,
                readyTimeout: TimeInterval = Readiness.deadline, resources: URL = Bundled.resources,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.catalog = catalog
        self.store = store
        self.supervisor = supervisor
        installer = ServiceInstaller(paths: paths, downloader: downloader)
        self.portCheck = portCheck
        self.phpBinary = phpBinary
        self.portBase = portBase
        self.readyTimeout = readyTimeout
        self.resources = resources
        self.log = log
    }

    static func processName(_ id: String) -> String { "service-\(id)" }

    // MARK: - Adding

    /// Resolves the recipe, chooses ports, installs the binaries if they aren't yet, creates the
    /// instance's folders, initialises its data (unless data for that id is already there, which is used
    /// as it is), saves it, starts it and waits until it is ready. A failure before the save leaves no
    /// instance and removes the folders it created (verified binaries stay); a failure to start after it
    /// leaves the instance, crashed, so it can be started again or removed.
    public func add(kind: String, version: String?) async throws -> ServiceInstance {
        let result: Result<ServiceInstance, Error> = await adds.withLock {
            do { return .success(try await self.addOne(kind: kind, version: version)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func addOne(kind: String, version: String?) async throws -> ServiceInstance {
        let recipe = try resolve(kind: kind, version: version)
        let state = store.load()
        let identity = ServiceInstance.newIdentity(
            kind: recipe.kind, version: recipe.version, displayName: recipe.displayName,
            kindHasSeveralVersions: catalog.recipes(of: recipe.kind).count > 1, existing: Set(state.services.map(\.id)))
        guard ServiceInstance.isValidID(identity.id) else {
            throw ServiceError.unavailable(name: identity.name, reason: "its catalog entry has an unusable name")
        }
        if recipe.needsPHP && phpBinary() == nil {
            throw ServiceError.unavailable(name: identity.name, reason: "it runs on PHP, and no PHP is installed")
        }
        let ports: [String: Int]
        do {
            ports = try ServicePorts.choose(for: recipe, taken: Set(state.services.flatMap { $0.ports.values }),
                                            isFree: portCheck.isFree)
        } catch ServicePortError.noFreePort(_, let preferred) {
            throw ServiceError.noFreePort(name: identity.name, preferred: preferred)
        }
        do {
            try await installer.install(recipe)
        } catch is CancellationError {
            throw ServiceError.cancelled(name: identity.name)
        } catch let error as ServiceInstallError {
            throw ServiceError.installFailed(name: identity.name, reason: error)
        }
        if Task.isCancelled { throw ServiceError.cancelled(name: identity.name) }

        let instance = ServiceInstance(id: identity.id, kind: recipe.kind, version: recipe.version, name: identity.name,
                                       ports: ports, autostart: true, createdAt: Date())
        try await Self.offPool { try self.create(instance, recipe: recipe) }
        try await Self.offPool { try self.start(instance.id) }
        return instance
    }

    /// The catalog's recipe, with the preferred ports moved by the port base.
    private func resolve(kind: String, version: String?) throws -> ServiceRecipe {
        guard let newest = catalog.recipe(kind: kind, version: nil) else {
            throw ServiceError.unknownKind(kind, available: catalog.kinds().map(\.kind))
        }
        guard let recipe = catalog.recipe(kind: kind, version: version) else {
            throw ServiceError.unknownVersion(kind: newest.kind, version: version ?? "",
                                              available: catalog.recipes(of: kind).map(\.version))
        }
        return ServicePorts.shifted(recipe, base: portBase)
    }

    /// Creates the instance's folders, runs the initialise steps when its data is new, and saves it.
    /// On failure removes what it created, never data that was already there.
    private func create(_ instance: ServiceInstance, recipe: ServiceRecipe) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let fm = FileManager.default
        let data = paths.serviceData(instance.id)
        let dataExisted = fm.fileExists(atPath: data.path)
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
            if dataExisted {
                let notice = Messages.existingServiceData(instance.name)
                setNotice(notice, for: instance.id)
                log(notice)
            } else {
                let context = try self.context(instance, recipe: recipe)
                for step in recipe.initialise { try initialise(step, instance: instance, context: context) }
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

    /// Runs one initialise step to completion; its output goes to the service's log too.
    private func initialise(_ step: RecipeCommand, instance: ServiceInstance, context: ServiceTemplateContext) throws {
        let command = try ServiceTemplate.render(step, context: context)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
        process.currentDirectoryURL = paths.serviceHome(instance.id)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = command.stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch {
            throw ServiceError.initialiseFailed(name: instance.name,
                                                output: "\(command.executable): \(error.localizedDescription)")
        }
        if let stdin = command.stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let timeout = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.initialiseTimeout, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        appendToLog(instance.id, data)
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self)
            throw ServiceError.initialiseFailed(name: instance.name, output: Self.lastLines(text, 30))
        }
    }

    // MARK: - Running

    /// Starts an added service and waits until it is ready. Does nothing if it is running.
    public func start(_ name: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let instance = try find(name)
        if let error = startLocked([instance])[instance.id] { throw error }
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
        if let error = startLocked([instance])[instance.id] { throw error }
    }

    /// Starts every service whose "start with Paddock" is on, side by side; one that can't start (its
    /// port taken, say) is reported in its status and the log, and the others start anyway.
    public func startAutostart() {
        operationLock.lock()
        defer { operationLock.unlock() }
        for (id, error) in startLocked(store.load().services.filter(\.autostart)).sorted(by: { $0.key < $1.key }) {
            log("service \(id) did not start: \(Messages.serviceError(error))")
        }
    }

    /// Stops every service, each with its own signal; for the daemon's exit.
    public func stopAll() {
        operationLock.lock()
        defer { operationLock.unlock() }
        supervisor.stopAll()
        runtimeLock.lock()
        for id in runtime.keys { runtime[id] = .stopped }
        notices = [:]
        cancelled = false
        runtimeLock.unlock()
    }

    /// Makes readiness waits in progress give up, so shutting down never waits for one.
    func cancelPendingWork() {
        runtimeLock.lock()
        cancelled = true
        runtimeLock.unlock()
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

    /// The instance `name` names (id or name, any case).
    public func instance(named name: String) -> ServiceInstance? {
        ServiceInstance.find(name, in: store.load().services)
    }

    private func find(_ name: String) throws -> ServiceInstance {
        guard let instance = instance(named: name) else { throw ServiceError.unknownService(name) }
        return instance
    }

    private func stopLocked(_ id: String) {
        supervisor.stop(Self.processName(id))
        setRuntime(.stopped, for: id)
        setNotice(nil, for: id)
    }

    /// Starts the instances side by side and waits for each to be ready. Returns the ones that failed.
    private func startLocked(_ instances: [ServiceInstance]) -> [String: ServiceError] {
        var errors: [String: ServiceError] = [:]
        var pending: [(instance: ServiceInstance, readiness: Readiness, target: String)] = []
        for instance in instances {
            let id = instance.id
            if case .running = supervisor.status(Self.processName(id)) {
                setRuntime(.running, for: id)
                continue
            }
            guard let recipe = recipe(for: instance) else {
                let reason = Self.notInCatalog(instance)
                setRuntime(.unavailable(reason: reason), for: id)
                errors[id] = .unavailable(name: instance.name, reason: reason)
                continue
            }
            let held = portCheck.holders(instance.ports.values.sorted())
            if let port = held.first?.port {
                let holder = Messages.portHolder(held.filter { $0.port == port })
                setRuntime(.portInUse(holder: holder), for: id)
                errors[id] = .portInUse(name: instance.name, port: port, holder: holder)
                continue
            }
            do {
                let context = try self.context(instance, recipe: recipe)
                let command = try ServiceTemplate.render(recipe.start, context: context)
                let texts = [command.executable] + command.arguments + Array(command.environment.values)
                if let wildcard = texts.lazy.compactMap(ServiceLoopback.wildcard(in:)).first {
                    throw ServiceError.unavailable(name: instance.name,
                                                   reason: "its recipe would listen on \(wildcard), not only on this Mac")
                }
                try ensureFolders(id)
                if let socket = context.socket { try? FileManager.default.removeItem(atPath: socket) }
                try supervisor.start(ProcessSpec(
                    name: Self.processName(id), executable: URL(fileURLWithPath: command.executable),
                    arguments: command.arguments, environment: command.environment, logFile: paths.serviceLog(id),
                    stopSignal: recipe.signalNumber, stopGrace: TimeInterval(recipe.stopGraceSeconds)))
                setRuntime(.starting, for: id)
                pending.append((instance, recipe.ready, try ServiceTemplate.render(recipe.ready.template, context: context)))
            } catch {
                supervisor.stop(Self.processName(id))
                if let error = error as? ServiceError, case .unavailable(_, let reason) = error {
                    setRuntime(.unavailable(reason: reason), for: id)
                    errors[id] = error
                } else {
                    setRuntime(.crashed, for: id)
                    let reason = error is SupervisorError ? "\(command(for: instance)) could not be run" : "\(error)"
                    errors[id] = .notReady(name: instance.name, log: reason)
                }
            }
        }

        var ready = [Bool](repeating: false, count: pending.count)
        let readyLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pending.count) { index in
            let item = pending[index]
            let ok = waitUntilReady(Self.processName(item.instance.id), item.readiness, item.target)
            readyLock.lock()
            ready[index] = ok
            readyLock.unlock()
        }
        for (item, ok) in zip(pending, ready) {
            let id = item.instance.id
            if ok {
                setRuntime(.running, for: id)
            } else {
                supervisor.stop(Self.processName(id))
                setRuntime(.crashed, for: id)
                errors[id] = .notReady(name: item.instance.name, log: Self.lastLines(logTail(id), 20))
            }
        }
        return errors
    }

    private func command(for instance: ServiceInstance) -> String {
        recipe(for: instance).map { $0.start.executable } ?? instance.kind
    }

    /// Polls the readiness probe until it passes, the process exits, the deadline passes, or shutting
    /// down cancels the wait.
    private func waitUntilReady(_ process: String, _ readiness: Readiness, _ target: String) -> Bool {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            runtimeLock.lock()
            let stop = cancelled
            runtimeLock.unlock()
            if stop { return false }
            guard case .running = supervisor.status(process) else { return false }
            if ServiceReadiness.probe(readiness, rendered: target) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    // MARK: - Reporting

    /// Every added service and its last known state. Never waits for a change in progress.
    public func statuses() -> [ServiceStatus] {
        store.load().services.map(status(of:))
    }

    /// The `.env` lines of an added service.
    public func env(_ name: String) throws -> [String] {
        let instance = try find(name)
        guard let recipe = recipe(for: instance) else {
            throw ServiceError.unavailable(name: instance.name, reason: Self.notInCatalog(instance))
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
        let recipe = recipe(for: instance)
        let context = recipe.flatMap { try? self.context(instance, recipe: $0) }
        let env = recipe.flatMap { recipe in context.map { envLines(recipe, context: $0) } } ?? []
        let openURL = recipe?.openURL.flatMap { template in context.flatMap { try? ServiceTemplate.render(template, context: $0) } }
        runtimeLock.lock()
        let known = runtime[instance.id]
        let notice = notices[instance.id]
        runtimeLock.unlock()
        let state: ServiceState
        if recipe == nil {
            state = .unavailable(reason: Self.notInCatalog(instance))
        } else if known == .starting {
            state = .starting
        } else {
            switch supervisor.status(Self.processName(instance.id)) {
            case .running: state = .running
            case .crashed: state = .crashed
            case .stopped: state = known.map { $0 == .running ? .stopped : $0 } ?? .stopped
            }
        }
        return ServiceStatus(
            id: instance.id, name: instance.name, kind: instance.kind, version: instance.version,
            displayName: recipe?.displayName ?? catalog.recipes(of: instance.kind).first?.displayName ?? instance.kind,
            state: state, ports: instance.ports, env: env, openURL: openURL,
            dataPath: paths.serviceData(instance.id).path, autostart: instance.autostart,
            mainPort: recipe?.ports.first.flatMap { instance.ports[$0.name] }, notice: notice)
    }

    private static func notInCatalog(_ instance: ServiceInstance) -> String {
        "this copy of Paddock doesn't offer \(instance.kind) \(instance.version)"
    }

    // MARK: - Recipes, templates and folders

    /// The recipe an instance was added from: exactly its kind and version.
    private func recipe(for instance: ServiceInstance) -> ServiceRecipe? {
        catalog.recipes(of: instance.kind).first { $0.version == instance.version }
    }

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
