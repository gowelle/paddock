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

- Zed itself has not been driven: the test speaks the debugger protocol
  directly, which is what Zed's Xdebug adapter does, but a breakpoint
  stopping inside Zed's window is the owner's to try.
- Xdebug is built for the two series shipped. A new PHP series needs
  `Scripts/build-xdebug.sh <series>` and its lock and manifest lines.
- Every request enters through Paddock's router, so "break at first line"
  stops in `router/server.php`. Documented in the README; not changed.

Done when: a breakpoint in the owner's editor stops on a request to a `.test`
site, and turning it off returns PHP to its normal speed. (The second half
is covered by the test; the first, inside Zed, is the owner's to try.)

## Stage 4: log viewer

A window for the logs Paddock already keeps under `log/`: Paddock's own,
each service's, each site task's, and a site's Laravel log.

Decision first: **is a site's `storage/logs/laravel.log` in scope?** It is the
log people look at most, but it belongs to the project, not Paddock.
Recommended: yes, read-only, for Laravel sites only.

- [ ] A model that lists the logs, tails one, and follows it while the window
      shows (bounded memory; the files are already bounded on disk).
- [ ] A Logs window: sources on the left, the tail on the right, a filter
      field, a pause switch, Reveal in Finder.
- [ ] The Tasks and Services tabs' log buttons open this window at that log.
- [ ] Laravel log entries split into level, time and message, with the stack
      trace folded.

Done when: an error thrown in a site shows in the window within two seconds
without a refresh.

## Stage 5: dumps window

`dump()` and `dd()` output from a site, shown in Paddock instead of in the
page.

Decision first: **how the dumps get to Paddock.** Either Symfony VarDumper's
dump server protocol (works with Laravel as is, needs
`VAR_DUMPER_FORMAT=server` in the site's environment), or a small PHP file
Paddock auto-prepends for every site (no setup, but Paddock's code runs in
every request). Recommended: the dump server, with the `.env` line printed
the same way services print theirs.

- [ ] A listener in the daemon on a loopback port; dumps kept in memory, a
      bounded number of them.
- [ ] A Dumps window: newest first, the site and file and line each came
      from, the value as a foldable tree, a Clear button.
- [ ] An unread count on a Dumps row in the menu, as Mail has.

Done when: `dump($user)` in a controller appears in the window and not in the
response.

## Stage 6: shareable release

`Scripts/bundle.sh` signs ad hoc. On another Mac, Gatekeeper refuses the app.

Needs: an Apple Developer account (a yearly fee) and a Developer ID
Application certificate. That purchase and enrolment are the owner's.

- [ ] Sign every executable in the bundle with the Developer ID and the
      hardened runtime, with only the entitlements each needs (PHP and Caddy
      included).
- [ ] Notarize and staple in `bundle.sh`; fail the build if either fails.
- [ ] Decide what happens to PHP versions and services downloaded later:
      they are not in the notarized bundle, so they must be signed too or
      verified by checksum before they run (they are already checksummed).
- [ ] Auto-update: Sparkle, with an appcast on GitHub Releases. The daemon
      keeps running through an app update, as it did when the Mail build was
      installed by hand.
- [ ] A release script: version bump, build, notarize, zip, GitHub Release,
      appcast.
- [ ] README: a real download link in the Quick start.

Done when: the zip downloaded on a second Intel Mac opens with no warning,
and that Mac later updates itself.

## Stage 7: finish the look

- [ ] Bundle Bricolage Grotesque and Figtree (both under the SIL Open Font
      License; add them to `THIRD-PARTY-NOTICES`) and use them in the About
      window, the licence window and window titles. System controls keep the
      system font.
- [ ] Add the Mail window, Services, Tasks and the approval sheet to the
      Paddock Design System, which predates all four.
- [ ] One pass over those screens against the design system: spacing, the
      table stripes that still draw white in light appearance, focus rings.
- [ ] "Start Paddock at login" says what it does now: it starts Paddock's
      services, not the menu-bar app.

Done when: every screen is in the design system and no screen uses a colour
or size outside it.

## Not planned

Unchanged from the core design's non-goals: Apple Silicon, Windows and Linux
builds; PHP older than 8.1; Node version management; sharing tunnels;
importing settings from Herd or Valet.
