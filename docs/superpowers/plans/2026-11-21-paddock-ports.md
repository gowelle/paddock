# Paddock Ports 80/443 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Paddock reachable on the standard ports 80 and 443 (loopback only) without any Paddock code running as root.

**Architecture:** Caddy listens on two owner-only Unix sockets instead of network ports. A tiny helper, `paddock-ports`, accepts connections on listening sockets and copies bytes to those Unix sockets. On the real system launchd opens `127.0.0.1`/`::1` on 80 and 443 and runs the helper as the owner's user (a root-owned LaunchDaemon entry installed by the existing one-prompt privileged script). In development homes the daemon runs the same helper as a child on high ports, so tests exercise the same path.

**Tech Stack:** Swift 6.2 toolchain (language mode 5), SwiftPM, launchd socket activation (`launch_activate_socket`), Caddy 2.11.9 Unix-socket listeners, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-21-paddock-ports-design.md` (amends `2026-11-21-paddock-core-design.md`)

## Global Constraints

- All Global Constraints of `docs/superpowers/plans/2026-11-21-paddock-core.md` still apply (x86_64, macOS 13+, no Homebrew/MacPorts dependency, state under `PADDOCK_HOME`, proprietary licence, commit per task).
- **No Paddock code runs as root after install.** Root is used only by the single privileged `osascript` script.
- Loopback only: the launchd entry lists `127.0.0.1` and `::1`, never a wildcard address.
- The helper reads no config file and no environment; its behaviour is fixed by its arguments.
- Still exactly one password prompt at install and one at uninstall.
- `SystemIntegration.isEnabled(environment:)` remains the single rule for whether any system change may happen; every system command goes through the injected `CommandRunner`.
- **Safety on the owner's machine:** never run osascript-with-privileges, sudo, `launchctl` or `security` trust commands for real; never write under `/etc`, `/Library`, `~/Library/LaunchAgents` or the real `~/.zshrc`; never bind 80, 443, 53 or 53535; never launch the app or daemon without `PADDOCK_HOME` on a short scratch dir and all three port variables on free high ports; never signal a process you did not start. A bind-only or connect-only probe of ports 81 and 444 is allowed.
- Identifiers: LaunchDaemon label `app.paddock.ports`; plist `/Library/LaunchDaemons/app.paddock.ports.plist`; helper installed at `/Library/PrivilegedHelperTools/app.paddock.ports`; launchd socket names `http` and `https`; Unix sockets `<home>/run/http.sock` and `<home>/run/https.sock`.

## Review Focus

1. **Web server not running** (stopped, crashed, mid-restart): a connection through the helper is closed promptly, the helper keeps running, and the next connection after Caddy returns works. Test in Task 1 and Task 2.
2. **Large and slow transfers**: a multi-megabyte response and a slow client are delivered completely and in order; one stalled connection does not block others. Test in Task 1.
3. **Half-closed connections and abrupt disconnects**: client closes its write side and still receives the full response; a client that resets mid-transfer does not kill the helper (no SIGPIPE) or leak file descriptors. Test in Task 1.
4. **Something else already listening on 80/443 at install time**: no password prompt, nothing installed, the holder is named. Test in Task 3.
5. **Unix socket path too long** (home paths approaching the ~104-byte limit): a clear error naming the path, not a hang or a generic failure. Test in Task 2.

---

## File Structure

```
Sources/paddock-ports/main.swift        # or a small C target if launch.h cannot be imported from Swift
Sources/PaddockCore/Paths.swift         # + httpSocket, httpsSocket
Sources/PaddockCore/Web/Caddyfile.swift # bind Unix sockets
Sources/PaddockCore/Engine.swift        # start helper child in development homes
Sources/PaddockCore/Process/PortCheck.swift   # connection-based check
Sources/PaddockCore/System/PortHelper.swift   # install/uninstall script fragments, plist, status
Sources/PaddockCore/System/Resolver.swift     # privileged script composes resolver + port-helper steps
Sources/PaddockCore/System/SystemLifecycle.swift
Scripts/bundle.sh                       # ship paddock-ports
Tests/IntegrationTests/PortHelperTests.swift
Tests/PaddockCoreTests/PortHelperInstallTests.swift
```

---

### Task 1: The `paddock-ports` helper

**Files:**
- Create: `Sources/paddock-ports/` (new executable target `paddock-ports` in `Package.swift`), `Tests/IntegrationTests/PortHelperTests.swift`

**Interfaces:**
- Produces the executable `paddock-ports` with exactly two invocation forms:
  - `paddock-ports launchd <http-socket-path> <https-socket-path>` — obtains listening sockets from launchd with `launch_activate_socket("http", …)` and `launch_activate_socket("https", …)` (each may return several file descriptors: IPv4 and IPv6); exits 78 with a message on stderr if launchd provides none.
  - `paddock-ports listen <http-port> <https-port> <http-socket-path> <https-socket-path>` — binds `127.0.0.1:<port>` and `[::1]:<port>` itself for both ports (`SO_REUSEADDR`), for development homes and tests; exits 1 with a message if a bind fails.
  - Any other arguments: usage on stderr, exit 64.
- Behaviour: for each accepted connection, connect to the matching Unix socket; if that fails, close the client connection immediately. Otherwise copy bytes both ways until both directions have ended; propagate half-close (`shutdown(SHUT_WR)`) in each direction; close both ends. Ignore SIGPIPE. Never exits because of a single connection's error. SIGTERM exits 0.
- No config files, no environment variables read, no logging except one line to stderr on start and on fatal errors.
- Connection-heavy but small scale (a developer's browser): one thread per connection or an event loop, builder's choice; cap concurrent connections at 512 and close new ones beyond that.

- [ ] **Step 1:** Add the target. If `launch_activate_socket` cannot be imported in Swift via `Darwin`/`launch`, implement the helper as a C target (`Sources/paddock-ports/main.c`); record the choice in the commit message.
- [ ] **Step 2:** Write failing integration tests using the `listen` form on free high ports and a test-owned Unix-socket server:

```swift
func testForwardsRequestAndResponse()        // echo server; bytes round-trip on the http port and on the https port, each to its own socket
func testIPv6LoopbackIsServed()              // connect to [::1]
func testUpstreamDownClosesConnectionPromptly() // no Unix server: client sees EOF/reset within 1s; helper still alive; after starting the server the next connection works
func testLargeTransferIsCompleteAndOrdered() // 8 MB each way, compared by SHA-256
func testHalfCloseStillDeliversResponse()    // client shuts down write side, still reads full reply
func testAbruptClientResetDoesNotKillHelper()// SO_LINGER 0 close mid-transfer; helper alive; fd count of helper returns to baseline (lsof -p)
func testManyParallelConnections()           // 100 concurrent round-trips all succeed
func testStalledConnectionDoesNotBlockOthers()
func testBadArgumentsExit64()
func testSIGTERMExitsZero()
```

- [ ] **Step 3:** Run `swift test --filter PortHelperTests`; expect FAIL (binary missing). Implement. Re-run; expect PASS.
- [ ] **Step 4:** Check the binary links only against system libraries (`otool -L`) and is small. Commit.

---

### Task 2: Caddy on Unix sockets, helper in development homes, connection-based port check

**Files:**
- Modify: `Sources/PaddockCore/Paths.swift`, `Web/Caddyfile.swift`, `Engine.swift`, `Process/PortCheck.swift`, `Messages.swift`, IPC status types as needed
- Test: `Tests/PaddockCoreTests/CaddyfileTests.swift`, `PortCheckTests.swift`, `Tests/IntegrationTests/CaddyValidateTests.swift`, `EngineTests.swift`, `PHPVersionsTests.swift`, `DaemonTests.swift`, `CLITests.swift`

**Interfaces:**
- Consumes: `paddock-ports listen …` from Task 1; `Supervisor`, `Engine`, `Settings`, `Bundled.resources` as they exist after the final-review fix wave (read the current code first).
- Produces:
  - `Paths.httpSocket` = `<home>/run/http.sock`, `Paths.httpsSocket` = `<home>/run/https.sock`.
  - `Caddyfile.render`: no `default_bind` with IP addresses; every HTTP site block has `bind "unix/<httpSocket>"` and every HTTPS site block `bind "unix/<httpsSocket>"` (quoted for paths with spaces). `http_port`/`https_port` global options stay set to `settings.httpPort`/`settings.httpsPort` so URL and redirect generation keep the public ports. Redirect targets unchanged (`https://{host}{uri}` at 443, with port otherwise).
  - `PortHelperLocator.binary() -> URL?` — `paddock-ports` beside the running executable, else `<Bundled.resources>/../MacOS/paddock-ports`, else `<Bundled.resources>/paddock-ports` (for `Vendor`-style layouts used by tests: tests pass the built product path explicitly).
  - `Engine`: when `SystemIntegration.isEnabled` is false (development home), after Caddy is ready it supervises `paddock-ports listen <httpPort> <httpsPort> <httpSocket> <httpsSocket>` as a child named `ports`; when true it does not start the helper (launchd owns it, Task 3). Readiness = the Unix sockets exist and accept a connection.
  - `PortCheck.holders(of:)`: a port is "held" iff a TCP connect to `127.0.0.1:<port>` or `[::1]:<port>` succeeds (200 ms timeout). `lsof` is still used afterwards to name the holder where it can. The `ports_not_permitted` state added by the fix wave is removed, with its message and status field.
  - Before start, in a development home the engine checks its own two ports are free; on the real system the check that matters happens at install (Task 3), and at start the engine only reports whether the port helper is installed (`EngineStatus.portHelperInstalled`, real value in Task 3; `true` in development homes).
  - A Unix socket path longer than 103 bytes fails start with `Messages.socketPathTooLong(path)`: `Paddock's folder path is too long for macOS sockets: <path>`.

- [ ] **Step 1:** Update `CaddyfileTests` expectations (bind lines, no IP `default_bind`, spaced home quoted) and add `testSocketPathTooLongIsReported`; update `PortCheckTests` for connect-based detection (listener on a free high port → held; closed port → free; a bind-only probe is no longer used). Run; expect FAIL.
- [ ] **Step 2:** Implement `Paths`, `Caddyfile`, `PortCheck`. Unit tests and `CaddyValidateTests` PASS.
- [ ] **Step 3:** Add to `EngineTests`: `testServesThroughPortHelperOverUnixSockets` (existing HTTP tests must now pass through the helper unchanged), `testCaddyHasNoTCPListeners` (`lsof -a -p <caddy pid> -iTCP -sTCP:LISTEN` is empty), `testHelperSurvivesCaddyRestart` (kill the engine's own Caddy; after the supervisor restarts it, requests succeed without restarting the helper), `testWebServerDownClosesConnection`. Run; FAIL.
- [ ] **Step 4:** Implement the engine changes. Every existing integration test (`EngineTests`, `PHPVersionsTests`, `DaemonTests`, `CLITests`, HTTPS tests) must pass through the helper with no change to what they assert about HTTP behaviour. Run the full suite; expect all PASS. Commit.

---

### Task 3: Install, uninstall, status, bundle

**Files:**
- Create: `Sources/PaddockCore/System/PortHelper.swift`, `Tests/PaddockCoreTests/PortHelperInstallTests.swift`
- Modify: `System/Resolver.swift` (script composition), `System/SystemLifecycle.swift`, `Engine.swift` (status), `Messages.swift`, `Sources/paddock/ServiceCommands.swift`, `Sources/PaddockCore/App/AppModel.swift` (status line only), `Scripts/bundle.sh`
- Test: `Tests/PaddockCoreTests/ResolverTests.swift`, `SystemLifecycleTests.swift`, `LaunchAgentTests.swift` as needed

**Interfaces:**
- Produces:
  - `struct PortHelper { init(source: URL, user: String, paths: Paths, runner: CommandRunner, installedBinary: URL = /Library/PrivilegedHelperTools/app.paddock.ports, plist: URL = /Library/LaunchDaemons/app.paddock.ports.plist); func plistData() throws -> Data; func isInstalled() -> Bool; func installScriptFragment() throws -> String; func uninstallScriptFragment() -> String }`
  - `plistData()` (built with `PropertyListSerialization`): `Label` `app.paddock.ports`; `ProgramArguments` `[installedBinary, "launchd", httpSocket, httpsSocket]`; `UserName` = the installing user's short name; `Sockets` = `{ http: [ {SockNodeName: "127.0.0.1", SockServiceName: "80"}, {SockNodeName: "::1", SockServiceName: "80"} ], https: [ …"443" twice ] }`; `ProcessType` `Interactive`; no `RunAtLoad`, no `KeepAlive` (launchd starts it on the first connection).
  - `isInstalled()`: the installed binary exists, its SHA-256 equals the bundled helper's, and the installed plist's bytes equal `plistData()`. No privileges needed.
  - `installScriptFragment()`: shell text appended to the single privileged script. It: refuses (distinct marker `PADDOCK_PORTS_BUSY`, exit 0, nothing changed) if a TCP connect to 127.0.0.1 port 80 or 443 succeeds (`/usr/bin/nc -z -G 1`), unless the existing loaded job is Paddock's own; writes the helper from embedded base64 to a root `mktemp` file in `/Library/PrivilegedHelperTools`, verifies its SHA-256 against the embedded expected hash (`/usr/bin/shasum -a 256`), `chmod 755`, `chown root:wheel`, `mv` into place; writes the plist the same way (`chmod 644`, `chown root:wheel`); `/bin/launchctl bootout system/app.paddock.ports` (ignored if not loaded) then `/bin/launchctl bootstrap system <plist>`. Any failure removes temp files and exits non-zero. All paths single-quoted; whole script AppleScript-escaped, as the resolver script already does.
  - `uninstallScriptFragment()`: `launchctl bootout system/app.paddock.ports` (ignore "not loaded"), remove the plist and the installed binary.
  - The privileged install runs **one** `osascript` call containing the port-helper fragment followed by the resolver steps; uninstall runs one call containing the resolver restore followed by the port-helper removal. If the port fragment reports busy, the resolver is not touched.
  - `ResolverError`/lifecycle outcome gains `.portsBusy`; CLI and app show `Messages.portsBlocked(holders)` using the connection-based `PortCheck` to name the holder. The lifecycle also runs that check **before** prompting, so the normal busy case never shows a password prompt.
  - `SystemLifecycle` start order on the real system: daemon up → if `!portHelper.isInstalled() || !resolver.isInstalled()`: check ports → one privileged call → wait for status. Subsequent starts with both installed issue no `osascript` call.
  - `EngineStatus.portHelperInstalled` is real (via an injected check). Menu status line and `paddock status` show `Running` only when the engine runs and the helper is installed; otherwise `Finish setup: run paddock start` (CLI) / a `Finish Setup…` menu item that runs the same start path (app).
  - `Scripts/bundle.sh` ships `Contents/MacOS/paddock-ports`, signs it with the other nested executables.

- [ ] **Step 1:** Failing unit tests with the recording fake and temp paths: plist has exactly the keys above and loopback-only socket entries (assert no entry lacks `SockNodeName`); `isInstalled` true/false for matching, different-binary, different-plist and missing cases; the install fragment for hostile paths is correctly quoted (reuse the existing reverse-escaping test approach); running the generated install and uninstall scripts **as the current user under `/bin/sh` against temp directories, with `launchctl`, `chown` and `nc` replaced by stub scripts on a temp `PATH`-free indirection** (the script takes tool paths from variables the test overrides) proves: files land with the right contents and modes, a checksum mismatch aborts and leaves nothing, a busy port prints the marker and changes nothing, uninstall removes both files. Lifecycle tests: fresh start issues exactly one `osascript` call containing both the port-helper and resolver steps; start with ports busy issues none and returns the blocked outcome; start with everything installed issues none; uninstall issues exactly one containing both removals; cancelled prompt leaves nothing half-installed and the agent not started.
- [ ] **Step 2:** Run; FAIL. Implement. PASS.
- [ ] **Step 3:** Update `bundle.sh`; run it; verify `dist/Paddock.app/Contents/MacOS/paddock-ports` exists, is x86_64, and `codesign --verify --deep --strict` passes. Re-run the bundled-app scratch-home smoke check (development home, `PADDOCK_RESOURCES` unset): both fixture sites serve over HTTP through the helper.
- [ ] **Step 4:** Full `swift test`; expect all PASS with clean output. Update the owner switch-over checklist in `docs/superpowers/plans/2026-11-21-paddock-core.md` Task 14 Step 6 to: copy `dist/Paddock.app` to `/Applications` first; quit Herd; open Paddock (one password prompt); `sudo launchctl print system/app.paddock.ports` shows the job; `lsof -nP -iTCP:80 -sTCP:LISTEN` run with sudo shows launchd on `127.0.0.1` and `[::1]` only; then the existing site, HTTPS, isolate and uninstall checks; after uninstall, ports 80/443 are free and `/etc/resolver/test` is restored. Commit.
