import Foundation

/// A first-in-first-out async lock. Requests that change state take it so they run one at a time.
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume() // The lock passes straight to the next waiter.
        }
    }
}

extension Engine {
    /// Applies one request. `status` is answered at once; everything else runs one at a time, in
    /// arrival order, and returns the fresh status (or an error with a stable code).
    ///
    /// `shutdown` marks the engine as shutting down before it queues, so nothing queued behind it (or
    /// arriving later) can start the web stack again just before the daemon exits.
    public func handle(_ request: Request) async -> Response {
        if case .status = request { return .ok(status()) }
        if case .shutdown = request { markShuttingDown() }
        return await mutations.withLock {
            if self.isShuttingDown && request != .shutdown { return self.shuttingDownError }
            return await self.perform(request)
        }
    }

    /// The daemon's exit on a signal: refuses new work, cancels a PHP install in progress (so it never
    /// waits for a download), waits for the request in progress, then stops everything (web stack and DNS).
    /// The same path a `shutdown` request takes.
    public func shutDownAfterPendingWork() async {
        markShuttingDown()
        await mutations.withLock { await self.blocking { self.shutdown() } }
    }

    private var shuttingDownError: Response { error(ErrorCode.internal, "Paddock is shutting down.") }

    private func perform(_ request: Request) async -> Response {
        switch request {
        case .status:
            return .ok(status())
        case .start:
            return await startReply()
        case .stop:
            await blocking { self.stop() }
            return .ok(status())
        case .restart:
            await blocking { self.stop() }
            return await startReply()
        case .shutdown:
            // The daemon exits after this reply has been written.
            await blocking { self.shutdown() }
            return .ok(status())

        case .park(let path):
            guard let dir = Self.standardizedDirectory(path) else { return notADirectory(path) }
            return await change { state in
                if !state.parked.contains(dir) { state.parked.append(dir) }
            }
        case .forget(let path):
            let dir = Self.standardizedPath(path)
            return await change { $0.parked.removeAll { $0 == dir || $0 == path } }
        case .link(let name, let path):
            guard let site = SiteName.normalize(name) else {
                return error(ErrorCode.internal, "\"\(name)\" cannot be turned into a site name; use letters or digits")
            }
            guard let dir = Self.standardizedDirectory(path) else { return notADirectory(path) }
            return await change { $0.links[site] = dir }
        case .unlink(let name):
            return await change { state in
                state.links = state.links.filter { SiteName.normalize($0.key) != SiteName.normalize(name) }
            }

        case .secure(let name):
            guard let site = knownSite(name) else { return unknownSite(name) }
            let changed = await change { $0.secured.insert(site) }
            guard case .ok = changed else { return changed }
            return await ensureTrusted(afterSecuring: site) ?? changed
        case .unsecure(let name):
            guard let site = knownSite(name, alsoIn: { $0.secured }) else { return unknownSite(name) }
            return await change { $0.secured.remove(site) }
        case .isolate(let name, let version):
            guard let site = knownSite(name) else { return unknownSite(name) }
            guard installer.isInstalled(version) else { return notInstalled(version) }
            return await change { $0.phpPins[site] = version }
        case .unisolate(let name):
            guard let site = knownSite(name, alsoIn: { Set($0.phpPins.keys) }) else { return unknownSite(name) }
            return await change { $0.phpPins[site] = nil }

        case .trust:
            guard let trust else { return error(ErrorCode.trustDisabled, Messages.trustDisabled) }
            let current = await ensureTrusted(afterSecuring: nil)
            // Then roots replaced when the certificate authority was renamed: best-effort, never failing
            // this request; a file whose trust couldn't be removed stays for the next attempt. Not after the
            // owner just declined (or the change failed for) the current root: no second prompt then.
            let currentDeclined = current != nil
                && current != error(ErrorCode.needsTrust, Messages.certificateNotReady)
            await blocking {
                if !currentDeclined {
                    for failure in trust.cleanUpReplacedRoots() { self.log(failure) }
                }
                self.refreshTrustChecks()
            }
            return current ?? .ok(status())

        case .use(let version):
            guard installer.isInstalled(version) else { return notInstalled(version) }
            return await change { $0.defaultPHP = version }
        case .installPHP(let version):
            return await install(version)
        case .removePHP(let version):
            let state = store.load()
            // Before the first start there is no stored default yet: the newest installed one will be.
            let effectiveDefault = state.defaultPHP ?? installer.installed().max()
            if effectiveDefault == version || state.phpPins.values.contains(version) {
                return error(ErrorCode.phpInUse, "PHP \(version) is the default or pinned by a site; switch those first")
            }
            do {
                try installer.remove(version)
            } catch {
                return self.error(ErrorCode.internal, "Could not remove PHP \(version): \(error.localizedDescription)")
            }
            return .ok(status())
        }
    }

    // MARK: - Pieces

    /// Starts the engine; held ports are `ports_blocked` with the full sentence naming who holds them.
    private func startReply() async -> Response {
        do {
            try await blocking { try self.start() }
        } catch EngineError.notReady(let process, let log) {
            return error(ErrorCode.internal, "\(process) did not become ready; see \(log)")
        } catch EngineError.caddyReloadFailed(let output) {
            return error(ErrorCode.internal, "Caddy rejected the configuration: \(output)")
        } catch EngineError.socketPathTooLong(let path) {
            return error(ErrorCode.internal, Messages.socketPathTooLong(path))
        } catch EngineError.portHelperMissing {
            return error(ErrorCode.internal, Messages.portHelperMissing)
        } catch {
            return self.error(ErrorCode.internal, "Could not start: \(error.localizedDescription)")
        }
        let current = status()
        if !current.blockedBy.isEmpty {
            return error(ErrorCode.portsBlocked, Messages.portsBlocked(current.blockedBy))
        }
        return .ok(current)
    }

    /// Updates state, regenerates configs and reloads, then returns the fresh status.
    private func change(_ body: @escaping @Sendable (inout State) -> Void) async -> Response {
        do {
            try await blocking {
                try self.store.update(body)
                try self.reload()
            }
        } catch EngineError.notReady(let process, let log) {
            return error(ErrorCode.internal, "\(process) did not become ready; see \(log)")
        } catch EngineError.caddyReloadFailed(let output) {
            return error(ErrorCode.internal, "Caddy rejected the configuration: \(output)")
        } catch {
            return self.error(ErrorCode.internal, "\(error.localizedDescription)")
        }
        return .ok(status())
    }

    /// Trusts Paddock's certificate authority if macOS does not yet. Nil when it is (or no trust
    /// object is set); `needs_trust` when it still is not afterwards (declined, or the command failed).
    private func ensureTrusted(afterSecuring site: String?) async -> Response? {
        guard let trust else { return nil }
        let outcome = (try? await blocking { () -> TrustOutcome in
            // Caddy creates its CA lazily; with it down there is nothing to wait for.
            if self.isServing { _ = self.waitForRootCertificate(trust) }
            // Never ask macOS to trust a file that is not there.
            guard FileManager.default.fileExists(atPath: trust.rootCertificate.path) else { return .notReady }
            if trust.isTrusted() { return .trusted }
            do {
                try trust.trust()
            } catch {
                // Declined, or the command failed: keep what `security` said for diagnosis.
                self.log("trusting \(trust.rootCertificate.path) failed: \(error)")
            }
            if trust.isTrusted() { return .trusted }
            self.log("macOS still doesn't trust \(trust.rootCertificate.path) after add-trusted-cert")
            return .declined
        }) ?? .declined
        // The status this request answers with already knows the outcome.
        await blocking { self.refreshTrustChecks() }
        if outcome == .trusted { return nil }
        if outcome == .notReady { return error(ErrorCode.needsTrust, Messages.certificateNotReady) }
        return error(ErrorCode.needsTrust, site.map { Messages.needsTrust(host: "\($0).\(settings.tld)") }
            ?? Messages.stillNotTrusted)
    }

    private enum TrustOutcome { case trusted, declined, notReady }

    private func install(_ version: PHPVersion) async -> Response {
        if installer.isInstalled(version) { return .ok(status()) }
        guard installAction != nil || installer.isAvailable(version) else {
            return error(ErrorCode.phpNotAvailable, Messages.phpNotAvailable(version))
        }
        let installer = installer
        let installAction = installAction
        // Its own task, so shutting down can cancel it; the installer keeps nothing of a cancelled install.
        let work = Task {
            if let installAction {
                try await installAction(version)
            } else {
                try await installer.install(version)
            }
        }
        setInstallInProgress(work)
        defer { setInstallInProgress(nil) }
        do {
            try await work.value
        } catch is CancellationError {
            return error(ErrorCode.internal, Messages.phpInstallCancelled(version))
        } catch PHPInstallError.notInManifest {
            return error(ErrorCode.phpNotAvailable, Messages.phpNotAvailable(version))
        } catch PHPInstallError.buildMissing(_, let file) {
            log("cannot install PHP \(version): its build \(file) isn't on this Mac")
            return error(ErrorCode.phpNotAvailable, Messages.phpNotAvailable(version))
        } catch {
            return self.error(ErrorCode.internal, "Could not install PHP \(version): \(describe(error))")
        }
        return .ok(status())
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case PHPInstallError.checksumMismatch(_, let file): return "the downloaded \(file) failed its checksum"
        case PHPInstallError.downloadFailed(_, let reason): return reason
        default: return error.localizedDescription
        }
    }

    /// The registry's name for `input` if such a site is served now (or, for removals, if state
    /// still mentions it).
    private func knownSite(_ input: String, alsoIn stale: ((State) -> Set<String>)? = nil) -> String? {
        let name = SiteName.normalize(input) ?? input
        let state = store.load()
        let php = state.defaultPHP ?? installer.installed().max() ?? PHPVersion(major: 8, minor: 1)
        if SiteRegistry(state: state, defaultPHP: php, settings: settings).site(named: name) != nil { return name }
        if let stale, stale(state).contains(name) { return name }
        return nil
    }

    /// Runs blocking engine work off the cooperative thread pool.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func blocking(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                work()
                continuation.resume()
            }
        }
    }

    // MARK: - Errors and paths

    private func error(_ code: String, _ message: String) -> Response {
        .error(code: code, message: message)
    }

    private func notADirectory(_ path: String) -> Response {
        error(ErrorCode.notADirectory, "\(path) is not a directory (use an absolute path)")
    }

    private func unknownSite(_ name: String) -> Response {
        error(ErrorCode.unknownSite, "No site named \"\(name)\"")
    }

    private func notInstalled(_ version: PHPVersion) -> Response {
        error(ErrorCode.phpNotInstalled, "PHP \(version) is not installed; install it first")
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// The standardized absolute path if `path` is absolute (after `~` expansion) and a directory.
    private static func standardizedDirectory(_ path: String) -> String? {
        guard (path as NSString).expandingTildeInPath.hasPrefix("/") else { return nil }
        let standardized = standardizedPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return standardized
    }
}
