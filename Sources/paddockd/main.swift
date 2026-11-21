import Darwin
import Dispatch
import Foundation
import PaddockCore

// The Paddock background daemon: runs the engine and serves IPC on <home>/run/paddockd.sock.
// PADDOCK_HOME and PADDOCK_{HTTP,HTTPS,DNS}_PORT override the defaults (used by tests).

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)
// A client or a service step that goes away mid-write must never kill the daemon: writes fail instead.
signal(SIGPIPE, SIG_IGN)

// A development build never runs on the owner's real home: before anything is opened or created.
if SystemIntegration.thisProcessIsDevelopmentBuild {
    fputs("paddockd: \(Messages.developmentBuild)\n", stderr)
    exit(78) // EX_CONFIG
}

let paths = Paths.current
let settings = Settings.current

// A second instance has nothing to do while the first one answers.
if PaddockClient(paths: paths).daemonIsRunning {
    print("paddockd: already running")
    exit(0)
}

do {
    try paths.ensureDirectories()
} catch {
    fputs("paddockd: cannot create \(paths.home.path): \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Trusting Caddy's CA changes the owner's keychain, so a daemon on a throwaway home never does it.
let trustsCertificate = SystemIntegration.isEnabled(environment: ProcessInfo.processInfo.environment)
// On the real system launchd's helper forwards ports 80/443. Status reports it working only when this
// build's files are installed, launchd has the job loaded and 127.0.0.1 accepts a connection on the HTTP
// port; worked out off the request path and kept for a few seconds, so `status` never waits for it.
let portHelperCheck: CachedCheck? = trustsCertificate ? CachedCheck { [paths, settings] in
    guard let source = PortHelperLocator.bundledBinary() else { return false }
    return PortHelper(source: source, user: NSUserName(), paths: paths, runner: SystemCommandRunner())
        .isServing(port: settings.httpPort)
} : nil
let engine = Engine(paths: paths, settings: settings,
                    trust: trustsCertificate ? CertificateTrust(paths: paths, runner: SystemCommandRunner()) : nil,
                    portHelperInstalled: { portHelperCheck?.value ?? false })
let server = IPCServer(socket: paths.daemonSocket) { await engine.handle($0) }

/// Stops everything and exits; safe to reach more than once. Goes through the engine's serialized
/// request path: new requests are refused at once, the one in progress finishes, then the web stack and
/// the DNS responder stop. Called on a dispatch queue thread (never the cooperative pool), so it may block.
let shutdownLock = NSLock()
func shutDownAndExit() -> Never {
    shutdownLock.lock() // Never unlocked: the process is on its way out.
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await engine.shutDownAfterPendingWork()
        done.signal()
    }
    done.wait()
    server.stop()
    exit(0)
}

server.didRespond = { request in
    if request == .shutdown { shutDownAndExit() }
}

do {
    try server.start()
} catch IPCServerError.alreadyRunning {
    print("paddockd: already running")
    exit(0)
} catch {
    fputs("paddockd: cannot serve \(paths.daemonSocket.path): \(error)\n", stderr)
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { shutDownAndExit() }
    source.resume()
    signalSources.append(source)
}

print("paddockd: listening on \(paths.daemonSocket.path)")

// .test names resolve for as long as the daemon runs, whatever happens to the web server.
engine.startDNS()

// Start the engine through the same path as a client's `start`, so it queues with other requests. Then the
// services that start with Paddock, whatever happened to the web side (its ports may be taken).
Task {
    switch await engine.handle(.start) {
    case .ok(let status):
        print("paddockd: engine \(status.running ? "running" : "not running")")
    case .error(let code, let message):
        fputs("paddockd: start failed (\(code)): \(message)\n", stderr)
    default:
        break
    }
    await engine.startAutostartServices()
}

dispatchMain()
