# Paddock: what's next

Date: 2026-11-22
Status: draft, awaiting the owner's order and go-ahead

This is a roadmap, not an implementation plan. Each stage below gets its own
design document and task-by-task plan before any code, as core, ports,
services and site tasks did. It records the order, what "done" means for each
stage, and the decisions that are the owner's to make first.

## Where Paddock stands

Built and merged into `main`: core (sites, `.test`, HTTPS, PHP versions, CLI),
ports, site tasks, and four of the services stage's services (PostgreSQL,
Redis/Valkey, Meilisearch, Mail).

Planned in the services design and plan but **not built**: MySQL (Task 7) and
object storage on SeaweedFS (Task 8). Reverb (Task 6) is not a catalog service
either; it runs as a site task (`php artisan reverb:start` plus a proxy route),
which covers it.
On `msadini`, not yet merged: the app icon in the README, the README rewrite,
and the native Mail window. Version 0.1.0 is installed and in daily use on the
owner's Mac.

## Global constraints (carried over)

- Paddock is live on the owner's Mac with real sites, services and data. Tests
  and manual runs use a scratch `PADDOCK_HOME`, free high ports and scratch
  folders. Nothing touches `~/Library/Application Support/Paddock`,
  `/Applications/Paddock.app` or a real project folder unless the owner asks.
- x86_64 only; nothing shipped or tested depends on Homebrew or MacPorts.
- Nothing asks the user a question Paddock could answer itself. A setting
  exists only if Herd has the equivalent.
- Views hold no logic; the models in `PaddockCore` do, with unit tests.
- New screens use `Theme` and the Paddock Design System, and get snapshot
  shots in light and dark.
- Work happens on `msadini`; commit per task; push and merge only when asked.

## Order

| # | Stage | Size | Needs from the owner |
|---|---|---|---|
| 0 | Close out the Mail window | Small | Try it; say what's wrong |
| 1 | Mail follow-ups | Small | Nothing |
| 2 | Finish the services: MySQL, object storage | Medium | Confirm two points (below) |
| 3 | Xdebug toggle | Medium | Two decisions (below) |
| 4 | Log viewer | Medium | One decision |
| 5 | Dumps window | Medium to large | One decision |
| 6 | Shareable release | Medium | An Apple Developer account |
| 7 | Finish the look | Small to medium | Approve bundling the fonts |

Stage 6 moves to the front if Paddock is to be handed to anyone else soon:
until it is done the app only opens cleanly on a Mac that built it.

## Stage 0: close out the Mail window

The window is built, unit-tested and installed, but nobody has clicked
through it.

- [ ] Owner opens Mail from the menu and reads the test message as HTML, Text
      and Source.
- [ ] Load Remote Content loads the blocked image; nothing loads before it.
- [ ] The attachment saves; the link opens in the browser.
- [ ] Fix whatever that turns up.
- [ ] `paddock restart` so the daemon runs the new build; delete
      `dist/Paddock-previous.app`.
- [ ] Merge `msadini` into `main`.

Done when: the owner has used it on real mail from a real app and `main` has it.

## Stage 1: mail follow-ups

Left out of the first version on purpose.

- [x] Search the list by sender, recipient, subject and body (Mailpit's
      search API).
- [x] Delete one message; clear the inbox, with a confirmation.
- [x] The Services tab's Open button on the mail service opens the Mail
      window. Mailpit's web page stays reachable with
      `paddock service open mail`.
- [x] Mark a message unread again.

Done when: each has model tests and a snapshot, and the README says so.

Built on 2026-11-22: model tests, snapshots and README are in; the calls were
checked against a scratch Mailpit. Not yet tried by hand in the running app.

## Stage 2: finish the services (MySQL, object storage)

Both are already designed and planned:
`docs/superpowers/specs/2026-11-21-paddock-services-design.md` and Tasks 7 and
8 of `docs/superpowers/plans/2026-11-21-paddock-services.md`. This stage
carries those tasks out; it needs no new design. The service framework, CLI
and Services tab they plug into are built.

To confirm first:

1. **MySQL versions.** The design offers 8.4 (pinned to 8.4.11, the last
   Intel build Oracle published) and 9.7. Check both tarballs are still
   downloadable before starting; if 8.4.11 has gone, 8.4 is dropped or
   Paddock hosts the archive itself (GPLv2: hosting an unmodified Oracle
   build is allowed, with its licence and source offer).
2. **Reverb.** Confirm it stays a site task and is struck from the services
   list, or say if a one-click Reverb service is still wanted.
   (Still open: not asked yet.)

### MySQL (services plan, Task 7)

Built on 2026-11-22.

- [x] Catalog entries `mysql` 8.4 (8.4.11) and 9.7 (9.7.2) from Oracle's
      `macos15-x86_64` tarballs in Oracle's archive, each checked against
      Oracle's published MD5. 9.7.4 exists but only under Oracle's current
      downloads path, which moves when a release is superseded; the archive
      address is stable, so 9.7.2 is used.
- [x] `initialise` with `mysqld --initialize-insecure`; start bound to
      127.0.0.1 with the X plugin off and `--no-defaults`, so no `my.cnf` on
      the Mac is read. Run from a path with a space.
- [x] The socket is in the instance's run folder. MySQL always makes a
      socket, so it is first given one relative to its data folder and then,
      when the run folder's path is short enough, that one instead: it never
      falls back to `/tmp/mysql.sock`.
- [x] `.env` lines: `DB_CONNECTION=mysql`, host, port, `root`, no password.
- [x] `paddock service create-db` and the app's Create Database sheet work
      for MySQL as they do for PostgreSQL.
- [x] Integration test: 8.4 end to end (PDO over TCP and the socket, a table
      and rows, stop and start, remove and re-add keep the data, a stale
      socket lock, loopback only), 9.7 beside it, and a long folder path.
- [x] MySQL is in `THIRD-PARTY-NOTICES` and the README's services table.

### Object storage (services plan, Task 8)

Built on 2026-11-22, on SeaweedFS **4.17** by the owner's decision.

SeaweedFS 4.18 and later create four gRPC Unix sockets at a hard-coded
`/tmp/seaweedfs-<component>-grpc-<port>.sock`, with no option to move or turn
them off, and its own components dial those sockets first. Paddock keeps every
socket in an owner-only folder and never in `/tmp`; a predictable path in
`/tmp` is one another user of the Mac could create first. 4.17 (2026-03-11) is
the last release without them. Move to a newer release only once SeaweedFS
lets those sockets be moved or turned off; the test fails if any appear.

- [x] Catalog entry `storage`, shown as "Object Storage (S3)", from
      SeaweedFS 4.17's `darwin_amd64` release, checked against the release's
      published checksum.
- [x] One process (`weed server -s3`), every listener on 127.0.0.1 and all
      eight ports (master, volume, filer and S3, each with its gRPC port)
      taken from the recipe; the Iceberg listener is off. Usage reporting is
      off by default in 4.17.
- [x] Its two local sockets are named relative to its own folder, so they are
      never in `/tmp` and their length never matters.
- [x] `ServiceRecipe` has `afterReady` steps, run once after the first start
      that became ready and recorded by a marker in the config folder; used to
      create the bucket `paddock` with SeaweedFS's own shell.
- [x] Fixed development key and secret, shown in the `.env` lines with
      `AWS_ENDPOINT` and path-style addressing.
- [x] Integration test: signed PUT and GET; unsigned, wrongly signed and
      unknown-key requests refused; stop and start and remove and re-add keep
      the objects; exactly its eight loopback listeners; no socket in `/tmp`;
      a long folder path.
- [x] SeaweedFS is in `THIRD-PARTY-NOTICES` and the README's services table.

Worth knowing: SeaweedFS's shell exits 0 even when a command fails, so a
failed bucket step is not detected by its exit status; the test checks the
bucket really exists. The service's Open button shows the filer's page of
buckets, which needs no sign-in (loopback only).

Done when: `paddock service add mysql 8.4` and `paddock service add storage`
each give a Laravel app a working database or S3 disk from the printed `.env`
lines alone, and both appear in the Services tab's Add Service… list.

## Stage 3: Xdebug toggle

Built on 2026-11-22.

Decided by the owner: **one switch per PHP version**, and Xdebug **starts a
session only when a request asks for one**.

- [x] `Scripts/build-xdebug.sh`: Xdebug 3.5.3 as `xdebug.so` for each PHP
      series Paddock ships (8.4, 8.5), locked in `Scripts/versions.lock`
      (`xdebug-<series>`) and named by `Resources/php-manifest.json`. Pinned
      sources, a neutral build folder, privacy and link checks and a
      reproducible archive, as the other build scripts.
- [x] Paddock's PHP is static, so there are no installed headers to build
      against. The script takes the same php.net release the PHP build used,
      installs only its headers, phpize and php-config, and refuses to build
      unless those agree with the shipped binary on the PHP version, the API
      numbers, thread safety, debug build, Zend signals and DTrace. The
      shipped `php` must then load the result.
- [x] The archives are in the app (`Resources/builds/`), so switching on needs
      no network. `bundle.sh` and `fetch-vendor.sh` verify them.
- [x] Loaded from PHP's command line (`-d zend_extension=…`, `xdebug.mode=debug`,
      `xdebug.start_with_request=trigger`): the user's `php.ini` is never
      edited, and it can still set the debugger's host and port.
- [x] Kept in `bin/php-extensions/<version>/`, outside the PHP build's folder
      (which an update replaces) and outside the user's `ext/`.
- [x] Daemon request to switch it; only that version's PHP-FPM restarts. The
      choice is saved in `state.json`.
- [x] `paddock xdebug`, `paddock xdebug on|off [version]`; a checkbox per
      installed version on the PHP tab.
- [x] `php` in the terminal follows the same switch; `composer` never loads it.
- [x] Tests: the switch against a real PHP-FPM, including a DBGp session that
      starts on the trigger and not without it.

- [x] A full debugger session is tested the way an editor runs one (DBGp):
      a breakpoint set in the site's own file is hit past Paddock's router,
      the call stack and two variables read back, and the request finishes
      when the debugger lets go.
- [x] The user's `php.ini` wins: `xdebug.mode` or
      `xdebug.start_with_request` set there is used in place of Paddock's
      default (a command-line setting would otherwise override it).
- [x] Zed (the owner's editor): `paddock xdebug zed` writes
      `.zed/debug.json` with the entry Zed's PHP documentation gives, on the
      port `php.ini` names, and never over an existing file. README sections
      for Zed, VS Code and PhpStorm.

Not done:

- Xdebug is built for the two series shipped. A new PHP series needs
  `Scripts/build-xdebug.sh <series>` and its lock and manifest lines.
- Every request enters through Paddock's router, so "break at first line"
  stops in `router/server.php`. Documented in the README; not changed.

Done: the owner confirmed on 2026-11-22 that a breakpoint stops in Zed on
t-market. (Zed's adapter listens on port 9003 for as long as a session runs;
starting a second session fails with "address already in use" until the
first is stopped.)

## Stage 4: log viewer

Built on 2026-11-22.

Decided by the owner: a site's own logs are shown too, **every `.log` file in
its `storage/logs`**, read-only.

- [x] `LogCatalog` lists the logs: Paddock's (daemon, web server), PHP's per
      version, each service's, each site task's, and each site's own
      (`laravel.log` first, then the most recently written, the newest 20;
      regular files only, a symlink is never followed).
- [x] `LogTail` reads a log's last 256 KB and then only what is added; a
      rotated or cut-down file starts over; a line still being written waits
      for its end; terminal colour sequences and control characters are
      dropped.
- [x] `LogParser` makes a Laravel (Monolog) entry of a line and what follows
      it, with its level; a long trace is cut with a count. Any other log is a
      line per entry.
- [x] `LogsModel`: one look a second while the window shows, at most 3,000
      entries kept, a filter (traces included), pause and catch up, fold and
      unfold, Reveal in Finder.
- [x] A Logs window, and a Logs row in the menu.
- [x] Open Log on a task and (new) on a service opens the window at that log.
- [x] Checked against the owner's real logs, read-only: every group found;
      t-market's `laravel.log` (1,316 lines) became 252 entries with 10 traces
      folded, in 36 ms.

Not done:

- Not tried by hand in the running app (scrolling to the newest line, the
  split view, selecting text across entries).
- Only Laravel's format gets levels and folding. PHP's, Caddy's and the
  services' logs are shown a line at a time.
- A site's logs are listed only for sites Paddock serves, and only directly in
  `storage/logs` (no subfolders).
- Nothing clears or rotates a log from the window; it only reads.

Done when: an error thrown in a site shows in the window within two seconds
without a refresh. (Covered by a test with a real file and the one-second
look; the owner's to see in the app.)

## Stage 5: dumps window

Built on 2026-11-22.

Decided by the owner: **Symfony's dump server** (none of Paddock's code in a
request), for **all sites, while the window is open**.

- [x] `PHPSerialized`: reads PHP's `serialize()` format into plain values. No
      class is looked up and nothing is run, whatever the bytes say; bounded in
      depth and size.
- [x] `DumpDecoder`: a port of VarDumper's own walk over its data
      (`Data::dump`) and of how its text dumper writes each value. Tested
      against 98 real payloads (VarDumper 8.1 and 6.4), each compared with the
      text VarDumper's own `CliDumper` prints: every one matches exactly.
      `Scripts/fixtures/var-dumper-fixtures.php` regenerates them.
- [x] `DumpListener`: listens on 127.0.0.1 only, one line per dump.
- [x] The listener is in the menu-bar app, not the daemon (a change from the
      first outline): with the app closed, nothing listens and VarDumper falls
      back to the page by itself, so a dump is never swallowed unseen.
- [x] `dumps(port:)` daemon request: PHP is told where to send dumps only
      while the window listens (two FastCGI variables in the Caddyfile; the
      `php` shim sets them for the terminal). Build number 19.
- [x] The app clears the setting when the window closes, at quit, and at launch
      if a previous run left it set; it sets it again if the daemon restarted
      under an open window.
- [x] A Dumps window (a tree per dump, fold and unfold, Copy, Clear) and a
      Dumps row in the menu.
- [x] End to end through the real web server and PHP-FPM, as a test; and once,
      by hand, with a real `dump()` and the real VarDumper: in the page before,
      only in the listener while it listened, in the page again after.

Not done:

- Not tried by hand in the running app, and not with t-market itself.
- No unread count in the menu: dumps only arrive while the window is open.
- A long-running command (a queue worker) started before the window opened
  does not send its dumps until it is restarted.
- With the window open, Laravel's own dumper is not registered, so its small
  source line under a dump in the page is absent if the listener is not
  reachable for some reason. The window shows the source itself.
- The request shown with a dump needs `symfony/http-foundation` in the project
  (Laravel has it); without it only the file and line show.

Done when: `dump($user)` in a controller appears in the window and not in the
response. (Shown by the hand run above with a real `dump()`; the owner's to
see in t-market.)

## Stage 6: shareable release

Decided 2026-11-22: no Apple Developer account, so no Developer ID signature
and no notarization. Paddock stays signed ad hoc and reaches other Macs
another way:

- [x] `Scripts/install.sh`, run with `curl … | bash`: downloads the latest
      release's zip, checks it against the release's `SHA256SUMS`, unpacks it
      into `/Applications` and opens it. A file fetched by `curl` is not
      marked as downloaded, so Gatekeeper does not question it.
- [x] The README says how to install by hand as well (Open Anyway in System
      Settings, or clearing the download mark).
- [x] PHP versions and services downloaded later are verified by checksum
      before they run, as they already were; nothing more is needed without
      notarization.
- [x] Auto-update: Sparkle 2.10.1 in the app (its Intel half), a check once
      a day and from "Check for Updates…", asking before it installs. The
      feed is `appcast.xml` on the latest GitHub Release of `gowelle/paddock`,
      which the owner chose to make public (still private when this was
      written: nothing downloads until it is). Updates are verified with an
      EdDSA key; the private half is in the owner's login Keychain.
      An app that finds its daemon on another build of the same install
      replaces it at launch, so the daemon keeps serving through the update
      and moves to the new build when the app comes back.
- [x] A release script, `Scripts/release.sh`: version, build number, bundle,
      signed feed; `--publish` commits, tags, pushes and creates the GitHub
      Release with the zip, `SHA256SUMS` and the feed.
- [x] README: a download link in the Quick start, and how updates work.
- [ ] Not yet tried: an installed copy updating itself from a published
      release. The feed and its signature are checked by the script; the
      install step needs a first release to update from.

Done when: the install command works on a second Intel Mac, and that Mac
later updates itself.

## Stage 7: finish the look

Built. What it came to:

- [x] Bricolage Grotesque ships in the app (`Resources/fonts/`, SIL Open Font
      License, in `THIRD-PARTY-NOTICES`), registered for the app alone and used
      for headings only: the About window's name, the licence window's title
      and a mail's subject. Everything else keeps the system font. Figtree is
      not bundled: with headings only, nothing in the app would use it; it
      stays the face for the website and docs.
- [x] The Mail, Logs and Dumps windows, service rows, task rows and the
      approval sheet are in the Paddock Design System, with a section on
      windows in its brand book.
- [x] Tables draw no alternating stripes (macOS 14 and later; 13 keeps the
      system's), and every window tints its focus and selection with
      `honeyText`, as Settings did.
- [x] "Start Paddock at login" has a caption that says what starts.

Done when: every screen is in the design system and no screen uses a colour
or size outside it.

## Not planned

Unchanged from the core design's non-goals: Apple Silicon, Windows and Linux
builds; PHP older than 8.1; Node version management; sharing tunnels;
importing settings from Herd or Valet.
