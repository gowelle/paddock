#!/bin/bash
# Builds Xdebug as a loadable extension for each of Paddock's own PHP builds (Intel Macs), using no Homebrew
# and no MacPorts, and writes the archives Paddock ships into Vendor/builds/:
#   xdebug-<version>-php<series>-macos-x86_64.tar.gz   (xdebug.so and Xdebug's LICENSE at the top level)
#
# Usage: Scripts/build-xdebug.sh [--force] [series...]   default: every PHP series in Scripts/versions.lock
#        Scripts/build-xdebug.sh --check FILE...          run the post-build checks on files
#
# An existing archive is never replaced unless --force is given; that is checked before anything is
# downloaded. A clean run takes about five minutes (m4 and autoconf once, then about a minute per series).
#
# Everything is built under /private/tmp/paddock-xdebug-build-<uid> (override with
# PADDOCK_XDEBUG_BUILD_DIR), a neutral path, so no user name ends up in the binaries. As for
# Scripts/build-php.sh, the folder must be an absolute path outside your home folder and /Users/, a real
# directory (not a symlink) owned by you and writable by no one else, created by this script (it writes a
# .paddock-xdebug-build sentinel in it, with mode 700); any other folder is refused. Delete it to start
# from scratch.
#
# How it matches Paddock's PHP. Paddock's PHP is static (Scripts/build-php.sh), so there is no installed
# phpize or header set to build against. This script takes the same php.net release the PHP build used
# (php-<patch>.tar.xz, by the checksum in Scripts/php-sources/<patch>.sha256), configures it just far
# enough to install its headers, phpize and php-config (nothing of PHP is compiled), and builds Xdebug
# against those. An extension must agree with the PHP that loads it on a handful of build settings, so
# before building, the script compares what the headers say with what the shipped binary reports
# (`php -i`, from the verified Vendor/builds/ archive): the PHP version, the extension and Zend extension
# API numbers, and thread safety, debug build and Zend signal handling. Any difference stops the build.
# After building, the shipped `php` must load the result and report Xdebug's version.
#
# What is pinned, by SHA-256, verified on every run before anything extracted or built from it is used:
#   - Xdebug's source release, below;
#   - each PHP source release (the same file and checksum as Scripts/php-sources/<patch>.sha256);
#   - each of Paddock's PHP CLI archives checked against (Scripts/versions.lock);
#   - m4 1.4.19 and autoconf 2.72, which phpize needs (the same tarballs as build-php.sh).
# Xcode's clang, make and the macOS SDK are whatever the Mac has. zlib comes from macOS (/usr/lib) and is
# not shipped. MACOSX_DEPLOYMENT_TARGET 12.0, as Paddock's PHP.
#
# Each archive is written reproducibly (Scripts/build-lib.sh, reproducible_archive): fixed times (the
# newest file time in the Xdebug source), modes, owner and order, and no gzip time.
#
# Every archive is checked before it is written: xdebug.so is x86_64 and links only /usr/lib/ and
# /System/, with no rpath; no file contains this Mac's user name, host names (hostname -s, LocalHostName,
# ComputerName) or a /Users/ path.
#
# Afterwards: put each archive's name, checksum and size into Scripts/versions.lock (xdebug-<series>) and
# Resources/php-manifest.json (the build's "xdebug"), then run Scripts/fetch-vendor.sh.
#
# Xdebug is under the Xdebug License (a BSD-style licence based on the PHP License); the archive carries
# it, and THIRD-PARTY-NOTICES reproduces it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${PADDOCK_XDEBUG_BUILD_DIR:-/private/tmp/paddock-xdebug-build-$(id -u)}"
OUT="$ROOT/Vendor/builds"
LOCK="$ROOT/Scripts/versions.lock"
PHP_SOURCES="$ROOT/Scripts/php-sources"
BUILD_USER="$(id -un)"

XDEBUG_VER=3.5.3
XDEBUG_URL="https://xdebug.org/files/xdebug-$XDEBUG_VER.tgz"
XDEBUG_SHA=f073de91bea046106abf4d6071c963ea71e58571df6ce58948ceca89d121cb2d
M4_URL=https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz
M4_SHA=63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96
AUTOCONF_URL=https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.gz
AUTOCONF_SHA=afb181a76e1ee72832f6581c0eddf8df032b83e2e0239ef79ebedc4467d92d6e

fail() { echo "build-xdebug.sh: $*" >&2; exit 1; }
[ "${#BUILD_USER}" -ge 3 ] || fail "user name '$BUILD_USER' is shorter than 3 characters; the privacy check cannot work."
say() { echo "==> $*"; }
# shellcheck source=build-lib.sh
source "$ROOT/Scripts/build-lib.sh"
usage() { sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }

archive_name() { echo "xdebug-$XDEBUG_VER-php$1-macos-x86_64.tar.gz"; }

# require_private_dir DIR: as in build-php.sh. DIR must be an absolute path outside the home folder and
# /Users/. When missing it is created (mode 700) with a sentinel file; an existing directory must carry
# that sentinel (so the script never deletes things inside a folder it did not create), be a real
# directory (not a symlink), owned by this user and writable by no one else.
SENTINEL=.paddock-xdebug-build
require_private_dir() {
  local d="$1" mode parent resolved home p
  case "$d" in /*) ;; *) fail "PADDOCK_XDEBUG_BUILD_DIR must be an absolute path (got: $d)." ;; esac
  case "$d" in */|*/.|*/..|*/./*|*/../*) fail "use a plain path for the build folder (got: $d)." ;; esac
  parent="$(dirname "$d")"
  [ -d "$parent" ] || fail "$parent does not exist."
  resolved="$(cd "$parent" && pwd -P)" || fail "cannot resolve $d"
  resolved="$resolved/$(basename "$d")"
  home="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
  for p in "$d" "$resolved"; do
    case "$p" in
      "$HOME"|"$HOME"/*|"$home"|"$home"/*|/Users/*)
        fail "$d is inside a home folder; pick a build folder outside it (the default is /private/tmp/paddock-xdebug-build-<uid>)." ;;
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

# This Mac's host names (build_host_names fails the build when one can't be read).
HOST_NAMES=()
HOST_LIST="$(build_host_names)" || fail "could not read this Mac's host names"
while IFS= read -r line; do HOST_NAMES+=("$line"); done <<< "$HOST_LIST"

# privacy_check FILE: as in build-php.sh. Fails when FILE contains this Mac's user name, host names or a
# /Users/ path. grep reads the file itself (byte-wise) and counts matches; no `grep -q` in a pipeline.
privacy_check() {
  local file="$1" name patterns=(-e "/Users/") count
  for name in "$BUILD_USER" "${HOST_NAMES[@]}"; do
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

if [ "${1:-}" = --check ]; then
  shift
  [ "$#" -gt 0 ] || usage
  check_files "$@"
  echo "build-xdebug.sh: $# file(s) passed the checks."
  exit 0
fi

# lock_field NAME FIELD: a tab-separated field of NAME's line in Scripts/versions.lock (2: URL, 3: SHA-256).
lock_field() {
  awk -F'\t' -v name="$1" -v field="$2" '$1 == name { print $field; exit }' "$LOCK"
}

# The PHP series Paddock ships: php-<series>-cli in the lock.
ALL_SERIES="$(awk -F'\t' '$1 ~ /^php-[0-9]+\.[0-9]+-cli$/ { sub(/^php-/, "", $1); sub(/-cli$/, "", $1); print $1 }' "$LOCK")"
[ -n "$ALL_SERIES" ] || fail "Scripts/versions.lock names no PHP build."

FORCE=0
SERIES=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    [0-9]*.[0-9]*)
      grep -qxF "$arg" <<< "$ALL_SERIES" || fail "not a PHP series Paddock ships ($(tr '\n' ' ' <<< "$ALL_SERIES")): $arg"
      SERIES+=("$arg") ;;
    *) usage ;;
  esac
done
if [ "${#SERIES[@]}" = 0 ]; then
  while IFS= read -r line; do SERIES+=("$line"); done <<< "$ALL_SERIES"
fi

[ "$(uname -s)" = Darwin ] || fail "builds for macOS only."
[ "$(uname -m)" = x86_64 ] || fail "run this on an Intel Mac: Paddock's builds are x86_64."
for tool in clang make curl shasum tar otool file awk sed strip; do
  command -v "$tool" >/dev/null || fail "$tool is missing (install Xcode's command line tools)."
done

# Refuse to replace existing archives before anything is downloaded.
existing=0
for s in "${SERIES[@]}"; do
  if [ -f "$OUT/$(archive_name "$s")" ]; then
    echo "  existing $(shasum -a 256 -- "$OUT/$(archive_name "$s")")"
    existing=1
  fi
done
[ "$existing" = 0 ] || [ "$FORCE" = 1 ] || fail "Vendor/builds already holds these archives (above);" \
  "installed copies, Scripts/versions.lock and the PHP manifest refer to them. Pass --force to replace them."

require_private_dir "$W"
mkdir -p "$W"/{downloads,tools/bin,logs} "$OUT"

# Only the build tools made here and the system's: never Homebrew's or MacPorts'.
export PATH="$W/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET=12.0
unset CFLAGS CPPFLAGS LDFLAGS LIBS PHP_AUTOCONF PHP_AUTOHEADER
JOBS="$(sysctl -n hw.ncpu)"

# fetch URL SHA256 FILE: FILE in $W/downloads, downloaded when missing, verified on every run.
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

# autotool NAME VERSION URL SHA256: built from its verified tarball into $W/tools, once per tarball.
autotool() {
  local name="$1" version="$2" url="$3" sha="$4" file="${3##*/}"
  fetch "$url" "$sha" "$file"
  [ ! -f "$W/tools/.built-$name-$version-$sha" ] || return 0
  say "building $name $version"
  rm -rf "$W/tools-src/$name-$version"
  mkdir -p "$W/tools-src"
  tar -xf "$W/downloads/$file" -C "$W/tools-src"
  (cd "$W/tools-src/$name-$version" && ./configure --prefix="$W/tools" --disable-nls && make -j"$JOBS" && make install) \
    > "$W/logs/tool-$name.log" 2>&1 || fail "building $name failed; see $W/logs/tool-$name.log"
  touch "$W/tools/.built-$name-$version-$sha"
}

say "downloading and verifying the pinned files in $W/downloads"
fetch "$XDEBUG_URL" "$XDEBUG_SHA" "xdebug-$XDEBUG_VER.tgz"
# Xcode's m4 is too old for autoconf.
autotool m4 1.4.19 "$M4_URL" "$M4_SHA"
autotool autoconf 2.72 "$AUTOCONF_URL" "$AUTOCONF_SHA"

# reported BINARY NAME: the value `php -i` gives for NAME ("Thread Safety" -> "disabled").
reported() {
  local out
  out="$("$1" -n -i)" || fail "$1 -n -i failed"
  awk -F' => ' -v name="$2" '$1 == name { print $2; exit }' <<< "$out"
}

# header_define FILE NAME: the value NAME is defined to in FILE; empty when it is not defined.
header_define() {
  awk -v name="$2" '$1 == "#define" && $2 == name { print ($3 == "" ? "1" : $3); exit }' "$1"
}

# expect WHAT HEADERS BINARY: the two must agree.
expect() {
  [ "$2" = "$3" ] || fail "the PHP headers and Paddock's PHP disagree on $1: headers say '$2', the binary says '$3'." \
    "An extension built this way could crash PHP; nothing was built."
}

built=()
for series in "${SERIES[@]}"; do
  cli_url="$(lock_field "php-$series-cli" 2)"
  cli_sha="$(lock_field "php-$series-cli" 3)"
  cli_file="${cli_url#paddock-builds://}"
  [ -n "$cli_sha" ] && [ "$cli_file" != "$cli_url" ] || fail "Scripts/versions.lock has no paddock-builds:// php-$series-cli."
  patch="${cli_file#php-}"; patch="${patch%%-cli-*}"
  [[ "$patch" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot read the PHP patch version from $cli_file"
  [ -f "$OUT/$cli_file" ] || fail "Vendor/builds/$cli_file is missing. Build it with: Scripts/build-php.sh $series"
  actual="$(shasum -a 256 -- "$OUT/$cli_file" | awk '{print $1}')"
  [ "$actual" = "$cli_sha" ] || fail "Vendor/builds/$cli_file has checksum $actual; Scripts/versions.lock expects $cli_sha."
  src_sha="$(awk -v f="php-$patch.tar.xz" '$2 == f { print $1; exit }' "$PHP_SOURCES/$patch.sha256" 2>/dev/null || true)"
  [[ "$src_sha" =~ ^[0-9a-f]{64}$ ]] || fail "Scripts/php-sources/$patch.sha256 does not list php-$patch.tar.xz."

  say "PHP $patch: headers from the pinned php.net release"
  fetch "https://www.php.net/distributions/php-$patch.tar.xz" "$src_sha" "php-$patch.tar.xz"
  B="$W/php-$series"
  rm -rf "$B"
  mkdir -p "$B/bin" "$B/stage"
  tar -xzf "$OUT/$cli_file" -C "$B/bin" php
  PHP="$B/bin/php"
  tar -xf "$W/downloads/php-$patch.tar.xz" -C "$B"
  # The settings an extension must share with its PHP are the defaults here, as in Paddock's build
  # (its configure line is in `php -i`): no thread safety, no debug build, Zend signal handling on.
  (cd "$B/php-$patch" && ./configure --prefix="$B/prefix" --disable-all --disable-cgi --disable-phpdbg \
      --with-valgrind=no && make install-headers install-build install-programs) \
    > "$W/logs/php-$series-headers.log" 2>&1 || fail "preparing the PHP $patch headers failed; see $W/logs/php-$series-headers.log"
  INC="$B/prefix/include/php"
  [ -x "$B/prefix/bin/phpize" ] && [ -x "$B/prefix/bin/php-config" ] || fail "phpize or php-config was not installed for PHP $patch"

  say "PHP $patch: comparing the headers with Paddock's PHP"
  expect "the PHP version" "$("$B/prefix/bin/php-config" --version)" "$("$PHP" -n -r 'echo PHP_VERSION;')"
  expect "the PHP version" "$patch" "$(reported "$PHP" "PHP Version")"
  api="$(header_define "$INC/main/php.h" PHP_API_VERSION)"
  module_api="$(header_define "$INC/Zend/zend_modules.h" ZEND_MODULE_API_NO)"
  extension_api="$(header_define "$INC/Zend/zend_extensions.h" ZEND_EXTENSION_API_NO)"
  expect "the PHP API number" "$api" "$(reported "$PHP" "PHP API")"
  expect "the extension API number" "$module_api" "$(reported "$PHP" "PHP Extension")"
  expect "the Zend extension API number" "$extension_api" "$(reported "$PHP" "Zend Extension")"
  expect "the extension build" "API$module_api,NTS" "$(reported "$PHP" "PHP Extension Build")"
  expect "the Zend extension build" "API$extension_api,NTS" "$(reported "$PHP" "Zend Extension Build")"
  [ -z "$(header_define "$INC/main/php_config.h" ZTS)" ] && thread_safety=disabled || thread_safety=enabled
  expect "thread safety" "$thread_safety" "$(reported "$PHP" "Thread Safety")"
  [ "$(header_define "$INC/main/php_config.h" ZEND_DEBUG)" = 1 ] && debug=yes || debug=no
  expect "a debug build" "$debug" "$(reported "$PHP" "Debug Build")"
  [ -n "$(header_define "$INC/main/php_config.h" ZEND_SIGNALS)" ] && signals=enabled || signals=disabled
  expect "Zend signal handling" "$signals" "$(reported "$PHP" "Zend Signal Handling")"
  [ -n "$(header_define "$INC/main/php_config.h" HAVE_DTRACE)" ] && dtrace=enabled || dtrace=disabled
  expect "DTrace support" "$dtrace" "$(reported "$PHP" "DTrace Support")"

  say "PHP $patch: building Xdebug $XDEBUG_VER"
  tar -xzf "$W/downloads/xdebug-$XDEBUG_VER.tgz" -C "$B"
  X="$B/xdebug-$XDEBUG_VER"
  [ -f "$X/config.m4" ] && [ -f "$X/LICENSE" ] || fail "the Xdebug archive is not laid out as expected"
  EPOCH="$(newest_mtime "$X")"
  # No debug information and no build paths in the result.
  (cd "$X" && "$B/prefix/bin/phpize" \
    && ./configure --enable-xdebug --with-php-config="$B/prefix/bin/php-config" \
         CFLAGS="-O2 -g0 -ffile-prefix-map=$B=." \
    && make -j"$JOBS") > "$W/logs/xdebug-$series.log" 2>&1 || fail "building Xdebug for PHP $series failed; see $W/logs/xdebug-$series.log"
  SO="$X/modules/xdebug.so"
  [ -f "$SO" ] || fail "the build made no xdebug.so; see $W/logs/xdebug-$series.log"
  cp "$SO" "$B/stage/xdebug.so"
  strip -x "$B/stage/xdebug.so" || fail "could not strip xdebug.so"
  cp "$X/LICENSE" "$B/stage/LICENSE"

  say "PHP $patch: checking the result"
  check_files "$B/stage/xdebug.so" "$B/stage/LICENSE"
  loaded="$("$PHP" -n -d "zend_extension=$B/stage/xdebug.so" -r 'echo phpversion("xdebug"), " ", (int) extension_loaded("xdebug");' 2>&1)" \
    || fail "Paddock's PHP $patch could not run with the new xdebug.so: $loaded"
  [ "$loaded" = "$XDEBUG_VER 1" ] || fail "Paddock's PHP $patch did not load the new xdebug.so (it said: $loaded)"
  banner="$("$PHP" -n -d "zend_extension=$B/stage/xdebug.so" -v 2>&1)" || fail "php -v failed with the new xdebug.so: $banner"
  case "$banner" in *"with Xdebug v$XDEBUG_VER"*) ;; *) fail "php -v does not name Xdebug $XDEBUG_VER: $banner" ;; esac

  archive="$OUT/$(archive_name "$series")"
  reproducible_archive "$B/stage" "$EPOCH" "$archive" LICENSE xdebug.so
  built+=("$series")
done

say "done"
for series in "${built[@]}"; do
  archive="$OUT/$(archive_name "$series")"
  printf 'xdebug-%s\tpaddock-builds://%s\t%s\t(%s bytes)\n' "$series" "$(archive_name "$series")" \
    "$(shasum -a 256 -- "$archive" | awk '{print $1}')" "$(stat -f %z "$archive")"
done
echo "Put these into Scripts/versions.lock and Resources/php-manifest.json, then run Scripts/fetch-vendor.sh."
