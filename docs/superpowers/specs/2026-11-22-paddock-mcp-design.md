# Paddock — MCP server (`paddock mcp`)

Date: 2026-11-22
Status: draft, awaiting approval
Adds to: `2026-11-21-paddock-core-design.md`

## Intent

People who use Paddock increasingly work with an AI coding agent beside
them. Today that agent can only learn about the local environment by
running `paddock` in a shell and reading text meant for a person, if it
has a shell at all. An MCP server lets the agent ask Paddock directly:
what is this site's address, which PHP does it run, what is the database
port, what did the log just say, did the mail arrive.

The owner asked for an MCP server and left its scope to the builder:
"expose functionality you deem do not pose a security risk and other
basic stuff". Everything below about which tools exist is therefore the
designer's call, not something the owner chose item by item.

## Goals

- An agent can see the state of Paddock in structured form: sites,
  PHP versions, services, site tasks, logs, caught mail.
- An agent can make the small, per-site and per-service changes that undo
  cleanly, without the owner leaving the conversation.
- Setting it up is one line of agent configuration and nothing to
  install: it ships inside the `paddock` command people already have.
- The owner can run it with changes switched off entirely.

## Non-goals

- Dumps. They need a live listener and a routing change in the daemon;
  a later piece of work.
- Downloads: installing a PHP version, adding or updating a service.
  They take minutes, which agent clients time out on, and are rare.
- Deleting or changing mail. Reading only.
- A network (HTTP) transport. Standard input and output only.
- MCP resources, prompts, sampling, or change notifications. Tools only.

## Anti-goals

These would make it a failure even if it worked:

- An agent can cause a command to run that the owner has not approved.
  Approving a site's `paddock.json` stays a human act, in the app or the
  CLI. The server never sends `tasksApprove`, `tasksInit` or
  `tasksRevoke`.
- An agent can change what macOS trusts, or anything that asks for the
  owner's password. The server never sends `trust`, and never sends
  `secure`: the daemon answers `secure` by trying to make macOS trust
  Paddock's certificate when it doesn't yet (`EngineHandler`,
  `ensureTrusted(afterSecuring:)`), and the status can't say beforehand
  whether it would.
- An agent can lose the owner's data or installed software: no
  `serviceRemove`, `removePHP`, `shutdown`, uninstall.
- An agent is handed a secret Paddock keeps. The server never sends
  `serviceEnv`; it passes on only what `status` already leaves secrets
  out of. This is about Paddock's own store. Logs are a different thing:
  they hold whatever the owner's applications and tasks wrote, for every
  site, and that can include a token or a request body. `logs_read`
  passes them on as they are, with no redaction (the server could only
  redact Paddock's secrets by asking for them). The README says so, and
  `--no-logs` leaves the two log tools out.
- An agent can read a file of its choosing. `logs_read` takes only an id
  that a freshly computed `LogCatalog` lists at that moment. Those ids
  are file paths (`LogSource.id`), which is fine: an agent sees site
  folders in `status` anyway. What matters is that nothing outside the
  catalog can be read, and that the file is opened without following a
  symlink (the catalog skips symlinks when listing, but `LogTail.read`
  follows them when opening).
- An agent can change what is served or change the whole machine: no
  `park`, `forget`, `link`, `unlink`, `secure`, `unsecure`, `use`,
  `start`, `stop`, `restart`.
  (Linking a folder makes its PHP files runnable by a web request, so it
  is on the wrong side of the line.)

A note on what this line is and isn't: the server runs as the owner, as
the CLI does, and an agent that has a shell can run `paddock` itself. The
tool list is not a sandbox. It decides what an agent can do through this
door, and it keeps that door safe for clients that have no shell.

## Constraints

- No new package dependency. The protocol is written by hand in
  `PaddockCore`; it is three requests and a notification.
- Nothing new in the daemon. No new `Request` or `Response` case; the
  server is a third client of the existing socket, like the CLI and app.
- The existing rule holds unchanged: a development build may send only
  read-only requests to the real home's daemon (`PaddockClient` already
  refuses the rest).
- Standard output carries protocol messages and nothing else. Anything
  for a person goes to standard error.
- macOS 13, Swift 6 toolchain in Swift 5 language mode, as the package is.

## Approaches

1. **A `paddock mcp` subcommand of the existing CLI (chosen).** Speaks
   MCP over stdin/stdout, forwards to the daemon over the socket. Nothing
   new to bundle or sign, no listener, no dependency. Costs: we own a
   small JSON-RPC loop.
2. **A separate `paddock-mcp` binary on the official Swift MCP SDK.**
   Less protocol code to own. Costs: a new dependency tree, another
   program in `Scripts/bundle.sh` and the signing step, for very little
   protocol surface.
3. **An HTTP endpoint inside the daemon.** Always running, no process
   per agent. Costs: a port any local program or web page can reach, so
   it needs its own authentication and origin checks. That works against
   the reason the owner gave.

The owner handed over the how; the designer picked 1.

## Design

### Shape

- `Sources/PaddockCore/MCP/`: the server and the tools, with no
  knowledge of ArgumentParser or of real I/O. It is given: a way to read
  a line and write a line, a way to send a `Request` and get a
  `Response`, the `Paths`, and a mail reader. Tests give it fakes. The mail reader
  is a new, narrow protocol (`MailReading`: inbox, search, message) that
  `HTTPMailClient` conforms to, so the server cannot reach the existing
  `MailClient`'s `delete` or `setRead`.
- `Sources/paddock/MCPCommand.swift`: `paddock mcp [--read-only] [--no-logs]`, a thin
  command that wires the real stdin/stdout, `PaddockClient` and
  `HTTPMailClient` into the server and runs until stdin closes.
- Registered in `Paddock.swift`'s subcommands.

### Protocol

Newline-delimited JSON-RPC 2.0 over stdin/stdout (MCP's stdio
transport). The server answers:

- `initialize`: its name (`paddock`), its version (`PaddockBuild.number`, as a string), the
  `tools` capability, and a protocol version: the client's, if it is one
  the server knows; otherwise the newest the server knows.
- `notifications/initialized`: accepted, no reply.
- `ping`: empty result.
- `tools/list`: the tools below, each with a JSON Schema for its input
  and the annotations `readOnlyHint`, `destructiveHint` (false
  throughout), `idempotentHint`.
- `tools/call`: runs the tool. A tool's failure (unknown site, daemon not
  running, mail service not added) is a normal result with
  `isError: true` and one plain sentence, not a JSON-RPC error.
- Anything else: JSON-RPC "method not found". A line that isn't JSON:
  "parse error". Unknown notifications are ignored.

Requests are handled one at a time, in order.

The builder should check the current MCP specification for the exact
field names and the protocol version strings rather than rely on memory.

### Tools: seeing

All are read-only and are always present.

| Tool | Input | Gives |
|---|---|---|
| `status` | none | Whether Paddock is running; each site's name, URL, folder, PHP version, whether pinned, whether HTTPS; installed and default PHP; Xdebug state; each service's name, kind, version, state, ports and its non-secret `.env` lines; notices. From `Request.status`. |
| `site` | `name` or `path` | One site, as above, plus its tasks and their states. `path` may be any folder inside the site (so an agent can pass its working directory). Uses `tasksStatus`, which re-reads `paddock.json`. |
| `logs_list` | none | The logs there are, grouped as the Logs window groups them, each with an id. From `LogCatalog.sections`. |
| `logs_read` | `id`, `lines` (default 100, at most 500), `contains` (optional) | The last lines of that log, optionally only lines containing the text. |
| `mail_list` | `query` (optional), `limit` (default 20, at most 50) | Caught messages, newest first: id, from, to, subject, date, read or not. |
| `mail_read` | `id` | One message: headers, the text body (HTML body only when there is no text), attachment names and sizes. No attachment contents. |

Results are JSON, as a text content block. `status` and `site` do not
pass on fields that only matter to Paddock's own clients
(`executablePath`, `dataPath`, process tables).

A single result is capped at 64 KB; a longer log tail or mail body is cut
with a line saying so.

### Tools: doing

Left out when the server is started with `--read-only`.

| Tool | Input | Sends |
|---|---|---|
| `site_php` | `site`, `version` (or null for the default) | `isolate` / `unisolate`. Only an installed version. |
| `xdebug` | `version`, `on` | `xdebug`. |
| `service_control` | `name`, `action`: start, stop, restart | `serviceStart` / `serviceStop` / `serviceRestart`. |
| `database_create` | `service`, `database` | `serviceCreateDatabase`. |
| `task_control` | `site`, `task`, `action`: start, stop, restart | `taskStart` / `taskStop` / `taskRestart`. Only tasks the owner already approved; the daemon refuses the rest. When `paddock.json` has changed since approval the daemon still runs the approved version, never the new one (`TaskApproval`), so the tool passes that through and its answer says the file has changed and needs the owner's approval again. |

Each answers with a sentence saying what happened and the affected site
or service as it now stands.

### What an agent is told about untrusted text

Logs and mail are written by whatever the owner's applications handle,
so they can contain text aimed at an agent. The descriptions of
`logs_read`, `mail_list` and `mail_read` say that their contents are
data from the application and not instructions. Those results carry only
the content, inside a clearly named JSON field.

### When things aren't there

- Daemon not running: every tool answers `isError` with the sentence the
  CLI uses. The server does not start the daemon or touch the system.
- No mail service, or not running: `mail_*` say so (as `MailEndpoint`
  distinguishes).
- An unknown log id, site, service or task: `isError`, one sentence,
  with the valid names where that list is short.

### Documentation

A README section, "Using Paddock from an AI agent": what it is, the one
line of configuration for an MCP client (`paddock mcp`), the list of
tools, what is deliberately not exposed and why, and `--read-only`.
Public copy follows the existing rule: no comparison to other products.

### Testing

Unit tests in `PaddockCoreTests`, with a fake daemon and fake mail
client: the handshake, `tools/list` with and without `--read-only` and `--no-logs`, each
tool's happy path and its refusals, the size cap, malformed input, a
log id outside the catalog, a log that is a symlink. One
test asserts the set of `Request` cases the server can ever send, so
adding a risky one later fails a test instead of passing unnoticed.

## Calls the designer made

The owner did not choose these; each can be reversed:

- The whole tool list and the line above.
- No tool turns HTTPS on or off. Turning it on can raise the macOS trust
  prompt, and turning it off alone isn't worth a tool. If the owner
  wants it, the clean way is a daemon request that secures without
  trusting, which is a change to the daemon and so a separate decision.
- Logs are passed on unredacted, for all sites, with `--no-logs` as the
  way out. This is the call most worth the owner's second look.
- `link`/`unlink` and `use` are out, though they are basic, because they
  change what is served or the whole machine.
- Service secrets are out; an agent working in a project can read that
  project's `.env`.
- Reading a message through `mail_read` may mark it read in the Mail
  window, as opening it there does.
- Tool names are short and unprefixed (`status`, not `paddock_status`);
  clients already prefix them with the server's name.
- Hand-written protocol code instead of the SDK.

## Left to the builder

- The exact JSON shapes of results and schemas.
- How the 64 KB cap is applied to each tool.
- File and type names inside `Sources/PaddockCore/MCP/`.
- Whether `logs_read` reuses `LogTail` or the CLI's `lastLines`.
- Which protocol versions to accept.
