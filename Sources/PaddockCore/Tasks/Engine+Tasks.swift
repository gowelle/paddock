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
                try await ServiceManager.offPool { _ = try tasks.approve(site: site, hash: hash) }
            case .tasksRevoke(let site):
                try await ServiceManager.offPool { try tasks.revoke(site: site) }
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
