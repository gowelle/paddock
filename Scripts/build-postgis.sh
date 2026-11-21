#!/bin/bash
# Builds Paddock's PostGIS add-on for each PostgreSQL series it offers (the theseus-rs builds for Intel
# Macs), using no Homebrew and no MacPorts, and writes the archives Paddock ships into Vendor/builds/:
#   postgis-3.6.4-pg<series>-macos-x86_64.tar.gz
# Each is unpacked over the PostgreSQL install folder (a second asset of the PostgreSQL recipe in
# Resources/services-catalog.json) and adds only new files: lib/postgis-3.dylib with GEOS, PROJ and json-c
# beside it (found by @rpath through a single @loader_path rpath), share/extension/postgis*, share/proj/
# (proj.db, found relative to libproj: no environment variable needed) and share/licenses/postgis/.
#
# Usage: Scripts/build-postgis.sh [--force] [series...]     default: 18 17 16
#        Scripts/build-postgis.sh --fetch-only               set up the build folder, download and verify
#                                                            every pinned file, then stop
#        Scripts/build-postgis.sh --check FILE...            run the post-build checks on files (any Mach-O
#                                                            is checked for its links too)
#
# An existing archive is never replaced unless --force is given; that is checked before anything is
# downloaded. A clean run takes about 20 minutes (GEOS and PROJ once, then PostGIS per series, serially:
# its SQL generation races under make -j).
#
# Everything is built under /private/tmp/paddock-postgis-build-<uid> (override with
# PADDOCK_POSTGIS_BUILD_DIR), a neutral path, so no user name ends up in the binaries. As for
# Scripts/build-php.sh, the folder must be an absolute path outside your home folder and /Users/, a real
# directory (not a symlink) owned by you and writable by no one else, created by this script (it writes a
# .paddock-postgis-build sentinel in it, with mode 700); any other folder is refused. Delete it to start
# from scratch.
#
# What is pinned, by SHA-256, verified on every run before anything extracted or built from it is used:
#   - the sources: PostGIS 3.6.4, GEOS 3.14.1, PROJ 9.9.0, json-c 0.18 (tag json-c-0.18-20240915);
#   - the theseus-rs PostgreSQL archives built against: 18.7.0, 17.12.0, 16.16.0 (the same files and
#     checksums as Resources/services-catalog.json);
#   - cmake 3.31.8 (the same tarball as build-php.sh).
# Xcode's clang, make and the macOS SDK are whatever the Mac has. libxml2, sqlite3, libiconv and libc++ come
# from macOS (/usr/lib) and are not shipped. Built --without-raster --without-topology --without-tiger
# --without-address-standardizer --without-protobuf; MACOSX_DEPLOYMENT_TARGET 12.0 (PostgreSQL itself needs
# macOS 15). PGXS needs PG_SYSROOT pointed at this Mac's SDK and with_llvm=no (theseus records its CI's
# SDK and an absent clang for JIT bitcode, which is optional).
#
# Every archive is checked before it is written: each library is x86_64 and links only @rpath/, /usr/lib/
# and /System/ (its only rpath @loader_path); no file contains this Mac's user name, host names (hostname -s,
# LocalHostName, ComputerName) or a /Users/ path; and no file would replace one of PostgreSQL's (Paddock
# refuses an asset that overwrites another's). The archives shipped today predate that privacy check: in all
# three (pg16, pg17 and pg18), lib/postgis-3.dylib embeds one string with the original build machine's user
# name (a build path to PostgreSQL's tupmacs.h), so all three must be rebuilt with this script before the app
# is given to anyone else. They were built from these same pinned releases by an earlier form of this recipe.
#
# Afterwards: put each archive's checksum and size into Scripts/versions.lock (postgis-pg<series>) and
# Resources/services-catalog.json, then run Scripts/fetch-vendor.sh.
#
# PostGIS is GPL-2.0-or-later and GEOS LGPL-2.1-or-later: the archives carry their licences, and these
# pinned releases built by this script are their corresponding source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${PADDOCK_POSTGIS_BUILD_DIR:-/private/tmp/paddock-postgis-build-$(id -u)}"
OUT="$ROOT/Vendor/builds"
BUILD_USER="$(id -un)"

POSTGIS_VER=3.6.4
GEOS_VER=3.14.1
PROJ_VER=9.9.0
JSONC_TAG=json-c-0.18-20240915
# file|url|sha256
SOURCES=(
  "postgis-$POSTGIS_VER.tar.gz|https://download.osgeo.org/postgis/source/postgis-$POSTGIS_VER.tar.gz|ed8dc6679f1e06f7b113592b04cde2a7e00f1b1e681294c8ca2204058990cec6"
  "geos-$GEOS_VER.tar.bz2|https://download.osgeo.org/geos/geos-$GEOS_VER.tar.bz2|3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716"
  "proj-$PROJ_VER.tar.gz|https://download.osgeo.org/proj/proj-$PROJ_VER.tar.gz|791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3"
  "$JSONC_TAG.tar.gz|https://github.com/json-c/json-c/archive/refs/tags/$JSONC_TAG.tar.gz|3112c1f25d39eca661fe3fc663431e130cc6e2f900c081738317fba49d29e298"
)
# series|version|sha256 of the theseus-rs archive
PG_ARCHIVES=(
  "18|18.7.0|9cd649259d6bf4af60a235e772c83853df215b63f4c1967c2eed7f9376aefb89"
  "17|17.12.0|34ba0eca0f15776b4ab9a07b2decc6fb0b1910a57870ad7d7dacb7399b43c9bd"
  "16|16.16.0|6bcc3f98c76fdb4b52bf4e59781308ea996058941566579a0961b3a25626b6bb"
)
CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-macos-universal.tar.gz
CMAKE_SHA=d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7

fail() { echo "build-postgis.sh: $*" >&2; exit 1; }
[ "${#BUILD_USER}" -ge 3 ] || fail "user name '$BUILD_USER' is shorter than 3 characters; the privacy check cannot work."
say() { echo "==> $*"; }
usage() { sed -n '10,15p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }

archive_name() { echo "postgis-$POSTGIS_VER-pg$1-macos-x86_64.tar.gz"; }

# require_private_dir DIR: as in build-php.sh. DIR must be an absolute path outside the home folder and
# /Users/. When missing it is created (mode 700) with a sentinel file; an existing directory must carry
# that sentinel (so the script never deletes things inside a folder it did not create), be a real
# directory (not a symlink), owned by this user and writable by no one else.
SENTINEL=.paddock-postgis-build
require_private_dir() {
  local d="$1" mode parent resolved home
  case "$d" in /*) ;; *) fail "PADDOCK_POSTGIS_BUILD_DIR must be an absolute path (got: $d)." ;; esac
  case "$d" in */|*/.|*/..|*/./*|*/../*) fail "use a plain path for the build folder (got: $d)." ;; esac
  parent="$(dirname "$d")"
  [ -d "$parent" ] || fail "$parent does not exist."
  resolved="$(cd "$parent" && pwd -P)/$(basename "$d")" || fail "cannot resolve $d"
  home="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
  for p in "$d" "$resolved"; do
    case "$p" in
      "$HOME"|"$HOME"/*|"$home"|"$home"/*|/Users/*)
        fail "$d is inside a home folder; pick a build folder outside it (the default is /private/tmp/paddock-postgis-build-<uid>)." ;;
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

# link_check FILE: a Mach-O must be x86_64, link only @rpath/, /usr/lib/ and /System/, and have no rpath but
# @loader_path. The otool output is captured first, then read; no pipeline decides the result.
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
      @rpath/*|/usr/lib/*|/System/*) ;;
      *) fail "$file links ${line%% (*}, which is not @rpath/, /usr/lib/ or /System/" ;;
    esac
  done <<< "$out"
  out="$(otool -l "$file")" || fail "otool -l failed on $file"
  rpaths="$(awk '/cmd LC_RPATH/ { getline; getline; print $2 }' <<< "$out")"
  [ "$rpaths" = "@loader_path" ] || fail "$file has rpaths '${rpaths//$'\n'/ }'; only @loader_path is allowed"
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
  echo "build-postgis.sh: $# file(s) passed the checks."
  exit 0
fi

FETCH_ONLY=0
FORCE=0
SERIES=()
for arg in "$@"; do
  case "$arg" in
    --fetch-only) FETCH_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    16|17|18) SERIES+=("$arg") ;;
    *) fail "not a PostgreSQL series Paddock builds PostGIS for (16, 17 or 18): $arg" ;;
  esac
done
[ "${#SERIES[@]}" -gt 0 ] || SERIES=(18 17 16)

[ "$(uname -s)" = Darwin ] || fail "builds for macOS only."
[ "$(uname -m)" = x86_64 ] || fail "run this on an Intel Mac: Paddock's builds are x86_64."

# Refuse to replace existing archives before anything is downloaded.
if [ "$FETCH_ONLY" = 0 ]; then
  existing=0
  for s in "${SERIES[@]}"; do
    if [ -f "$OUT/$(archive_name "$s")" ]; then
      echo "  existing $(shasum -a 256 -- "$OUT/$(archive_name "$s")")"
      existing=1
    fi
  done
  [ "$existing" = 0 ] || [ "$FORCE" = 1 ] || fail "Vendor/builds already holds these archives (above);" \
    "installed copies, Scripts/versions.lock and the catalog refer to them. Pass --force to replace them."
fi

require_private_dir "$W"
mkdir -p "$W"/{downloads,src,tools/bin,build,logs} "$OUT"

# Only Xcode's and our own tools: never Homebrew (/usr/local, /opt/homebrew) or MacPorts (/opt/local).
export PATH="$W/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH LIBS || true
for tool in clang make perl curl shasum tar otool install_name_tool codesign xcrun file awk sed \
            /usr/bin/xml2-config /usr/bin/sqlite3; do
  command -v "$tool" >/dev/null || fail "$tool is missing; install the Xcode command line tools (xcode-select --install)."
done
# No AppleDouble ._ files in archives.
export COPYFILE_DISABLE=1
export MACOSX_DEPLOYMENT_TARGET=12.0

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

say "downloading and verifying the pinned files in $W/downloads"
for entry in "${SOURCES[@]}"; do IFS='|' read -r f u s <<< "$entry"; fetch "$u" "$s" "$f"; done
fetch "$CMAKE_URL" "$CMAKE_SHA" cmake-3.31.8-macos-universal.tar.gz
for entry in "${PG_ARCHIVES[@]}"; do
  IFS='|' read -r ser ver sha <<< "$entry"
  for s in "${SERIES[@]}"; do
    [ "$s" = "$ser" ] || continue
    a="postgresql-$ver-x86_64-apple-darwin"
    fetch "https://github.com/theseus-rs/postgresql-binaries/releases/download/$ver/$a.tar.gz" "$sha" "$a.tar.gz"
  done
done
[ "$FETCH_ONLY" = 0 ] || { say "every pinned file is downloaded and verified"; exit 0; }

# extract FILE SHA DIR: unpack a verified download into $W/src once (again if its checksum changed).
extract() {
  local file="$1" sha="$2" dir="$3"
  if [ -f "$W/src/.extracted-$dir-$sha" ] && [ -d "$W/src/$dir" ]; then return; fi
  rm -rf "$W/src/$dir"
  tar -xf "$W/downloads/$file" -C "$W/src" || fail "could not unpack $file"
  [ -d "$W/src/$dir" ] || fail "$file did not unpack into $dir"
  touch "$W/src/.extracted-$dir-$sha"
}
for entry in "${SOURCES[@]}"; do
  IFS='|' read -r f u s <<< "$entry"
  case "$f" in
    postgis-*) d="postgis-$POSTGIS_VER" ;;
    geos-*) d="geos-$GEOS_VER" ;;
    proj-*) d="proj-$PROJ_VER" ;;
    json-c-*) d="json-c-$JSONC_TAG" ;;
  esac
  extract "$f" "$s" "$d"
done
if [ ! -f "$W/tools/.extracted-cmake-$CMAKE_SHA" ]; then
  say "unpacking cmake 3.31.8"
  rm -rf "$W/tools/cmake-3.31.8-macos-universal"
  tar -xzf "$W/downloads/cmake-3.31.8-macos-universal.tar.gz" -C "$W/tools"
  for b in cmake ctest cpack; do
    ln -sf "$W/tools/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/$b" "$W/tools/bin/$b"
  done
  touch "$W/tools/.extracted-cmake-$CMAKE_SHA"
fi
command -v cmake >/dev/null || fail "cmake did not unpack"

SDK="$(xcrun --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
SRC="$W/src"; B="$W/build"; DEPS="$B/deps"; LOGS="$W/logs"
mkdir -p "$DEPS"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$DEPS"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_OSX_ARCHITECTURES=x86_64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
  -DCMAKE_OSX_SYSROOT="$SDK"
  -DCMAKE_INSTALL_NAME_DIR=@rpath
  -DCMAKE_INSTALL_RPATH=@loader_path
  -DCMAKE_FIND_FRAMEWORK=NEVER
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/local;/usr/local;/opt/homebrew"
  -DBUILD_TESTING=OFF
)

# cmake_dep NAME SOURCE-DIR [flags...]: build and install a dependency into $DEPS, once per build folder.
cmake_dep() {
  local name="$1" src="$2"
  shift 2
  [ -f "$B/$name.stamp" ] && return
  say "building $name"
  rm -rf "$B/$name"
  cmake -S "$src" -B "$B/$name" "${CMAKE_COMMON[@]}" "$@" > "$LOGS/$name-configure.log" 2>&1 \
    || fail "configuring $name failed; see $LOGS/$name-configure.log"
  cmake --build "$B/$name" -j "$JOBS" > "$LOGS/$name-build.log" 2>&1 || fail "building $name failed; see $LOGS/$name-build.log"
  cmake --install "$B/$name" > "$LOGS/$name-install.log" 2>&1 || fail "installing $name failed; see $LOGS/$name-install.log"
  touch "$B/$name.stamp"
}

# json-c (MIT), GEOS (LGPL-2.1-or-later), PROJ (MIT; sqlite3 from macOS, no TIFF, no curl, no grid
# downloads; no build path embedded: PROJ finds proj.db in <libproj's folder>/../share/proj).
cmake_dep jsonc "$SRC/json-c-$JSONC_TAG" -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DDISABLE_EXTRA_LIBS=ON \
  -DBUILD_APPS=OFF
cmake_dep geos "$SRC/geos-$GEOS_VER" -DBUILD_SHARED_LIBS=ON -DBUILD_GEOSOP=OFF -DBUILD_BENCHMARKS=OFF \
  -DBUILD_DOCUMENTATION=OFF
cmake_dep proj "$SRC/proj-$PROJ_VER" -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF \
  -DEMBED_PROJ_DATA_PATH=OFF -DEMBED_RESOURCE_FILES=OFF -DSQLite3_INCLUDE_DIR="$SDK/usr/include" \
  -DSQLite3_LIBRARY="$SDK/usr/lib/libsqlite3.tbd" -DEXE_SQLITE3=/usr/bin/sqlite3

# libxml2 from the macOS SDK (/usr/lib/libxml2.2.dylib at run time); this wrapper gives configure its -I.
mkdir -p "$B/bin"
cat > "$B/bin/xml2-config" <<EOF
#!/bin/sh
case "\$1" in
  --version) /usr/bin/xml2-config --version ;;
  --cflags) echo "-I$SDK/usr/include/libxml2" ;;
  --libs) echo "-lxml2" ;;
  *) /usr/bin/xml2-config "\$@" ;;
esac
EOF
chmod +x "$B/bin/xml2-config"

# fix_rpaths FILE: the only rpath becomes @loader_path.
fix_rpaths() {
  local f="$1" r out
  out="$(otool -l "$f")" || fail "otool -l failed on $f"
  for r in $(awk '/cmd LC_RPATH/ { getline; getline; print $2 }' <<< "$out"); do
    install_name_tool -delete_rpath "$r" "$f" || fail "could not remove the rpath $r of $f"
  done
  install_name_tool -add_rpath @loader_path "$f" || fail "could not add @loader_path to $f"
}

# licenses DIR: the licence texts of everything in the archive, from the verified sources.
licenses() {
  local d="$1" P="$SRC/postgis-$POSTGIS_VER" G="$SRC/geos-$GEOS_VER" R="$SRC/proj-$PROJ_VER" J="$SRC/json-c-$JSONC_TAG"
  local out src
  while read -r out src; do
    [ -f "$src" ] || fail "licence file $src is missing"
    cp "$src" "$d/$out"
  done <<EOF
postgis-COPYING-GPL-2.0.txt $P/COPYING
postgis-LICENSE.TXT $P/LICENSE.TXT
postgis-deps-ryu-LICENSE.txt $P/deps/ryu/LICENSE
postgis-deps-ryu-LICENSE-Apache2.txt $P/deps/ryu/LICENSE-Apache2
postgis-deps-ryu-LICENSE-Boost.txt $P/deps/ryu/LICENSE-Boost
postgis-deps-uthash-LICENSE.txt $P/deps/uthash/LICENSE
postgis-deps-flatbuffers-LICENSE-Apache-2.0.txt $P/deps/flatgeobuf/include/flatbuffers/LICENSE
geos-COPYING-LGPL-2.1.txt $G/COPYING
geos-deps-ryu-LICENSE.txt $G/src/deps/ryu/LICENSE
geos-deps-ryu-LICENSE-Apache2.txt $G/src/deps/ryu/LICENSE-Apache2
geos-deps-ryu-LICENSE-Boost.txt $G/src/deps/ryu/LICENSE-Boost
proj-COPYING-MIT.txt $R/COPYING
json-c-COPYING-MIT.txt $J/COPYING
EOF
  # nlohmann/json, vendored by PROJ: its licence is the header of json.hpp.
  head -n 30 "$R/include/proj/internal/vendor/nlohmann/json.hpp" > "$d/proj-vendor-nlohmann-json-MIT.txt"
  cat > "$d/LICENSES-SUMMARY.txt" <<EOF
Components shipped in $(archive_name "<series>")
====================================================================
lib/postgis-3.dylib, share/extension/postgis*  PostGIS $POSTGIS_VER      GPL-2.0-or-later   (postgis-COPYING-GPL-2.0.txt, postgis-LICENSE.TXT)
   statically contains: liblwgeom (GPL-2.0-or-later), ryu (Apache-2.0 OR BSL-1.0), uthash (BSD-1-Clause),
   flatgeobuf (GPL-2.0-or-later in PostGIS tree) with flatbuffers headers (Apache-2.0). Built without
   protobuf, so mapbox wagyu and geometry.hpp are not compiled in.
lib/libgeos.$GEOS_VER.dylib, lib/libgeos_c.1.dylib GEOS $GEOS_VER       LGPL-2.1-or-later  (geos-COPYING-LGPL-2.1.txt; ryu Apache-2.0 OR BSL-1.0)
   Shipped as unmodified shared libraries (only install names / rpaths changed with install_name_tool);
   source: https://download.osgeo.org/geos/geos-$GEOS_VER.tar.bz2 (LGPL relinking requirement satisfied by dynamic linking).
lib/libproj.25.dylib                          PROJ $PROJ_VER         MIT                (proj-COPYING-MIT.txt; vendored nlohmann/json MIT)
share/proj/proj.db, proj.ini                  PROJ $PROJ_VER data    MIT; proj.db embeds the EPSG Geodetic Parameter Dataset,
   redistributable under the EPSG terms of use (https://epsg.org/terms-of-use.html), plus ESRI/IGNF/etc.
   catalogues as described in PROJ's documentation.
lib/libjson-c.5.dylib                         json-c 0.18        MIT                (json-c-COPYING-MIT.txt)
Linked from macOS (not shipped): /usr/lib/libxml2.2.dylib, libsqlite3.dylib, libiconv.2.dylib, libc++.1.dylib, libSystem.B.dylib
Corresponding source: the pinned upstream releases built by Scripts/build-postgis.sh in Paddock's
repository, and that script; available from the publisher of Paddock on request.
EOF
}

build_series() {
  local series="$1" ver="$2" arch="postgresql-$2-x86_64-apple-darwin"
  local PG="$B/pg$series" STG="$B/stage-pg$series" ADD="$B/addon-pg$series" L="$LOGS/postgis-pg$series"
  local name f
  name="$(archive_name "$series")"
  say "building PostGIS $POSTGIS_VER for PostgreSQL $ver"
  rm -rf "$PG" "$B/postgis-pg$series" "$STG" "$ADD"
  mkdir -p "$PG"
  tar -xzf "$W/downloads/$arch.tar.gz" -C "$PG" --strip-components 1 || fail "could not unpack $arch"
  cp -R "$SRC/postgis-$POSTGIS_VER" "$B/postgis-pg$series"
  # One && chain: a subshell on the left of || runs without errexit, so each step must gate the next.
  (
    cd "$B/postgis-pg$series" &&
    export PG_SYSROOT="$SDK" &&
    ./configure \
      --with-pgconfig="$PG/bin/pg_config" --with-geosconfig="$DEPS/bin/geos-config" \
      --with-projdir="$DEPS" --with-jsondir="$DEPS" --with-xml2config="$B/bin/xml2-config" \
      --without-raster --without-topology --without-tiger --without-address-standardizer \
      --without-protobuf --without-interrupt-tests --without-phony-revision \
      --disable-nls --without-libintl-prefix --without-libiconv-prefix \
      CFLAGS="-O2 -arch x86_64 -isysroot $SDK" CXXFLAGS="-O2 -arch x86_64 -isysroot $SDK" \
      LDFLAGS="-arch x86_64 -isysroot $SDK -L$DEPS/lib -Wl,-rpath,$DEPS/lib" > "$L-configure.log" 2>&1 &&
    # Serially: PostGIS 3.6's SQL generation races under make -j.
    make -j1 PG_SYSROOT="$SDK" with_llvm=no > "$L-build.log" 2>&1 &&
    make install PG_SYSROOT="$SDK" with_llvm=no DESTDIR="$STG" > "$L-install.log" 2>&1
  ) || fail "building PostGIS for PostgreSQL $ver failed; see $L-*.log"

  # Only what CREATE EXTENSION postgis needs, as real files under their install names.
  local S="$STG$PG"
  mkdir -p "$ADD/lib" "$ADD/share/extension" "$ADD/share/proj" "$ADD/share/licenses/postgis"
  cp "$S/lib/postgis-3.dylib" "$ADD/lib/"
  cp "$S/share/extension/postgis.control" "$S"/share/extension/postgis--*.sql "$ADD/share/extension/"
  for f in libgeos_c.1 "libgeos.$GEOS_VER" libproj.25 libjson-c.5; do cp -L "$DEPS/lib/$f.dylib" "$ADD/lib/$f.dylib"; done
  cp "$DEPS/share/proj/proj.db" "$DEPS/share/proj/proj.ini" "$ADD/share/proj/"
  for f in "$ADD"/lib/*.dylib; do chmod u+w "$f"; fix_rpaths "$f"; done
  install_name_tool -id @rpath/libgeos_c.1.dylib "$ADD/lib/libgeos_c.1.dylib"
  for f in "$ADD"/lib/*.dylib; do codesign --force -s - "$f" 2>/dev/null || fail "could not sign $f"; done
  licenses "$ADD/share/licenses/postgis"
  cat > "$ADD/share/licenses/postgis/BUILDINFO.txt" <<EOF
postgis $POSTGIS_VER (GPL-2.0-or-later) built against theseus-rs postgresql $ver x86_64-apple-darwin
geos $GEOS_VER (LGPL-2.1-or-later), proj $PROJ_VER (MIT), json-c ${JSONC_TAG#json-c-} (MIT)
system libraries used: libxml2, libsqlite3, libiconv, libc++, libSystem (macOS)
MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET SDK=$(xcrun --show-sdk-version) by Scripts/build-postgis.sh
configure: --without-raster --without-topology --without-tiger --without-address-standardizer --without-protobuf
EOF

  # The checks every archive passes before it is written.
  # find writes to files first and its status is checked: a failure in a process substitution would
  # go unnoticed and leave nothing to check.
  local files=() rel list="$B/files-pg$series"
  find "$ADD" -type f -print0 > "$list" || fail "could not list the files of the add-on"
  while IFS= read -r -d '' f; do files+=("$f"); done < "$list"
  [ "${#files[@]}" -gt 0 ] || fail "the add-on for PostgreSQL $ver is empty"
  check_files "${files[@]}"
  find "$ADD" ! -type f ! -type d -print0 > "$list" || fail "could not list the add-on"
  [ ! -s "$list" ] || fail "unexpected symlink or special file in the add-on: $(tr '\0' ' ' < "$list")"
  for f in "${files[@]}"; do
    rel="${f#"$ADD"/}"
    [ ! -e "$PG/$rel" ] && [ ! -L "$PG/$rel" ] || fail "$rel would replace a file of PostgreSQL $ver"
  done

  (cd "$ADD" && tar --uid 0 --gid 0 --uname root --gname wheel -czf "$OUT/$name.part" lib share) \
    || fail "could not write $name"
  mv "$OUT/$name.part" "$OUT/$name"
  say "wrote Vendor/builds/$name"
  echo "  $(shasum -a 256 -- "$OUT/$name" | awk '{print $1}')  $(stat -f %z "$OUT/$name") bytes"
}

for s in "${SERIES[@]}"; do
  for entry in "${PG_ARCHIVES[@]}"; do
    IFS='|' read -r ser ver sha <<< "$entry"
    if [ "$s" = "$ser" ]; then build_series "$ser" "$ver"; fi
  done
done
say "done; put the checksums and sizes above into Scripts/versions.lock and Resources/services-catalog.json"
