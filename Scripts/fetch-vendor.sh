#!/bin/bash
# Prepares the programs Paddock bundles in Vendor/.
#
# Caddy and composer.phar are downloaded. First run: resolves the latest Caddy 2.x and composer.phar,
# downloads them and records "name<TAB>url<TAB>sha256" in Scripts/versions.lock. Later runs download
# exactly the URLs in the lock and fail on a checksum mismatch. To upgrade, delete the relevant lines
# (or the whole file) and run again.
#
# PHP is never downloaded: Paddock ships its own builds (no Swoole), made by Scripts/build-php.sh into
# Vendor/builds/. The lock names each archive (php-<series>-cli / -fpm, paddock-builds://<file>) with its
# checksum; this script requires those archives in Vendor/builds/, verifies them, and unpacks each
# series into Vendor/php/<series>/default/ with a build.json recording what it was unpacked from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/Scripts/versions.lock"
VENDOR="$ROOT/Vendor"
BUILDS="$VENDOR/builds"
MANIFEST="$ROOT/Resources/php-manifest.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$VENDOR"
touch "$LOCK"

fail() { echo "fetch-vendor.sh: $*" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

lock_field() { # name field(2=url,3=sha)
  awk -F'\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }' "$LOCK"
}

# fetch NAME RESOLVER_FUNCTION -> sets FETCHED to the downloaded file path
fetch() {
  local name="$1" resolver="$2" url sha file actual
  url="$(lock_field "$name" 2)"
  sha="$(lock_field "$name" 3)"
  file="$TMP/$name"
  if [ -n "$url" ]; then
    curl -fL --retry 3 -sS -o "$file" "$url"
    actual="$(sha256 "$file")"
    if [ "$actual" != "$sha" ]; then
      echo "Checksum mismatch for $name ($url): expected $sha, got $actual" >&2
      exit 1
    fi
  else
    url="$($resolver)"
    curl -fL --retry 3 -sS -o "$file" "$url"
    actual="$(sha256 "$file")"
    printf '%s\t%s\t%s\n' "$name" "$url" "$actual" >> "$LOCK"
    echo "Locked $name -> $url"
  fi
  FETCHED="$file"
}

resolve_caddy() {
  curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*_mac_amd64\.tar\.gz"' \
    | head -n 1 | sed -E 's/.*"(https[^"]*)"/\1/'
}

resolve_composer() { # versioned URL, so the locked checksum stays valid
  local path
  path="$(curl -fsSL https://getcomposer.org/versions | grep -o '"path": *"/download/[^"]*composer.phar"' | head -n 1 | sed -E 's/.*"(\/download[^"]*)"/\1/')"
  echo "https://getcomposer.org$path"
}

# Caddy
fetch caddy resolve_caddy
mkdir -p "$TMP/caddy-x" && tar -xzf "$FETCHED" -C "$TMP/caddy-x" caddy
install -m 755 "$TMP/caddy-x/caddy" "$VENDOR/caddy"

# Composer
fetch composer resolve_composer
install -m 644 "$FETCHED" "$VENDOR/composer.phar"

# PHP: Paddock's own builds, from Vendor/builds/
SERIES="$(awk -F'\t' '$1 ~ /^php-[0-9]+\.[0-9]+-cli$/ { s = $1; sub(/^php-/, "", s); sub(/-cli$/, "", s); print s }' "$LOCK")"
[ -n "$SERIES" ] || fail "Scripts/versions.lock names no PHP build (php-<series>-cli lines)."

# verified_build NAME -> sets ARCHIVE (verified path in Vendor/builds) and ARCHIVE_SHA
verified_build() {
  local name="$1" url sha file actual
  url="$(lock_field "$name" 2)"
  sha="$(lock_field "$name" 3)"
  [ -n "$url" ] && [ -n "$sha" ] || fail "Scripts/versions.lock has no $name line."
  case "$url" in
    paddock-builds://*) file="${url#paddock-builds://}" ;;
    *) fail "$name in Scripts/versions.lock is $url; PHP must come from Paddock's own builds (paddock-builds://)." ;;
  esac
  ARCHIVE="$BUILDS/$file"
  [ -f "$ARCHIVE" ] || fail "Vendor/builds/$file is missing. Build it with: Scripts/build-php.sh ${name%-*}" \
    "(about 30 minutes), or copy the archive there."
  actual="$(sha256 "$ARCHIVE")"
  [ "$actual" = "$sha" ] || fail "Vendor/builds/$file has checksum $actual; Scripts/versions.lock expects $sha."
  grep -q "\"$sha\"" "$MANIFEST" || fail "Resources/php-manifest.json does not list $file with checksum $sha."
  ARCHIVE_SHA="$sha"
}

bin_name() { if [ "$1" = fpm ]; then echo php-fpm; else echo php; fi; }

for series in $SERIES; do
  stage="$TMP/php-$series"
  mkdir -p "$stage"
  patch=""
  for kind in cli fpm; do
    verified_build "php-$series-$kind"
    tar -xzf "$ARCHIVE" -C "$stage" "$(bin_name $kind)"
    chmod 755 "$stage/$(bin_name $kind)"
    if [ "$kind" = cli ]; then CLI_SHA="$ARCHIVE_SHA"; else FPM_SHA="$ARCHIVE_SHA"; fi
    patch="$(basename "$ARCHIVE" | sed -E 's/^php-([0-9.]+)-(cli|fpm)-.*/\1/')"
  done
  # What this directory was unpacked from; Paddock copies it with the binaries (PHPBuildRecord).
  printf '{"patch":"%s","cliSHA256":"%s","fpmSHA256":"%s"}\n' "$patch" "$CLI_SHA" "$FPM_SHA" > "$stage/build.json"
  dest="$VENDOR/php/$series/default"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest.old"
  if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
  mv "$stage" "$dest"
  rm -rf "$dest.old"
  echo "PHP $patch unpacked into Vendor/php/$series/default."
done

# PostGIS: Paddock's own add-on for each PostgreSQL series, made by Scripts/build-postgis.sh into
# Vendor/builds/ and shipped in the app (a services-catalog.json paddock-builds:// asset). Checked only.
POSTGIS_NAMES="$(awk -F'\t' '$1 ~ /^postgis-pg[0-9]+$/ { print $1 }' "$LOCK")"
for name in $POSTGIS_NAMES; do
  url="$(lock_field "$name" 2)"
  sha="$(lock_field "$name" 3)"
  case "$url" in
    paddock-builds://*) file="${url#paddock-builds://}" ;;
    *) fail "$name in Scripts/versions.lock is $url; PostGIS must come from Paddock's own builds (paddock-builds://)." ;;
  esac
  [ -f "$BUILDS/$file" ] || fail "Vendor/builds/$file is missing. Build it with: Scripts/build-postgis.sh ${name#postgis-pg}" \
    "(about 20 minutes), or copy the archive there."
  actual="$(sha256 "$BUILDS/$file")"
  [ "$actual" = "$sha" ] || fail "Vendor/builds/$file has checksum $actual; Scripts/versions.lock expects $sha."
  grep -q "\"$sha\"" "$ROOT/Resources/services-catalog.json" \
    || fail "Resources/services-catalog.json does not list $file with checksum $sha."
  echo "PostGIS add-on $file verified."
done

# Valkey: Paddock's own build for the Redis (Valkey) service, made by Scripts/build-valkey.sh into
# Vendor/builds/ and shipped in the app (a services-catalog.json paddock-builds:// asset). Checked only.
url="$(lock_field valkey 2)"
sha="$(lock_field valkey 3)"
[ -n "$url" ] && [ -n "$sha" ] || fail "Scripts/versions.lock has no valkey line."
case "$url" in
  paddock-builds://*) file="${url#paddock-builds://}" ;;
  *) fail "valkey in Scripts/versions.lock is $url; Valkey must come from Paddock's own builds (paddock-builds://)." ;;
esac
[ -f "$BUILDS/$file" ] || fail "Vendor/builds/$file is missing. Build it with: Scripts/build-valkey.sh" \
  "(a few minutes), or copy the archive there."
actual="$(sha256 "$BUILDS/$file")"
[ "$actual" = "$sha" ] || fail "Vendor/builds/$file has checksum $actual; Scripts/versions.lock expects $sha."
echo "Valkey build $file verified."

# Router and manifest
ln -sfn ../Resources/router "$VENDOR/router"
cp "$MANIFEST" "$VENDOR/php-manifest.json"

echo "Vendor/ is ready."
