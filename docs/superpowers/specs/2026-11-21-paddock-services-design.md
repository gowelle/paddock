# Paddock — Stage 2 (Services) design

Date: 2026-11-21
Status: draft, awaiting approval
Builds on: `2026-11-21-paddock-core-design.md`, `2026-11-21-paddock-ports-design.md`

## Intent

Herd Pro gives every project its database, cache, search, storage, mail and
websocket server with one click. Paddock's owner needs the same on an Intel
Mac: their own app (`t-market`) uses PostgreSQL, Redis, Meilisearch, Reverb
and a local mail server, and today those come from leftover MacPorts
installs they want to remove.

The rule from stage 1 still governs: **nothing asks the user a question
Paddock could answer itself.** A service is added with one action and then
simply works. Decided earlier by the owner: services are not bundled in the
app; they are downloaded when added, like extra PHP versions.

## What research established (2026-11-21)

Sources and details: research notes kept with the session
(`services-research.md`); items marked "unverified" there are re-checked by
the builder before use.

| Service | Intel macOS source | Licence | Note |
|---|---|---|---|
| PostgreSQL 16 / 17 / 18 | `theseus-rs/postgresql-binaries` releases (~92 MB) | PostgreSQL | Relocatable; checksums, SBOM and provenance published |
| MySQL 8.4 LTS, 9.7 LTS | Oracle tarballs (~175 MB) | GPLv2 | **Oracle stopped Intel builds of 8.4 after 8.4.11**; 9.7 still has them |
| Redis | **No prebuilt Intel macOS binary exists anywhere** | Redis 8: AGPL/RSAL/SSPL | Must be compiled |
| Valkey (Redis-compatible fork) | Source only; compiles with Xcode's tools alone | BSD-3 | The licence-safe way to offer "Redis" |
| Meilisearch | Official GitHub binary (~350 MB) | MIT | No checksum file published |
| MinIO | **Gone** (downloads removed, repository archived) | — | Cannot be offered |
| SeaweedFS (S3-compatible) | Official GitHub binary (~50 MB) | Apache-2.0 | Maintained Intel build |
| MariaDB | No macOS binaries at all | GPLv2 | Would have to be built and hosted by Paddock |
| Mailpit | Official GitHub binary (~11 MB) | MIT | SMTP catcher with web UI and API |
| Laravel Reverb | PHP package (`laravel/reverb`) | MIT | Runs on Paddock's own PHP |

Also found on the owner's first real run of stage 1: the prebuilt PHP that
Paddock shipped cannot connect to PostgreSQL over TCP (a Swoole hook spins
forever). Paddock's own PHP builds without Swoole are being produced now
and are a **prerequisite** for this stage.

## Goals

- One action adds a service; it is downloaded, initialised and started with
  working defaults. No forms.
- Each service shows the exact `.env` lines for a Laravel app, with one
  click to copy them.
- Services start with Paddock and stop with it; each can also be stopped,
  started, and removed on its own.
- Several versions or instances of a service can run side by side.
- Everything listens on this Mac only.
- Data survives stop, restart, app updates and uninstall of the app.

## The services in this stage (designer's calls, for the owner to confirm)

1. **PostgreSQL** 16, 17, 18.
2. **Redis**, delivered as **Valkey** built by Paddock. Shown in the app as
   "Redis (Valkey)". Laravel's Redis client works with it unchanged.
3. **Meilisearch**.
4. **Reverb**, run from a small bundled Laravel app on Paddock's PHP.
5. **Mail**: Mailpit. In this stage "Open Mailbox" opens its page in the
   browser; a native mail window is stage 3.
6. **MySQL** 8.4 (pinned to 8.4.11, the last Intel build) and 9.7.
7. **Object storage (S3-compatible)**: SeaweedFS, in place of MinIO.

Order of building follows the owner's own app: 1–5 first, then 6 and 7.

## Non-goals

- **MariaDB.** No Intel macOS binaries exist; building and hosting a GPL
  database is not worth it for stage 2.
- Typesense, MongoDB, and other services Herd does not offer.
- Remote access, replication, backups, GUI database browsing.
- Moving data out of an existing MacPorts/Herd database automatically. The
  switch-over notes will give the two commands to copy a database across.
- Native windows for mail, logs and dumps (stage 3).

## Anti-goals

- No port, path, user or password prompts when adding a service.
- Never take over a port another program is using, and never stop another
  program's database.
- Never delete a service's data unless the user explicitly asks.

## Approaches considered

1. **A catalog of service recipes run by one service manager (picked).**
   Each service is described as data: where to download it, how to
   initialise a data folder, how to start it, how to tell it is ready, its
   default port and its `.env` lines. One piece of code in Paddock's daemon
   downloads, initialises, supervises and reports on any service from its
   recipe, reusing the downloader and process supervisor from stage 1.
   Adding a service later is mostly adding a recipe.
2. **Hand-written code per service.** Flexible, but seven near-copies of
   the same download/init/run/readiness logic, and every new service is new
   code to review.
3. **Run services in containers.** Needs Docker or a VM; the opposite of
   standalone and of Herd's feel.

Picked: 1. The differences between services are small and mostly data; the
few real quirks (PostgreSQL and MySQL need a one-time initialisation;
Reverb needs PHP) are steps the recipe format names explicitly.

## Design

### Recipes and instances

- A **recipe** (bundled catalog file, updatable later from a hosted copy):
  kind, display name, version, download(s) with SHA-256 and size, licence
  name, the one-time initialise step, the start command, how to check
  readiness (connect to port or socket, or an HTTP check), preferred port,
  and the `.env` template.
- An **instance** is one added service: recipe + name + port + its own
  folder `services/<id>/` holding `data/`, the service's own config file,
  its socket and its log. Binaries are shared per recipe under
  `services/bin/<kind>/<version>/`.
- Adding the same kind twice gives a second instance on the next free
  port, named with its version (`PostgreSQL 17`, `PostgreSQL 18`).

### Ports

- Each recipe has the conventional port (5432, 3306, 6379, 7700, 8080,
  1025/8025, 8333). If it is free, use it. If not, use the next free port
  and show that port everywhere, including in the `.env` lines. Nothing is
  asked.
- The chosen port is saved with the instance and does not move later. If it
  is taken at a later start, that instance shows "port in use by …" (same
  wording and detection as stage 1) and the others keep running.

### Defaults (mirroring Herd where it has a convention)

- PostgreSQL: superuser `root`, no password, connections from this Mac
  trusted; TCP on loopback and a Unix socket.
- MySQL: `root`, no password; loopback and a Unix socket.
- Redis (Valkey): no password; loopback and a Unix socket.
- Meilisearch: development mode, no key.
- Object storage: fixed development key and secret shown in the `.env`
  lines; one default bucket.
- Mail: SMTP on 1025, mailbox page on 8025.
- Reverb: port 8080, fixed development app id, key and secret shown in the
  `.env` lines; plain `ws://` on loopback in this stage (secure `wss://`
  through Paddock's web server is noted for a later stage).
- A database named after a site is **not** created automatically in this
  stage; the `.env` lines name the database and the service page offers
  one action, "Create database…", which is the single place a name is
  typed. (Herd behaves the same way.)

### Lifecycle

- Run by Paddock's daemon under the stage 1 supervisor: started when
  Paddock starts (each instance has a "start with Paddock" switch, on by
  default), restarted with backoff if it crashes, stopped cleanly with the
  right signal for that service when Paddock stops.
- Stopping the web side of Paddock does not stop services unless the
  daemon itself is shutting down.
- **Remove** stops the instance and removes it from the list but keeps its
  data folder, and says where it is. "Remove and delete data" is a separate,
  explicit action with a confirmation.
- Uninstalling Paddock leaves all service data in place.

### Where it shows up

- CLI: `paddock service list`, `add <kind> [version]`, `start|stop|restart
  <name>`, `remove <name> [--delete-data]`, `env <name>` (prints the
  `.env` lines), `logs <name>`, `create-db <name> <database>`.
- App: a Services section listing instances with state, port, start/stop,
  "Copy .env", "Open" where the service has a page, and "Add Service…"
  showing the catalog. The look is the owner's (their design system); this
  stage supplies the behaviour and a plain default.
- `paddock status` lists services under sites.

### Paddock-built binaries

- Valkey is compiled by a build script in the repository (Xcode's tools
  only) into a tarball in the same single-binary layout as PHP builds.
- Together with the Swoole-free PHP builds, this makes "Paddock's own
  builds" a real thing in this stage. Until a public download location is
  chosen, the catalog and PHP manifest accept a local builds folder, so the
  owner's Mac installs from files built on it. **Choosing where to host
  builds is required before sharing Paddock, not before using it.**

### Safety

- Every service binds loopback only; the recipe's start command is the only
  way a listen address is set, and a test asserts no recipe binds a
  wildcard address.
- Downloads are verified against the catalog's SHA-256 before anything is
  unpacked or run (for sources that publish no checksum, the catalog pins
  the hash of the exact file Paddock was tested with).
- Third-party programs run as separate processes as the normal user; none
  is linked into Paddock (required by the GPL/AGPL-family licences involved,
  and already the rule from stage 1).
- The service's licence name is shown in the catalog list.

### Things the builder must verify early

- The minimum macOS version of the PostgreSQL and MySQL archives (the
  PostgreSQL source says macOS 15). If they need macOS 15, services require
  macOS 15 and Paddock says so on older systems; the web side keeps
  working on macOS 13 and 14.
- Whether files Paddock downloads are quarantined by macOS, and handle it.
- Every initialise/start/stop command, by running it, before it goes into
  a recipe.
- That Paddock's PHP connects to each service over TCP and over its Unix
  socket (the check that would have caught the Swoole problem).

### Testing

- Unit: recipe decoding, port choice, command rendering, `.env` rendering,
  loopback-only assertion, state round-trip.
- Integration, per service, on free high ports in a scratch home: add
  (download cached between runs), initialise, start, a real client check
  from Paddock's PHP, stop, start again and confirm data is still there,
  remove keeps data, remove-and-delete removes it.
- The owner's checklist: add PostgreSQL, Redis, Meilisearch, Reverb and
  Mail; copy a database across from the MacPorts PostgreSQL; point
  `t-market` at Paddock's services; stop the MacPorts services.

## Build order

1. Service framework (recipes, instances, ports, lifecycle, status) with
   Mail (Mailpit) as the first, smallest service; CLI.
2. PostgreSQL.
3. Valkey build script, then Redis (Valkey).
4. Meilisearch.
5. Reverb.
6. MySQL.
7. Object storage (SeaweedFS).
8. App Services section (behaviour; plain look).

Each step leaves something usable.

## Left to the builder

- Recipe file format details; socket protocol additions; internal layout.
- Exact config files written for each service.

## Open

- Where Paddock's own builds are hosted (needed before sharing).
