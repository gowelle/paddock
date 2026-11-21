# Paddock — Site tasks (scheduler, queues, custom scripts)

Date: 2026-11-21
Status: draft, awaiting approval
Adds to: `2026-11-21-paddock-services-design.md` (stage 2)

## Intent

Services give a project its database, cache, search and mail. A Laravel
project also needs things that belong to the project itself and must keep
running: a queue worker, the scheduler, a websocket server, a webhook
forwarder. Today the owner starts these by hand in a terminal with
`bun run dev:backend`, which runs six processes at once. Paddock should
keep the project's own processes running, so that with Paddock open the
application simply works and no terminal is needed.

The owner asked for "scheduler, queues, and custom scripts" and pointed at
the `dev:backend` script in `t-market/package.json` as the reference:

| In `dev:backend` today | With Paddock |
|---|---|
| Meilisearch | service |
| Mailpit | service (Mail) |
| `php artisan reverb:start` | site task, reached through the site's own HTTPS (see Proxy) |
| `php artisan queue:work redis --queue=default,scout,media,listeners --tries=3` | site task |
| `php artisan schedule:work` | site task |
| `bun run webhook:flutterwave:forward` | site task |

## Goals

- A site's tasks are defined once and then run whenever Paddock runs:
  started with Paddock, restarted if they crash, stopped cleanly with it.
- Any command can be a task. Queue worker and scheduler are just commands.
- Tasks run in the site's folder, with that site's PHP version and the
  user's normal shell environment, so `php`, `composer`, `bun`, `node` and
  the project's own scripts behave as they do in the user's terminal.
- Each task has its own log, and can be started, stopped and restarted on
  its own from the CLI and the app.
- A queue worker does not keep running old code after the code changes.
- Websockets work on the site's `https://` address without a separate
  certificate.

## Non-goals

- Managing Node, Bun or other toolchains. Tasks use what the user has.
- Per-task resource limits, scheduling tasks at times (that is what the
  Laravel scheduler task is for), or dependencies between tasks.
- Running tasks for sites that are not on this Mac.

## Anti-goals

- **Paddock never runs a command from a project the user has not approved.**
  Parking a folder full of other people's repositories must not start
  anything.
- No forms. A task is a line in a file, or one CLI command that writes that
  line.

## Approaches considered

1. **A file in the project (picked).** `paddock.json` in the site's folder
   lists its tasks. It travels with the repository, the exact queue command
   lives next to the code that needs it, and a teammate with Paddock gets
   the same setup. Paddock's side stays zero-config: it sees the file.
2. **Stored in Paddock per site.** Nothing to commit, but it must be redone
   on every machine and is invisible to the project.
3. **Read existing files** (`package.json` scripts, `composer.json`
   scripts, a `Procfile`). No new file, but those scripts are written for a
   terminal (`concurrently …`, colours, tools that Paddock already
   provides), so Paddock would be guessing which parts to run.

Picked: 1 (recommended to the owner; awaiting their confirmation in the
approval of this document). `paddock tasks init` writes a starter file so
the common case needs no typing.

## Design

### The file

`paddock.json` at the site's root:

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
  `restartOnChange` (true/false), `autostart` (default true),
  `stopSeconds` (how long to wait for a clean stop; default 30).
- `proxy`: path prefix → local port on this Mac. See Proxy.
- Unknown keys are an error naming the key, so typos do not pass silently.
- The file is read when a site is discovered and whenever it changes.

### Approval (the one question Paddock must ask)

A project file that makes Paddock run commands is powerful, so each site's
tasks run only after the user approves them once:

- A site with a `paddock.json` shows as "tasks need your approval" and
  nothing runs. `paddock tasks on` in the site's folder (or one click in
  the app) shows the exact commands and approves them.
- Approval is tied to the file's contents. If the `tasks` or `proxy`
  sections change, tasks keep running on the last approved version and the
  site shows "paddock.json changed: review and approve". Approving switches
  to the new version. (This stops a `git pull` from silently changing what
  runs on the machine.)
- `paddock tasks off` stops and un-approves.

### How a task runs

- Supervised by Paddock's daemon with the existing process supervisor: own
  process group, restart with backoff on a crash, give up after repeated
  failures and say so.
- Working directory: the site's folder.
- Environment: the user's login-shell environment, captured by Paddock
  (so `PATH` includes `~/.bun/bin`, nvm, etc.), with Paddock's `bin` first
  so `php` and `composer` are the site's PHP version. The site's `.env` is
  not injected; the project's own tooling reads it as it does today.
- The command line is run by the user's shell, as it would be in a
  terminal.
- Stop: SIGTERM to the process group, wait `stopSeconds` (queue workers
  finish their current job), then SIGKILL.
- Tasks start when Paddock starts (if approved and `autostart`), stop when
  Paddock's daemon shuts down, and keep running across a restart of the web
  side. If a site is removed or its folder disappears, its tasks stop.
- After a daemon crash, leftover task processes are recognised and stopped
  before being started again, as for services.

### Not running old code

A long-lived PHP worker keeps the code it started with. For any task with
`restartOnChange` on, Paddock watches the site's PHP source (not `vendor`,
`node_modules`, `storage`, `.git`, or build output) and restarts the task
shortly after changes settle. It is on by default for commands that run
`artisan queue:work`, `artisan horizon` or `artisan reverb:start`, and off
otherwise; the file can set it either way.

### Proxy (websockets and other local servers on the site's address)

Today the site's page connects to `wss://t-market.test:8080`, which works
only because Reverb borrows Herd's certificate for the site. Without Herd
that breaks. Instead, Paddock's web server forwards chosen paths of the
site to a local port:

- `"/app": 8080` forwards `https://t-market.test/app/…` (including
  websocket upgrades) to `127.0.0.1:8080`.
- The project then uses the site's normal address: `REVERB_PORT=443`,
  `REVERB_SCHEME=https`, and the server side listens on
  `REVERB_SERVER_HOST=127.0.0.1`, `REVERB_SERVER_PORT=8080`. This is the
  standard production arrangement for Reverb.
- Proxy targets are local ports only. Proxy routes are part of what the
  user approves.

This replaces the separate shared "Reverb" service planned as Task 6 of the
services plan: a project's own `reverb:start` as a site task, with its own
keys, is simpler and matches production. (The shared Reverb service can
still be added later if wanted.)

### Listening beyond this Mac

Paddock does not rewrite the user's commands, so it cannot force a task to
listen locally. It checks what each task listens on and shows a warning on
the task ("listening on all network interfaces") rather than stopping it.
The starter file and documentation use `--host=127.0.0.1`.

### Where it shows up

- CLI, run inside a site's folder (or with `--site <name>`):
  `paddock tasks` (list with state), `tasks init` (write a starter
  `paddock.json` for a Laravel project: queue and scheduler; never
  overwrites), `tasks on` / `off`, `tasks start|stop|restart <task>`,
  `tasks logs <task> [-f]`.
- `paddock status` shows each site's tasks under the site.
- App: tasks listed under each site with state, start/stop/restart, open
  log, and the approval prompt. Plain look; the owner's design comes later.
- Logs: one file per task under Paddock's log folder, size-capped and
  rotated.

### Testing

- Unit: file parsing and errors, approval hashing, default
  `restartOnChange` detection, environment assembly, proxy rule
  generation.
- Integration (scratch home, high ports): approve → tasks run in the site
  folder with the site's PHP; unapproved file runs nothing; changed file
  keeps the approved version until re-approved; crash → restart; stop waits
  for a slow task; change to a PHP file restarts a `restartOnChange` task;
  proxy forwards an HTTP request and a websocket upgrade over the site's
  HTTPS to a test server; daemon restart brings tasks back; orphan cleanup
  after a daemon kill.
- Owner checklist: `paddock.json` for `t-market` as above, the Reverb
  `.env` changes, then `bun run dev:backend` is no longer needed.

## Left to the builder

- How the login-shell environment is captured and refreshed.
- File-watching mechanism and debounce.
- Log rotation details.

## Open

- None blocking.
