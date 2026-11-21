# Paddock

A native macOS app that gives Intel Macs the same local PHP/Laravel environment
Laravel Herd gives everyone else: a working PHP/Laravel setup the moment it is
installed. Drag it to Applications, open it, enter your password once, and any
folder in a parked directory is served at `<folder>.test` over trusted HTTPS.

Paddock is a menu-bar app, a background daemon, and a `paddock` command-line tool
that share one Swift core. It bundles Caddy, Composer, Valet's request router,
and its own static PHP builds, so the first launch works offline — no Homebrew,
no MacPorts, nothing else to install.

> Paddock is **proprietary software**. Its source is public for transparency,
> but it is not open source. See [License and third-party notices](#license-and-third-party-notices).

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [The `paddock` CLI](#the-paddock-cli)
  - [Sites](#sites)
  - [PHP](#php)
  - [Lifecycle](#lifecycle)
  - [Services](#services)
  - [Site tasks](#site-tasks)
- [Site tasks and `paddock.json`](#site-tasks-and-paddockjson)
- [Services](#services-1)
- [Files and directories](#files-and-directories)
- [Environment variables](#environment-variables)
- [Building from source](#building-from-source)
- [Testing](#testing)
- [Repository layout](#repository-layout)
- [License and third-party notices](#license-and-third-party-notices)
- [Contributing](#contributing)

---

## Features

- **Zero-configuration sites.** Park a directory once and every folder inside
  it is served at `http://<folder>.test` — or link a single folder to
  `<name>.test`.
- **Trusted local HTTPS.** `paddock secure` serves a site over HTTPS and makes
  macOS trust Paddock's local certificate authority, so browsers never complain.
- **Multiple PHP versions side by side.** Paddock ships with the newest stable
  PHP; other versions are the only downloads, and only when you ask
  (`paddock use 8.4`). Each site can pin its own version.
- **`php` and `composer` that follow you.** Paddock installs `php` and
  `composer` commands in your terminal that use the PHP version of the site
  whose folder you are in.
- **Framework-aware routing.** Paddock vendors (and patches) Laravel Valet's
  PHP request router, so Laravel, WordPress, Symfony, and friends resolve the
  same way Valet users expect.
- **One-click services.** Add PostgreSQL, Redis (Valkey), Meilisearch, or a
  local mail catcher with a single command; each prints the exact `.env` lines
  for a Laravel app.
- **Project-owned background tasks.** A `paddock.json` file in a project keeps
  its queue worker, scheduler, websocket server, and custom scripts running —
  with your approval, and restarted when they crash or the code changes.
- **Native menu-bar app.** Start/stop, see sites, switch PHP versions, and add
  services from the menu bar. No configuration forms.

## Requirements

- An **Intel Mac (x86_64)** running **macOS 13 or later**.
- No other dependencies for day-to-day use. The app is standalone.
- For building from source: Xcode with the Swift 6 toolchain.

## Quick start

1. Download or build `Paddock.app` and move it to `/Applications`.
2. Open Paddock. The first launch asks for your password **once** to install
   the `.test` DNS resolver and the port 80/443 entry. No Paddock code runs as
   root after that.
3. `paddock park ~/Sites` — now every folder in `~/Sites` is served at
   `<folder>.test`.
4. `paddock secure mysite` — `mysite` is now served over HTTPS, and macOS
   trusts Paddock's certificate (one extra prompt the very first time).
5. `paddock service add postgres 18` — a PostgreSQL 18 instance is downloaded,
   initialized, started, and its `.env` lines are printed.
6. In a Laravel project, run `paddock tasks init`, `paddock tasks on`, and
   your queue worker and scheduler keep running while Paddock runs.

Add Paddock to your terminal (menu-bar app → Settings… → "Add Paddock to
Terminal") so `php`, `composer`, and `paddock` work in new terminal windows.

## How it works

Paddock is four small executables sharing one library:

| Executable | What it does |
|---|---|
| `PaddockApp` | The menu-bar app. |
| `paddockd`   | The background daemon: runs the web stack, the DNS responder, services, and site tasks, and serves IPC over a Unix socket. |
| `paddock`    | The command-line tool. Symlinked as `php` and `composer`, it becomes those programs (using the site's PHP version) without parsing arguments. |
| `paddock-ports` | A tiny C helper that copies bytes between ports 80/443 and Caddy's private Unix sockets. |

The web stack:

- **Caddy** listens only on two owner-only Unix sockets (`http.sock`,
  `https.sock`), never on a network port.
- **`paddock-ports`**, registered with launchd during the one-password setup,
  receives the already-open loopback ports 80 and 443 from launchd and forwards
  each connection to Caddy's sockets. Nothing runs as root at runtime.
- **One PHP-FPM pool per PHP version in use** sits behind Caddy.
- **A DNS responder** answers every `*.test` name on port `53535` (a resolver
  entry forwards `.test` to it), so no `/etc/hosts` entry is ever needed.
- **A supervisor** keeps PHP-FPM, Caddy, services, and site tasks alive:
  restart with backoff on crashes, clean shutdown, and leftovers reclaimed
  after a daemon crash.

## The `paddock` CLI

Run `paddock --help` or `paddock <command> --help` for details.

### Sites

| Command | What it does |
|---|---|
| `paddock park [dir]`   | Serve every folder in a directory at `<folder>.test` (default: current directory). |
| `paddock forget [dir]` | Stop serving a parked directory. |
| `paddock parked`       | List the parked directories. |
| `paddock link [name]`  | Serve the current directory at `<name>.test` (default: the folder's name). |
| `paddock unlink [name]`| Stop serving a linked site. |
| `paddock links`        | List the linked sites. |
| `paddock secure [site]`| Serve a site over HTTPS and trust Paddock's certificate. |
| `paddock unsecure [site]` | Serve a site over plain HTTP. |
| `paddock trust`        | Make macOS trust Paddock's certificate for HTTPS sites. |
| `paddock open [site]`  | Open a site in the browser. |

Sites default to the one containing the current directory.

### PHP

| Command | What it does |
|---|---|
| `paddock use 8.4`        | Make a PHP version the default for every site (downloading it if needed). |
| `paddock isolate 8.4`    | Pin the current site to a PHP version. |
| `paddock unisolate`      | Return the current site to the default PHP version. |

### Lifecycle

| Command | What it does |
|---|---|
| `paddock start`    | Start Paddock. |
| `paddock stop`     | Stop Paddock. |
| `paddock restart`  | Restart Paddock. |
| `paddock status`   | Show whether Paddock is running, and its sites. |
| `paddock logs`     | Show the end of each Paddock log. |
| `paddock uninstall`| Remove Paddock's resolver, port 80/443 entry, login item, and certificate trust. |

### Services

`paddock service …` adds and runs services such as mail, databases, and caches.

| Command | What it does |
|---|---|
| `paddock service list`      | List the services you added. |
| `paddock service available` | List the services Paddock can add. |
| `paddock service add <kind> [version]` | Download, set up, and start a service, and print its `.env` lines. |
| `paddock service start <name>`  | Start a service. |
| `paddock service stop <name>`   | Stop a service. |
| `paddock service restart <name>`| Restart a service. |
| `paddock service remove <name> [--delete-data]` | Stop and remove a service; data is kept unless `--delete-data`. |
| `paddock service update <name>` | Download the newest version of a service's series and switch to it. |
| `paddock service create-db <name> <database>` | Create a database in a running service such as PostgreSQL. |
| `paddock service env <name>`  | Print a service's `.env` lines for a Laravel app. |
| `paddock service logs <name>` | Show the end of a service's log. |
| `paddock service open <name>` | Open a service's page in the browser. |

A service's name is like `mail` or `postgres-18`; a version is a series such
as `18` or an exact version. Everything listens on loopback only, and data
survives stop, restart, app updates, and uninstall.

### Site tasks

`paddock tasks …` runs a site's own commands (queue worker, scheduler, …) from
its `paddock.json`.

| Command | What it does |
|---|---|
| `paddock tasks list`        | List a site's tasks, or every site's outside a site folder. |
| `paddock tasks init`        | Write a starter `paddock.json` for a Laravel project (never over an existing one). |
| `paddock tasks on [--show]` | Show every command in the site's `paddock.json` and approve them, so they run with Paddock. |
| `paddock tasks off`         | Stop the site's tasks and withdraw their approval. |
| `paddock tasks start <task>`  | Start a task. |
| `paddock tasks stop <task>`   | Stop a task; it stays stopped across restarts until started again. |
| `paddock tasks restart <task>`| Restart a task. |
| `paddock tasks logs <task> [-f] [-n <n>]` | Show the end of a task's log, optionally following it. |

## Site tasks and `paddock.json`

A `paddock.json` at the root of a site defines its long-running tasks and, for
websocket servers, reverse-proxy routes on the site's own HTTPS address:

```json
{
  "tasks": {
    "queue":       { "run": "php artisan queue:work redis --queue=default,scout,media,listeners --tries=3" },
    "scheduler":   { "run": "php artisan schedule:work" },
    "reverb":      { "run": "php artisan reverb:start --host=127.0.0.1 --port=8080" },
    "flutterwave": { "run": "bun run webhook:flutterwave:forward" }
  },
  "proxy": {
    "/app":  8080,
    "/apps": 8080
  }
}
```

- `tasks`: name → `run` (one command line). Optional per task:
  `restartOnChange`, `autostart` (default `true`), `stopSeconds` (default 30).
- `proxy`: path prefix → local port.
- Unknown keys are errors, so typos fail loudly.

**Approval is required.** A site with a `paddock.json` shows as "tasks need
your approval" and runs nothing until you run `paddock tasks on` (or approve in
the app). Approval is tied to the file's contents: if `tasks` or `proxy`
change — for example after a `git pull` — the site keeps running the last
approved version and asks for review. Paddock never runs a project's commands
without your explicit approval.

Tasks run in the site's folder, with that site's PHP version and your login
shell's environment, and are supervised by the daemon (own process group,
restart with backoff, clean SIGTERM→SIGKILL shutdown).

## Services

`paddock service available` lists what Paddock can add. One action downloads,
initializes, and starts a service with working defaults — no forms. Each
instance prints its Laravel `.env` lines, starts and stops with Paddock, and
keeps its data on remove (unless you ask to delete it).

| Kind | Display name | Notes |
|---|---|---|
| `postgres` | PostgreSQL 16, 17, 18 | Includes PostGIS 3.6.4 (no raster or topology). |
| `redis` | Redis (Valkey) | Valkey, a Redis-compatible server; Laravel's Redis client works unchanged. |
| `meilisearch` | Meilisearch | A random master key is generated per instance and shown in its `.env`. |
| `mail` | Mail (Mailpit) | SMTP catcher with a web UI and API. |

## Files and directories

Everything Paddock writes lives under **`~/Library/Application Support/Paddock`**
(`PADDOCK_HOME` overrides this):

| Path | Contents |
|---|---|
| `bin/` | The `php` and `composer` shims, and `php-versions/` with installed PHP builds. |
| `config/` | Regenerated configuration, including the `Caddyfile` and the vendored router home. |
| `php/` | Your PHP settings (e.g. `php/8.4/php.ini`) — never regenerated. |
| `run/` | Owner-only Unix sockets and pid files. |
| `log/` | Paddock, service, and task logs. |
| `services/` | Shared service binaries and one folder per instance (`data/` kept on remove). |
| `state.json` | Parked directories, links, PHP choices, and service state. |

## Environment variables

| Variable | Purpose |
|---|---|
| `PADDOCK_HOME` | Override the data directory (default `~/Library/Application Support/Paddock`). |
| `PADDOCK_HTTP_PORT` | Override the HTTP port (default `80`). |
| `PADDOCK_HTTPS_PORT` | Override the HTTPS port (default `443`). |
| `PADDOCK_DNS_PORT` | Override the DNS responder port (default `53535`). |
| `PADDOCK_RESOURCES` | Override where bundled binaries (Caddy, PHP, …) are found. |
| `PADDOCK_OPEN_COMMAND` | Override the browser opener used by `paddock open` (used by tests). |

## Building from source

The repository does not commit its third-party binaries (`Vendor/` is
gitignored). Fetch them first, then build:

```sh
# 1. Fetch Caddy, Composer, the Valet router, and Paddock's PHP builds.
Scripts/fetch-vendor.sh

# 2. Build and test the Swift package (debug).
swift build
swift test

# 3. Build the standalone release app for Intel Macs.
swift Scripts/make-icon.swift   # generates Resources/AppIcon.icns
Scripts/bundle.sh               # produces dist/Paddock.app
```

`Scripts/bundle.sh` builds for `x86_64`, assembles `dist/Paddock.app` with the
bundled binaries and Paddock's own PHP/PostGIS/Valkey archives (so installing
another version needs no network), signs it ad hoc, and verifies the signature.

Building Paddock's own PHP, PostGIS, and Valkey artifacts is done with
`Scripts/build-php.sh`, `Scripts/build-postgis.sh`, and
`Scripts/build-valkey.sh`; the locked versions and checksums live in
[`Scripts/versions.lock`](Scripts/versions.lock).

## Testing

```sh
swift test
```

- [`Tests/PaddockCoreTests`](Tests/PaddockCoreTests) — unit tests for the core
  library (Caddyfile generation, DNS messages, IPC, PHP resolution, path and
  port handling, and more).
- [`Tests/IntegrationTests`](Tests/IntegrationTests) — end-to-end tests that
  start the real daemon, Caddy, PHP-FPM, the DNS responder, and services.
  These need the bundled third-party binaries, so run `Scripts/fetch-vendor.sh`
  first.

## Repository layout

```
Sources/
  PaddockApp/     The menu-bar app (SwiftUI).
  PaddockCore/    The engine, daemon logic, services, tasks, web stack, and IPC.
  paddock/        The `paddock` command-line tool (ArgumentParser subcommands).
  paddockd/       The background daemon.
  paddock-ports/  The C port-80/443 helper.
Tests/
  PaddockCoreTests/   Unit tests.
  IntegrationTests/   End-to-end tests.
  PaddockTestSupport/ Shared test helpers.
  FakeService/        A stand-in service for the service framework's tests.
Resources/        App icon, Info.plist, service recipes, and the vendored router.
Scripts/          Fetch, build, and bundle scripts; version lock file.
Vendor/           Fetched third-party binaries (gitignored).
docs/superpowers/ Design documents and plans.
```

## License and third-party notices

Paddock is **proprietary software** — copyright © 2026 John Gowelle. The
compiled application is free to install and use; redistribution, modification,
and derivative works are not permitted. See [LICENSE](LICENSE).

The Paddock source is public for transparency only; no open-source license is
granted by its availability. Third-party components bundled with Paddock
(Caddy, PHP, Composer, the Valet router, swift-argument-parser, and the
libraries inside Paddock's PHP builds) are licensed under their own terms —
see [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).

## Contributing

Paddock's source is public for transparency, not as open source. By submitting
a contribution you grant the owner the rights described in
[CONTRIBUTING.md](CONTRIBUTING.md). Please read it before opening a pull
request, and do not submit confidential, third-party, patented, or GPL/LGPL
code without prior written approval.
