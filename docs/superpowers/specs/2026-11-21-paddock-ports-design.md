# Paddock — ports 80 and 443 (addition to the stage 1 design)

Date: 2026-11-21
Status: draft, awaiting approval
Amends: `2026-11-21-paddock-core-design.md`, sections "Privileges" and
"Web server"

## Why this exists

The stage 1 design said Paddock's web server could listen on ports 80 and
443 as a normal user. That was wrong. On macOS a normal-user program cannot
listen on a port below 1024 on `127.0.0.1`; it is refused whether or not
anything else is using the port. Confirmed on the owner's Mac: ports 81 and
444 on loopback were refused, while listening on all interfaces was allowed.
Herd gets around this with a root-run web server process.

Without a fix, Paddock cannot serve on real ports at all.

The owner chose (2026-11-21): **a small helper installed with the one
password prompt, loopback only** — over listening on all network interfaces
without root. The owner also wants only one service on those ports and
plans to uninstall Herd once Paddock works.

## Goals

- Sites are reachable at `http://name.test` and `https://name.test` on the
  standard ports, from this Mac only.
- Still exactly one password prompt at install.
- **No Paddock code runs as root after install.**
- Uninstall removes everything this adds, in its one password prompt.
- The web server path is the same in tests as on the real system.

## Non-goals

- Serving sites to other devices on the network.
- Sharing ports 80/443 with another tool. Once installed, Paddock holds
  them until it is uninstalled.

## Approaches considered

1. **Port helper started by macOS with the ports already open (picked).**
   macOS's own service manager (launchd) opens 80 and 443 on loopback and
   hands them to a tiny helper that it runs **as the owner's normal user**.
   The helper passes each connection to Paddock's web server. Nothing of
   Paddock's runs as root; root is only used once, by the install script,
   to register the helper.
2. **Hand the open ports straight to Caddy.** Same launchd trick, but the
   listening ports are passed across processes into Caddy itself, with no
   helper in the traffic path. Slightly more efficient, but it depends on a
   newer Caddy feature, on passing open ports between three processes, and
   on changing how the supervisor starts children. More to go wrong for no
   benefit a developer would notice.
3. **Firewall redirect (pf).** A root-installed rule redirects 80/443 to
   high ports. No helper process, but it means switching on and owning part
   of the system firewall, which other tools and macOS updates also touch.
4. **Run Caddy as root.** Rejected: Caddy's config is written by the
   normal user, so any program running as the user could make a root
   process serve or overwrite files. That is a privilege-escalation hole.

Picked: 1. Smallest amount of privileged surface, nothing running as root,
and the helper is small enough to review line by line.

## Design

### The pieces

- **Caddy listens on two private Unix sockets** inside Paddock's folder
  (`run/http.sock` and `run/https.sock`, owner-only), not on any network
  port. A scratch test on the owner's Mac confirmed Caddy 2.11.9 serves
  HTTP and HTTPS this way, including wildcard hosts, with no network
  listeners at all.
- **`paddock-ports`, the helper.** A tiny program whose whole job is: take
  the already-open listening ports it is given, and for each connection,
  copy bytes to and from the matching Unix socket (port 80 → `http.sock`,
  port 443 → `https.sock`). It reads no config files and takes its two
  socket paths as fixed arguments. If Paddock's web server is not running
  it closes the connection.
- **A system service entry** (`/Library/LaunchDaemons/app.paddock.ports.plist`,
  owned by root) that tells launchd to open `127.0.0.1` and `::1` on 80 and
  443 and run the helper as the owner's user when a connection arrives.
- The helper binary is copied to
  `/Library/PrivilegedHelperTools/app.paddock.ports` and owned by root, so
  no normal-user program can replace what launchd runs.

### Why this is safe

- The helper runs as the normal user. Even a bug in it gains nothing the
  user's own programs do not already have.
- It can only be started by launchd with those four loopback ports. It does
  not listen on the network.
- It forwards to Unix sockets that only the owner's user can open, so no
  other local program can stand in for Paddock's web server (which would be
  possible if it forwarded to a high network port).
- The install script checks the helper's checksum after copying it, and
  refuses to install if anything is already listening on 80 or 443.

### One code path

In tests and development homes there is no launchd entry. Instead Paddock's
own daemon starts the same `paddock-ports` helper as a child, telling it to
open two free high ports itself. Caddy is configured identically in both
cases. So the integration tests exercise the real helper and the real Caddy
setup; only "who opened the ports" differs.

### Install, start, stop, uninstall

- **Install (first `start`, one password prompt):** the existing privileged
  script gains three steps — copy the helper, write the system service
  entry, register it. It still also writes the `.test` DNS setting. If
  ports 80 or 443 are in use, nothing is installed, no password is asked,
  and Paddock says who holds them (unchanged rule).
- **Detecting a busy port** now uses a connection attempt, since a normal
  user cannot test-bind low ports.
- **Stop:** stops Paddock's own daemon. The ports stay reserved for
  Paddock; a browser gets "connection closed" until Paddock starts again.
  This matches the owner's "only one service on those ports".
- **Uninstall (one password prompt):** the script unregisters and removes
  the service entry and the helper, then restores the DNS setting. After
  it, ports 80 and 443 are free again.
- **App updates:** the helper is deliberately tiny and stable so that
  updates almost never need to replace it. If its checksum ever differs
  from the bundled one, Paddock asks for the password once to update it.

### What changes in the existing code

- Caddy config: listen on the two Unix sockets instead of loopback ports.
  Redirects to HTTPS keep using the public port (443, or the test port).
- Engine: starts the helper as a child only in development homes.
- Port check: connection-based; "not permitted" state from the fix wave
  goes away once this lands.
- Resolver install script and uninstall script: the added steps above.
- Status gains whether the port helper is installed.
- Bundle: `paddock-ports` ships in the app.

### Testing

- Unit tests for the script text (as today, never run for real).
- Integration tests: helper + Caddy on high ports through the Unix sockets
  (HTTP, HTTPS, redirect, large response, many parallel connections, web
  server down → connection closed, helper survives a Caddy restart).
- The real launchd behaviour (ports 80/443, running as the user) can only
  be proven on the real system, in the owner switch-over checklist. If it
  fails there, the fallback is approach 3.

## Left to the builder

- Whether the helper uses one thread per connection or an event loop.
- Idle behaviour (stay running, or exit after a quiet period).

## Open

- None blocking. The real-system proof happens at switch-over.
