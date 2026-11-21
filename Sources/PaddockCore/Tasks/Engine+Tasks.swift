import Foundation

extension Engine {
    /// At daemon start, after the services: reads the user's shell environment and starts every approved site
    /// task that starts with Paddock, whatever the web side is doing. Queued with the other requests, so
    /// shutting down waits for it.
    public func startTasks() async {
        await mutations.withLock {
            guard !self.isShuttingDown else { return }
            let tasks = self.tasks
            _ = try? await ServiceManager.offPool { tasks.start() }
        }
    }

    /// Answers a site task request. Called from the serialized request path.
    func performTasks(_ request: Request) async -> Response {
        let tasks = self.tasks
        do {
            switch request {
            case .tasksApprove(let site, let hash):
                let asked = Date()
                try await ServiceManager.offPool { _ = try tasks.approve(site: site, hash: hash) }
                await applyProxyRoutes(since: asked)
            case .tasksRevoke(let site):
                let asked = Date()
                try await ServiceManager.offPool { try tasks.revoke(site: site) }
                await applyProxyRoutes(since: asked)
            case .taskStart(let site, let task):
                try await ServiceManager.offPool { try tasks.start(site: site, task: task) }
            case .taskStop(let site, let task):
                try await ServiceManager.offPool { try tasks.stop(site: site, task: task) }
            case .taskRestart(let site, let task):
                try await ServiceManager.offPool { try tasks.restart(site: site, task: task) }
            case .taskForceRestart(let site, let task):
                try await ServiceManager.offPool { try tasks.restart(site: site, task: task, force: true) }
            case .tasksStatus(let site):
                try await ServiceManager.offPool { tasks.reloadFile(site: site) }
            case .tasksInit(let site):
                try await ServiceManager.offPool { _ = try tasks.writeStarter(site: site) }
            default:
                return .error(code: ErrorCode.internal, message: "not a site task request")
            }
        } catch let error as SiteTaskError {
            return Self.response(for: error)
        } catch {
            return .error(code: ErrorCode.internal, message: error.localizedDescription)
        }
        return .ok(status())
    }

    /// Approving or withdrawing a site's tasks changes its proxy routes: the web side follows (a route Caddy would
    /// refuse leaves the config it serves untouched, `writeConfigs`). Never fails the request.
    func applyProxyRoutes(since asked: Date) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            routesQueue.async {
                self.applyRoutesIfChanged(forced: true, since: asked)
                continuation.resume()
            }
        }
    }

    static func response(for error: SiteTaskError) -> Response {
        let code: String
        switch error {
        case .unknownSite: code = ErrorCode.unknownSite
        case .noTasksFile: code = ErrorCode.noTasksFile
        case .invalid, .notShowable: code = ErrorCode.tasksInvalid
        case .notApproved: code = ErrorCode.tasksNotApproved
        case .unknownTask: code = ErrorCode.unknownTask
        case .changedSinceShown: code = ErrorCode.tasksChanged
        case .alreadyRunning, .leftoverProcesses: code = ErrorCode.taskAlreadyRunning
        case .stillStopping: code = ErrorCode.internal
        case .fileExists: code = ErrorCode.tasksFileExists
        case .notLaravel: code = ErrorCode.invalidArgument
        case .couldNotStart, .couldNotWrite, .shuttingDown: code = ErrorCode.internal
        }
        return .error(code: code, message: Messages.taskError(error))
    }
}
