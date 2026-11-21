# Paddock Site Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A site's own long-running commands (queue worker, scheduler, websocket server, custom scripts) are defined in a `paddock.json` file in the project, approved once, and then kept running by Paddock; chosen paths of the site can be forwarded to a local port so websockets work on the site's HTTPS address.

**Architecture:** A `SiteTaskManager` in `paddockd` reads each site's `paddock.json`, runs only approved definitions through the existing `Supervisor` (own process group, backoff, orphan reclaim via process records), with the user's captured login-shell environment and Paddock's `bin` first on `PATH`. Approval is a hash of the file's `tasks` and `proxy` sections stored in Paddock's state. Proxy routes become `reverse_proxy` handlers in the generated Caddyfile for approved sites only.

**Tech Stack:** Swift 6.2 toolchain (language mode 5), SwiftPM, XCTest, FSEvents (DispatchSource/`FSEventStream`), Caddy 2.11 `reverse_proxy`.

**Spec:** `docs/superpowers/specs/2026-11-21-paddock-site-tasks-design.md`

## Global Constraints

- All Global Constraints of the core, ports and services plans still apply (x86_64; no Homebrew/MacPorts dependency in anything shipped or in tests; state under `PADDOCK_HOME`; `SystemIntegration` rules; development builds are read-only against a real home; proprietary licence; commit per task).
- **Paddock is installed and live on the owner's Mac** with real sites and, possibly, real Paddock services holding real data. Tests and manual runs use a scratch `PADDOCK_HOME`, fresh free high ports and scratch site folders only; never touch `~/Library/Application Support/Paddock`, `/Applications/Paddock.app`, `release/`, `~/Code/t-market` or any real project folder; never connect to, stop or signal anything the test did not start.
- **Paddock never runs a command from a `paddock.json` that the user has not approved**, and never forwards a path for an unapproved file. Approval is tied to the canonical content of the `tasks` and `proxy` sections; a changed file keeps running the last approved definition until approved again.
- Proxy targets are ports on `127.0.0.1` only (1024–65535).
- Task commands are the user's own, approved text and are run by the user's shell; nothing else in Paddock passes text to a shell.
- Every user-facing string that includes text from `paddock.json`, a process, or a path goes through the existing display sanitisers (`Messages.displayName` / `printable`).
- `Request` cases are classified in the exhaustive `isReadOnly` switch; `EngineStatus`/site status additions decode tolerantly; bump `PaddockBuild.number` when the protocol or status changes.
- No fixed ports in tests; time limits in tests are generous enough for a loaded machine.

## Review Focus

1. **An unapproved or changed `paddock.json`** (a freshly cloned repository in a parked folder; a `git pull` that edits a command): nothing new runs and nothing new is proxied until `paddock tasks on`; the previously approved version keeps running. Test in Task 1 and Task 3.
2. **A malformed or hostile file** (invalid JSON, unknown keys, a task name with path characters, a 1 MB command, a proxy to another host, a symlinked `paddock.json` pointing outside the site): a clear error on that site only; other sites and the web server are unaffected. Test in Task 1 and Task 3.
3. **A task that exits immediately, crash-loops, or ignores SIGTERM**: backoff, give-up with a visible state, bounded stop; Paddock's daemon stays responsive and shutdown stays within its time limit. Test in Task 1.
4. **The site disappears** (folder deleted, drive unmounted, site un-parked) while its tasks run: they are stopped; nothing is left running. Test in Task 1.
5. **Commands that depend on the user's shell setup** (`bun`, `node` via nvm, project-local scripts): they resolve as in the user's terminal, and `php`/`composer` are the site's pinned PHP version. Test in Task 1.

---

## File Structure

```
Sources/PaddockCore/Tasks/SiteTasksFile.swift       # paddock.json model, parsing, canonical hash
Sources/PaddockCore/Tasks/TaskApproval.swift        # approved hashes + approved definitions in state
Sources/PaddockCore/Tasks/ShellEnvironment.swift    # login-shell environment capture
Sources/PaddockCore/Tasks/SiteTaskManager.swift     # lifecycle, supervision, status, logs
Sources/PaddockCore/Tasks/SiteWatcher.swift         # restartOnChange file watching
Sources/PaddockCore/Tasks/Engine+Tasks.swift        # engine wiring, requests
Sources/PaddockCore/Web/Caddyfile.swift             # proxy routes (Task 3)
Sources/paddock/TaskCommands.swift                  # `paddock tasks …`
Tests/PaddockCoreTests/Tasks/…
Tests/IntegrationTests/Tasks/SiteTasksTests.swift, SiteProxyTests.swift
```

---

### Task 1: `paddock.json`, approval, running tasks, CLI

**Files:**
- Create: `Sources/PaddockCore/Tasks/SiteTasksFile.swift`, `TaskApproval.swift`, `ShellEnvironment.swift`, `SiteTaskManager.swift`, `Engine+Tasks.swift`, `Sources/paddock/TaskCommands.swift`, unit tests, `Tests/IntegrationTests/Tasks/SiteTasksTests.swift`
- Modify: `State.swift`, `Sites.swift` (site status), `Engine.swift`, `IPC/Protocol.swift`, `IPC/EngineHandler.swift`, `Messages.swift`, `Paths.swift`, `Sources/paddock/Paddock.swift`, status output

**Interfaces:**
- Produces:
  - `struct SiteTasksFile: Equatable { let tasks: [String: TaskDefinition]; let proxy: [String: Int] }`, `struct TaskDefinition: Codable, Equatable { let run: String; let restartOnChange: Bool?; let autostart: Bool? /* default true */; let stopSeconds: Int? /* default 30, 1…300 */ }`.
    - `static func load(siteFolder: URL) -> LoadResult` with `enum LoadResult { case none; case file(SiteTasksFile, hash: String); case invalid(reason: String) }`. Rules: file name exactly `paddock.json` at the site root; a regular file (a symlink is followed only if its target is inside the site folder), at most 64 KB; JSON object with only the keys `tasks` and `proxy`; task names `^[a-z][a-z0-9-]{0,30}$`, at most 16 tasks; `run` 1…2000 characters, no NUL or newline; unknown keys anywhere → `invalid("unknown key \"…\"")`; proxy keys are path prefixes `^/[A-Za-z0-9._~/-]{1,100}$` without `..` or `//`, at most 16, values 1024…65535.
    - `hash`: SHA-256 of a canonical encoding (sorted keys, defaults applied) of `tasks` and `proxy`, so formatting changes do not need re-approval.
    - `static func starter(forSiteAt: URL) -> String?` — for a Laravel project (an `artisan` file exists): the JSON text with `queue` (`php artisan queue:work`) and `scheduler` (`php artisan schedule:work`); nil otherwise.
  - `State.taskApprovals: [String /* site name */: ApprovedTasks]` with `struct ApprovedTasks: Codable, Equatable { let hash: String; let file: StoredTasksFile; let sitePath: String; var stopped: Set<String> /* tasks the user stopped by hand */ }` (decoded tolerantly, default empty). The approved definition is stored so the approved version keeps running after the file changes.
  - `struct ShellEnvironment { static func capture(runner:timeout:) -> [String: String] }` — runs the user's login shell (`$SHELL`, default `/bin/zsh`) as `-l -i -c 'env -0'` with a 5-second limit and no stdin, parses NUL-separated pairs; on failure falls back to a minimal environment and records a notice. Captured once at daemon start and again on `tasks on` and on request. Paddock's `bin` is prepended to `PATH`; variables beginning `PADDOCK_` are removed.
  - `final class SiteTaskManager { init(paths:store:supervisor:environment:sites:…); func refresh(); func approve(site: String) throws -> SiteTasksStatus; func revoke(site: String); func start(site:task:) throws; func stop(site:task:); func restart(site:task:) throws; func statuses() -> [String: SiteTasksStatus]; func stopAll(); func logFile(site:task:) -> URL }`.
    - Process name `task/<site>/<task>`; working directory the site folder; command `[$SHELL, "-c", run]` with the captured environment; `stopSignal` TERM, grace `stopSeconds`; process records under `run/tasks/<site>/<task>/pid` so orphans of a dead daemon are reclaimed with the same identity checks as services (allowed executable: the user's shell).
    - `refresh()` runs at daemon start, on every site list change, and when a watched `paddock.json` changes: unapproved or invalid → nothing started; approved hash equals current hash → reconcile running tasks with the definition; approved but file changed/removed/invalid → keep running the stored approved definition and report `changed`.
    - Site gone (folder missing or no longer a site) → its tasks are stopped and reported; the approval is kept for 30 days in case the folder returns, then dropped.
  - `struct SiteTasksStatus: Codable, Equatable { let approval: Approval /* none, needsApproval, approved, changed, invalid(reason) */; let tasks: [TaskStatus]; let pending: [PendingTask] /* what approving would run: name + run + proxy lines, sanitised */; let notice: String? }`, `struct TaskStatus { let name, run: String; let state: TaskState /* running(pid), starting, stopped, crashed(reason), waitingForApproval */; let restartOnChange: Bool; let logPath: String; let warning: String? }`. `Site` status gains `tasks: SiteTasksStatus?` (tolerant decode).
  - IPC: `Request.tasksApprove(site:)`, `tasksRevoke(site:)`, `taskStart(site:task:)`, `taskStop(site:task:)`, `taskRestart(site:task:)`, `tasksInit(site:)` (writes the starter file if none exists; never overwrites) — all not read-only. Error codes `unknown_task`, `tasks_not_approved`, `tasks_invalid`, `no_tasks_file`.
  - Logs: `<home>/log/tasks/<site>/<task>.log`, opened in append mode, rotated at 5 MB keeping one previous file.
  - CLI `paddock tasks` (in a site folder or with `--site <name>`): list; `init`; `on` (prints every command and proxy line that will be approved, then approves — no interactive prompt: running the command is the approval; `--show` prints without approving); `off`; `start|stop|restart <task>`; `logs <task> [-f] [-n <lines>]`. `paddock status` shows tasks under each site and a line for sites needing approval: `<site>: paddock.json has tasks waiting for your approval. Review them with: paddock tasks on --show`.
  - Tasks start with the daemon (approved, `autostart` not false, not in `stopped`), independently of the web stack; they stop on daemon shutdown in parallel, within the LaunchAgent's exit timeout (extend the compile-time constant and its test if `stopSeconds` up to 300 could exceed it: cap the grace actually used at shutdown so the total stays inside the timeout, and say so in the status when a task was cut short).

- [ ] **Step 1:** Failing unit tests: parsing (valid file; every rejection rule above with its message; symlink inside and outside the site; size cap); canonical hash stable across key order/whitespace and changed by any command, option or proxy change; starter text for a Laravel folder and nil otherwise; `ShellEnvironment` parsing of NUL-separated output including values with newlines and `=`; `PATH` prepending and `PADDOCK_*` removal; state round-trip with and without approvals.
- [ ] **Step 2:** Run; FAIL. Implement the file model, approval state and environment capture. PASS.
- [ ] **Step 3:** Failing integration tests (scratch home, scratch site folders, a test helper as the "command" where a real program is not needed):

```swift
func testNothingRunsUntilApproved()                // file present → status needsApproval with the pending commands; no process
func testApprovedTasksRunInTheSiteFolderWithItsPHP()// `run` = a script printing cwd, `php -r 'echo PHP_VERSION;'`, and $PATH's first entry → log shows site folder, the site's pinned version, Paddock's bin
func testAChangedFileKeepsTheApprovedVersion()      // edit run → state changed; old command still running; approve → new command running
func testFormattingChangesNeedNoReapproval()
func testInvalidFileAffectsOnlyThatSite()
func testCrashLoopGivesUpAndSaysSo()
func testStopWaitsForASlowTaskThenKills()           // helper ignoring SIGTERM, stopSeconds 2
func testASiteThatDisappearsHasItsTasksStopped()
func testTasksComeBackAfterADaemonRestart()         // real paddockd
func testOrphanTasksOfAKilledDaemonAreReclaimed()   // SIGKILL paddockd; children survive; restart → same task running once
func testUserStoppedTaskStaysStoppedAcrossRestart()
func testShutdownStopsAllTasksWithinItsLimit()
func testDevelopmentBuildCannotApproveOnARealHome() // request classification / client gate
```

- [ ] **Step 4:** Run; FAIL. Implement `SiteTaskManager`, engine wiring, IPC, status. PASS.
- [ ] **Step 5:** CLI commands and status output with tests against a scratch daemon. Full `swift test`; PASS. Commit.

---

### Task 2: Restart on change, and the listening warning

**Files:**
- Create: `Sources/PaddockCore/Tasks/SiteWatcher.swift`, tests
- Modify: `SiteTaskManager.swift`, `Messages.swift`

**Interfaces:**
- Produces:
  - `final class SiteWatcher { init(folder: URL, ignoring: [String], debounce: TimeInterval, onChange: @escaping () -> Void); func start(); func stop() }` — FSEvents on the site folder; ignores paths under `vendor`, `node_modules`, `storage`, `bootstrap/cache`, `.git`, `public/build`, `public/hot`, and dot-directories; reacts only to files ending `.php`, `.env`, `composer.lock`, or `paddock.json`; debounce 1 second after the last event.
  - Default for `restartOnChange` when the file does not set it: true when `run` matches `artisan (queue:work|queue:listen|horizon|reverb:start|octane:start|schedule:work)` (word-boundary match on the command text), false otherwise.
  - One watcher per site with at least one running `restartOnChange` task; on change those tasks are restarted (graceful stop with their grace, then start); restarts are coalesced so a burst of changes causes one restart; a task that the user stopped is not started by a change.
  - The same watcher triggers `refresh()` when `paddock.json` itself changes.
  - Listening warning: 5 and 30 seconds after a task starts, Paddock lists the listening TCP sockets of the task's process group (the existing listener-listing function); if any is not on a loopback address the task's `warning` is `Listening on all network interfaces (port <p>). Add --host=127.0.0.1 or similar to keep it on this Mac.` The task is NOT stopped.

- [ ] **Step 1:** Failing unit tests for the default detection table and the ignore/include rules (pure path filter).
- [ ] **Step 2:** Failing integration tests: touching `app/Foo.php` restarts a `restartOnChange` task once (new pid) within a few seconds and not a second time for a burst of 20 writes; touching `vendor/x.php` or `storage/logs/laravel.log` does not; a task with `restartOnChange: false` is not restarted; editing `paddock.json` moves the site to `changed`; a helper task binding `0.0.0.0` on a free high port gets the warning and keeps running; one binding `127.0.0.1` gets none.
- [ ] **Step 3:** Run; FAIL. Implement. PASS. Full suite. Commit.

---

### Task 3: Proxy routes

**Files:**
- Modify: `Sources/PaddockCore/Web/Caddyfile.swift`, `SiteTaskManager.swift`/`Engine+Tasks.swift` (approved proxy routes feed config generation and trigger a reload), `Messages.swift`
- Test: `Tests/PaddockCoreTests/CaddyfileTests.swift`, `Tests/IntegrationTests/Tasks/SiteProxyTests.swift`, `CaddyValidateTests`

**Interfaces:**
- Consumes: approved `proxy` maps per site from `SiteTaskManager`.
- Produces:
  - `Caddyfile.render(…, proxies: [String /* site name */: [String: Int]])`: a site with approved proxy routes gets its own site block(s) (HTTP and, when secured, HTTPS, with the same bind sockets, TLS and subdomain rules as today) in which each prefix `P` → port `N` is handled before the PHP handler as `handle P/* { reverse_proxy 127.0.0.1:N }` plus an exact-match `handle P { reverse_proxy 127.0.0.1:N }`; longest prefix first; websocket upgrades pass through (Caddy's `reverse_proxy` does this by default — verify with a real upgrade); the original path is preserved (no prefix stripping). A site without approved routes renders exactly as today (byte-identical output for existing tests).
  - Only approved routes are rendered; approving, revoking or re-approving triggers `Engine.reload()`; an unsecured site proxies over HTTP only.
  - When the target port refuses connections, Caddy's 502 is replaced with a short plain response `Paddock: nothing is listening on port <N> for <prefix> (is the task running?)` via `handle_errors` scoped to those routes.
  - `paddock tasks on --show` and the approval listing include each proxy line as `forward https://<site>.test<prefix> → 127.0.0.1:<port>`.

- [ ] **Step 1:** Failing unit tests: rendered blocks for a secured and an unsecured site; longest-prefix ordering; no change for sites without routes; quoting; `caddy validate` passes for the rendered config.
- [ ] **Step 2:** Failing integration tests (scratch home, high ports, a test HTTP+websocket echo server on a free high port bound to 127.0.0.1): unapproved file → `/app/x` reaches PHP (404 from the router), not the test server; approved → `GET https://<site>.test:<port>/app/hello?x=1` reaches the test server with path and query intact; a websocket handshake through `wss://…/app/ws` succeeds and echoes a frame (URLSessionWebSocketTask with the test CA); a non-proxied path still reaches PHP; revoking removes the route; target down → the plain message with status 502; a second site is unaffected.
- [ ] **Step 3:** Run; FAIL. Implement. PASS. Full suite. Commit.

---

### Task 4: App surfaces (merged with the services plan's Task 9)

**Files:**
- Modify: `Sources/PaddockCore/App/AppModel.swift`, `Sources/PaddockApp/` (one new view file for site tasks; smallest hook-up), `Snapshots.swift`
- Test: `Tests/PaddockCoreTests/AppModelTests.swift`

**Interfaces:**
- Consumes: site `tasks` status, the task requests.
- Produces in `AppModel` (unit-tested, no SwiftUI): per site `taskRows` (name, command, state text, warning, `canStart`/`canStop`), `approvalPrompt(for site:)` (title, the exact commands and proxy lines, sanitised), `approveTasks(site:)`, `revokeTasks(site:)`, `startTask`, `stopTask`, `restartTask`, `openTaskLog`, `createStarterFile(site:)`.
- View: plain, stock; approval shown as a sheet listing every command and forward line with `Approve` and `Not Now`. **The owner is redesigning the app's look**: new view in its own file, smallest hook-up, no restyling of existing views, no edits to a view file with uncommitted owner changes.
- Built together with the services plan's Task 9 (Services section) by one implementer, since both add list sections to the same model and window.

- [ ] **Step 1:** Failing `AppModelTests` for each derived property and action with the fake client. Implement. PASS.
- [ ] **Step 2:** View, snapshot states (needs approval; running tasks; a crashed task; a warning). Full suite. `Scripts/bundle.sh` and the development-home smoke check (a scratch Laravel-like site with a `paddock.json`: approve, see tasks running, proxy answers). Commit.
- [ ] **Step 3: Owner checklist (the owner runs or approves each line; touches the real project).** In `~/Code/t-market`: add `paddock.json` (queue, scheduler, reverb with `--host=127.0.0.1 --port=8080`, flutterwave; proxy `/app` and `/apps` → 8080); set `REVERB_PORT=443`, `REVERB_SERVER_HOST=127.0.0.1`, `REVERB_SERVER_PORT=8080` in `.env`; `php artisan config:clear`; rebuild the frontend (`bun run build` or `bun run dev`) so the websocket port change reaches the browser; `paddock tasks on`; confirm a queued job runs, a scheduled command fires, a broadcast reaches the browser over `wss://t-market.test/app/…`, and the Flutterwave forwarder is up; then stop using `bun run dev:backend`.
