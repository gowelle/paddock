#!/bin/bash
# Builds Paddock's own static PHP for Intel Macs (php and php-fpm, without Swoole) with static-php-cli,
# using no Homebrew and no MacPorts, and writes the archives Paddock ships into Vendor/builds/:
#   php-<patch>-cli-macos-x86_64.tar.gz   (one file at the top level: php)
#   php-<patch>-fpm-macos-x86_64.tar.gz   (one file at the top level: php-fpm)
#
# Usage: Scripts/build-php.sh [--force] <series|patch>...   e.g. build-php.sh 8.5 8.4, or build-php.sh 8.4.28
#        Scripts/build-php.sh --tools-only                  only set up the build tools and run `spc doctor`
#        Scripts/build-php.sh --verify-sources <patch> <dir> check an spc downloads folder against the manifest
#
# A series (8.4) builds the newest patch php.net lists for it and prints which; a patch (8.4.28) builds
# exactly that release. An existing archive for the same patch is never replaced unless --force is given;
# that is checked before anything is downloaded.
#
# A clean run takes about 15 minutes of tool setup plus about 15 minutes per series (a later series reuses
# the libraries the first one built). Everything is built under /private/tmp/paddock-php-build-<uid>
# (override with PADDOCK_PHP_BUILD_DIR), a neutral path, so no user name ends up in the binaries. The
# folder must be an absolute path outside your home folder and /Users/, a real directory (not a
# symlink) owned by you and writable by no one else, created by this script (it writes a
# .paddock-php-build sentinel in it, with mode 700); any other folder is refused. Delete it to start
# from scratch.
#
# What is pinned:
#   - The build tools (cmake, xz, m4, autoconf, automake, libtool, re2c, bison) and the static-php-cli
#     binary: by SHA-256, below. (Xcode's clang, make and the macOS SDK are whatever the Mac has.)
#   - Every source and package static-php-cli downloads (the PHP source, each library's source, its
#     prebuilt static library packages for openssl, icu, zlib, libiconv, gmp, ncurses, libsodium, libpng,
#     libwebp and bzip2, the PECL extensions, its pkg-config package; the git checkout it makes, by commit):
#     by the committed manifest Scripts/php-sources/<patch>.sha256, which lists every file in spc's
#     downloads folder, hidden ones included, except spc's own bookkeeping file .lock.json (it records
#     the order and history of downloads, so it differs between identical sets of files); a git checkout
#     is recorded by commit and must have a clean working tree. A build whose downloads differ in any
#     way (changed, missing or extra file) stops before building. Sources extracted by an earlier run are
#     reused only when a marker written after a verified build says they came from the same library set;
#     otherwise they are deleted and re-extracted from the verified downloads.
#   - The tool tarballs and the spc tarball are re-verified on every run before anything built or
#     extracted from them is used. PADDOCK_PHP_ACCEPT_NEW_SOURCES=1
#     accepts the new downloads and rewrites that manifest (review and commit it). A patch with no
#     committed manifest records one. Each build also writes Vendor/builds/sources-<patch>.sha256.
#
# Every build is checked to contain no user name, host name (hostname -s, LocalHostName, ComputerName)
# or /Users/ path (PHP_UNAME and PHP_BUILD_SYSTEM are set to a neutral string). The archives shipped today (8.4.28 and 8.5.13) predate
# that: they embed the original build machine's host name and scratch paths with its user name, and must
# be rebuilt with this script before the app is given to anyone else.
#
# Afterwards: run Scripts/fetch-vendor.sh after putting each new archive's name and checksum into
# Scripts/versions.lock and Resources/php-manifest.json, commit Scripts/php-sources/, and refresh
# THIRD-PARTY-NOTICES from the licence texts this script dumps into <build dir>/licenses/<patch>/.
#
# The static binaries contain GMP and GNU libiconv (LGPL); this script and the source manifests are how
# anyone can rebuild (and so relink) them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${PADDOCK_PHP_BUILD_DIR:-/private/tmp/paddock-php-build-$(id -u)}"
OUT="$ROOT/Vendor/builds"
SOURCES="$ROOT/Scripts/php-sources"
BUILD_USER="$(id -un)"

# static-php-cli publishes its macOS binary only as a moving "nightly"; this is the 2.8.6 tarball the
# current builds were made with. If the nightly has moved on, review it and pass its checksum in
# PADDOCK_SPC_SHA256.
SPC_URL="https://dl.static-php.dev/static-php-cli/spc-bin/nightly/spc-macos-x86_64.tar.gz"
SPC_SHA256="${PADDOCK_SPC_SHA256:-7977e2a6b1bcda5c96c8191c5a26171c658f68f3435f762a06bb70a5c9d6ee18}"

# The extensions Paddock's PHP has (the design's list; mbregex needs the onig library) and the optional
# libraries it uses. --without-suggestions keeps out zstd, lz4, avif, libssh2, nghttp2, brotli, libidn2.
# Never name a variable LIBS here: autoconf treats it as linker input.
EXTS="apcu,bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,ftp,gd,gmp,iconv,igbinary,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,readline,redis,session,simplexml,soap,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,xsl,zip,zlib,mbregex,shmop,sysvmsg,sysvsem,sysvshm"
WITH_LIBS="freetype,libjpeg,libwebp,libpng,onig"

fail() { echo "build-php.sh: $*" >&2; exit 1; }
[ "${#BUILD_USER}" -ge 3 ] || fail "user name '$BUILD_USER' is shorter than 3 characters; the privacy check cannot work."
say() { echo "==> $*"; }
loud() { printf '\n!!! %s\n\n' "$*" >&2; }

usage() {
  sed -n '7,9p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2
  exit 2
}

# source_manifest DIR: "sha256  name" for every file in an spc downloads folder, hidden ones included
# except spc's own .lock.json (see the header), and "git:<commit>  name/" for a git checkout (with
# "-dirty" after the commit when its working tree has changes), sorted by name.
source_manifest() {
  local dir="$1" f commit changes sum
  (
    cd "$dir" || fail "cannot enter $dir"
    for f in * .[!.]* ..?*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      [ "$f" = .lock.json ] && continue
      if [ -L "$f" ]; then
        fail "unexpected symlink in $dir: $f"
      elif [ -d "$f" ]; then
        [ -d "$f/.git" ] || fail "unexpected directory in $dir: $f"
        commit="$(git -C "$f" rev-parse HEAD)" || fail "git rev-parse failed in $dir/$f"
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "git rev-parse gave no commit in $dir/$f"
        changes="$(git -C "$f" status --porcelain)" || fail "git status failed in $dir/$f"
        [ -z "$changes" ] || commit="$commit-dirty"
        printf 'git:%s  %s/\n' "$commit" "$f"
      else
        sum="$(shasum -a 256 -- "$f")" || fail "cannot hash $dir/$f"
        sum="${sum%% *}"
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || fail "cannot hash $dir/$f"
        printf '%s  %s\n' "$sum" "$f"
      fi
    done
  ) | LC_ALL=C sort -k2
}

# downloaded_patch DIR: the PHP release whose source is in an spc downloads folder.
downloaded_patch() {
  local found
  found="$(cd "$1" && ls php-[0-9]*.[0-9]*.[0-9]*.tar.* 2>/dev/null | sed -E 's/^php-([0-9]+\.[0-9]+\.[0-9]+)\.tar\..*/\1/' | sort -u)"
  [ "$(printf '%s\n' "$found" | grep -c .)" = 1 ] || fail "expected exactly one PHP source in $1, found: ${found:-none}"
  echo "$found"
}

# check_sources PATCH DIR: compare a downloads folder with Scripts/php-sources/PATCH.sha256.
check_sources() {
  local patch="$1" dir="$2" pinned="$SOURCES/$1.sha256" actual
  actual="$(source_manifest "$dir")" || fail "could not list the downloads in $dir"
  if [ ! -f "$pinned" ]; then
    mkdir -p "$SOURCES"
    printf '%s\n' "$actual" > "$pinned"
    loud "No source manifest existed for PHP $patch: recorded Scripts/php-sources/$patch.sha256 from these downloads. Review and commit it."
    return
  fi
  if [ "$actual" = "$(cat "$pinned")" ]; then
    say "every downloaded source matches Scripts/php-sources/$patch.sha256"
    return
  fi
  echo "build-php.sh: the downloads differ from Scripts/php-sources/$patch.sha256 (- pinned, + downloaded):" >&2
  printf '%s\n' "$actual" | diff "$pinned" - | grep -E '^[<>]' | sed 's/^</-/; s/^>/+/' >&2 || true
  if [ "${PADDOCK_PHP_ACCEPT_NEW_SOURCES:-}" = 1 ]; then
    printf '%s\n' "$actual" > "$pinned"
    loud "PADDOCK_PHP_ACCEPT_NEW_SOURCES=1: ACCEPTED THESE NEW SOURCES and rewrote Scripts/php-sources/$patch.sha256. Review the change and commit it."
    return
  fi
  fail "refusing to build from sources that differ from the pinned ones (set PADDOCK_PHP_ACCEPT_NEW_SOURCES=1 to accept them)."
}

# require_private_dir DIR: DIR must be an absolute path outside the home folder and /Users/. When
# missing it is created (mode 700) with a sentinel file; an existing directory must carry that sentinel
# (so the script never deletes things inside a folder it did not create), be a real directory (not a
# symlink), owned by this user and writable by no one else. Anything else may have been planted.
SENTINEL=.paddock-php-build
require_private_dir() {
  local d="$1" mode parent resolved home
  case "$d" in /*) ;; *) fail "PADDOCK_PHP_BUILD_DIR must be an absolute path (got: $d)." ;; esac
  case "$d" in */|*/.|*/..|*/./*|*/../*) fail "use a plain path for the build folder (got: $d)." ;; esac
  parent="$(dirname "$d")"
  [ -d "$parent" ] || fail "$parent does not exist."
  resolved="$(cd "$parent" && pwd -P)/$(basename "$d")" || fail "cannot resolve $d"
  home="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
  for p in "$d" "$resolved"; do
    case "$p" in
      "$HOME"|"$HOME"/*|"$home"|"$home"/*|/Users/*)
        fail "$d is inside a home folder; pick a build folder outside it (the default is /private/tmp/paddock-php-build-<uid>)." ;;
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

# resolve_patch SERIES: the newest release php.net lists for a series, e.g. 8.4 -> 8.4.28.
resolve_patch() {
  local json version
  json="$(mktemp "$W/release.XXXXXX")"
  curl -fsSL --retry 3 -o "$json" "https://www.php.net/releases/?json&version=$1" \
    || fail "could not ask php.net for the newest PHP $1"
  version="$(plutil -extract version raw -o - "$json" 2>/dev/null)" || version=""
  rm -f "$json"
  case "$version" in
    "$1".[0-9]*) echo "$version" ;;
    *) fail "php.net did not name a PHP $1 release (got: ${version:-nothing})" ;;
  esac
}

# privacy_check FILE: fail when FILE contains this Mac's user name, host names (hostname -s,
# LocalHostName, ComputerName) or a /Users/ path. grep reads the binary itself (byte-wise, so a
# ComputerName with non-ASCII letters is found too, which `strings` would split) and counts matches; no
# `grep -q` in a pipeline, which under pipefail lets the writer die of SIGPIPE and turns a match into a
# pass.
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

TOOLS_ONLY=0
FORCE=0
TARGETS=()
if [ "${1:-}" = --verify-sources ]; then
  [ "$#" = 3 ] || usage
  [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a PHP patch (like 8.4.28): $2"
  [ "$(downloaded_patch "$3")" = "$2" ] || fail "$3 holds the source of PHP $(downloaded_patch "$3"), not $2"
  [ -f "$SOURCES/$2.sha256" ] || fail "no Scripts/php-sources/$2.sha256"
  PADDOCK_PHP_ACCEPT_NEW_SOURCES=0 check_sources "$2" "$3"
  exit 0
fi
for arg in "$@"; do
  case "$arg" in
    --tools-only) TOOLS_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    *)
      [[ "$arg" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "not a PHP series or patch (like 8.4 or 8.4.28): $arg"
      TARGETS+=("$arg") ;;
  esac
done
[ "$TOOLS_ONLY" = 1 ] || [ "${#TARGETS[@]}" -gt 0 ] || usage

[ "$(uname -s)" = Darwin ] || fail "builds for macOS only."
[ "$(uname -m)" = x86_64 ] || fail "run this on an Intel Mac: Paddock's builds are x86_64."

require_private_dir "$W"
mkdir -p "$W"/{tool,tools/bin,tsrc,bin,work,out,logs,licenses} "$OUT"

# Resolve every target to a patch, and refuse to replace existing archives, before downloading anything.
PATCHES=()
for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
  case "$target" in
    *.*.*) patch="$target" ;;
    *) patch="$(resolve_patch "$target")"; say "PHP $target resolves to PHP $patch" ;;
  esac
  existing=0
  for kind in cli fpm; do
    archive="$OUT/php-$patch-$kind-macos-x86_64.tar.gz"
    if [ -f "$archive" ]; then
      echo "  existing $(shasum -a 256 -- "$archive")"
      existing=1
    fi
  done
  [ "$existing" = 0 ] || [ "$FORCE" = 1 ] || fail "Vendor/builds already holds PHP $patch archives (above);" \
    "installed copies and Scripts/versions.lock refer to them. Pass --force to replace them."
  PATCHES+=("$patch")
done

# Only Xcode's and our own tools: never Homebrew (/usr/local, /opt/homebrew) or MacPorts (/opt/local).
export PATH="$W/tools/bin:$W/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset LIBS
for tool in clang make perl flex unzip git curl shasum tar otool plutil; do
  command -v "$tool" >/dev/null || fail "$tool is missing; install the Xcode command line tools (xcode-select --install)."
done
# What PHP records as the system it was built on (php -i "Build System"): nothing about this Mac.
export PHP_UNAME="Darwin paddock-build x86_64"
export PHP_BUILD_SYSTEM="$PHP_UNAME"
# No AppleDouble ._ files in archives.
export COPYFILE_DISABLE=1

# `spc doctor` runs the Homebrew installer by itself when `brew` is missing; this stub refuses instead.
# It must be on PATH whenever spc runs.
printf '#!/bin/sh\necho "build-php.sh: spc wanted brew ($*); not used" >&2\nexit 1\n' > "$W/bin/brew"
chmod +x "$W/bin/brew"

# fetch URL SHA256 FILE: download into $W/tsrc (once) and verify it, on every run.
fetch() {
  local url="$1" sha="$2" file="$W/tsrc/$3" actual
  if [ ! -f "$file" ]; then
    curl -fL --retry 3 -sS -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  actual="$(shasum -a 256 -- "$file" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    rm -f "$file"
    fail "checksum mismatch for $url: expected $sha, got $actual"
  fi
}

# autotools NAME VERSION URL SHA256 [configure flags...]: build from source into $W/tools, once per
# verified tarball (the tarball is re-verified every run before its marker is trusted).
autotools() {
  local name="$1" version="$2" url="$3" sha="$4"
  shift 4
  local file="${url##*/}"
  fetch "$url" "$sha" "$file"
  if [ -f "$W/tools/.built-$name-$version-$sha" ]; then return; fi
  say "building $name $version"
  rm -rf "$W/tsrc/$name-$version"
  tar -xf "$W/tsrc/$file" -C "$W/tsrc"
  (cd "$W/tsrc/$name-$version" && ./configure --prefix="$W/tools" "$@" && make -j"$(sysctl -n hw.ncpu)" && make install) \
    > "$W/logs/tool-$name.log" 2>&1 || fail "building $name failed; see $W/logs/tool-$name.log"
  touch "$W/tools/.built-$name-$version-$sha"
}

setup_tools() {
  local cmake_sha=d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7
  # spc: the pinned tarball is verified and spc re-extracted from it on every run.
  fetch "$SPC_URL" "$SPC_SHA256" spc-macos-x86_64.tar.gz
  rm -f "$W/tool/spc"
  tar -xzf "$W/tsrc/spc-macos-x86_64.tar.gz" -C "$W/tool" spc
  fetch https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-macos-universal.tar.gz \
    "$cmake_sha" cmake-3.31.8-macos-universal.tar.gz
  if [ ! -f "$W/tools/.extracted-cmake-$cmake_sha" ]; then
    say "unpacking cmake 3.31.8"
    rm -rf "$W/tsrc/cmake-3.31.8-macos-universal"
    tar -xzf "$W/tsrc/cmake-3.31.8-macos-universal.tar.gz" -C "$W/tsrc"
    for b in cmake ctest cpack; do
      ln -sf "$W/tsrc/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/$b" "$W/tools/bin/$b"
    done
    touch "$W/tools/.extracted-cmake-$cmake_sha"
  fi
  autotools xz 5.8.1 https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz \
    507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543 --disable-doc --disable-nls --disable-shared
  # Xcode's m4 is too old for autoconf.
  autotools m4 1.4.19 https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz \
    63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96 --disable-nls
  autotools autoconf 2.72 https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.gz \
    afb181a76e1ee72832f6581c0eddf8df032b83e2e0239ef79ebedc4467d92d6e
  autotools automake 1.17 https://ftp.gnu.org/gnu/automake/automake-1.17.tar.gz \
    397767d4db3018dd4440825b60c64258b636eaf6bf99ac8b0897f06c89310acd
  autotools libtool 2.5.4 https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.gz \
    da8ebb2ce4dcf46b90098daf962cffa68f4b4f62ea60f798d0ef12929ede6adf --program-prefix=g
  autotools re2c 4.3 https://github.com/skvadrik/re2c/releases/download/4.3/re2c-4.3.tar.xz \
    51e88d6d6b6ab03eb7970276aca7e0db4f8e29c958b84b561d2fdcb8351c7150 --disable-docs
  autotools bison 3.8.2 https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz \
    9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2 --disable-nls
}

SPC="$W/tool/spc"

say "setting up build tools in $W"
setup_tools
say "spc doctor"
(cd "$W/work" && "$SPC" doctor) || fail "spc doctor found a problem (see above)."
[ "$TOOLS_ONLY" = 0 ] || { say "tools ready"; exit 0; }

# accept DIR SERIES: the checks every archive must pass before it is written.
accept() {
  local dir="$1" series="$2" b mods missing="" e out
  for b in php php-fpm; do
    out="$(file "$dir/$b")"
    grep -q x86_64 <<< "$out" || fail "$b is not x86_64"
    out="$(otool -L "$dir/$b")" || fail "otool -L failed on $b"
    [ "${out%%$'\n'*}" = "$dir/$b:" ] || fail "unexpected otool -L output for $b"
    if tail -n +2 <<< "$out" | grep -vE '^[[:space:]]*(/usr/lib/|/System/)'; then
      fail "$b links a library outside /usr/lib and /System"
    fi
    mods="$("$dir/$b" -n -m | tr 'A-Z' 'a-z')"
    for e in apcu bcmath bz2 calendar ctype curl dom exif fileinfo filter ftp gd gmp iconv igbinary intl \
             mbstring mysqli mysqlnd "zend opcache" openssl pcntl pdo pdo_mysql pdo_pgsql pdo_sqlite pgsql phar \
             posix readline redis session shmop simplexml soap sockets sodium sqlite3 sysvmsg sysvsem sysvshm \
             tokenizer xml xmlreader xmlwriter xsl zip zlib; do
      grep -qx "$e" <<< "$mods" || missing="$missing $e"
    done
    [ -z "$missing" ] || fail "$b lacks:$missing"
    for e in swoole openswoole opentelemetry imagick protobuf event; do
      if grep -qx "$e" <<< "$mods"; then fail "$b contains $e"; fi
    done
  done
  [ "$("$dir/php" -n -r 'echo implode(",", PDO::getAvailableDrivers());')" = "mysql,pgsql,sqlite" ] \
    || fail "PDO drivers are not mysql, pgsql, sqlite"
  [ "$("$dir/php" -n -r 'echo mb_ereg("b+", "abbc", $m) ? $m[0] : "none";')" = bb ] || fail "mb_ereg does not work"
  out="$("$dir/php" -n -r 'echo PHP_VERSION;')"
  grep -q "^$series\." <<< "$out" || fail "php is not PHP $series"
  "$dir/php-fpm" -n -v >/dev/null || fail "php-fpm -v failed"
  # Nothing about the machine that built it: no user name, host name or home folder path.
  for b in php php-fpm; do privacy_check "$dir/$b"; done
}

DOWNLOADS="$W/work/downloads"
cd "$W/work"
FIRST=1
[ -d "$W/work/source/php-src" ] && FIRST=0
for patch in "${PATCHES[@]}"; do
  series="$(echo "$patch" | cut -d. -f1,2)"
  custom=(--custom-url="php-src:https://www.php.net/distributions/php-$patch.tar.xz")
  if [ "$FIRST" = 1 ]; then
    say "downloading sources for PHP $patch"
    "$SPC" download --with-php="$series" --for-extensions="$EXTS" --for-libs="$WITH_LIBS" \
      --without-suggestions --prefer-pre-built --retry=3 "${custom[@]}"
    # The pre-built sqlite lacks SQLITE_ENABLE_COLUMN_METADATA and fails spc's sanity check: use the source.
    "$SPC" del-download sqlite
    "$SPC" download sqlite --retry=3
    FIRST=0
  else
    say "switching the sources to PHP $patch (the built libraries are reused if still verified)"
    "$SPC" switch-php-version "$series" --retry=3
    if [ "$(downloaded_patch "$DOWNLOADS")" != "$patch" ]; then
      "$SPC" del-download php-src
      "$SPC" download php-src --with-php="$series" --retry=3 "${custom[@]}"
    fi
  fi
  [ "$(downloaded_patch "$DOWNLOADS")" = "$patch" ] || fail "asked for PHP $patch, but the downloaded source is $(downloaded_patch "$DOWNLOADS")"
  check_sources "$patch" "$DOWNLOADS"
  manifest="$(source_manifest "$DOWNLOADS")" || fail "could not list the downloads in $DOWNLOADS"
  printf '%s\n' "$manifest" > "$OUT/sources-$patch.sha256"

  # Extracted sources and built libraries from an earlier run are kept only when a marker written after a
  # verified build says they came from these same library downloads (everything but the PHP source).
  libraries="$(grep -vE '  php-[0-9]+\.[0-9]+\.[0-9]+\.tar\.' <<< "$manifest" || true)"
  marker="$W/work/.verified-libraries"
  if [ -e "$W/work/source" ] || [ -e "$W/work/buildroot" ]; then
    if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$libraries" ]; then
      say "earlier extracted sources are not known to come from these downloads: deleting them"
      rm -f "$marker"
      rm -rf "$W/work/source" "$W/work/buildroot" "$W/work/pkgroot"
      # spc doctor puts its pkg-config package (verified above with the downloads) back in pkgroot.
      "$SPC" doctor > "$W/logs/doctor.log" 2>&1 || fail "spc doctor failed; see $W/logs/doctor.log"
    else
      rm -rf "$W/work/source/php-src"
    fi
  fi

  log="$W/logs/build-$patch.log"
  say "building PHP $patch (log: $log)"
  "$SPC" build "$EXTS" --with-libs="$WITH_LIBS" --build-cli --build-fpm > "$log" 2>&1 \
    || fail "the PHP $patch build failed; see $log"

  dir="$W/out/$patch"
  rm -rf "$dir" && mkdir -p "$dir"
  cp buildroot/bin/php buildroot/bin/php-fpm "$dir/"
  accept "$dir" "$series"
  [ "$("$dir/php" -n -r 'echo PHP_VERSION;')" = "$patch" ] || fail "the built php is not PHP $patch"
  printf '%s\n' "$libraries" > "$marker"

  for kind in cli fpm; do
    bin=php; [ "$kind" = fpm ] && bin=php-fpm
    archive="php-$patch-$kind-macos-x86_64.tar.gz"
    old=""
    [ -f "$OUT/$archive" ] && old="$(shasum -a 256 -- "$OUT/$archive" | awk '{print $1}')"
    tar -czf "$OUT/$archive.part" -C "$dir" "$bin"
    mv "$OUT/$archive.part" "$OUT/$archive"
    new="$(shasum -a 256 -- "$OUT/$archive" | awk '{print $1}')"
    if [ -n "$old" ]; then echo "  replaced $archive: $old -> $new"; else echo "  wrote $archive: $new"; fi
  done
  "$SPC" dump-license --for-extensions="$EXTS" --for-libs="$WITH_LIBS" --dump-dir="$W/licenses/$patch" \
    > "$W/logs/licenses-$patch.log" 2>&1 || echo "build-php.sh: dumping licence texts failed; see $W/logs/licenses-$patch.log" >&2
  say "PHP $patch: Vendor/builds/php-$patch-{cli,fpm}-macos-x86_64.tar.gz"
done

(cd "$OUT" && shasum -a 256 -- php-*-macos-x86_64.tar.gz > SHA256SUMS)
say "Checksums (Vendor/builds/SHA256SUMS):"
cat "$OUT/SHA256SUMS"
echo "Put the new names and checksums into Scripts/versions.lock and Resources/php-manifest.json, commit Scripts/php-sources/, then run Scripts/fetch-vendor.sh."
