#!/bin/bash
# Builds Paddock's own Valkey (its "Redis (Valkey)" service) for Intel Macs, using Xcode's toolchain only
# (no Homebrew, no MacPorts), and writes the archive Paddock ships into Vendor/builds/:
#   valkey-9.2.0-macos-x86_64.tar.gz
# with valkey-server and valkey-cli at the top level and the licence texts of everything compiled into
# them under share/licenses/valkey/. No prebuilt Valkey or Redis for Intel Macs exists anywhere, so Paddock
# compiles it; the recipe in Resources/services-catalog.json names it as paddock-builds://<archive>.
#
# Usage: Scripts/build-valkey.sh [--force] [9.2.0]   build the pinned release (the version, if given, must
#                                                    be the pinned one)
#        Scripts/build-valkey.sh --fetch-only        set up the build folder, download and verify the
#                                                    pinned source, then stop
#        Scripts/build-valkey.sh --check FILE...     run the post-build checks on files
#
# An existing archive is never replaced unless --force is given; that is checked before anything is
# downloaded. A clean run takes a few minutes.
#
# Everything is built under /private/tmp/paddock-valkey-build-<uid> (override with
# PADDOCK_VALKEY_BUILD_DIR), a neutral path, so no user name ends up in the binaries. As for
# Scripts/build-php.sh, the folder must be an absolute path outside your home folder and /Users/, a real
# directory (not a symlink) owned by you and writable by no one else, created by this script (it writes a
# .paddock-valkey-build sentinel in it, with mode 700); any other folder is refused. Delete it to start
# from scratch.
#
# What is pinned, by SHA-256, verified on every run before anything extracted from it is used:
#   - the source: Valkey 9.2.0, https://github.com/valkey-io/valkey/archive/refs/tags/9.2.0.tar.gz
#     (the checksum the Valkey project publishes for it in github.com/valkey-io/valkey-hashes).
# Xcode's clang, make and the macOS SDK are whatever the Mac has. Built with BUILD_TLS=no MALLOC=libc
# BUILD_ZSTD=no USE_SYSTEMD=no (macOS's malloc; no OpenSSL, no jemalloc), with the dependencies Valkey
# vendors in deps/ compiled in statically (libvalkey, linenoise, Lua 5.1 with its cjson, cmsgpack, bit and
# struct libraries, lz4, hdr_histogram, fpconv, fast_float); MACOSX_DEPLOYMENT_TARGET 13.0.
#
# The build identity is neutral: Valkey's release header would record `uname -n` (this Mac's host name)
# as its build id; SOURCE_DATE_EPOCH (the release date) replaces it, and git is never consulted.
# Every binary is checked before the archive is written: x86_64, linking only /usr/lib/ and /System/ with
# no rpath, and no file containing this Mac's user name, host names (hostname -s, LocalHostName,
# ComputerName) or a /Users/ path.
#
# Afterwards: put the archive's checksum into Scripts/versions.lock (valkey) and its checksum and size into
# Resources/services-catalog.json (the redis recipe), then run Scripts/fetch-vendor.sh.
#
# Valkey is BSD-3-Clause; the archive carries its licence and those of every vendored dependency compiled
# in, and this pinned release built by this script is its corresponding source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${PADDOCK_VALKEY_BUILD_DIR:-/private/tmp/paddock-valkey-build-$(id -u)}"
OUT="$ROOT/Vendor/builds"
BUILD_USER="$(id -un)"

VALKEY_VER=9.2.0
VALKEY_URL="https://github.com/valkey-io/valkey/archive/refs/tags/$VALKEY_VER.tar.gz"
VALKEY_SHA=a02cb44db1269b699629e419d4949e6e51e984b1f0e9a984e8ee1e1b3b7cc36f
# 2026-11-18 00:00 UTC, the release date: the build id Valkey records instead of this Mac's host name.
RELEASE_EPOCH=1794960000
MINIMUM_MACOS=13.0

fail() { echo "build-valkey.sh: $*" >&2; exit 1; }
[ "${#BUILD_USER}" -ge 3 ] || fail "user name '$BUILD_USER' is shorter than 3 characters; the privacy check cannot work."
say() { echo "==> $*"; }
usage() { sed -n '9,14p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }

ARCHIVE="valkey-$VALKEY_VER-macos-x86_64.tar.gz"

# require_private_dir DIR: as in build-php.sh. DIR must be an absolute path outside the home folder and
# /Users/. When missing it is created (mode 700) with a sentinel file; an existing directory must carry
# that sentinel (so the script never deletes things inside a folder it did not create), be a real
# directory (not a symlink), owned by this user and writable by no one else.
SENTINEL=.paddock-valkey-build
require_private_dir() {
  local d="$1" mode parent resolved home
  case "$d" in /*) ;; *) fail "PADDOCK_VALKEY_BUILD_DIR must be an absolute path (got: $d)." ;; esac
  case "$d" in */|*/.|*/..|*/./*|*/../*) fail "use a plain path for the build folder (got: $d)." ;; esac
  parent="$(dirname "$d")"
  [ -d "$parent" ] || fail "$parent does not exist."
  resolved="$(cd "$parent" && pwd -P)/$(basename "$d")" || fail "cannot resolve $d"
  home="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
  for p in "$d" "$resolved"; do
    case "$p" in
      "$HOME"|"$HOME"/*|"$home"|"$home"/*|/Users/*)
        fail "$d is inside a home folder; pick a build folder outside it (the default is /private/tmp/paddock-valkey-build-<uid>)." ;;
    esac
  done
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then
    mkdir -m 700 "$d" || fail "cannot create $d"
    : > "$d/$SENTINEL"
  fi
  [ ! -L "$d" ] || fail "$d is a symlink; refusing to build there."
  [ -d "$d" ] || fail "$d is not a directory."
  [ "$(stat -f %u "$d")" = "$(id -u)" ] || fail "$d is not owned by you; refusing to build there."
  mode="$(stat -f %Lp "$d")"
  [ $(( 8#$mode & 8#022 )) = 0 ] || fail "$d is writable by others (mode $mode); refusing to build there."
  [ "$(cd "$d" && pwd -P)" = "$resolved" ] || fail "$d does not resolve to itself; refusing to build there."
  [ -f "$d/$SENTINEL" ] && [ ! -L "$d/$SENTINEL" ] \
    || fail "$d already exists and was not created by this script (no $SENTINEL in it); pick an empty or new path."
}

# privacy_check FILE: as in build-php.sh. Fails when FILE contains this Mac's user name, host names
# (hostname -s, LocalHostName, ComputerName) or a /Users/ path. grep reads the file itself (byte-wise) and
# counts matches; no `grep -q` in a pipeline, which under pipefail lets the writer die of SIGPIPE and turns
# a match into a pass.
privacy_check() {
  local file="$1" name patterns=(-e "/Users/") count
  for name in "$BUILD_USER" "$(hostname -s 2>/dev/null || true)" \
              "$(scutil --get LocalHostName 2>/dev/null || true)" "$(scutil --get ComputerName 2>/dev/null || true)"; do
    [ -n "$name" ] || continue
    [ "${#name}" -ge 3 ] || fail "cannot check $file for '$name': names shorter than 3 characters match too much."
    patterns+=(-e "$name")
  done
  [ -r "$file" ] || fail "cannot read $file"
  count="$(LC_ALL=C grep -a -c -iF "${patterns[@]}" -- "$file" || true)"
  [ -n "$count" ] || fail "grep failed on $file"
  [ "$count" = 0 ] || fail "$file contains the build machine's user name, host name or a /Users/ path:"$'\n'"$(LC_ALL=C grep -a -o -iF "${patterns[@]}" -- "$file" | sort -u | head -n 5 || true)"
}

# link_check FILE: a Mach-O must be x86_64, link only /usr/lib/ and /System/, and have no rpath. The otool
# output is captured first, then read; no pipeline decides the result.
link_check() {
  local file="$1" out line rpaths
  out="$(file -b "$file")" || fail "file failed on $file"
  case "$out" in *Mach-O*) ;; *) return 0 ;; esac
  case "$out" in *x86_64*) ;; *) fail "$file is not x86_64 ($out)" ;; esac
  case "$out" in *universal*|*arm64*) fail "$file is not x86_64 only ($out)" ;; esac
  out="$(otool -L "$file")" || fail "otool -L failed on $file"
  [ "${out%%$'\n'*}" = "$file:" ] || fail "unexpected otool -L output for $file"
  out="$(tail -n +2 <<< "$out")" || fail "could not read the otool -L output for $file"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      /usr/lib/*|/System/*) ;;
      *) fail "$file links ${line%% (*}, which is not /usr/lib/ or /System/" ;;
    esac
  done <<< "$out"
  out="$(otool -l "$file")" || fail "otool -l failed on $file"
  rpaths="$(awk '/cmd LC_RPATH/ { getline; getline; print $2 }' <<< "$out")"
  [ -z "$rpaths" ] || fail "$file has rpaths '${rpaths//$'\n'/ }'; none is allowed"
}

check_files() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ ! -L "$f" ] || fail "$f is not a regular file"
    privacy_check "$f"
    link_check "$f"
  done
}

# minimum_macos FILE: the minos of a Mach-O's LC_BUILD_VERSION.
minimum_macos() {
  local out minos
  out="$(otool -l "$1")" || fail "otool -l failed on $1"
  minos="$(awk '/cmd LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }' <<< "$out")"
  [ -n "$minos" ] || fail "$1 has no LC_BUILD_VERSION"
  echo "$minos"
}

if [ "${1:-}" = --check ]; then
  shift
  [ "$#" -gt 0 ] || usage
  check_files "$@"
  echo "build-valkey.sh: $# file(s) passed the checks."
  exit 0
fi

FETCH_ONLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --fetch-only) FETCH_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    "$VALKEY_VER") ;;
    *) fail "this script builds the pinned Valkey $VALKEY_VER only (got: $arg); change the pin to build another." ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail "builds for macOS only."
[ "$(uname -m)" = x86_64 ] || fail "run this on an Intel Mac: Paddock's builds are x86_64."

# Refuse to replace an existing archive before anything is downloaded.
if [ "$FETCH_ONLY" = 0 ] && [ -f "$OUT/$ARCHIVE" ]; then
  echo "  existing $(shasum -a 256 -- "$OUT/$ARCHIVE")"
  [ "$FORCE" = 1 ] || fail "Vendor/builds already holds $ARCHIVE (above); installed copies, Scripts/versions.lock" \
    "and the catalog refer to it. Pass --force to replace it."
fi

require_private_dir "$W"
mkdir -p "$W"/{downloads,build,stage,logs,tools} "$OUT"

# Only Xcode's tools: never Homebrew (/usr/local, /opt/homebrew) or MacPorts (/opt/local).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH LIBS CFLAGS LDFLAGS \
  CPPFLAGS CC OPTIMIZATION OPENSSL_PREFIX MAKEFLAGS || true
for tool in clang make curl shasum tar otool codesign xcrun file awk sed; do
  command -v "$tool" >/dev/null || fail "$tool is missing; install the Xcode command line tools (xcode-select --install)."
done
xcrun --find clang >/dev/null || fail "Xcode's clang is missing; install the Xcode command line tools (xcode-select --install)."
# No AppleDouble ._ files in archives.
export COPYFILE_DISABLE=1
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS"
# Valkey's build id: the release date rather than `uname -n` and the time of the build.
export SOURCE_DATE_EPOCH="$RELEASE_EPOCH"
# Valkey's release header asks git for a commit and for local changes: a git that always fails stands in
# for the real one (outside a repository, `git diff` would compare src/ with deps/ and call the tree dirty),
# so it records commit 00000000, clean.
mkdir -p "$W/tools/bin"
printf '#!/bin/sh\nexit 1\n' > "$W/tools/bin/git"
chmod 755 "$W/tools/bin/git"
export PATH="$W/tools/bin:$PATH"
# Xcode's clang (/usr/bin/clang) with this Mac's macOS SDK.
SDKROOT="$(xcrun --show-sdk-path)" || fail "xcrun cannot find the macOS SDK"
export SDKROOT

# fetch URL SHA256 FILE: download into $W/downloads (once) and verify it, on every run.
fetch() {
  local url="$1" sha="$2" file="$W/downloads/$3" actual
  if [ ! -f "$file" ]; then
    curl -fL --retry 3 -sS -o "$file.part" "$url" || fail "could not download $url"
    mv "$file.part" "$file"
  fi
  actual="$(shasum -a 256 -- "$file" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    rm -f "$file"
    fail "checksum mismatch for $url: expected $sha, got $actual"
  fi
}

say "downloading and verifying Valkey $VALKEY_VER in $W/downloads"
fetch "$VALKEY_URL" "$VALKEY_SHA" "valkey-$VALKEY_VER.tar.gz"
[ "$FETCH_ONLY" = 0 ] || { say "the pinned source is downloaded and verified"; exit 0; }

# A fresh tree on every run: Valkey's Makefile keeps settings between builds.
SRC="$W/build/valkey-$VALKEY_VER"
rm -rf "$W/build" "$W/stage"
mkdir -p "$W/build" "$W/stage"
tar -xzf "$W/downloads/valkey-$VALKEY_VER.tar.gz" -C "$W/build" || fail "could not unpack valkey-$VALKEY_VER.tar.gz"
[ -d "$SRC/src" ] || fail "valkey-$VALKEY_VER.tar.gz did not unpack into valkey-$VALKEY_VER"

JOBS="$(sysctl -n hw.ncpu)"
LOG="$W/logs/valkey-$VALKEY_VER-build.log"
say "building valkey-server and valkey-cli (log: $LOG)"
make -C "$SRC/src" -j "$JOBS" valkey-server valkey-cli \
  CC=/usr/bin/clang BUILD_TLS=no MALLOC=libc BUILD_ZSTD=no BUILD_RDMA=no USE_SYSTEMD=no \
  USE_LIBBACKTRACE=no DEBUG="" V=1 > "$LOG" 2>&1 || fail "building Valkey failed; see $LOG"

STAGE="$W/stage"
LIC="$STAGE/share/licenses/valkey"
mkdir -p "$LIC"
install -m 755 "$SRC/src/valkey-server" "$STAGE/valkey-server"
install -m 755 "$SRC/src/valkey-cli" "$STAGE/valkey-cli"
for f in "$STAGE/valkey-server" "$STAGE/valkey-cli"; do
  codesign --force -s - "$f" 2>/dev/null || fail "could not sign $f"
  minos="$(minimum_macos "$f")"
  [ "$minos" = "$MINIMUM_MACOS" ] || fail "$f needs macOS $minos, not $MINIMUM_MACOS"
done

# The licence texts of everything compiled in, from the verified source (its REUSE.toml maps each file
# to its licence; LICENSES/ holds the texts).
while read -r out src; do
  [ -f "$SRC/$src" ] || fail "licence file $src is missing"
  cp "$SRC/$src" "$LIC/$out"
done <<EOF
COPYING COPYING
REUSE.toml REUSE.toml
LICENSES-Apache-2.0.txt LICENSES/Apache-2.0.txt
LICENSES-BSD-2-Clause.txt LICENSES/BSD-2-Clause.txt
LICENSES-BSD-3-Clause.txt LICENSES/BSD-3-Clause.txt
LICENSES-BSL-1.0.txt LICENSES/BSL-1.0.txt
LICENSES-CC0-1.0.txt LICENSES/CC0-1.0.txt
LICENSES-ISC.txt LICENSES/ISC.txt
LICENSES-MIT.txt LICENSES/MIT.txt
LICENSES-Zlib.txt LICENSES/Zlib.txt
deps-libvalkey-COPYING.txt deps/libvalkey/COPYING
deps-lua-COPYRIGHT.txt deps/lua/COPYRIGHT
deps-lz4-LICENSE.txt deps/lz4/LICENSE
deps-hdr_histogram-LICENSE.txt deps/hdr_histogram/LICENSE.txt
deps-hdr_histogram-COPYING.txt deps/hdr_histogram/COPYING.txt
deps-fpconv-LICENSE.txt deps/fpconv/LICENSE.txt
EOF
# linenoise and fast_float carry their licences in their source headers.
sed -n '/^ \* Copyright (c) 2010-2016, Redis Ltd\./,/EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE\./p' \
  "$SRC/deps/linenoise/linenoise.c" > "$LIC/deps-linenoise-LICENSE.txt"
[ -s "$LIC/deps-linenoise-LICENSE.txt" ] || fail "could not find linenoise's licence in linenoise.c"
sed -n '/^\/\/ MIT License Notice/,/DEALINGS IN THE SOFTWARE\./p' "$SRC/deps/fast_float/ffc.h" \
  > "$LIC/deps-fast_float-LICENSE-MIT.txt"
[ -s "$LIC/deps-fast_float-LICENSE-MIT.txt" ] || fail "could not find fast_float's licence in ffc.h"
cat > "$LIC/BUILDINFO.txt" <<EOF
Valkey $VALKEY_VER (BSD-3-Clause), built by Paddock's Scripts/build-valkey.sh from
$VALKEY_URL
(SHA-256 $VALKEY_SHA).
make valkey-server valkey-cli BUILD_TLS=no MALLOC=libc BUILD_ZSTD=no BUILD_RDMA=no USE_SYSTEMD=no
MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET SDK=$(xcrun --show-sdk-version) SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
Compiled in from deps/: libvalkey (BSD-3-Clause), linenoise (BSD-2-Clause), Lua 5.1 with lua_cjson,
lua_cmsgpack, lua_bit, lua_struct, strbuf and fpconv (MIT), lz4 (BSD-2-Clause), hdr_histogram
(CC0-1.0 AND BSD-2-Clause), fpconv (BSL-1.0), fast_float (MIT, also Apache-2.0 or BSL-1.0).
Valkey's own sources include files under MIT, BSD-2-Clause, CC0-1.0, Zlib and ISC: see REUSE.toml.
Linked from macOS (not shipped): libSystem.
EOF

# The checks every file passes before the archive is written.
LIST="$W/stage-files"
FILES=()
find "$STAGE" -type f -print0 > "$LIST" || fail "could not list the staged files"
while IFS= read -r -d '' f; do FILES+=("$f"); done < "$LIST"
[ "${#FILES[@]}" -gt 2 ] || fail "the staged archive is incomplete"
check_files "${FILES[@]}"
find "$STAGE" ! -type f ! -type d -print0 > "$LIST" || fail "could not list the staged files"
[ ! -s "$LIST" ] || fail "unexpected symlink or special file in the archive: $(tr '\0' ' ' < "$LIST")"

# Both programs run.
"$STAGE/valkey-server" --version > "$W/logs/version.txt" || fail "valkey-server --version failed"
"$STAGE/valkey-cli" --version >> "$W/logs/version.txt" || fail "valkey-cli --version failed"
cat "$W/logs/version.txt"

tar -C "$STAGE" --uid 0 --gid 0 --uname root --gname wheel -czf "$OUT/$ARCHIVE.part" valkey-server valkey-cli share \
  || fail "could not write $ARCHIVE"
mv "$OUT/$ARCHIVE.part" "$OUT/$ARCHIVE"
say "wrote Vendor/builds/$ARCHIVE (macOS $MINIMUM_MACOS or later)"
echo "  $(shasum -a 256 -- "$OUT/$ARCHIVE" | awk '{print $1}')  $(stat -f %z "$OUT/$ARCHIVE") bytes"
say "put the checksum into Scripts/versions.lock (valkey) and the checksum and size into Resources/services-catalog.json"
