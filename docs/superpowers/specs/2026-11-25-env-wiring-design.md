# One-action `.env` wiring

**Status:** approved for implementation.

## Goal

`paddock service env <name>` and the app's **Copy .env** print a service's lines and leave
the paste to the owner. This feature does the paste: one command or one click writes a
service's lines into a site's `.env`, updating the keys the service owns and leaving every
other line exactly as it was.

It appears as:

- `paddock env <service> [site]` in the CLI.
- **Write to .env…** beside **Copy .env** in Settings → Services, with a short site picker.

Nothing else changes: no new daemon request, no MCP tool, no app window.

## Non-goals

- Generating or repairing a site's whole `.env`. Paddock writes only the keys the chosen
  service defines; `APP_KEY`, `APP_NAME`, mail settings and everything else stay the owner's.
- Writing to more than one site at a time, or to every site.
- Editing a service's lines, choosing values, or exposing secrets in any output.
- A new IPC request. The lines already come from `.serviceEnv` (secrets included) and the
  merge and write happen in the client that asked for them.

## Where it lives

A pure merge and a small file writer in PaddockCore, used by both surfaces:

```swift
public enum EnvWiring {
    public struct Result: Equatable, Sendable {
        public let text: String          // the whole new file
        public let settings: [String]    // every key the service defines, each once
        public let added: [String]       // key names, in the service's order
        public let updated: [String]     // key names, in the service's order
    }
    public static func merge(existing: String, service lines: [String]) -> Result
}

public enum EnvFile {
    public enum Problem: Error, Equatable {
        case missing
        case symlink
        case notUTF8
        case unreadable(String)          // the system's sentence
        case unwritable(String)          // the system's sentence
    }
    /// Reads `<sitePath>/.env`, merges `lines`, writes it back atomically with its own
    /// permissions, and returns the merge result. Throws before writing when it refuses.
    public static func wire(_ lines: [String], intoSiteAt sitePath: String) throws -> EnvWiring.Result
}
```

Files: `Sources/PaddockCore/Services/EnvWiring.swift` and
`Sources/PaddockCore/Services/EnvFile.swift`.

The sentences live in `Messages.swift`, so the CLI and the app say the same thing:

- `Messages.wiredEnv(service:host:added:updated:)` — see **Output**.
- `Messages.envAlreadyWired(service:host:)` — `<host>'s .env already has every line from <service>.`
- `Messages.serviceHasNoEnvLines(_:)` — `<service> has no .env lines to wire.`
- `Messages.noEnvFile(_:)` — `<host> has no .env. Create one from .env.example first; Paddock won't write secrets into a new file.`
- `Messages.symlinkedEnvFile(_:)` — `<host>'s .env is a symlink; Paddock won't write through it.`
- `Messages.utf8EnvFile(_:)` — `<host>'s .env isn't UTF-8; Paddock left it alone.`
- `Messages.couldntReadEnvFile(_:reason:)` — `Paddock couldn't read <host>'s .env: <reason>.`
- `Messages.couldntWriteEnvFile(_:reason:)` — `Paddock couldn't write <host>'s .env: <reason>.`

## The merge

Input: the file's current text and the service's lines (as `.serviceEnv` returns them).

**Service lines.** A line is a setting when it matches `KEY=value` with `KEY` matching
`[A-Za-z_][A-Za-z0-9_]*`; the key is the text before the first `=`, the value everything
after it (a value may be empty or contain `=`). Comments and blank lines in the service's
output are ignored. If a key appears twice in the service's lines, the last wins. If no
line is a setting, nothing is written (`serviceHasNoEnvLines`).

**The file.** Split it into lines keeping each line's terminator. For each existing line:

- if its key is one the service defines, replace the whole line with `KEY=value` from the
  service, keeping that line's terminator — the line stays where it is, comments and
  spacing around it untouched. A line the file spells `export KEY=…` is the same key and is
  replaced by the plain `KEY=value` line;
- every occurrence of a duplicated key is replaced (the service's value wins everywhere);
- every other line — comments, blank lines, unknown keys, malformed lines — is copied
  byte for byte.

Keys the file lacks are appended at the end in the service's order. If the file does not
end with a newline, one newline is inserted before the first appended line and none after
the last appended line; otherwise each appended line ends with a newline. Appended lines
use `\r\n` when every terminated line in the file ends with `\r\n`, otherwise `\n`.

`settings` is every key the service defines (once each); `added` and `updated` are its
subset that was missing or whose line text changed (a line already equal to the service's
line is replaced by identical text and is not listed), key names only, listed in each
key's first position in the service's lines. A file with none of the service's keys yet gets every key in `added`.
A service whose lines hold no settings gives `settings`, `added` and `updated` empty and
leaves `text` untouched; so does a service whose keys the file already has with the same
values (`added` and `updated` empty). The first prints `serviceHasNoEnvLines`, the second
`envAlreadyWired`.

## The write

`EnvFile.wire` refuses, before reading or writing anything it can help:

1. **Missing** `.env` (no file at `<sitePath>/.env`): `noEnvFile`.
2. **Symlink**: the path itself is a symbolic link (`FileManager.destinationOfSymbolicLink`
   succeeds): `symlinkedEnvFile`. The parent folders may be links; only the file may not.
3. **Not UTF-8**: `String(contentsOf:encoding:.utf8)` fails with an encoding error: `utf8EnvFile`.
4. **Unreadable** for any other read reason: `unreadable` with the error's sentence.

It then merges and writes with `Data.write(to:options:.atomic)`, then restores the file's
previous `posixPermissions` (the atomic write creates a new file, which would otherwise
lose e.g. `0600`). A write failure is `unwritable` with the error's sentence. Nothing is
written when the merge changes nothing.

## CLI

`paddock env <service> [site]`.

- `<service>` resolves with the existing `CLI.service(named:in:)` — id or name, any case —
  from a fresh `.status` (the same 30-second timeout `service env` uses).
- `[site]` resolves by name or host; without it, the folder the command runs in is used via
  the existing `CLI.site(named:in:)`. A folder that isn't a site gets the existing
  `Messages.notASite` sentence. The argument wins over the folder.
- Order: resolve the site, then the service, then fetch the lines, then wire. A wrong site
  and a wrong service in one command report the site first; a missing `.env` is reported
  after the service is known, so the refusal can name the service that was about to be wired.
- `CLI.refuseChangesFromDevelopmentBuild()` first, exactly as `service env` does: the lines
  hold secrets only a real home may read, and this command writes them into a project.
- The command never prints a value, with or without `--verbose`.

Output, exit 0:

```
Wired mail into shop.test's .env: added REDIS_HOST, REDIS_PORT; updated DB_PASSWORD.
```

Only added or only updated lists its one part; nothing to do prints `envAlreadyWired`; a
service with no settings prints `serviceHasNoEnvLines`. Refusals and failures print their
sentence and exit 1.

## App

- `AppModel.writeEnv(_ id: String, into site: Site) async` in `AppModel+Services.swift`,
  beside `copyEnv`:
  1. fetch the lines with `act(.serviceEnv(id:), timeout: 30)`, exactly as `copyEnv` does;
  2. call `EnvFile.wire(lines, intoSiteAt: site.path)`;
  3. `showNotice` with `wiredEnv` / `envAlreadyWired` / `serviceHasNoEnvLines`, or, on
     `EnvFile.Problem`, the matching sentence — the same words the CLI prints.
  It never touches the pasteboard and never shows a line's value.
- `ServiceRowView` gains **Write to .env…** beside **Copy .env**. It opens a small sheet
  (the `createDatabase` sheet in `ServicesTab` is the pattern): a site picker listing
  `site.host` for every site in `model.sites`, defaulting to the first, and **Write**. With
  no sites, the button is disabled and a caption says `No sites yet.`
- The sheet names the service it will wire (`Wire <service> into a site's .env`) and, after
  writing, closes; the result arrives as the usual notice.

## Testing

- `Tests/PaddockCoreTests/EnvWiringTests.swift`: replace in place; every duplicate updated;
  append order; comments, blank lines, unknown and malformed lines byte-identical; missing
  final newline; CRLF file appends CRLF; value containing `=`; empty value; service
  comments/blank lines ignored; repeated service key, last wins; no settings; nothing to do
  (`added` and `updated` empty, text unchanged).
- `Tests/PaddockCoreTests/EnvFileTests.swift` (temp directories): writes and preserves
  `0600`; missing, symlink and non-UTF-8 refusals write nothing; nothing-to-do also writes
  nothing; an unreadable file reports `unreadable` (`XCTSkipIf(getuid() == 0)`); a write
  into a read-only folder reports `unwritable`.
- `Tests/IntegrationTests/CLITests.swift`: in the daemon section, `paddock env mail`
  outside a site prints `Messages.notASite` and exits 1, and `paddock env mail plain-php`
  with no such service prints the unknown-service sentence and exits 1; `paddock env`
  requires its service argument. In the no-daemon section it prints
  `Messages.daemonNotRunning` (a site is only resolved from the daemon's status). (Wiring a
  real service needs one added in the throwaway home, so the success path is covered by
  `EnvFileTests` rather than the harness.)
- App: `swift build`; the Settings → Services snapshot regenerates with the new button, and
  the new sheet has no snapshot.
- Gates: `swift build`, `swift test --filter PaddockCoreTests`, `swift test --filter
  CLITests`, `swift test --skip IntegrationTests`.

## Shipping

README: a feature-table row beside **One-action services**, the services section gains a
sentence that **Write to .env…** / `paddock env` does the paste, and the CLI table gains
`paddock env <name> [site]`. The unreleased `docs/releases/0.5.0.md` gains a bullet; this
work does not bump `VERSION` or `PaddockBuild.number`.
