import Darwin
import Dispatch
import Foundation
import PaddockCore

// The Paddock background daemon: runs the engine and serves IPC on <home>/run/paddockd.sock.
// PADDOCK_HOME and PADDOCK_{HTTP,HTTPS,DNS}_PORT override the defaults (used by tests).

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

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

// Trusting Caddy's CA changes the owner's keychain, so a daemon running on a throwaway home
// (PADDOCK_HOME set, as in tests) never does it unless PADDOCK_TRUST=1 asks for it.
let env = ProcessInfo.processInfo.environment
let trustsCertificate = env["PADDOCK_HOME"].map { $0.isEmpty } ?? true || env["PADDOCK_TRUST"] == "1"
let engine = Engine(paths: paths, settings: settings,
                    trust: trustsCertificate ? CertificateTrust(paths: paths, runner: SystemCommandRunner()) : nil)
let server = IPCServer(socket: paths.daemonSocket) { await engine.handle($0) }

/// Stops everything and exits; safe to reach more than once.
let shutdownLock = NSLock()
func shutDownAndExit() -> Never {
    shutdownLock.lock() // Never unlocked: the process is on its way out.
    engine.stop()
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

// Start the engine through the same path as a client's `start`, so it queues with other requests.
Task {
    switch await engine.handle(.start) {
    case .ok(let status):
        print("paddockd: engine \(status.running ? "running" : "not running")")
    case .error(let code, let message):
        fputs("paddockd: start failed (\(code)): \(message)\n", stderr)
    }
}

dispatchMain()
