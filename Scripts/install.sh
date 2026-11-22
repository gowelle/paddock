#!/bin/bash
# Installs Paddock on an Intel Mac, from its latest release:
#
#   curl -fsSL https://raw.githubusercontent.com/gowelle/paddock/main/Scripts/install.sh | bash
#
# It downloads the release's zip, checks it against the release's SHA-256, unpacks Paddock.app into
# /Applications and opens it. It asks for no password and runs nothing as root (Paddock itself asks for your
# password once, on first launch, and says why).
#
# Why a script: Paddock is not signed with an Apple Developer ID, so macOS questions a copy downloaded in a
# browser. A copy fetched this way is not marked as downloaded, and opens like any other app.
#
# PADDOCK_VERSION=1.2.3 installs that version instead of the latest.
set -euo pipefail

main() {
  local repo="gowelle/paddock"
  local base="${PADDOCK_INSTALL_BASE:-}"            # another address, to try the script against a local server
  local applications="${PADDOCK_INSTALL_DIR:-/Applications}"
  local app="$applications/Paddock.app"

  fail() { echo "Paddock was not installed: $*" >&2; exit 1; }

  [ "$(uname -s)" = "Darwin" ] || fail "Paddock is a Mac app."
  # An Apple Silicon Mac says x86_64 too when the shell runs under Rosetta; sysctl says what the Mac is.
  if [ "$(uname -m)" != "x86_64" ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
    fail "Paddock is for Intel Macs; this Mac has Apple Silicon."
  fi
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 13 ] || fail "Paddock needs macOS 13 or later; this is $(sw_vers -productVersion)."
  [ -e "$app" ] && fail "$app is already there. To update it, choose Check for Updates… in Paddock's menu; to install afresh, move it to the Trash first."
  [ -d "$applications" ] && [ -w "$applications" ] || fail "you can't write to $applications."

  if [ -z "$base" ]; then
    if [ -n "${PADDOCK_VERSION:-}" ]; then
      base="https://github.com/$repo/releases/download/v$PADDOCK_VERSION"
    else
      base="https://github.com/$repo/releases/latest/download"
    fi
  fi

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/paddock-install.XXXXXX")"
  # The folder's name is written into the trap now: `work` is gone by the time the script exits.
  trap "rm -rf '$work'" EXIT

  echo "Finding the release…"
  curl -fsSL --proto '=https,http' -o "$work/SHA256SUMS" "$base/SHA256SUMS" \
    || fail "the release's checksum file could not be downloaded from $base."
  # One line: <64 hex digits>  Paddock-<version>.zip
  local line sum zip
  line="$(grep -E '^[0-9a-f]{64}  Paddock-[0-9]+\.[0-9]+\.[0-9]+\.zip$' "$work/SHA256SUMS" | head -n 1 || true)"
  [ -n "$line" ] || fail "the release's checksum file names no Paddock zip."
  sum="${line%% *}"
  zip="${line##* }"

  echo "Downloading ${zip}…"
  curl -fL --proto '=https,http' --progress-bar -o "$work/$zip" "$base/$zip" || fail "$zip could not be downloaded."
  [ "$(shasum -a 256 "$work/$zip" | awk '{print $1}')" = "$sum" ] \
    || fail "$zip does not match the release's checksum. Nothing was installed; try again."

  echo "Unpacking…"
  ditto -x -k "$work/$zip" "$work/unpacked" || fail "$zip could not be unpacked."
  local unpacked="$work/unpacked/Paddock.app"
  [ -d "$unpacked" ] || fail "$zip holds no Paddock.app."
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$unpacked/Contents/Info.plist" 2>/dev/null)" = "app.paddock" ] \
    || fail "what $zip holds is not Paddock."
  codesign --verify --deep --strict "$unpacked" 2>/dev/null || fail "the app in $zip is damaged (its seal does not verify)."

  ditto "$unpacked" "$app" || { rm -rf "$app"; fail "the app could not be copied to $applications."; }
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  echo "Paddock $version is in $applications."
  if [ "$applications" = "/Applications" ]; then
    open "$app"
    echo "It is opening now: look for the gate in the menu bar. It asks for your password once, to set up .test addresses."
  fi
}

# Nothing runs until the whole script has arrived.
main "$@"
