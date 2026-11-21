# Paddock Stage 2 (Services) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One action adds a database, cache, search, storage, mail or websocket service to Paddock; it downloads, initialises, starts with working defaults, shows its `.env` lines, and is supervised by Paddock's daemon.

**Architecture:** A bundled catalog of service *recipes* (data) is executed by one `ServiceManager` inside `paddockd`, reusing stage 1's downloader, state store and process supervisor. Each added service is an *instance* with its own data folder and saved port. Paddock-built artifacts (Swoole-free PHP, Valkey) are resolved through a `paddock-builds://` source that for now points at files shipped in the app bundle.

**Tech Stack:** Swift 6.2 toolchain (language mode 5), SwiftPM, XCTest; PostgreSQL (theseus-rs binaries), Valkey (built from source), Meilisearch, Mailpit, SeaweedFS, MySQL (Oracle tarballs), Laravel Reverb on Paddock's PHP.

**Spec:** `docs/superpowers/specs/2026-11-21-paddock-services-design.md`

## Global Constraints

- All Global Constraints of `docs/superpowers/plans/2026-11-21-paddock-core.md` and `2026-11-21-paddock-ports.md` still apply (x86_64; no Homebrew/MacPorts dependency in anything shipped or in tests; state under `PADDOCK_HOME`; `SystemIntegration.isEnabled` is the single development-versus-real rule; proprietary licence; commit per task).
- **Paddock is installed and live on the owner's Mac** (`/Applications/Paddock.app`, real daemon, real sites), and MacPorts PostgreSQL (5432) and Redis (6379) are running with the owner's data. Tests and manual runs use a scratch `PADDOCK_HOME` and free high ports only; never 80, 443, 53, 53535, 5432, 3306, 6379, 7700, 8080, 1025, 8025, 8333; never connect to, stop or signal a service the test did not start; never touch `~/Library/Application Support/Paddock`.
- Every service binds `127.0.0.1` (and a Unix socket where the service supports one) and nothing else. A test asserts no rendered start command or config contains `0.0.0.0`, `::` as a listen address, or `*` as a listen host.
- Nothing asks the user for a port, path, user name or password when adding a service.
- A download is verified against the catalog's SHA-256 before it is unpacked or executed.
- Third-party programs run as separate processes; nothing is linked into Paddock.
- Removing a service never deletes its data unless explicitly requested.
- **Every command in a recipe is verified by running it** in a scratch home before it is committed; a recipe's integration test runs the real binary. Research notes (not authoritative; several commands in them are from memory): `/private/tmp/claude-501/-Users-johngowelle-Code/500d620f-9de8-4a01-b281-995de3e0e883/scratchpad/services-research.md`.
- Downloaded service archives are cached in `Vendor/services/` (git-ignored) so the suite does not re-download; tests `XCTSkip` with a clear message when a download is impossible.
- Unix socket paths must stay under 104 bytes; when an instance's socket path would be too long the service runs TCP-only and the `.env` lines say so, rather than failing.

## Review Focus

1. **The conventional port is already taken** (the owner's MacPorts PostgreSQL holds 5432 today): the instance gets the next free port, that port is saved, shown, and used in the `.env` lines; nothing is asked. Test in Task 2.
2. **A service's saved port is taken at a later start**: that instance reports "port in use by …" naming the holder, other instances and the web side keep running, and it starts normally once the port is free. Test in Task 2.
3. **Paddock's PHP connects to each service over TCP on loopback** (the failure that the prebuilt PHP had with PostgreSQL), and over the Unix socket where one exists. Test in Tasks 1, 3, 4, 7.
4. **Interrupted download or failed initialisation** leaves no half-added instance: nothing in the instance list, no partial binaries, a clear error, and a retry works. Test in Task 2.
5. **Data survives**: stop/start, daemon restart, `remove` (data kept and its path reported), and a second `add` of the same kind does not touch the first instance's data. Test in Tasks 2 and 3.

---

## File Structure

```
Resources/services-catalog.json                 # bundled recipes
Resources/reverb/                               # minimal Laravel app for Reverb (Task 6)
Scripts/build-php.sh, Scripts/build-valkey.sh   # Paddock's own builds
Sources/PaddockCore/Builds/BuildSource.swift    # paddock-builds:// resolution
Sources/PaddockCore/Download/ArtifactDownloader.swift   # shared download+verify+unpack
Sources/PaddockCore/Services/ServiceRecipe.swift
Sources/PaddockCore/Services/ServiceCatalog.swift
Sources/PaddockCore/Services/ServiceInstance.swift
Sources/PaddockCore/Services/ServiceTemplate.swift      # placeholder rendering
Sources/PaddockCore/Services/ServiceInstaller.swift
Sources/PaddockCore/Services/ServicePorts.swift
Sources/PaddockCore/Services/ServiceManager.swift
Sources/PaddockCore/Services/ServiceReadiness.swift
Sources/paddock/ServiceTypeCommands.swift               # `paddock service …`
Tests/PaddockCoreTests/Services/…                       # one file per source file
Tests/IntegrationTests/Services/<Kind>ServiceTests.swift
```

---

### Task 1: Paddock's own builds, and Swoole-free PHP

**Files:**
- Create: `Sources/PaddockCore/Builds/BuildSource.swift`, `Sources/PaddockCore/Download/ArtifactDownloader.swift`, `Scripts/build-php.sh`, `Tests/PaddockCoreTests/BuildSourceTests.swift`, `Tests/IntegrationTests/PHPDatabaseDriverTests.swift`
- Modify: `Sources/PaddockCore/PHP/PHPInstaller.swift` (use `ArtifactDownloader`), `PHP/PHPManifest.swift`, `Resources/php-manifest.json`, `Scripts/fetch-vendor.sh`, `Scripts/versions.lock`, `Scripts/bundle.sh`, `THIRD-PARTY-NOTICES`

**Interfaces:**
- Consumes: the Swoole-free PHP 8.4 and 8.5 builds and their recipe produced by the investigation (binaries under `…/scratchpad/php-build/out/<version>/`, archives each holding one binary at top level, recipe in `…/scratchpad/php-build/REPORT.md`; the controller gives the exact path and the report's findings in the dispatch).
- Produces:
  - `enum BuildSource { static func resolve(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? }` — a `paddock-builds://<file>` URL resolves to the first existing of: `<PADDOCK_BUILDS_DIR>/<file>`, `<Bundled.resources>/builds/<file>`; any other URL is returned unchanged; an unresolvable `paddock-builds` URL returns nil.
  - `struct ArtifactDownloader { init(session: URLSession = .shared); func fetch(_ asset: Artifact, into directory: URL, progress: ((Double) -> Void)?) async throws -> URL }` with `struct Artifact: Codable, Equatable { let url: URL; let sha256: String; let size: Int? }` — downloads (or copies a resolved local file) to a temp file inside `directory`'s parent volume, verifies SHA-256, returns the verified file; cancellable; errors `ArtifactError.checksumMismatch|downloadFailed(reason)|notAvailable|cancelled`. `PHPInstaller` uses it with unchanged behaviour and tests.
  - `Resources/php-manifest.json`: 8.4 and 8.5 entries point at `paddock-builds://php-<patch>-cli-macos-x86_64.tar.gz` / `…-fpm-…` with the new hashes; 8.1–8.3 are removed (no Swoole-free builds exist for them yet; `PHPVersion` still parses them, and asking for one answers `PHP 8.3 isn't available for Intel Macs yet.`).
  - `Vendor/builds/` (git-ignored) holds Paddock-built archives; `Scripts/fetch-vendor.sh` no longer downloads PHP from static-php.dev and instead requires the archives named in `versions.lock` to be present in `Vendor/builds/` (clear message pointing at `Scripts/build-php.sh`); it unpacks the default version into `Vendor/php/<v>/default/` as before. `Scripts/bundle.sh` copies every `Vendor/builds/*` archive into `Contents/Resources/builds/` and still ships the default PHP unpacked.
  - `Scripts/build-php.sh <version>`: the investigation's recipe, re-runnable, writing archives to `Vendor/builds/`.
  - `THIRD-PARTY-NOTICES`: the PHP section is regenerated for the new builds' linked libraries; the GPL JBIG-KIT/ImageMagick entry goes away if the new builds no longer link it.

- [ ] **Step 1:** Failing unit tests: `BuildSourceTests` (resolution order, pass-through of https URLs, nil when missing); `ArtifactDownloader` tests moved/extended from the installer tests (checksum mismatch leaves nothing; local-file source; cancel).
- [ ] **Step 2:** Failing integration test `PHPDatabaseDriverTests.testPDOPostgresOverTCPDoesNotHang`: start a throwaway TCP listener on a free high port that accepts and immediately closes; run the vendored `php -n -r 'new PDO("pgsql:host=127.0.0.1;port=<p>;dbname=x","u","p");'` under an 8-second cap; assert it exits with a PDOException in under 5 seconds (with the old builds this spins until killed). Also `testNoSwooleInAnyBundledBuild` (`php -m` for each manifest version lacks `swoole`) and `testRequiredExtensionsPresent` (the spec's extension list).
- [ ] **Step 3:** Run; expect FAIL against the current `Vendor/php`. Copy the new archives into `Vendor/builds/`, update manifest, lock, scripts and installer. Re-run; PASS. Full `swift test`; PASS.
- [ ] **Step 4:** `Scripts/bundle.sh`; confirm `dist/Paddock.app/Contents/Resources/builds/` holds the archives, the bundled default `php -m` has no swoole, and report the app's new size. Commit.

---

### Task 2: Service framework, Mail (Mailpit), CLI

**Files:**
- Create: everything under `Sources/PaddockCore/Services/`, `Resources/services-catalog.json`, `Sources/paddock/ServiceTypeCommands.swift`, unit tests, `Tests/IntegrationTests/Services/MailServiceTests.swift`, `Tests/IntegrationTests/Services/ServiceFrameworkTests.swift`
- Modify: `Paths.swift`, `State.swift`, `Engine.swift`, `IPC/Protocol.swift`, `IPC/EngineHandler.swift`, `Process/Supervisor.swift`, `Messages.swift`, `Sources/paddock/Paddock.swift` and `ServiceCommands.swift` (status output), `Scripts/bundle.sh` (ship the catalog)

**Interfaces:**
- Produces:
  - `struct ServiceRecipe: Codable, Equatable { let kind: String; let displayName: String; let version: String; let licence: String; let minimumMacOS: String?; let assets: [RecipeAsset]; let initialise: [RecipeCommand]; let start: RecipeCommand; let ready: Readiness; let stopSignal: String /* "TERM" | "INT" | "QUIT" */; let stopGraceSeconds: Int; let ports: [RecipePort]; let socket: String? /* template */; let env: [String] /* template lines */; let openURL: String? /* template */; let needsPHP: Bool }`
    - `RecipeAsset { let artifact: Artifact; let archive: String /* "tar.gz" | "tar.xz" | "zip" | "binary" */; let stripComponents: Int; let installAs: String? /* file name for "binary" */ }`
    - `RecipeCommand { let executable: String /* template */; let arguments: [String] /* templates */; let environment: [String: String]; let stdin: String? }`
    - `RecipePort { let name: String /* "main", "http", … */; let preferred: Int }`
    - `enum Readiness: Codable { case tcp(port: String); case unixSocket(path: String); case http(url: String, expectStatus: Int) }` with a 30-second default deadline.
  - Template placeholders, rendered by `ServiceTemplate.render(_:context:)`: `{bin}` (the recipe's unpacked directory), `{data}`, `{config}`, `{run}`, `{log}`, `{name}`, `{id}`, `{port.<name>}`, `{socket}`, `{php}` (Paddock's default PHP binary), `{resources}`. Unknown placeholder → throws `TemplateError.unknown(name)`.
  - `struct ServiceInstance: Codable, Equatable, Identifiable { let id: String /* e.g. "mail", "postgres-18" */; let kind: String; let version: String; var name: String; var ports: [String: Int]; var autostart: Bool; let createdAt: Date }`; `State.services: [ServiceInstance]` (decoded with `decodeIfPresent`, default `[]`).
  - `Paths`: `services` (`<home>/services`), `serviceBin(kind:version:)` (`services/bin/<kind>/<version>`), `serviceHome(_ id:)` (`services/<id>` with `data/`, `config/`), `serviceRun(_ id:)` (`<home>/run/svc/<id>`), `serviceLog(_ id:)` (`<home>/log/service-<id>.log`).
  - `struct ServiceCatalog { static func bundled() throws -> ServiceCatalog; let recipes: [ServiceRecipe]; func recipe(kind: String, version: String?) -> ServiceRecipe? /* nil version = newest */; func kinds() -> [CatalogEntry] }` with `struct CatalogEntry: Codable { let kind, displayName, licence: String; let versions: [String]; let downloadBytes: Int? }`.
  - `enum ServicePorts { static func choose(for recipe: ServiceRecipe, taken: Set<Int>, isFree: (Int) -> Bool) -> [String: Int] }` — preferred if free and not taken by another instance, else the next free port above it (cap +100, then throw).
  - `Supervisor.ProcessSpec` gains `stopSignal: Int32 = SIGTERM` and `stopGrace: TimeInterval?`.
  - `final class ServiceManager { init(paths:catalog:store:supervisor:downloader:portCheck:phpBinary:); func add(kind: String, version: String?) async throws -> ServiceInstance; func remove(_ name: String, deleteData: Bool) throws -> URL /* data path */; func start(_ name: String) throws; func stop(_ name: String); func restart(_ name: String) throws; func startAutostart(); func stopAll(); func statuses() -> [ServiceStatus]; func env(_ name: String) throws -> [String] }`. `add` = resolve recipe → choose ports → install binaries if absent → create instance folders → run `initialise` once → save instance to state → start → wait ready. Any failure before the save leaves no instance and removes folders it created; binaries already verified stay cached.
  - `struct ServiceStatus: Codable, Equatable { let id, name, kind, version, displayName: String; let state: ServiceState; let ports: [String: Int]; let env: [String]; let openURL: String?; let dataPath: String; let autostart: Bool }` and `enum ServiceState: Codable, Equatable { case running, starting, stopped, crashed, portInUse(holder: String), unavailable(reason: String) }`.
  - `EngineStatus.services: [ServiceStatus]` (tolerant decode, default `[]`; bump `PaddockBuild.number`).
  - IPC: `Request` gains `serviceAdd(kind: String, version: String?)`, `serviceRemove(name: String, deleteData: Bool)`, `serviceStart(name:)`, `serviceStop(name:)`, `serviceRestart(name:)`, `serviceCatalog`; `Response` gains `.catalog([CatalogEntry])` and `.removed(dataPath: String, status: EngineStatus)`. Error codes: `unknown_service`, `unknown_service_kind`, `service_port_in_use`, `service_failed`, `service_unavailable`. Service requests are serialized with other mutations; `serviceAdd` downloads are cancellable on shutdown like PHP installs.
  - Engine: services with `autostart` start when the daemon starts (independently of the web stack and of blocked web ports) and stop on daemon shutdown; `stop` of the web side leaves services running.
  - Catalog entry `mail`: Mailpit (version and SHA-256 of the exact GitHub `darwin-amd64` archive, verified by download), ports `smtp` 1025 and `http` 8025, bound to 127.0.0.1, data in `{data}`, `.env` lines `MAIL_MAILER=smtp`, `MAIL_HOST=127.0.0.1`, `MAIL_PORT={port.smtp}`, `MAIL_USERNAME=null`, `MAIL_PASSWORD=null`, `MAIL_ENCRYPTION=null`; `openURL` `http://127.0.0.1:{port.http}`.
  - CLI `paddock service`: `list`; `add <kind> [version]` (prints `Downloading <displayName>…`, then `<name> is running on port <p>.` followed by the `.env` lines); `start|stop|restart <name>`; `remove <name> [--delete-data]` (prints `Removed <name>. Its data is still at <path>.` or `…and deleted its data.`); `env <name>`; `logs <name>`; `open <name>`; `available` (catalog). `paddock status` lists services (name, state, port) under sites. Names match case-insensitively by id or display name.

- [ ] **Step 1:** Failing unit tests: recipe decode of a sample; template rendering (every placeholder, unknown placeholder throws, values with spaces stay single arguments); port choice (preferred free; preferred taken by another instance; preferred busy → next free; cap); catalog lookup (newest version); loopback-only assertion over every bundled recipe's rendered start command and config; state round-trip with and without `services`.
- [ ] **Step 2:** Run; FAIL. Implement recipe, template, ports, catalog, instance, state changes. PASS.
- [ ] **Step 3:** Failing framework integration tests using a **fake recipe** whose "service" is a tiny script in the test bundle (so no download is involved): add → running and ready; stop/start; data folder persists; `remove` keeps data and returns its path; `remove --delete-data` deletes it; second add of the same kind gets the next port and its own folder; preferred port taken by a test listener → next port chosen and present in `env`; saved port taken at a later start → state `portInUse` naming the holder while another instance keeps running, then starts once freed; initialise step failing → no instance in state, no instance folder, error message carries the step's output; checksum mismatch → nothing installed; daemon restart restores autostart instances; shutdown stops them and leaves no process (check process groups).
- [ ] **Step 4:** Run; FAIL. Implement `ServiceInstaller`, `ServiceManager`, readiness, engine wiring, IPC, status. PASS.
- [ ] **Step 5:** Mailpit recipe: verify the download and every flag by running it in a scratch home; then `MailServiceTests`: add `mail` on free ports, send a message with Paddock's PHP (`mail()` is not enough — use a raw SMTP conversation over `fsockopen`), read it back from Mailpit's HTTP API, stop/start and confirm the message is still there, confirm it listens on 127.0.0.1 only (`lsof` on its pid shows no `*:` listener).
- [ ] **Step 6:** CLI commands and status output with tests against a scratch daemon (fake recipe). Full `swift test`; PASS. Commit.

---

### Task 3: PostgreSQL

**Files:**
- Modify: `Resources/services-catalog.json`, `Services/ServiceManager.swift` (create database), `IPC/Protocol.swift`, `IPC/EngineHandler.swift`, `Sources/paddock/ServiceTypeCommands.swift`, `Messages.swift`
- Test: `Tests/IntegrationTests/Services/PostgresServiceTests.swift`, unit tests for the new request

**Interfaces:**
- Produces:
  - Catalog entries `postgres` 16, 17, 18 from `theseus-rs/postgresql-binaries` (`x86_64-apple-darwin` archives; exact versions and SHA-256 from the published `.sha256`, re-verified by download). `initialise`: `initdb` with superuser `root`, no password, `trust` auth for local and loopback, UTF-8, data in `{data}`. `start`: `postgres -D {data}` with port, `listen_addresses=127.0.0.1`, `unix_socket_directories={run}`. `stopSignal` `INT` (fast shutdown), grace 20 s. Ready: TCP on `{port.main}`. `socket`: `{run}/.s.PGSQL.{port.main}`.
  - `.env` lines: `DB_CONNECTION=pgsql`, `DB_HOST=127.0.0.1`, `DB_PORT={port.main}`, `DB_DATABASE=laravel`, `DB_USERNAME=root`, `DB_PASSWORD=`.
  - `RecipeCommand`-based `createDatabase` step in the recipe (`createdb` over the instance's port); `Request.serviceCreateDatabase(name: String, database: String)`; CLI `paddock service create-db <name> <database>`; database names limited to `[A-Za-z0-9_]{1,63}` (anything else → `Database names can use letters, numbers and underscores.`); an existing database is reported as already there, not as an error.
  - If the archive's minimum macOS is newer than the running system, `add` fails with `service_unavailable` and `PostgreSQL <v> needs macOS <x> or later.`; determine the real minimum from the binaries (`otool -l` `LC_BUILD_VERSION`) and record it in the recipe's `minimumMacOS`.

- [ ] **Step 1:** Verify by hand in a scratch home: download, check relocation (run from a path with a space), `initdb`, start on a free port, connect, clean stop; note the minimum macOS and whether downloaded files carry a quarantine attribute (and handle it in `ServiceInstaller` if so, with a test).
- [ ] **Step 2:** Failing `PostgresServiceTests` (scratch home, free ports): add 18; Paddock's PHP connects with PDO **over TCP** and over the Unix socket, creates a table, inserts a row; `create-db`; stop/start keeps the row; add 17 alongside (different port, separate data); loopback-only check on the postmaster pid; `remove` keeps data; the preferred-port-taken case with a test listener on the recipe's preferred port **override** (tests override preferred ports to free high ports; never 5432).
- [ ] **Step 3:** Run; FAIL. Add the recipes and create-database support. PASS. Full suite. Commit.

---

### Task 4: Valkey build and Redis (Valkey)

**Files:**
- Create: `Scripts/build-valkey.sh`, `Tests/IntegrationTests/Services/RedisServiceTests.swift`
- Modify: `Resources/services-catalog.json`, `Scripts/versions.lock`, `Scripts/bundle.sh` (already ships `Vendor/builds/*`), `THIRD-PARTY-NOTICES`

**Interfaces:**
- Produces:
  - `Scripts/build-valkey.sh <version>`: downloads the pinned Valkey source tarball (SHA-256 in `versions.lock`), builds with Xcode's toolchain only (`make BUILD_TLS=no MALLOC=libc` or the options that yield binaries linking only system libraries; verify with `otool -L`), and writes `Vendor/builds/valkey-<version>-macos-x86_64.tar.gz` containing `valkey-server` and `valkey-cli` at top level, printing its SHA-256.
  - Catalog entry `redis`, display name `Redis (Valkey)`, asset `paddock-builds://valkey-<version>-macos-x86_64.tar.gz`. `start`: `valkey-server` with a config file written to `{config}/valkey.conf` from a recipe-declared template (bind 127.0.0.1, port, `unixsocket {run}/redis.sock`, `dir {data}`, append-only persistence on, `daemonize no`, `protected-mode yes`). Ready: TCP. `.env`: `REDIS_CLIENT=phpredis`, `REDIS_HOST=127.0.0.1`, `REDIS_PORT={port.main}`, `REDIS_PASSWORD=null`.
  - `ServiceRecipe` gains `configFiles: [RecipeFile]` (`RecipeFile { let path: String /* template, must be inside {config} */; let contents: String /* template */ }`), written before initialise/start and rewritten on each start; a rendered path outside `{config}` is refused.

- [ ] **Step 1:** Write and run the build script; confirm `otool -L` shows only system libraries and both binaries run.
- [ ] **Step 2:** Failing `RedisServiceTests`: add on a free port; Paddock's PHP (phpredis) SET/GET over TCP and over the Unix socket; stop/start keeps the key; loopback-only; `configFiles` path-escape refusal (unit).
- [ ] **Step 3:** Run; FAIL. Implement. PASS. Full suite. Commit.

---

### Task 5: Meilisearch

**Files:** Modify `Resources/services-catalog.json`; Test `Tests/IntegrationTests/Services/MeilisearchServiceTests.swift`

**Interfaces:**
- Produces: catalog entry `meilisearch` (official `meilisearch-macos-amd64` binary; pin the SHA-256 of the exact file tested since none is published; `archive: "binary"`). `start`: `--http-addr 127.0.0.1:{port.main} --db-path {data}/data.ms --dump-dir {data}/dumps --no-analytics --env development`. Ready: HTTP `http://127.0.0.1:{port.main}/health` 200. `.env`: `SCOUT_DRIVER=meilisearch`, `MEILISEARCH_HOST=http://127.0.0.1:{port.main}`, `MEILISEARCH_KEY=`. `openURL` the same host.

- [ ] **Step 1:** Verify flags by running. Failing test: add; index a document and search it through the HTTP API from Paddock's PHP; stop/start keeps the index; loopback-only.
- [ ] **Step 2:** Implement; PASS; full suite; commit. (The download is ~350 MB: cache it in `Vendor/services/` and skip the test with a clear message when offline.)

---

### Task 6: Reverb

**Files:**
- Create: `Resources/reverb/` (a minimal Laravel application with `laravel/reverb`, its `vendor/` produced by Composer at fetch time and shipped in the bundle, not committed), `Tests/IntegrationTests/Services/ReverbServiceTests.swift`
- Modify: `Resources/services-catalog.json`, `Scripts/fetch-vendor.sh`, `Scripts/bundle.sh`, `Scripts/versions.lock`, `THIRD-PARTY-NOTICES`, `.gitignore`

**Interfaces:**
- Produces: catalog entry `reverb` with `needsPHP: true` and no downloadable asset: the app lives at `{resources}/reverb`. `start`: `{php} {resources}/reverb/artisan reverb:start --host=127.0.0.1 --port={port.main}` with environment `REVERB_APP_ID=paddock`, `REVERB_APP_KEY=paddock-key`, `REVERB_APP_SECRET=paddock-secret`, `APP_KEY` generated once per instance and stored in `{config}`, writable paths (`storage`, `bootstrap/cache`) redirected into `{data}` so the bundled app directory stays read-only. Ready: TCP. `.env`: `BROADCAST_CONNECTION=reverb`, `REVERB_APP_ID=paddock`, `REVERB_APP_KEY=paddock-key`, `REVERB_APP_SECRET=paddock-secret`, `REVERB_HOST=127.0.0.1`, `REVERB_PORT={port.main}`, `REVERB_SCHEME=http`, plus the matching `VITE_REVERB_*` lines.
  - `Scripts/fetch-vendor.sh` runs Composer (the vendored `composer.phar` on the vendored PHP) to install the pinned `composer.lock` into `Vendor/reverb/`; `bundle.sh` ships it as `Contents/Resources/reverb/`.

- [ ] **Step 1:** Build the minimal app; verify `reverb:start` runs read-only from a copy with a space in its path, with storage redirected.
- [ ] **Step 2:** Failing test: add; a WebSocket client (URLSessionWebSocketTask) connects to `ws://127.0.0.1:<port>/app/paddock-key`, receives `pusher:connection_established`; an HTTP trigger to the Pusher-compatible events endpoint, signed with the secret, is delivered to a subscribed channel; loopback-only.
- [ ] **Step 3:** Implement; PASS; full suite; commit.

---

### Task 7: MySQL

**Files:** Modify `Resources/services-catalog.json`; Test `Tests/IntegrationTests/Services/MySQLServiceTests.swift`

**Interfaces:**
- Produces: catalog entries `mysql` 8.4 (pinned to 8.4.11, the last Intel build) and 9.7 from Oracle's `macos15-x86_64` tarballs (hash from the vendor's published checksum, re-verified). `initialise`: `mysqld --initialize-insecure --datadir={data} --basedir={bin}`. `start`: `mysqld --basedir={bin} --datadir={data} --port={port.main} --bind-address=127.0.0.1 --socket={run}/mysql.sock --mysqlx=OFF --pid-file={run}/mysql.pid --log-error={log}` (verify each flag by running; fix as needed). Stop `TERM`, grace 30 s. `.env`: `DB_CONNECTION=mysql`, `DB_HOST=127.0.0.1`, `DB_PORT={port.main}`, `DB_DATABASE=laravel`, `DB_USERNAME=root`, `DB_PASSWORD=`. Recipe `createDatabase` via the bundled `mysql` client. `minimumMacOS` from the binaries.

- [ ] **Step 1:** Verify by running (relocation from a path with a space, initialise time, flags). Failing test: add 8.4; PHP PDO over TCP and socket, table + row; `create-db`; stop/start keeps data; loopback-only.
- [ ] **Step 2:** Implement; PASS; full suite; commit.

---

### Task 8: Object storage (SeaweedFS)

**Files:** Modify `Resources/services-catalog.json`; Test `Tests/IntegrationTests/Services/StorageServiceTests.swift`

**Interfaces:**
- Produces: catalog entry `storage`, display name `Object Storage (S3)`, from SeaweedFS's `darwin_amd64` release (published checksum). One process (`weed server -s3` with all component listeners bound to 127.0.0.1 and every internal port assigned from recipe ports so nothing lands on a default port by accident), S3 credentials from a config file in `{config}` with access key `paddock` and secret `paddock-secret`, a default bucket `paddock` created by a recipe `afterReady` step. `.env`: `FILESYSTEM_DISK=s3`, `AWS_ACCESS_KEY_ID=paddock`, `AWS_SECRET_ACCESS_KEY=paddock-secret`, `AWS_DEFAULT_REGION=us-east-1`, `AWS_BUCKET=paddock`, `AWS_ENDPOINT=http://127.0.0.1:{port.main}`, `AWS_USE_PATH_STYLE_ENDPOINT=true`.
  - `ServiceRecipe` gains `afterReady: [RecipeCommand]`, run once after the first successful start (a marker file in `{config}` records it).

- [ ] **Step 1:** Verify by running, in particular that every listener SeaweedFS opens is on 127.0.0.1 (`lsof` on the process group). Failing test: add; PUT and GET an object with a signed request from Paddock's PHP (a minimal SigV4 implementation in the test is fine) or with `curl --aws-sigv4`; stop/start keeps the object; every listener loopback-only.
- [ ] **Step 2:** Implement; PASS; full suite; commit.

---

### Task 9: App Services section

**Files:**
- Modify: `Sources/PaddockCore/App/AppModel.swift`, `Sources/PaddockApp/` (one new view file for the Services section and the smallest hook-up into the existing settings/menu), `Sources/PaddockApp/Snapshots.swift`
- Test: `Tests/PaddockCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `EngineStatus.services`, the service requests, `Response.catalog`.
- Produces in `AppModel` (unit-tested, no SwiftUI): `services: [ServiceRow]` (name, state text, port text, `canStart`, `canStop`, `canOpen`, `envText`), `catalog: [CatalogRow]`, `func addService(kind:version:) async`, `startService`, `stopService`, `removeService(_:deleteData:)`, `copyEnv(_:)` (pasteboard through an injected closure), `openService(_:)`; indeterminate progress while an add is in flight; errors on the existing quiet error line.
- View: a plain, stock list with an `Add Service…` menu built from the catalog; `Remove and Delete Data…` asks for one confirmation. **The owner is redesigning the app's look with their own design system**: add the new view as its own file, hook it up with the smallest possible edit, do not restyle or reorganise existing views, and do not edit a view file that has uncommitted owner changes (leave the hook-up pending and report it).

- [ ] **Step 1:** Failing `AppModelTests` for each derived property and action with the fake client. Implement. PASS.
- [ ] **Step 2:** Add the view and snapshot states (no services; three services in mixed states; add in progress). Run the snapshot tool. Full suite. `Scripts/bundle.sh` and the development-home smoke check (add the fake or Mail service, see it listed). Commit.
- [ ] **Step 3: Owner checklist (the owner runs or approves each line; touches the live setup).** Update `/Applications/Paddock.app` from `dist/`; `paddock service add postgres`, `redis`, `meilisearch`, `reverb`, `mail` (each picks the next free port while the MacPorts services still run); copy the `tmarket` database across (`/opt/local/lib/postgresql18/bin/pg_dump -h /tmp tmarket | "<Paddock psql>" -h 127.0.0.1 -p <port> -U root tmarket` after `paddock service create-db …`); paste each `paddock service env <name>` into `t-market/.env`, `php artisan config:clear`; confirm the site, a queue job, a search, a broadcast and a mail all work; then stop the MacPorts services (`sudo port unload postgresql18-server redis nginx php84-fpm`).
