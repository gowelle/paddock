#!/bin/bash
# Builds Paddock's own static PHP for Intel Macs (php and php-fpm, without Swoole) with static-php-cli,
# using no Homebrew and no MacPorts, and writes the archives Paddock ships into Vendor/builds/:
#   php-<patch>-cli-macos-x86_64.tar.gz   (one file at the top level: php)
#   php-<patch>-fpm-macos-x86_64.tar.gz   (one file at the top level: php-fpm)
#
# Usage: Scripts/build-php.sh <series>...    e.g. Scripts/build-php.sh 8.5 8.4
#        Scripts/build-php.sh --tools-only   only set up the build tools and run `spc doctor`
#
# A clean run takes about 5 minutes of tool setup plus about 15 minutes per series (a later series reuses
# the libraries the first one built). Everything is built under Vendor/php-build/ (git-ignored; override
# with PADDOCK_PHP_BUILD_DIR); delete that folder to start from scratch. Every download is checked
# against the SHA-256 below before it is unpacked or run.
#
# Afterwards: run Scripts/fetch-vendor.sh after putting each new archive's name and checksum into
# Scripts/versions.lock and Resources/php-manifest.json, and refresh THIRD-PARTY-NOTICES from the licence
# texts this script dumps into Vendor/php-build/licenses/<series>/.
#
# The static binaries contain GMP and GNU libiconv (LGPL); this script is how anyone can rebuild (and
# so relink) them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${PADDOCK_PHP_BUILD_DIR:-$ROOT/Vendor/php-build}"
OUT="$ROOT/Vendor/builds"

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
say() { echo "==> $*"; }

usage() {
  sed -n '7,8p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2
  exit 2
}

TOOLS_ONLY=0
SERIES=()
for arg in "$@"; do
  case "$arg" in
    --tools-only) TOOLS_ONLY=1 ;;
    -h|--help) usage ;;
    [0-9].[0-9]|[0-9].[0-9][0-9]) SERIES+=("$arg") ;;
    *) fail "unknown argument: $arg" ;;
  esac
done
[ "$TOOLS_ONLY" = 1 ] || [ "${#SERIES[@]}" -gt 0 ] || usage

[ "$(uname -s)" = Darwin ] || fail "builds for macOS only."
[ "$(uname -m)" = x86_64 ] || fail "run this on an Intel Mac: Paddock's builds are x86_64."
for tool in clang make m4 perl flex unzip git curl shasum tar; do
  command -v "$tool" >/dev/null || fail "$tool is missing; install the Xcode command line tools (xcode-select --install)."
done

mkdir -p "$W"/{tool,tools/bin,tsrc,bin,work,out,logs,licenses} "$OUT"

# Only Xcode's and our own tools: never Homebrew (/usr/local, /opt/homebrew) or MacPorts (/opt/local).
export PATH="$W/tools/bin:$W/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset LIBS

# `spc doctor` runs the Homebrew installer by itself when `brew` is missing; this stub refuses instead.
# It must be on PATH whenever spc runs.
printf '#!/bin/sh\necho "build-php.sh: spc wanted brew ($*); not used" >&2\nexit 1\n' > "$W/bin/brew"
chmod +x "$W/bin/brew"

# fetch URL SHA256 FILE: download into $W/tsrc (once) and verify.
fetch() {
  local url="$1" sha="$2" file="$W/tsrc/$3" actual
  if [ ! -f "$file" ]; then
    curl -fL --retry 3 -sS -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    rm -f "$file"
    fail "checksum mismatch for $url: expected $sha, got $actual"
  fi
}

# autotools NAME VERSION URL SHA256 [configure flags...]: build from source into $W/tools, once.
autotools() {
  local name="$1" version="$2" url="$3" sha="$4"
  shift 4
  local file="${url##*/}"
  if [ -f "$W/tools/.built-$name-$version" ]; then return; fi
  say "building $name $version"
  fetch "$url" "$sha" "$file"
  rm -rf "$W/tsrc/$name-$version"
  tar -xf "$W/tsrc/$file" -C "$W/tsrc"
  (cd "$W/tsrc/$name-$version" && ./configure --prefix="$W/tools" "$@" && make -j"$(sysctl -n hw.ncpu)" && make install) \
    > "$W/logs/tool-$name.log" 2>&1 || fail "building $name failed; see $W/logs/tool-$name.log"
  touch "$W/tools/.built-$name-$version"
}

setup_tools() {
  if [ ! -x "$W/tool/spc" ]; then
    say "fetching static-php-cli"
    fetch "$SPC_URL" "$SPC_SHA256" spc-macos-x86_64.tar.gz
    tar -xzf "$W/tsrc/spc-macos-x86_64.tar.gz" -C "$W/tool"
  fi
  if [ ! -x "$W/tools/bin/cmake" ]; then
    say "fetching cmake 3.31.8"
    fetch https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-macos-universal.tar.gz \
      d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7 cmake-3.31.8-macos-universal.tar.gz
    tar -xzf "$W/tsrc/cmake-3.31.8-macos-universal.tar.gz" -C "$W/tsrc"
    for b in cmake ctest cpack; do
      ln -sf "$W/tsrc/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/$b" "$W/tools/bin/$b"
    done
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
  local dir="$1" series="$2" b mods missing="" e
  for b in php php-fpm; do
    file "$dir/$b" | grep -q x86_64 || fail "$b is not x86_64"
    if otool -L "$dir/$b" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/)'; then
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
  "$dir/php" -n -r 'echo PHP_VERSION;' | grep -q "^$series\." || fail "php is not PHP $series"
  "$dir/php-fpm" -n -v >/dev/null || fail "php-fpm -v failed"
}

cd "$W/work"
FIRST=1
[ -d "$W/work/source/php-src" ] && FIRST=0
for series in "${SERIES[@]}"; do
  log="$W/logs/build-$series.log"
  if [ "$FIRST" = 1 ]; then
    say "downloading sources for PHP $series"
    "$SPC" download --with-php="$series" --for-extensions="$EXTS" --for-libs="$WITH_LIBS" \
      --without-suggestions --prefer-pre-built --retry=3
    # The pre-built sqlite lacks SQLITE_ENABLE_COLUMN_METADATA and fails spc's sanity check: use the source.
    "$SPC" del-download sqlite
    "$SPC" download sqlite --retry=3
    FIRST=0
  else
    say "switching the sources to PHP $series (the built libraries are reused)"
    "$SPC" switch-php-version "$series" --retry=3
  fi
  say "building PHP $series (log: $log)"
  "$SPC" build "$EXTS" --with-libs="$WITH_LIBS" --build-cli --build-fpm > "$log" 2>&1 \
    || fail "the PHP $series build failed; see $log"

  dir="$W/out/$series"
  rm -rf "$dir" && mkdir -p "$dir"
  cp buildroot/bin/php buildroot/bin/php-fpm "$dir/"
  accept "$dir" "$series"
  patch="$("$dir/php" -n -r 'echo PHP_VERSION;')"

  for kind in cli fpm; do
    bin=php; [ "$kind" = fpm ] && bin=php-fpm
    archive="php-$patch-$kind-macos-x86_64.tar.gz"
    tar -czf "$OUT/$archive.part" -C "$dir" "$bin"
    mv "$OUT/$archive.part" "$OUT/$archive"
  done
  "$SPC" dump-license --for-extensions="$EXTS" --for-libs="$WITH_LIBS" --dump-dir="$W/licenses/$series" \
    > "$W/logs/licenses-$series.log" 2>&1 || echo "build-php.sh: dumping licence texts failed; see $W/logs/licenses-$series.log" >&2
  say "PHP $patch: Vendor/builds/php-$patch-{cli,fpm}-macos-x86_64.tar.gz"
done

(cd "$OUT" && shasum -a 256 php-*-macos-x86_64.tar.gz > SHA256SUMS)
say "Checksums (Vendor/builds/SHA256SUMS):"
cat "$OUT/SHA256SUMS"
echo "Put the new names and checksums into Scripts/versions.lock and Resources/php-manifest.json, then run Scripts/fetch-vendor.sh."
