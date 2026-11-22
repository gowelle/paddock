# Paddock Stage 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone native macOS app for Intel Macs that serves any folder in a parked directory at `<folder>.test`, with local HTTPS, per-site PHP versions, a `paddock` CLI and a menu bar app.

**Architecture:** One Swift package. `PaddockCore` holds all logic. `paddockd` is a per-user background agent that owns the running processes (Caddy, PHP-FPM, a built-in DNS responder) and listens on a Unix socket. The `paddock` CLI and the SwiftUI menu bar app are thin clients of `paddockd`. Request routing inside PHP reuses Laravel Valet's router and drivers.

**Tech Stack:** Swift 6.2 toolchain (language mode 5), SwiftPM, swift-argument-parser, SwiftUI `MenuBarExtra`, XCTest, Caddy 2.x, static PHP builds, Composer, Laravel Valet router (vendored, MIT).

**Spec:** `docs/superpowers/specs/2026-11-21-paddock-core-design.md`

## Global Constraints

- Target x86_64, macOS 13 or later. `platforms: [.macOS(.v13)]`.
- No dependency on Homebrew or MacPorts at build output or at run time. Tests must not use `/opt/local` binaries.
- **Development never touches the live setup.** The machine runs Herd 1.30.2 on 127.0.0.1:80/443 and owns `/etc/resolver/test`. Every test and every manual run in this plan uses `PADDOCK_HOME` pointed at a temp dir and high ports. No task writes `/etc/resolver/test`, binds 80/443, or stops Herd, except the final owner-run checklist in Task 14.
- Nothing asks the user a question Paddock could answer itself. No port, path or config prompts.
- Paddock never stops another server on its own, never edits another tool's launchd jobs, and only offers to stop processes owned by the current user.
- Bundled programs run as separate processes; never link their code into Paddock binaries.
- PHP 8.1 and later only.
- Private repository. Licence: proprietary, all rights reserved.
- Identifier prefix: `app.paddock`. Durable state lives only in `state.json`; everything in `config/` is regenerated.
- All state under `~/Library/Application Support/Paddock/`, overridable with the `PADDOCK_HOME` environment variable.
- Commit after every task. End commit messages with the attribution line the session provides.

## Review Focus

1. **Folder names that are not valid host names** (`My App`, `shop_v2`, `Blog.Old`): the site is still served, at a predictable lowercase hyphenated name (`my-app.test`, `shop-v2.test`, `blog-old.test`). Test in Task 3.
2. **Ports 80/443 already held at start** (Herd is running): Paddock does not start Caddy, does not hang, and `status` names the holder. Test in Task 9.
3. **`state.json` missing, empty or corrupt**: Paddock starts with defaults, and a corrupt file is moved aside to `state.json.corrupt-<timestamp>` rather than overwritten or crashing. Test in Task 2.
4. **PHP download interrupted or checksum mismatch**: nothing is left in `bin/php/<version>/`, the error says which version and why, and a retry works. Test in Task 4.
5. **A parked folder or link target disappears** (deleted, drive unmounted): its sites vanish from the list, other sites keep serving, the daemon keeps running. Test in Task 3.

---

## File Structure

```
Package.swift
LICENSE
THIRD-PARTY-NOTICES
.gitignore                      # .build/, Vendor/, dist/, .DS_Store
Scripts/
  fetch-vendor.sh               # downloads Caddy, Composer, PHP, Valet into Vendor/
  bundle.sh                     # assembles dist/Paddock.app
  versions.lock                 # pinned versions + SHA-256 of every vendored file
Resources/
  php-manifest.json             # bundled PHP manifest
  Info.plist                    # app bundle plist (LSUIElement = true)
  router/                       # vendored Valet router (committed, with PATCHES.md)
Sources/
  PaddockCore/
    Paths.swift                 # every filesystem location
    Settings.swift              # ports and other internals, env-overridable
    State.swift                 # state.json model + StateStore
    Sites.swift                 # Site, SiteName, SiteRegistry
    PHP/PHPVersion.swift
    PHP/PHPManifest.swift
    PHP/PHPInstaller.swift
    PHP/FPMConfig.swift
    PHP/PHPResolver.swift       # which PHP for a directory
    Web/Caddyfile.swift         # config generation
    Web/RouterConfig.swift      # Valet config.json + Sites symlinks
    DNS/DNSMessage.swift        # pure packet parse/build
    DNS/DNSResponder.swift      # UDP listener
    Process/Supervisor.swift
    Process/PortCheck.swift
    System/Resolver.swift       # /etc/resolver/test install/restore
    System/CertificateTrust.swift
    System/LaunchAgent.swift
    IPC/Protocol.swift          # Request / Response
    IPC/Server.swift
    IPC/Client.swift
    Engine.swift                # ties it together; what paddockd runs
  paddockd/main.swift
  paddock/                      # CLI, one file per command group
    Paddock.swift               # root command + multi-call dispatch (php, composer)
    SiteCommands.swift
    PHPCommands.swift
    ServiceCommands.swift
  PaddockApp/
    PaddockApp.swift            # MenuBarExtra
    AppModel.swift              # polls paddockd
    MenuView.swift
    Settings/GeneralTab.swift
    Settings/PHPTab.swift
    Settings/SitesTab.swift
    AboutView.swift
Tests/
  PaddockCoreTests/             # one test file per source file
  IntegrationTests/             # real Caddy + PHP on high ports
  Fixtures/plain-php/index.php
  Fixtures/laravel-like/public/index.php, artisan
```

---

### Task 1: Repository, package skeleton and vendoring

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`, `THIRD-PARTY-NOTICES`, `Scripts/fetch-vendor.sh`, `Scripts/versions.lock`, `Resources/php-manifest.json`, `Resources/router/` (+ `PATCHES.md`), `Sources/PaddockCore/Paths.swift`, `Sources/PaddockCore/Settings.swift`, stub `main.swift` for `paddockd`, stub root command for `paddock`
- Test: `Tests/PaddockCoreTests/PathsTests.swift`

**Interfaces:**
- Produces:
  - `struct Paths { init(home: URL); static var current: Paths }` (`current` reads `PADDOCK_HOME`, else `~/Library/Application Support/Paddock`). Properties, all `URL`: `home`, `bin`, `phpRoot` (`bin/php`), `config`, `run`, `log`, `stateFile` (`state.json`), `backup`, `caddyData` (`caddy`), `caddyfile` (`config/Caddyfile`), `routerHome` (`config/valet`), `daemonSocket` (`run/paddockd.sock`), `caddyAdminSocket` (`run/caddy-admin.sock`). Methods: `phpDir(_ v: PHPVersion, variant: String = "default") -> URL`, `fpmSocket(_ v: PHPVersion) -> URL` (`run/php-<v>.sock`), `phpIni(_ v: PHPVersion) -> URL` (`php/<v>/php.ini`), `ensureDirectories() throws`.
  - `struct Settings { var httpPort: Int = 80; var httpsPort: Int = 443; var dnsPort: Int = 53535; var tld = "test"; static var current: Settings }` (`current` reads `PADDOCK_HTTP_PORT`, `PADDOCK_HTTPS_PORT`, `PADDOCK_DNS_PORT`).
  - `struct Bundled { static var resources: URL }` — the directory holding `caddy`, `composer.phar`, `router/`, `php/`, `php-manifest.json`. Resolves to `Paddock.app/Contents/Resources` when run from a bundle, else `PADDOCK_RESOURCES`, else `<repo>/Vendor`.
  - `Vendor/` layout after `fetch-vendor.sh`: `Vendor/caddy`, `Vendor/composer.phar`, `Vendor/php/<version>/default/{php,php-fpm}`, `Vendor/router` (symlink to `Resources/router`), `Vendor/php-manifest.json` (copy).

- [ ] **Step 1:** `git init` in the project folder; add `.gitignore`; commit the existing `docs/`.
- [ ] **Step 2:** Write `Package.swift`: tools version 6.0, `swiftLanguageModes: [.v5]`, macOS 13, dependency `swift-argument-parser` (from 1.3.0); targets `PaddockCore` (library), `paddockd`, `paddock`, `PaddockApp` (executables), `PaddockCoreTests`, `IntegrationTests`.
- [ ] **Step 3:** Write the failing test.

```swift
func testPathsHonourHome() throws {
    let p = Paths(home: URL(fileURLWithPath: "/tmp/px"))
    XCTAssertEqual(p.stateFile.path, "/tmp/px/state.json")
    XCTAssertEqual(p.fpmSocket(PHPVersion("8.4")!).path, "/tmp/px/run/php-8.4.sock")
    XCTAssertEqual(p.phpDir(PHPVersion("8.4")!).path, "/tmp/px/bin/php/8.4/default")
    XCTAssertEqual(p.daemonSocket.path, "/tmp/px/run/paddockd.sock")
}
func testSettingsDefaults() {
    XCTAssertEqual(Settings().httpPort, 80); XCTAssertEqual(Settings().dnsPort, 53535)
}
```

- [ ] **Step 4:** Run `swift test --filter PathsTests`; expect a compile failure. Implement `Paths`, `Settings`, `Bundled` and a minimal `PHPVersion` (finished in Task 4). Re-run; expect PASS.
- [ ] **Step 5:** Write `Scripts/fetch-vendor.sh`. It downloads, into `Vendor/`: the latest stable Caddy 2.x `mac_amd64` tarball from Caddy's GitHub releases; the latest stable `composer.phar` from getcomposer.org; the newest PHP **8.5** `cli` and `fpm` `macos-x86_64` tarballs from `https://dl.static-php.dev/static-php-cli/bulk/` (follow redirects with `curl -L`). On first run it records each URL and SHA-256 in `Scripts/versions.lock`; on later runs it downloads exactly what the lock names and fails on a checksum mismatch.
- [ ] **Step 6:** Vendor Valet's router into `Resources/router/`: from the latest Laravel Valet v4 tag, copy `server.php`, `cli/Valet/Server.php`, `cli/Valet/Drivers/`, `cli/includes/require-drivers.php` and whatever those files `require`. Read the copied source and patch it so (a) the Valet home path comes from the `PADDOCK_ROUTER_HOME` FastCGI param instead of the user's `~/.config/valet`, and (b) nothing references Homebrew paths. Record the tag and every edit in `Resources/router/PATCHES.md`. Keep Valet's MIT licence file beside it.
- [ ] **Step 7:** Write `Resources/php-manifest.json` with every 8.1–8.5 latest-patch `bulk` build for `macos-x86_64`, shape:

```json
{ "builds": [ { "version": "8.4", "patch": "8.4.x", "variant": "default",
    "cli": { "url": "…", "sha256": "…" }, "fpm": { "url": "…", "sha256": "…" } } ] }
```

Compute each SHA-256 from the downloaded file.
- [ ] **Step 8:** Write `LICENSE` (proprietary, all rights reserved, copyright holder "John Gowelle", 2026; binaries free to install and use, no redistribution or modification, no warranty) and `THIRD-PARTY-NOTICES` (Caddy Apache-2.0, PHP License, Composer MIT, Laravel Valet MIT, swift-argument-parser Apache-2.0, each with its licence text).
- [ ] **Step 9:** Verify: `Scripts/fetch-vendor.sh && Vendor/caddy version && Vendor/php/8.5/default/php -v && swift build`. Expect a Caddy v2 version line, a PHP 8.5 version line, and a clean build. Commit.

---

### Task 2: State store

**Files:**
- Create: `Sources/PaddockCore/State.swift`
- Test: `Tests/PaddockCoreTests/StateTests.swift`

**Interfaces:**
- Produces:
  - `struct State: Codable, Equatable { var parked: [String]; var links: [String: String] /* name → path */; var secured: Set<String>; var phpPins: [String: PHPVersion] /* site name → version */; var defaultPHP: PHPVersion?; var previousResolver: String? }`
  - `final class StateStore { init(paths: Paths); func load() -> State; func update(_ body: (inout State) -> Void) throws -> State }`. `update` writes atomically. `load` never throws: missing or empty file returns `State.initial` (parked = `["~/Paddock"]` expanded); a file that fails to decode is renamed `state.json.corrupt-<unix timestamp>` and `State.initial` is returned.

- [ ] **Step 1:** Failing tests: `testMissingFileGivesInitial` (parked has one entry ending `/Paddock`), `testRoundTrip` (update adds a link, a new `StateStore` loads it equal), `testCorruptFileIsMovedAside` (write `"{not json"`, `load()` returns initial, directory contains one file matching `state.json.corrupt-*` and its contents are `"{not json"`), `testEmptyFileGivesInitial`.
- [ ] **Step 2:** Run `swift test --filter StateTests`; expect FAIL. Implement. Re-run; expect PASS. Commit.

---

### Task 3: Sites

**Files:**
- Create: `Sources/PaddockCore/Sites.swift`
- Test: `Tests/PaddockCoreTests/SitesTests.swift`

**Interfaces:**
- Consumes: `State`, `Settings.tld`.
- Produces:
  - `enum SiteName { static func normalize(_ folder: String) -> String? }` — lowercase; any run of characters outside `a-z0-9` becomes one `-`; trim leading/trailing `-`; `nil` if empty.
  - `struct Site: Codable, Equatable, Identifiable { let name: String; let path: String; let kind: Kind /* .parked, .linked */; var secured: Bool; var php: PHPVersion /* effective */; var pinned: Bool; var id: String { name }; var host: String /* name + ".test" */; var url: String }`
  - `struct SiteRegistry { init(state: State, defaultPHP: PHPVersion, fileManager: FileManager = .default); func sites() -> [Site]; func site(named: String) -> Site?; func site(containing directory: String) -> Site? }`. `sites()` lists each immediate subdirectory of each parked path (skipping hidden and non-directories) plus each link whose target exists. Links win over parked folders on a name clash; between two parked folders the earlier parked path wins. Sorted by name. Missing parked paths and missing link targets are skipped silently.

- [ ] **Step 1:** Failing tests, using a temp directory tree:

```swift
func testNormalize() {
    XCTAssertEqual(SiteName.normalize("My App"), "my-app")
    XCTAssertEqual(SiteName.normalize("shop_v2"), "shop-v2")
    XCTAssertEqual(SiteName.normalize("Blog.Old"), "blog-old")
    XCTAssertNil(SiteName.normalize("___"))
}
```

plus `testParkedFoldersBecomeSites`, `testLinkOverridesParked`, `testHiddenAndFilesSkipped`, `testMissingParkedPathAndLinkTargetSkipped` (state names a non-existent parked path and a link to a deleted folder; `sites()` returns the remaining sites and does not throw), `testSiteContainingDirectory` (a nested subdirectory resolves to its site), `testPinAndSecuredApplied`.
- [ ] **Step 2:** Run `swift test --filter SitesTests`; FAIL. Implement. PASS. Commit.

---

### Task 4: PHP versions, manifest and installer

**Files:**
- Create: `Sources/PaddockCore/PHP/PHPVersion.swift`, `PHPManifest.swift`, `PHPInstaller.swift`
- Test: `Tests/PaddockCoreTests/PHPInstallerTests.swift`

**Interfaces:**
- Produces:
  - `struct PHPVersion: Codable, Hashable, Comparable, CustomStringConvertible { init?(_ s: String) }` — accepts `"8.4"`, `"8.4.8"`, `"php@8.4"`, `"84"`; stores major.minor; rejects below 8.1; encodes as the string `"8.4"`.
  - `struct PHPManifest: Codable { struct Build { version, patch, variant, cli: Asset, fpm: Asset }; struct Asset { url: URL; sha256: String }; static func bundled() throws -> PHPManifest; static func remote(_ url: URL) async throws -> PHPManifest; func build(for: PHPVersion, variant: String = "default") -> Build? }`
  - `final class PHPInstaller { init(paths: Paths, manifest: PHPManifest, session: URLSession = .shared); func installed() -> [PHPVersion]; func isInstalled(_:) -> Bool; func installBundled() throws -> PHPVersion; func install(_ v: PHPVersion, progress: ((Double) -> Void)? = nil) async throws; func remove(_ v: PHPVersion) throws; func phpBinary(_:) -> URL; func fpmBinary(_:) -> URL }`
  - `enum PHPInstallError: Error, Equatable { case notInManifest(PHPVersion); case checksumMismatch(PHPVersion, file: String); case downloadFailed(PHPVersion, reason: String); case inUse(PHPVersion) }`
- `install` downloads both assets to a temp dir inside `paths.home`, verifies SHA-256, extracts, marks executable, then moves the finished directory into place in one rename. `installBundled` copies `Bundled.resources/php/<v>/default` and is a no-op if already present. It also writes `php/<v>/php.ini` if absent (Task 5 supplies the contents).

- [ ] **Step 1:** Failing tests using a `URLProtocol` stub and tiny tar.gz fixtures built in the test: `testVersionParsing`, `testInstallPlacesBinaries`, `testChecksumMismatchLeavesNothing` (expect `.checksumMismatch`; `paths.phpDir(v)` does not exist; no temp directory remains under `paths.home`), `testInterruptedDownloadLeavesNothingAndRetryWorks`, `testNotInManifest`, `testInstallBundledIsIdempotent`.
- [ ] **Step 2:** Run `swift test --filter PHPInstallerTests`; FAIL. Implement. PASS. Commit.

---

### Task 5: PHP-FPM config and php.ini

**Files:**
- Create: `Sources/PaddockCore/PHP/FPMConfig.swift`
- Test: `Tests/PaddockCoreTests/FPMConfigTests.swift`

**Interfaces:**
- Produces:
  - `enum FPMConfig { static func render(version: PHPVersion, paths: Paths) -> String; static func write(version:paths:) throws -> URL /* config/fpm/<v>.conf */; static func defaultIni(paths: Paths) -> String }`
  - Pool values: `listen = <paths.fpmSocket(v)>`, `pm = ondemand`, `pm.max_children = 10`, `pm.process_idle_timeout = 60s`, `error_log = <log>/php-fpm-<v>.log`, `daemonize = no`, `php_admin_value[error_log] = <log>/php-<v>.log`, no `user`/`group` lines.
  - php.ini dev defaults: `memory_limit = 512M`, `upload_max_filesize = 128M`, `post_max_size = 128M`, `max_execution_time = 120`, `display_errors = On`, `error_reporting = E_ALL`, `date.timezone` left unset, `extension_dir = <paths.phpDir(v)>/ext`.
  - FPM launch arguments used by Task 8: `[fpmBinary, "-y", conf, "-c", paths.phpIni(v), "-F"]`.

- [ ] **Step 1:** Failing tests asserting each value above appears in the rendered text and that `write` is idempotent. Run; FAIL. Implement; PASS.
- [ ] **Step 2:** Integration check in `Tests/IntegrationTests/FPMTests.swift`: start the vendored `php-fpm` 8.5 with the rendered config under a temp `PADDOCK_HOME`, assert the socket file appears within 5 seconds and the process is still alive, then terminate it. Run `swift test --filter FPMTests`; PASS. Commit.

---

### Task 6: Caddyfile and router config generation

**Files:**
- Create: `Sources/PaddockCore/Web/Caddyfile.swift`, `Sources/PaddockCore/Web/RouterConfig.swift`
- Test: `Tests/PaddockCoreTests/CaddyfileTests.swift`, `RouterConfigTests.swift`

**Interfaces:**
- Consumes: `Site`, `Paths`, `Settings`, `State`.
- Produces:
  - `enum Caddyfile { static func render(sites: [Site], defaultPHP: PHPVersion, paths: Paths, settings: Settings) -> String }`
  - `enum RouterConfig { static func write(state: State, paths: Paths, settings: Settings) throws }` — writes `config/valet/config.json` as `{"tld":"test","loopback":"127.0.0.1","paths":[<parked…>, "<routerHome>/Sites"]}` and makes `config/valet/Sites/<name>` a symlink for every link, removing stale symlinks. This is Valet's own model for linked sites.

Rendered Caddyfile, in order:

```
{
    admin unix/<caddyAdminSocket>
    http_port <httpPort>
    https_port <httpsPort>
    default_bind 127.0.0.1 [::1]
    local_certs
    skip_install_trust
    auto_https disable_redirects
    storage file_system <caddyData>
}

(paddock_php) {
    reverse_proxy unix/{args[0]} {
        transport fastcgi {
            env SCRIPT_FILENAME <Bundled.resources>/router/server.php
            env PADDOCK_ROUTER_HOME <routerHome>
        }
        @accel header X-Accel-Redirect *
        handle_response @accel {
            root * /
            rewrite * {rp.header.X-Accel-Redirect}
            uri strip_prefix <Valet's static prefix, read from the vendored Server.php>
            file_server
        }
    }
}

http://*.test { import paddock_php <fpmSocket(defaultPHP)> }
```

Then one block per site that is secured or pinned:

- pinned, not secured: `http://<host> { import paddock_php <fpmSocket(site.php)> }`
- secured: `https://<host> { tls internal ; import paddock_php <fpmSocket(site.php)> }` and `http://<host> { redir https://{host}{uri} }`

- [ ] **Step 1:** Failing unit tests: global block contains the admin socket and both ports; wildcard block uses the default version's socket; a pinned site gets its own block with its version's socket; a secured site gets an `https://` block with `tls internal` plus an HTTP redirect block; an unsecured unpinned site produces no block of its own; output is identical for the same input in any order. `RouterConfigTests`: JSON has the parked paths plus the `Sites` dir; links become symlinks; a removed link's symlink is deleted.
- [ ] **Step 2:** Run `swift test --filter CaddyfileTests` and `--filter RouterConfigTests`; FAIL. Implement; PASS.
- [ ] **Step 3:** Validate against the real binary: a test that renders a config with ports 18080/18443 and runs `Vendor/caddy validate --config <file> --adapter caddyfile`, expecting exit 0. If Caddy rejects a directive, fix the template and the expectations above, and note the change in the commit. Commit.

---

### Task 7: DNS responder

**Files:**
- Create: `Sources/PaddockCore/DNS/DNSMessage.swift`, `DNSResponder.swift`
- Test: `Tests/PaddockCoreTests/DNSMessageTests.swift`, `Tests/IntegrationTests/DNSResponderTests.swift`

**Interfaces:**
- Produces:
  - `enum DNSMessage { static func response(to query: Data, tld: String) -> Data? }` — pure. For a single-question query whose name is `<tld>` or ends `.<tld>`: type A → one answer `127.0.0.1`; type AAAA → one answer `::1`; any other type → NOERROR with zero answers. TTL 60. Names outside the TLD → NXDOMAIN. Malformed or multi-question packets → `nil` (drop). Response copies the ID and question, sets QR, AA, and RD as received.
  - `final class DNSResponder { init(port: Int, tld: String); func start() throws; func stop() }` — UDP on `127.0.0.1:<port>` only.

- [ ] **Step 1:** Failing unit tests with hand-built query packets: `testAQuery` (answer RDATA `7F 00 00 01`), `testAAAAQuery`, `testMXQueryHasNoAnswers`, `testOtherTLDIsNXDOMAIN`, `testTruncatedPacketIsDropped`, `testNameIsCaseInsensitive` (`MyApp.TEST`).
- [ ] **Step 2:** Run `swift test --filter DNSMessageTests`; FAIL. Implement; PASS.
- [ ] **Step 3:** Integration test: start a responder on port 53599, run `dig +short -p 53599 @127.0.0.1 anything.test A`, expect `127.0.0.1`. PASS. Commit.

---

### Task 8: Supervisor, port check and engine

**Files:**
- Create: `Sources/PaddockCore/Process/Supervisor.swift`, `Process/PortCheck.swift`, `Engine.swift`
- Test: `Tests/PaddockCoreTests/SupervisorTests.swift`, `PortCheckTests.swift`, `Tests/IntegrationTests/EngineTests.swift`, fixtures under `Tests/Fixtures/`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces:
  - `final class Supervisor { func start(_ spec: ProcessSpec) throws; func stop(_ name: String); func stopAll(); func status(_ name: String) -> ProcessStatus }` with `struct ProcessSpec { name: String; executable: URL; arguments: [String]; environment: [String: String]; logFile: URL }` and `enum ProcessStatus { case running(pid: Int32), stopped, crashed(exitCode: Int32) }`. A process that exits unexpectedly is restarted with backoff 1s, 2s, 4s, capped at 30s; after 5 consecutive failures inside 60 seconds it is left `crashed`.
  - `struct PortHolder: Codable, Equatable { let port: Int; let pid: Int32?; let command: String?; let ownedByCurrentUser: Bool }` and `enum PortCheck { static func holders(of ports: [Int]) -> [PortHolder] }`. Uses `lsof -nP -iTCP:<port> -sTCP:LISTEN`; if that shows nothing, attempts to bind `127.0.0.1:<port>`; a failed bind yields a holder with `pid == nil`, `ownedByCurrentUser == false`.
  - `final class Engine { init(paths: Paths = .current, settings: Settings = .current); func start() throws; func stop(); func reload() throws; func status() -> EngineStatus; var store: StateStore; var installer: PHPInstaller }`
  - `struct EngineStatus: Codable { var running: Bool; var blockedBy: [PortHolder]; var sites: [Site]; var installedPHP: [PHPVersion]; var defaultPHP: PHPVersion?; var processes: [String: String]; var resolverInstalled: Bool }`
- `Engine.start()`: ensure directories; `installBundled()` if no PHP is installed and set `defaultPHP`; create the first parked directory if missing; check ports and, if held, set `blockedBy` and start nothing; otherwise write router config, FPM configs and Caddyfile, start one FPM per version in use (default plus every pin), start Caddy as `caddy run --config <caddyfile> --adapter caddyfile` with `XDG_DATA_HOME` and `XDG_CONFIG_HOME` inside `paths.home`, and start the DNS responder.
- `Engine.reload()`: regenerate configs, start/stop FPM pools to match versions in use, then `caddy reload --config <caddyfile> --adapter caddyfile --address unix/<caddyAdminSocket>`.

- [ ] **Step 1:** Failing unit tests: Supervisor restarts `/bin/sh -c 'exit 1'` and reports `crashed` after the fifth failure; `stop` prevents restart; `PortCheckTests.testDetectsListener` opens a listener on a free high port and expects a holder with this process's pid and `ownedByCurrentUser == true`; `testFreePortHasNoHolder`.
- [ ] **Step 2:** Run; FAIL. Implement `Supervisor` and `PortCheck`; PASS.
- [ ] **Step 3:** Create fixtures: `plain-php/index.php` echoing `plain:` + `PHP_VERSION`; `laravel-like/public/index.php` echoing `laravel:` + `$_SERVER['REQUEST_URI']`, an empty `laravel-like/artisan`, and `laravel-like/public/robots.txt` containing `static-ok`.
- [ ] **Step 4:** Failing integration tests in `EngineTests`, each with a temp `PADDOCK_HOME`, ports 18080/18443/53598, and the fixtures copied into a temp parked directory:

```swift
func testServesParkedPlainSite()   // GET http://127.0.0.1:18080/ Host: plain-php.test → body starts "plain:8.5"
func testServesLaravelFrontController() // Host: laravel-like.test, path /users/7 → "laravel:/users/7"
func testServesStaticFile()        // Host: laravel-like.test, path /robots.txt → "static-ok"
func testUnknownSiteIs404()        // Host: nope.test → 404
func testNewFolderIsServedWithoutReload() // mkdir a new site after start → 200
func testBlockedPortsReported()    // hold 18080 first → start() returns, status().running == false, blockedBy[0].port == 18080
```

- [ ] **Step 5:** Run `swift test --filter EngineTests`; FAIL. Implement `Engine`. Iterate on the Caddy template and the router patch until all six pass. Record any router patch in `Resources/router/PATCHES.md`. Commit.

---

### Task 9: IPC and the daemon

**Files:**
- Create: `Sources/PaddockCore/IPC/Protocol.swift`, `Server.swift`, `Client.swift`; replace `Sources/paddockd/main.swift`
- Test: `Tests/PaddockCoreTests/IPCTests.swift`, `Tests/IntegrationTests/DaemonTests.swift`

**Interfaces:**
- Produces:
  - `enum Request: Codable { case status, start, stop, restart; case park(path: String), forget(path: String); case link(name: String, path: String), unlink(name: String); case secure(site: String), unsecure(site: String); case isolate(site: String, version: PHPVersion), unisolate(site: String); case use(version: PHPVersion); case installPHP(version: PHPVersion), removePHP(version: PHPVersion); case shutdown }`
  - `enum Response: Codable { case ok(EngineStatus); case error(code: String, message: String) }`. Error codes: `unknown_site`, `not_a_directory`, `php_not_installed`, `php_in_use`, `php_not_available`, `ports_blocked`, `needs_trust`, `internal`.
  - `final class IPCServer { init(socket: URL, handler: @escaping (Request) async -> Response); func start() throws; func stop() }` — one newline-terminated JSON request, one newline-terminated JSON response, per connection. Socket file mode 0600.
  - `struct PaddockClient { init(paths: Paths = .current); func send(_ r: Request, timeout: TimeInterval = 600) throws -> Response; var daemonIsRunning: Bool }` — throws `ClientError.daemonNotRunning` when the socket is absent or refuses.
  - `Engine.handle(_ r: Request) async -> Response` — mutates state through `StateStore.update`, calls `reload()`, returns fresh status. `park`/`link` validate the path is a directory. `isolate` and `use` return `php_not_installed` if the version is absent. `removePHP` returns `php_in_use` if it is the default or pinned. `secure`/`unsecure`/`isolate`/`unisolate` return `unknown_site` for a name not in the registry. `secure` behaviour is completed in Task 11.
  - `paddockd`: creates an `Engine`, calls `start()`, serves IPC, handles SIGTERM/SIGINT by stopping the engine and removing the socket. A second instance exits with status 0 if the socket already answers `status`.

- [ ] **Step 1:** Failing tests: `Request`/`Response` JSON round-trip for every case; client against an in-process server echoes `status`; `daemonNotRunning` when no socket; `DaemonTests` launches the built `paddockd` binary with a temp home and high ports, then sends `park`, `link`, `isolate` (to a not-installed version → `php_not_installed`), `secure nope` (→ `unknown_site`), and asserts the site list after each; `testStatusNamesPortHolder` holds the HTTP port before launch and asserts `status` returns `running == false` and `blockedBy` contains that port with this test's pid.
- [ ] **Step 2:** Run; FAIL. Implement; PASS. Commit.

---

### Task 10: CLI

**Files:**
- Create: `Sources/paddock/Paddock.swift`, `SiteCommands.swift`, `PHPCommands.swift`, `ServiceCommands.swift`
- Test: `Tests/IntegrationTests/CLITests.swift`

**Interfaces:**
- Consumes: `PaddockClient`, `Request`, `Response`, `EngineStatus`.
- Produces: the `paddock` binary with subcommands `park [path]` (default: current directory), `forget [path]`, `parked`, `link [name]` (default: normalized current folder name), `unlink [name]`, `links`, `secure [site]`, `unsecure [site]`, `isolate <version>`, `unisolate`, `use <version>`, `start`, `stop`, `restart`, `status`, `open [site]`, `logs`. `[site]` defaults to the site containing the current directory. `use` and `isolate` install a missing version first, printing download progress, rather than failing.
- Output rules: success prints one plain sentence (`myapp.test is now served over HTTPS.`). Errors go to stderr with exit code 1. `status` prints running state, default PHP, and a table of sites (name, URL, PHP, secured). When ports are blocked, `status` and `start` print `Paddock can't start: port 80 is in use by <command> (pid <pid>).` and, if the holder is not the user's, `Stop it with: sudo kill <pid>` — Paddock does not run that itself.
- When the daemon is not running, every command except `start` and `status` prints `Paddock isn't running. Start it with: paddock start` and exits 1. `start` launches `paddockd` detached (Task 13 replaces this with the LaunchAgent), then waits up to 10 seconds for the socket.

- [ ] **Step 1:** Failing integration tests that run the built CLI against a daemon on a temp home: `park` then `parked` lists the path; `link` in a fixture dir then `links` shows `<name> → <path>`; `status` output contains the site URL; a command with no daemon prints the not-running sentence and exits 1; `isolate 7.4` exits 1 with a message naming 8.1 as the minimum.
- [ ] **Step 2:** Run `swift test --filter CLITests`; FAIL. Implement; PASS. Commit.

---

### Task 11: HTTPS

**Files:**
- Create: `Sources/PaddockCore/System/CertificateTrust.swift`
- Modify: `Sources/PaddockCore/Engine.swift` (secure/unsecure handling)
- Test: `Tests/PaddockCoreTests/CertificateTrustTests.swift`, add to `Tests/IntegrationTests/EngineTests.swift`

**Interfaces:**
- Produces:
  - `protocol CommandRunner { func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) }` with a real implementation and a recording fake for tests.
  - `struct CertificateTrust { init(paths: Paths, runner: CommandRunner); var rootCertificate: URL /* <caddyData>/pki/authorities/local/root.crt */; func isTrusted() -> Bool; func trust() throws; func untrust() throws }`. `trust()` runs `/usr/bin/security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db <root.crt>` (user-level; macOS shows its own confirmation). `isTrusted()` runs `security verify-cert -c <root.crt>` and checks for exit 0. `untrust()` runs `security remove-trusted-cert <root.crt>`.
  - `Engine` secure flow: add the site to `secured`, reload, wait up to 5 seconds for `root.crt` to exist, then call `trust()` if `isTrusted()` is false. If the user declines, the site stays secured and the response is `error("needs_trust", …)`; the CLI prints `myapp.test is served over HTTPS, but macOS doesn't trust Paddock's certificate yet. Run: paddock trust`. Add `Request.trust` and a `paddock trust` command.
  - `Engine(…, trust: CertificateTrust?)` so tests inject a fake.

- [ ] **Step 1:** Failing unit tests with the fake runner: `trust()` issues exactly the `security` invocation above; `isTrusted()` maps exit 0/non-zero to true/false.
- [ ] **Step 2:** Failing integration tests with a fake trust object: after `secure plain-php`, `curl -k --resolve plain-php.test:18443:127.0.0.1 https://plain-php.test:18443/` returns the plain body; the certificate's issuer contains `Caddy Local Authority`; plain HTTP to that host returns a 3xx to `https://`; after `unsecure` HTTP returns 200 again. The tests never call the real `security` tool.
- [ ] **Step 3:** Run; FAIL. Implement; PASS. Commit.

---

### Task 12: Multiple PHP versions, resolver and shims

**Files:**
- Create: `Sources/PaddockCore/PHP/PHPResolver.swift`
- Modify: `Sources/paddock/Paddock.swift` (multi-call dispatch), `Sources/PaddockCore/Engine.swift`
- Test: `Tests/PaddockCoreTests/PHPResolverTests.swift`, add to `EngineTests` and `CLITests`

**Interfaces:**
- Produces:
  - `struct PHPResolver { init(paths: Paths); func version(forDirectory: String) -> PHPVersion?; func binary(forDirectory: String) -> URL? }` — reads `state.json` directly (no daemon), finds the site containing the directory, returns its pin or the default; `nil` only when no PHP is installed.
  - Multi-call dispatch at the top of `paddock`'s `main`: if `argv[0]`'s last path component is `php`, `execv` the resolved binary with `-c <php.ini>` followed by the original arguments; if it is `composer`, `execv` the resolved PHP with `<Bundled.resources>/composer.phar` and the arguments. With no PHP installed print `No PHP installed. Open Paddock or run: paddock use 8.5` and exit 1.
  - `Engine.installShims() throws` — copies the `paddock` binary to `bin/paddock` and creates `bin/php` and `bin/composer` as symlinks to it. Called from `start()`.
  - `enum ShellPath { static func isConfigured() -> Bool; static func configure() throws }` — appends `export PATH="$HOME/Library/Application Support/Paddock/bin:$PATH"  # Added by Paddock` to `~/.zshrc` once; `isConfigured` looks for the marker comment. Takes the rc file URL as an injectable parameter for tests.

- [ ] **Step 1:** Failing tests: resolver returns the pin inside a pinned site, the default elsewhere, `nil` with nothing installed; `ShellPath.configure` twice leaves exactly one marker line. Integration: install 8.4 from the manifest (real download; skip with `XCTSkip` when offline), `isolate plain-php 8.4`, HTTP body starts `plain:8.4` while `laravel-like` still reports 8.5; running `bin/php -r 'echo PHP_VERSION;'` with the working directory inside `plain-php` prints an 8.4 version and inside `laravel-like` an 8.5 version; `bin/composer --version` prints a Composer version line; `removePHP 8.4` while pinned returns `php_in_use`.
- [ ] **Step 2:** Run; FAIL. Implement; PASS. Commit.

---

### Task 13: Resolver install, LaunchAgent and uninstall

**Files:**
- Create: `Sources/PaddockCore/System/Resolver.swift`, `System/LaunchAgent.swift`
- Modify: `Sources/paddock/ServiceCommands.swift`, `Sources/PaddockCore/Engine.swift`
- Test: `Tests/PaddockCoreTests/ResolverTests.swift`, `LaunchAgentTests.swift`

**Interfaces:**
- Produces:
  - `struct Resolver { init(file: URL = URL(fileURLWithPath: "/etc/resolver/test"), settings: Settings, store: StateStore, runner: CommandRunner); var desiredContents: String /* "nameserver 127.0.0.1\nport 53535\n" */; func isInstalled() -> Bool; func install() throws; func restore() throws }`. `install()` saves any existing file's contents into `State.previousResolver` (only if not already saved and the file is not Paddock's own), then writes the file with one admin prompt via `/usr/bin/osascript -e 'do shell script "…" with administrator privileges'`. `restore()` writes `previousResolver` back, or deletes the file if there was none, through the same mechanism, then clears the saved value.
  - `struct LaunchAgent { init(runner: CommandRunner, plist: URL = ~/Library/LaunchAgents/app.paddock.paddockd.plist); func plistContents(daemon: URL) -> String; func install(daemon: URL) throws; func uninstall() throws; func isLoaded() -> Bool }` — label `app.paddock.paddockd`, `RunAtLoad` true, `KeepAlive` `{ SuccessfulExit: false }`, stdout/stderr to `log/paddockd.log`. Uses `launchctl bootstrap gui/<uid>` and `launchctl bootout gui/<uid>/app.paddock.paddockd`.
  - CLI: `paddock start` installs the resolver if `!isInstalled()`, then installs and loads the LaunchAgent (replacing Task 10's detached launch). `paddock stop` boots the agent out. New `paddock uninstall`: stops the agent, removes the plist, restores the resolver, removes the Paddock CA trust, and prints what it left behind (`~/Library/Application Support/Paddock` and `~/Paddock`), deleting neither.
  - When `PADDOCK_HOME` is set, `start` skips both the resolver and the LaunchAgent and uses the detached launch, so tests and development can never touch the system.

- [ ] **Step 1:** Failing tests with the fake runner and a temp file standing in for `/etc/resolver/test`: `install()` on a file containing `nameserver 127.0.0.1` stores that text in `previousResolver` and issues one `osascript` call whose script writes `desiredContents`; `install()` a second time does not overwrite the saved value; `restore()` issues a script writing the saved text back and clears it; `restore()` with nothing saved issues a script that removes the file; `plistContents` contains the label, the daemon path and `KeepAlive`; with `PADDOCK_HOME` set the CLI `start` issues no `osascript` or `launchctl` call.
- [ ] **Step 2:** Run; FAIL. Implement; PASS. Commit.

---

### Task 14: Menu bar app, bundle and owner switch-over

**Files:**
- Create: `Sources/PaddockApp/PaddockApp.swift`, `AppModel.swift`, `MenuView.swift`, `Settings/GeneralTab.swift`, `Settings/PHPTab.swift`, `Settings/SitesTab.swift`, `AboutView.swift`, `Resources/Info.plist`, `Scripts/bundle.sh`
- Test: `Tests/PaddockCoreTests/AppModelTests.swift` (move `AppModel` into `PaddockCore` if needed for testability), `Scripts/bundle.sh` smoke check

**Interfaces:**
- Consumes: `PaddockClient`, `EngineStatus`, `Request`, `ShellPath`, `LaunchAgent`, `Resolver`.
- Produces:
  - `@MainActor final class AppModel: ObservableObject { @Published var status: EngineStatus?; @Published var lastError: String?; @Published var busy: Set<String>; init(client: ClientProtocol); func refresh() async; func perform(_ r: Request) async }` — refreshes every 2 seconds while the menu or settings window is open and after every action. `protocol ClientProtocol { func send(_ r: Request) throws -> Response }` so tests use a fake.
  - Menu, top to bottom: status line (`Running`, `Stopped`, or `Can't start: port 80 in use by <command>` with a `Quit <command>` button only when `ownedByCurrentUser`); **Sites** submenu (each: name, lock icon if secured, PHP version; click opens the URL); **PHP <default>** submenu (installed versions with a tick on the default; choosing one sends `use`); `Open Sites Folder`; `Start`/`Stop`; `Settings…`; `About Paddock`; `Quit`.
  - Settings window, three tabs only. **General:** start at login (installs/removes the LaunchAgent `RunAtLoad`), parked folders list with add (folder picker) and remove, a `Add Paddock to Terminal` button shown only while `!ShellPath.isConfigured()`, and `Restore previous setup` (runs the uninstall flow after a confirmation). **PHP:** every manifest version with Install/Remove and a progress bar, a default picker, `Open php.ini`. **Sites:** table of sites with a secure toggle and a PHP version picker per site.
  - First launch: the app starts the daemon exactly as `paddock start` does (one password prompt for the resolver), with no other windows or questions.
  - About window shows the version and the full `THIRD-PARTY-NOTICES`.
  - `Scripts/bundle.sh`: `swift build -c release --arch x86_64`, then assembles `dist/Paddock.app` with `Contents/MacOS/{Paddock,paddockd,paddock}` and `Contents/Resources/{caddy,composer.phar,router/,php/<bundled version>/default/,php-manifest.json,THIRD-PARTY-NOTICES}`, `Info.plist` with `CFBundleIdentifier app.paddock`, `LSUIElement true`, `LSMinimumSystemVersion 13.0`, and ad-hoc signs it (`codesign -s - --deep`).

- [ ] **Step 1:** Failing `AppModelTests` with a fake client: `refresh` publishes status; an `error` response sets `lastError` and leaves `status` unchanged; `perform` marks the action busy and clears it; a blocked status exposes the holder for the menu line.
- [ ] **Step 2:** Run; FAIL. Implement `AppModel`; PASS.
- [ ] **Step 3:** Build the menu and the three settings tabs. **Before polishing, show the owner screenshots of the menu and each tab and apply their changes**; the spec leaves the exact look to them.
- [ ] **Step 4:** Write `Scripts/bundle.sh`. Verify: `Scripts/bundle.sh && file dist/Paddock.app/Contents/MacOS/Paddock && dist/Paddock.app/Contents/Resources/caddy version && otool -L dist/Paddock.app/Contents/MacOS/paddockd | grep -c /opt/local`. Expect `x86_64`, a Caddy version line, and `0`.
- [ ] **Step 5:** Run the bundled app against a scratch home: `PADDOCK_HOME=$(mktemp -d) PADDOCK_HTTP_PORT=18080 PADDOCK_HTTPS_PORT=18443 PADDOCK_DNS_PORT=53598 open -n dist/Paddock.app --env …`, confirm the menu lists the fixture sites and that the network is not needed (run once with Wi-Fi off). Run the full suite: `swift test`; expect all PASS. Commit.
- [ ] **Step 6: Owner switch-over checklist (the owner runs or explicitly approves each line; this is the only step that touches the live setup).** The launchd entry that has launchd open 127.0.0.1 and ::1 on ports 80 and 443 and run `paddock-ports` as the owner's normal user is the one mechanism that could not be tested before this checklist (development and tests only ever ran the helper's `listen` form on high ports, and the privileged script only as the current user against temp directories); the lines marked **(ports)** check it.
  0. **Warning:** do not press Run on the VS Code launch configurations for PaddockApp/paddockd/paddock during or before this checklist unless they set `PADDOCK_HOME` and the three `PADDOCK_*_PORT` variables. (A build from the repository refuses to set up ports 80 and 443, but it would still start a daemon against your real Paddock folder.)
  1. Copy `dist/Paddock.app` to `/Applications` first, and open that copy (the installed launchd entry and helper come from the copy that asks for the password).
  2. Quit Herd. If Paddock then reports ports 80 and 443 in use by Herd, open Herd, stop its services, quit it, then choose **Try Again** in Paddock's menu.
  3. Open `/Applications/Paddock.app`; enter the password once (one prompt, reading "Paddock needs your password once to serve sites on ports 80 and 443 and to route .test domains to this Mac.", installs the port entry and the resolver). macOS shows a **Background Items Added** notification for the port entry: that is expected; do not switch the item off in System Settings > General > Login Items (if it is switched off, Paddock shows "Setup needed" and Finish Setup asks for the password again).
  4. Until **Add Paddock to Terminal** has been clicked in Settings and a new Terminal window opened, use the `paddock` command by its full path: `~/Library/Application\ Support/Paddock/bin/paddock` (wherever these steps say `paddock`).
  5. **(ports)** `launchctl print system/app.paddock.ports` (no sudo needed) shows the job (label `app.paddock.ports`, user name yours).
  6. **(ports)** `sudo lsof -nP -iTCP:80 -sTCP:LISTEN` and the same for 443 show `launchd` on `127.0.0.1` and `[::1]` only (no `*:80`).
  7. `dig +short @127.0.0.1 -p 53535 anything.test` prints `127.0.0.1` (plain `dig anything.test` ignores `/etc/resolver`), and `dscacheutil -q host -a name anything.test` shows `ip_address: 127.0.0.1`; a project in `~/Paddock` loads at `http://<name>.test`.
  8. **(ports)** Sites load over both IPv4 and IPv6: `curl -H 'Host: <name>.test' http://127.0.0.1/` and `curl -H 'Host: <name>.test' 'http://[::1]/'` both return the site; after `paddock secure <name>`, `https://<name>.test` loads too (and `curl --resolve <name>.test:443:127.0.0.1 https://<name>.test/` and the `[::1]` equivalent).
  9. `paddock secure` gives a trusted padlock after one macOS confirmation; after the first `paddock trust`, `security verify-cert -c "$HOME/Library/Application Support/Paddock/caddy/pki/authorities/local/root.crt" -p ssl` exits 0.
  10. `paddock isolate 8.4` changes that site's version.
  11. **(ports)** `paddock stop` prints `Paddock stopped. Ports 80 and 443 stay reserved for Paddock until you uninstall it.`; `curl http://127.0.0.1/` then gets a closed connection (not Herd, not a hang), and `paddock start` serves again without a password prompt.
  12. **(ports)** Restart the Mac and log in. Without opening anything, `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ -H 'Host: <site>.test'` and `curl -s -o /dev/null -w '%{http_code}' 'http://[::1]/' -H 'Host: <site>.test'` both print `200`, and the site loads in a browser.
  13. Run `paddock uninstall` (one password prompt, reading "Paddock needs your password to release ports 80 and 443 and put your .test DNS setting back."). **(ports)** Afterwards ports 80 and 443 are free (`sudo lsof -nP -iTCP:80 -sTCP:LISTEN` and the same for 443 show nothing), `/Library/LaunchDaemons/app.paddock.ports.plist` and `/Library/PrivilegedHelperTools/app.paddock.ports` are gone, `launchctl print system/app.paddock.ports` fails, and `/etc/resolver/test` again reads `nameserver 127.0.0.1`.
  14. Reopen Herd and confirm its sites load.

  Record the results, including the Zend-extension check below, in the spec.
- [ ] **Step 7: Zend-extension check (time-boxed to half a day, does not gate anything).** Find or build an `opcache.so` or `xdebug.so` whose PHP patch version exactly matches a static build in `Vendor/php`, and try `php -n -d zend_extension=<file> -v`. Write the outcome into the spec's "What a spike established" section. Do not set up a static-php-cli build pipeline for this.
