# Paddock — Stage 1 (Core) design

Date: 2026-11-21
Status: draft, awaiting approval

## Intent

Laravel Herd no longer ships for Intel Macs. Paddock is a native macOS app
that gives Intel Mac users the same thing Herd gives everyone else: a local
PHP/Laravel environment that works the moment it is installed.

The owner uses an Intel Mac (macOS 15) and wants this for daily work first,
and wants to share it with other Intel Mac users later. They tried FlyEnv and
rejected it for "too much configuration that clearly did not consider UX".
Herd's simplicity is the product.

The whole of Paddock is three stages. This document covers stage 1 only.

1. **Core** (this doc): sites, `.test` domains, HTTPS, PHP versions, CLI.
2. **Services**: MySQL, PostgreSQL, Redis, Meilisearch, MinIO, Reverb.
3. **Debug tools**: mail catcher, log viewer, dumps window, Xdebug toggle.

Stages 2 and 3 get their own design docs. Stage 1 must not block them.

## Goals

- Drag to Applications, open, enter password once, and sites work. (The
  first time a site is secured, macOS asks once more to trust Paddock's
  certificate authority.)
- Any folder inside a parked directory is served at `<folder>.test`.
- One action gives a site trusted local HTTPS.
- Several PHP versions installed side by side; each site can pin one.
- `php` and `composer` in the terminal follow the site you are in.
- A `paddock` CLI whose commands mirror Herd's.
- **Standalone** (owner's requirement): the user installs nothing else and
  nothing has to be fetched for Paddock to work. The app bundle contains
  Caddy, Composer, Valet's router and the latest stable PHP, so the first
  launch works offline. It never requires Homebrew or MacPorts.
- Additional PHP versions are the only downloads, and only when the user
  asks for one (one click, or `paddock use 8.3`). (Designer's reading of
  "standalone"; Herd works the same way.)

## Non-goals (stage 1)

- Services and debug tools (stages 2 and 3).
- Apple Silicon builds, Windows, Linux.
- PHP older than 8.1.
- Node/nvm management, site sharing tunnels (`share`), Laravel installer UI.
- Code signing, notarization and auto-update. Needed before sharing; the
  design must not preclude them, but they are not built in stage 1.
- Importing settings from Herd or Valet.

## Anti-goals

- **Nothing asks the user a question Paddock could answer itself.** No port
  pickers, no path pickers, no config forms at install. A setting exists only
  if Herd has the equivalent.
- No step that requires a terminal to finish installation.
- Never silently fight another web server for ports 80/443.

## Constraints

- Target: x86_64, macOS 13 or later (owner's machine is 15.8.3).
- Native Swift. Xcode is installed on the owner's machine.
- The owner's machine has MacPorts nginx/PHP and an old `Herd.app`
  installed; Paddock must coexist with them and not depend on them.

## Approaches considered

1. **Fork Laravel Valet as the engine, Swift app on top.** What Herd did.
   Fastest to a working core, but Valet assumes Homebrew throughout, so much
   of it gets rewritten, and it leaves a PHP engine plus a Swift app to
   maintain.
2. **All-Swift engine, reusing only Valet's request router.** One Swift core
   used by the app and the CLI; Valet's small PHP router and framework
   drivers (MIT) are kept so Laravel, WordPress, Symfony etc. resolve
   correctly. Slower to first working site; one codebase; services and debug
   tools plug into the same core.
3. **Electron/Tauri.** Easier UI, but it is the FlyEnv shape and loses the
   native feel.

**Picked: 2**, chosen by the owner on recommendation. The engine is what all
three stages live on, and owning it is what keeps the app simple.

## What a spike established (2026-11-21)

- static-php.dev publishes prebuilt Intel macOS PHP binaries (CLI and FPM)
  for 8.0 through 8.5, current to 8.5.8.
- A downloaded 8.4 build ran on the owner's machine. It links only against
  system libraries.
- Its "common" extension set covers Laravel's requirements but lacks `intl`,
  `pdo_pgsql`, `opcache` and `xdebug`.
- It **can load ordinary shared extensions**: `intl.so` and `pdo_pgsql.so`
  from a MacPorts PHP of the same API version loaded and worked.
- Loading a Zend extension (`opcache.so`) failed with a missing symbol. The
  file came from PHP 8.4.27 and the binary was 8.4.8, so this is probably a
  version mismatch, but Zend-extension loading (which Xdebug needs) is **not
  yet proven**.

### Follow-up check after the build (2026-11-21)

- **Zend-extension loading is proven.** Xdebug 3.5.0, built from source
  with `phpize` against PHP 8.4 headers (MacPorts 8.4.27, used only as a
  build tool for this check), loaded into the static PHP 8.4.23 CLI and
  PHP-FPM binaries: `php -v` reports "with Xdebug v3.5.0" and
  `extension_loaded("xdebug")` is true. The resulting `xdebug.so` links
  only against the system library.
- So stage 3's Xdebug toggle can be a loadable `xdebug.so` per PHP minor
  version; a separate debug variant of PHP is not needed. Paddock still has
  to produce those `xdebug.so` files itself (one per supported minor, built
  against matching headers), since nobody publishes them for Intel macOS.
- The earlier `opcache.so` failure was a patch-version mismatch specific to
  OPcache, which is tied to its exact PHP build. It does not matter: the
  "bulk" builds Paddock uses have OPcache compiled in.
- The "bulk" builds also already include `intl`, `sodium`, `imagick`,
  `redis`, and PDO drivers for MySQL, PostgreSQL and SQLite, so the
  extension gap noted above for "common" does not apply to what ships.
- Cost of "bulk": each PHP binary is about 108 MB (about 216 MB per
  version on disk, 277 MB for the app). It also statically links LGPL
  libraries and one GPL library (JBIG-KIT, via ImageMagick). Fine for
  personal use; Paddock's own slimmer builds are needed before sharing.

### Corrections made during the build

- PHP builds live in `bin/php-versions/<version>/<variant>/`, not
  `bin/php/…`, because `bin/php` is the `php` command itself.
- The app's executable is `Contents/MacOS/PaddockApp`. `Paddock` and
  `paddock` would be the same file on a case-insensitive disk.
- Uninstall restores the `.test` DNS setting first and only then stops
  Paddock, so a cancelled password prompt never leaves `.test` domains
  resolving nowhere.
- The menu bar and settings UI in stage 1 is a stock placeholder. The owner
  is producing a fuller design separately.

## Design

### Shape

Three targets in one Swift package / Xcode project:

- **PaddockCore** — library. All logic: binary management, site registry,
  config generation, process supervision, DNS, certificates.
- **paddockd** — per-user background agent (launchd LaunchAgent) built on
  PaddockCore. Owns the running processes, so sites keep working when the
  menu bar app is closed. Listens on a Unix socket.
- **Paddock.app** — SwiftUI menu bar app (`MenuBarExtra`). Thin client of
  paddockd.
- **paddock** — CLI (swift-argument-parser). Thin client of paddockd.

The app and CLI never manage processes directly; they send requests to
paddockd. One source of truth.

### Files

Everything under `~/Library/Application Support/Paddock/`:

- `bin/` — shims (`php`, `composer`, `paddock`) and downloaded binaries,
  one folder per PHP version.
- `config/` — generated web server and PHP-FPM config. Disposable;
  regenerated from state.
- `state.json` — parked paths, links, secured sites, per-site PHP pins,
  default PHP version. The only durable state.
- `php/<version>/php.ini` — one per version, sensible dev defaults, user
  editable.
- `log/`, `run/` — logs, sockets, pid files.

Default parked directory: `~/Paddock`, created on first run.

### Web server: Caddy (builder's-level call, made by the designer)

Caddy instead of nginx, because:

- Official static Intel macOS binaries exist; nginx has none and would need
  its own build pipeline.
- It has a built-in local certificate authority, so HTTPS needs no separate
  certificate tooling.
- Config reloads gracefully through its admin API.

Trade-off: Herd/Valet users with custom per-site nginx config cannot reuse
it. Accepted for stage 1.

Routing follows Valet's model: one catch-all `*.test` site hands every
request to Valet's `server.php` router (vendored, MIT), which finds the site
folder from the host name and picks the framework driver. Secured sites and
sites with a pinned PHP version get their own generated site block.

### PHP

- A **manifest** (JSON: version, URL, SHA-256) lists available builds.
  Paddock downloads, verifies the checksum, and unpacks into `bin/`. For
  stage 1 the manifest is **bundled in the app and kept in the repo**,
  written by the builder with checksums computed from the downloaded
  files. The loader also accepts a remote manifest URL so a hosted one can
  replace it later without redesign; hosting is not a stage 1 task.
- Layout is `bin/php-versions/<version>/<variant>/` so a second variant of a version
  (for example a debug build with Xdebug compiled in) can be added later
  without moving anything. Stage 1 ships one variant.
- Stage 1 starts with static-php.dev's "bulk" Intel builds so work is not
  blocked. The intended end state is **Paddock's own builds**, produced with
  the open-source static-php-cli recipe, with a fixed extension set that
  adds `intl`, `pgsql`/`pdo_pgsql`, `opcache`, `sodium` and a loadable
  `xdebug`. Only the manifest URL changes when that switch happens.
- On first run Paddock copies the bundled latest stable PHP out of the app
  bundle into `bin/`; no network needed. Other versions download on demand
  through the manifest. Updating the app updates the bundled PHP.
- One PHP-FPM pool per installed version in use, each on its own Unix
  socket. Pools start when a site needs them.
- `php` shim: walks up from the current directory to find the site, runs
  that site's pinned version, otherwise the default. `composer` shim runs a
  bundled `composer.phar` through the `php` shim.
- The app offers one button to add `bin/` to the shell PATH (appends one
  line to `~/.zshrc`).

### DNS

paddockd contains a tiny built-in DNS responder that answers every `*.test`
query with `127.0.0.1` (and `::1`), listening on a high local port.
`/etc/resolver/test` points macOS at it. No dnsmasq.

### Privileges

(Designer's calls after the builder check.)

- **First run: one admin password prompt**, used only to write
  `/etc/resolver/test`.
- **Certificate trust is deferred to the first `secure`.** Paddock's local
  certificate authority is trusted at user level in the login keychain,
  which shows macOS's own confirmation dialog once. So the promise is: one
  password at install, one macOS confirmation the first time a site is
  secured. No root CA in the system keychain.
- **Ports 80 and 443 need no root.** Observed on the owner's machine
  (macOS 15.8.3): Herd 1.30.2's nginx runs as the normal user bound to
  `127.0.0.1:80` and `:443`. Caddy runs the same way, as the user, bound to
  loopback only. The builder confirms this on macOS 13 and 14 when a
  machine is available; no root daemon is planned.

### Coexistence

Observed on the owner's machine: Herd 1.30.2 is running and is the owner's
working environment today (its nginx holds 127.0.0.1:80/443, its dnsmasq
answers `.test`, and `/etc/resolver/test` already contains
`nameserver 127.0.0.1`). MacPorts nginx, php84-fpm, PostgreSQL and Redis
also run as launchd daemons.

The owner has confirmed the MacPorts services are not needed and will be
uninstalled later, separately from this work. Paddock does not have to
live beside them long term, and removing them is not part of stage 1.

Rules (designer's calls):

- **Development never touches the live setup.** All development and
  integration tests run on high ports with a temp state dir. Herd keeps
  working until the owner chooses to switch.
- **Switching is reversible.** When Paddock takes over, it saves the
  existing `/etc/resolver/test` before replacing it, and
  `paddock uninstall` (or "Restore previous setup" in Settings) puts it
  back.
- **Paddock never stops another server on its own.** Before starting,
  paddockd checks 80 and 443. If something holds them, Paddock does not
  start; the app names the process and offers to stop it for this session.
  It only stops processes owned by the user (e.g. quitting Herd). For
  root-owned servers such as MacPorts nginx it shows the one command to
  run and does nothing itself. It never unloads or edits another tool's
  launchd jobs.

### CLI

Mirrors Herd where an equivalent exists:

`paddock park [path]`, `forget`, `link [name]`, `unlink`, `links`, `parked`,
`secure [site]`, `unsecure`, `isolate <version>`, `unisolate`,
`use <version>`, `php`, `composer`, `start`, `stop`, `restart`, `status`,
`open [site]`, `logs`.

### Menu bar (sketch)

```
 🐎 Paddock            ● Running
 ─────────────────────────────
 Sites                      ▸   myapp.test      🔒  PHP 8.4
 PHP 8.4 (default)          ▸   blog.test           PHP 8.3
 ─────────────────────────────
 Open Sites Folder
 Stop All
 Settings…
 Quit
```

Settings window has three tabs only: **General** (start at login, parked
folders, PATH), **PHP** (installed versions, install/remove, default, open
php.ini), **Sites** (list with secure toggle and PHP version per site).

Exact look is the owner's to refine; mockups can follow before UI work.

### Testing

- Unit tests on PaddockCore: site resolution, config generation, state
  round-trip, DNS responder, manifest/checksum handling.
- Integration test that starts the stack on high ports with a temp state
  dir and requests a fixture PHP site and a fixture Laravel site.

## Build order

1. A time-boxed check (half a day at most) of Zend-extension loading:
   try a Zend extension whose PHP version exactly matches a static build.
   **The result does not gate stage 1.** Either way, record it in this
   doc. If it fails, opcache is compiled in statically in Paddock's own
   builds and Xdebug becomes a compiled-in debug variant, decided in the
   stage 3 design. Standing up the static-php-cli build pipeline is not
   part of this step.
2. PaddockCore + CLI: download PHP, park, serve a site over HTTP.
3. DNS and the privileged install step.
4. HTTPS (`secure`).
5. Multiple PHP versions, `isolate`, shims.
6. paddockd as a LaunchAgent; menu bar app and settings window.

## Left to the builder

- Internal module layout, socket protocol between clients and paddockd.
- Caddy config format (JSON via admin API vs. generated Caddyfile).
- Exact php.ini defaults and FPM pool tuning.
- Bundle identifier and versioning scheme.

## Repository and licence

- **Private repository** (owner's decision).
- **Licence (designer's pick, owner asked for one to be chosen):
  proprietary, all rights reserved.** Source stays closed. When builds are
  shared, they go out under a short freeware end-user licence: free to
  install and use, no redistribution or modification, no warranty. The
  repo carries a `LICENSE` file saying so.
- Paddock bundles open-source programs as separate executables, which a
  proprietary app may do provided their notices travel with it. The app
  ships a `THIRD-PARTY-NOTICES` file, shown in an About window, covering
  Caddy (Apache 2.0), PHP (PHP License), Composer (MIT) and Valet's router
  (MIT). The builder keeps this file current as components are added.
- None of the bundled code is linked into Paddock's own binary; it is run
  as separate processes. Keep it that way, because later services include
  copyleft programs (MySQL is GPL, MinIO is AGPL).

## Decided for later stages

- **Services (stage 2) are treated like extra PHP versions** (owner's
  decision): not bundled in the app, added with one click, then they work
  with no configuration.

## Open, not blocking stage 1

- Where Paddock's own PHP builds are produced and hosted.
