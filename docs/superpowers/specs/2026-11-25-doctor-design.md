# `paddock doctor`: one place that says why a site is broken

**Status:** approved for implementation.

## Goal

A single, read-only diagnosis of the chain a request takes: daemon → ports → port helper →
resolver → DNS → Caddy → PHP → the site's folder, certificate → the actual HTTP
response → the newest error in the site's log. Every failure says what was found and the
one command that fixes it.

It appears as:

- `paddock doctor [site]` in the CLI.
- A Doctor window in the app, opened from a "Check a Site…" row in the menu and a Check
  button on each Settings → Sites row.
- A read-only MCP tool, `doctor`, so an agent can answer "why is this site down".

Nothing in doctor changes the system: it never runs a fix, never writes a file, and never
restarts anything. Every check is a read.

## Non-goals

- Running the fixes. The fix is a command the owner runs.
- Checking a site's tasks, queue workers, mail, or database contents. `paddock status`,
  the Logs window and the services windows cover those.
- A new daemon IPC request. All clients already receive `EngineStatus` and can read
  files; doctor is a pure function over that plus three probes.
- A `--json` CLI flag. MCP is the JSON surface.
- Caching or watching. A report is a snapshot of the moment it ran.

## Architecture

One new core type, `Doctor`, and its report types in
`Sources/PaddockCore/Doctor/Doctor.swift`. It takes:

- the current `EngineStatus`, or the error that fetching it produced;
- the site to diagnose, or nothing for every site;
- four probes, defaulted to the real system and injectable in tests:
  - `resolve: (String) -> [String]` — the addresses a host resolves to (getaddrinfo);
  - `readable: (String) -> Bool` — whether a site folder can be read;
  - `probe: (URL) async throws -> DoctorProbe` — one HTTP request, returning status and
    milliseconds;
  - `logFinding: (Site) -> DoctorLogFinding` — the newest error in a site's own log.

The CLI (`Sources/paddock/DoctorCommands.swift`), the app's `DoctorModel` and the MCP tool
each build an `EngineStatus` their own way, call `Doctor.report`, and render it. No daemon
change is needed, and "the daemon doesn't answer" is itself the first check — something a
daemon-side implementation could not report.

## Data model

```swift
public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case passed, failed, skipped, info }
    public let id: String        // "daemon", "dns", "http", …
    public let title: String     // "DNS answers mysite.test"
    public let outcome: Outcome
    public let detail: String    // one sentence: what was found
    public let fix: String?      // a command to run; nil when passed or when none helps
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public struct SiteReport: Codable, Equatable, Sendable {
        public let site: String      // "mysite"
        public let host: String      // "mysite.test"
        public let php: PHPVersion
        public let url: String       // "https://mysite.test"
        public let checks: [DoctorCheck]
    }
    public let global: [DoctorCheck]
    public let sites: [SiteReport]

    public var failures: [DoctorCheck]   // failed only, global + every site
    public var isHealthy: Bool           // failures.isEmpty
}

public struct DoctorProbe: Equatable, Sendable {
    public let statusCode: Int
    public let milliseconds: Int
}

public enum DoctorLogFinding: Equatable, Sendable {
    case none                          // the site has no storage/logs/*.log
    case noErrors(file: String)
    case error(file: String, line: String)
    case unreadable(file: String)
}
```

`info` exists for the newest-log-error row: an old error is evidence, not a failure.
`skipped` exists for checks a failed prerequisite made meaningless.

## Checks

Global, run once, in this order:

| id            | title                                  | source                                        | fix |
|---------------|----------------------------------------|-----------------------------------------------|-----|
| `daemon`      | The daemon answers (build `<n>`)       | status fetched; running (or blocked ports, which `ports` reports); `version == PaddockBuild.number` | `paddock start` (or `paddock restart` on a build mismatch) |
| `ports`       | Ports 80 and 443 are free              | `blockedBy.isEmpty`                           | the holder's stop command when there is one, else `paddock start` |
| `port-helper` | The port helper manages 80 and 443     | `portHelperInstalled`                         | `paddock start` |
| `resolver`    | The `.test` resolver entry is installed| `resolverInstalled`                           | `paddock start` |
| `dns`         | DNS answers `<host>`                   | resolves to `127.0.0.1` (first site, or the named one) | `paddock restart` |
| `caddy`       | Caddy is running                       | `processes["caddy"]` starts with `running`    | `paddock start` |

Per site, in this order:

| id         | title                                  | source                                            | fix |
|------------|----------------------------------------|---------------------------------------------------|-----|
| `php`      | PHP `<version>` is installed           | `installedPHP.contains(site.php)`                 | `paddock use <version>` |
| `php-fpm`  | PHP-FPM `<version>` is running         | `processes["php-fpm-<version>"]` is running       | `paddock restart` |
| `folder`   | The site folder is readable            | `readable(site.path)`                             | none; the detail names the path |
| `trust`    | macOS trusts Paddock's certificate     | unsecured → skipped; else `trustEnabled && !needsTrust` | `paddock trust` |
| `http`     | `<url>` answers                        | `probe(URL(site.url))`; status and latency        | depends on the failure (below) |
| `log`      | Newest error in the site's log         | `logFinding(site)`; always `info` or `skipped`    | none |

### One cause, one red row

Each check declares its prerequisites. When one fails, the dependent becomes `skipped`
with `Skipped: <prerequisite title> failed.` (the prerequisite's id in the detail):
a stopped daemon does not paint eleven rows red.

- `daemon` failing (unreachable, stopped, or another build) means no site names are known:
  the report is one failed global check.
- `ports` failing skips `caddy`, `php-fpm` and `http`: nothing downstream of a port it
  cannot bind is meaningful.
- `port-helper`, `dns` or `caddy` failing skips `http`.
- `php` failing skips `php-fpm` and `http`; `php-fpm` failing skips `http`.
- `folder` failing does not skip `http`: Caddy's answer is useful evidence, and the folder
  row already says what is wrong.
- A skipped check never has a fix.

### Details

- **daemon.** Passed: `The daemon answers (build 24).` Failed to reach: the client's error
  as the detail. Stopped with nothing blocking its ports: `Paddock is stopped.` Wrong build:
  `The daemon is build 23; this is build 24.` Stopped with ports in use is not the daemon's
  failure: the daemon row passes and the ports row explains it.
- **ports.** Passed: `Nothing was listening on 80 or 443 before Paddock.` Failed: the
  blocked holders in `Messages.cantStart`'s one-line form, and the holder's stop command as
  the fix when it has one.
- **dns.** Passed: `mysite.test resolves to 127.0.0.1.` Failed: the addresses found, or
  `mysite.test does not resolve.` With no sites, the check is skipped: `No sites to resolve.`
- **php.** Passed: `PHP 8.5 is installed.`
- **php-fpm.** Failed: `PHP-FPM 8.5 isn't running.`
- **folder.** Failed: `<path> can't be read.`
- **trust.** Unsecured: skipped, `<name> isn't secured; nothing to trust.` Failed when
  `needsTrust`: `macOS doesn't trust Paddock's certificate.` Failed when trust is off:
  `Paddock can't install certificate trust in this build.`
- **http.** Passed: `HTTP 200 in 24 ms.` (or `HTTPS`). A 5xx is failed:
  `HTTPS 500 in 30 ms. Some request reached the site and failed; see the log row.` A
  transport error is failed with a mapped sentence:
  - certificate problems (`serverCertificateUntrusted`, `serverCertificateHasUnknownRoot`,
    `secureConnectionFailed`, …) → `TLS failed: <reason>.` fix `paddock trust`;
  - `cannotFindHost` → `mysite.test did not resolve for the request.` fix `paddock restart`;
  - `cannotConnectToHost` → `Nothing answered on port 443.` fix `paddock start`;
  - `timedOut` → `No answer within 5 seconds.` fix `paddock restart`;
  - anything else → the error's localized sentence, no fix.
- **log.** `none`: skipped, `No logs in storage/logs.` `noErrors`: info, `No errors in
  <file>.` `error`: info, `Newest error in <file>: <first 160 characters of the line>.`
  `unreadable`: skipped, `<file> couldn't be read.` `<file>` is the first source
  `LogCatalog.siteLogs` returns (laravel.log when present).

The log row reads the site's logs the way the Logs window does: `LogCatalog.siteLogs(in:)`
(laravel.log first, at most 20, never following a symlink) and `MCPLogReader.tail` with the
site folder as its root, parsed with `LogParser`; the newest entry with `isProblem` wins.

### The HTTP probe

An ephemeral `URLSession` with a 5-second request timeout and no cache, the same shape as
the Mailpit client. One GET of the site's address (following redirects), latency measured
with `ContinuousClock` around the request, and the final status code. The address is the
site's URL, with Paddock's configured HTTP/HTTPS port when it isn't 80/443 (a development
home's high ports), so doctor checks what Paddock actually serves. The default TLS trust
evaluation is the point: if macOS doesn't trust Paddock's root, the probe fails exactly as
the browser would.

## CLI

`paddock doctor` and `paddock doctor <name|host>`. The site is resolved with the existing
`CLI.site(named:in:)`; an unknown name gets the existing failure sentence and exit 1.

Output for one site:

```
mysite.test — PHP 8.5, https://mysite.test

  ✓ The daemon answers (build 24).
  ✓ Ports 80 and 443 are free.
  ✓ The port helper manages 80 and 443.
  ✓ The .test resolver entry is installed.
  ✓ DNS answers mysite.test.
  ✓ Caddy is running.
  ✓ PHP 8.5 is installed.
  ✓ PHP-FPM 8.5 is running.
  ✓ The site folder is readable.
  ✓ macOS trusts Paddock's certificate.
  ✗ https://mysite.test answers.
      No answer within 5 seconds.
      Fix: paddock restart
  i Newest error in the site's log.
      Newest error in laravel.log: …
```

Without a site, Paddock-wide checks print once under `Paddock`, then each site under
`mysite.test — PHP 8.5, https://mysite.test`; a site with no failed checks prints as
`mysite.test: OK.` to stay short. The last line is `Everything checks out.` or
`N checks need attention.`; exit 0 when healthy, 1 otherwise.

Rendering lives in `DoctorText` in PaddockCore
(`DoctorText.lines(for report: DoctorReport, site: String?) -> [String]`, `site` naming
the single-site report's heading) so the exact format is unit-tested and the CLI only
prints and chooses the exit code.

## App

- `DoctorModel` (`Sources/PaddockCore/App/DoctorModel.swift`): `@MainActor
  ObservableObject` with `sites`, `target: String?`, `report: DoctorReport?`,
  `isChecking`, `error`. `check()` asks for a fresh `EngineStatus` (an injected
  `@Sendable () async throws -> EngineStatus`), then runs `Doctor.report` off the main
  actor and publishes the result. A status fetch failure becomes the `daemon` row, not an
  error screen.
- `DoctorView` (`Sources/PaddockApp/Doctor/DoctorView.swift`): a window
  (`windowID = "doctor"`, about 560×620) titled "Doctor", with a site picker (all sites,
  preselected from the opener), a "Check again" button, and a scrollable list: outcome
  symbol (checkmark in green, xmark in red, minus in grey, info in blue), title, detail,
  and the fix command in a monospaced, selectable line. A healthy report says
  "Everything checks out." Rows are stable while a new check runs (`isChecking` shows a
  small progress line, not a blank window).
- Entry points: a "Check a Site…" MenuRow above Logs in the menu (opens the window), and a
  Check button in each Settings → Sites row that opens the window with that site chosen.
  The menu's site rows keep their one-click "open the site" behavior; `PopUpItem` has no
  submenu support and adding it would change that click, so the entry point is a row of
  its own.
- Snapshots: `doctor` (healthy secured site) and `doctor-problems` (daemon down plus a
  failing HTTP row) in `Snapshots.swift`, light and dark; the healthy shot goes into the
  README.

## MCP

A `doctor` tool in `seeing` (so it exists in read-only mode), `readOnly: true`,
`idempotent: true`. Input: optional `site` (name or host) and optional `path` (a folder
inside a site), resolved with the existing `findSite`/`site(named:)` helpers; neither means
every site. Output:

```json
{
  "site": "mysite" | null,
  "global": [{"id": "daemon", "title": "…", "outcome": "passed", "detail": "…", "fix": null}],
  "sites": [{"site": "mysite", "checks": [ … ]}]
}
```

The tool runs the same `Doctor` with the same real probes. Its description tells an agent
to read failures before suggesting anything, and that every fix is a command for the owner
to run, not for the agent to run.

## Testing

- `Tests/PaddockCoreTests/DoctorTests.swift`: a status builder, fake probes, and cases for
  every check's pass/fail path, each skip dependency, a parked site, an unsecured site, a
  5xx, each mapped transport error, the log findings, the all-sites report, and the
  daemon-unreachable report.
- `Tests/PaddockCoreTests/DoctorTextTests.swift`: exact CLI lines for a healthy site, a
  failing site with a fix, a skipped row, the all-sites summary, and the final sentence.
- `Tests/PaddockCoreTests/MCPDoctorTests.swift` (in the existing `MCPToolsTests` style):
  the JSON shape, `site` and `path` lookups, unknown-site failure, and that the tool is
  present under `readOnly: true`.
- `Tests/PaddockCoreTests/DoctorModelTests.swift`: a fresh-status check publishes a report;
  a status failure publishes a daemon-failure report, not an error.
- Integration: in `Tests/IntegrationTests/CLITests.swift`, with a real daemon, `paddock
  doctor <site>` prints the site's heading and the checklist, and its exit code agrees with
  its last line (a throwaway home has no system `.test` resolver, so DNS may be the one
  failed check); with the daemon stopped, it exits 1 and names `paddock start`.
- `swift build`, `swift test --filter PaddockCoreTests`, the integration file, and the
  snapshot run for the Doctor shots.

## Shipping

README: a "The Doctor" section under the existing window sections, a feature-table row,
and the CLI list entry. Release notes are written when the owner asks for a release; this
work adds the notes file `docs/releases/0.5.0.md` with the feature described but does not
bump `VERSION` or `PaddockBuild.number` on its own.
