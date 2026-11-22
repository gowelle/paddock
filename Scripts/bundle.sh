#!/bin/bash
# Builds Paddock for Intel and assembles the standalone dist/Paddock.app:
#   Contents/MacOS/{PaddockApp,paddockd,paddock,paddock-ports}
# (The app's executable is not called "Paddock": on a case-insensitive disk it would be the same file
# as the "paddock" command.)
#   Contents/Resources/{caddy,composer.phar,router/,php/<bundled>/default/,builds/,php-manifest.json,services-catalog.json,LICENSE,THIRD-PARTY-NOTICES,AppIcon.icns}
# builds/ holds Paddock's own PHP archives (every version in the manifest, from Vendor/builds/), so
# installing another version needs no network, and its PostGIS add-ons for PostgreSQL (postgis-pg<series>
# in the lock) and its Valkey build for the Redis (Valkey) service (valkey in the lock); php/<bundled>/default/
# is the newest PHP, unpacked.
# then signs it ad hoc and verifies the signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
LOCK="$ROOT/Scripts/versions.lock"
APP="$ROOT/dist/Paddock.app"

fail() { echo "bundle.sh: $*" >&2; exit 1; }

# The PHP series the app ships unpacked is the newest one locked (php-<series>-cli).
PHP_SERIES="$(awk -F'\t' '$1 ~ /^php-[0-9]+\.[0-9]+-cli$/ { sub(/^php-/, "", $1); sub(/-cli$/, "", $1); print $1 }' "$LOCK" 2>/dev/null \
  | sort -t. -k1,1n -k2,2n | tail -n 1 || true)"
[ -n "$PHP_SERIES" ] || fail "Scripts/versions.lock names no PHP build. Run Scripts/fetch-vendor.sh first."
# Every PHP archive the lock names (paddock-builds://<file>), with its checksum.
PHP_ARCHIVES="$(awk -F'\t' '$1 ~ /^php-[0-9]+\.[0-9]+-(cli|fpm)$/ && $2 ~ /^paddock-builds:\/\// { sub(/^paddock-builds:\/\//, "", $2); print $2 "\t" $3 }' "$LOCK")"
[ -n "$PHP_ARCHIVES" ] || fail "Scripts/versions.lock names no paddock-builds:// PHP archive."
# Paddock's PostGIS add-ons (postgis-pg<series>), with their checksums.
POSTGIS_ARCHIVES="$(awk -F'\t' '$1 ~ /^postgis-pg[0-9]+$/ && $2 ~ /^paddock-builds:\/\// { sub(/^paddock-builds:\/\//, "", $2); print $2 "\t" $3 }' "$LOCK")"
[ -n "$POSTGIS_ARCHIVES" ] || fail "Scripts/versions.lock names no paddock-builds:// PostGIS add-on."
# Paddock's Valkey build (valkey), with its checksum.
VALKEY_ARCHIVES="$(awk -F'\t' '$1 == "valkey" && $2 ~ /^paddock-builds:\/\// { sub(/^paddock-builds:\/\//, "", $2); print $2 "\t" $3 }' "$LOCK")"
[ -n "$VALKEY_ARCHIVES" ] || fail "Scripts/versions.lock names no paddock-builds:// Valkey build."
# Paddock's Xdebug for each PHP series (xdebug-<series>), with their checksums.
XDEBUG_ARCHIVES="$(awk -F'\t' '$1 ~ /^xdebug-[0-9]+\.[0-9]+$/ && $2 ~ /^paddock-builds:\/\// { sub(/^paddock-builds:\/\//, "", $2); print $2 "\t" $3 }' "$LOCK")"
[ -n "$XDEBUG_ARCHIVES" ] || fail "Scripts/versions.lock names no paddock-builds:// Xdebug build."

for item in caddy composer.phar php-manifest.json router/server.php "php/$PHP_SERIES/default/php" "php/$PHP_SERIES/default/php-fpm" "php/$PHP_SERIES/default/build.json"; do
  [ -e "$VENDOR/$item" ] || fail "Vendor/$item is missing. Run Scripts/fetch-vendor.sh first."
done
[ -f "$ROOT/VERSION" ] || fail "VERSION is missing at the repository root."
[ -f "$ROOT/Resources/services-catalog.json" ] || fail "Resources/services-catalog.json is missing."
[ -f "$ROOT/Resources/AppIcon.icns" ] || fail "Resources/AppIcon.icns is missing. Run: swift Scripts/make-icon.swift"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "Building release binaries for x86_64…"
swift build --package-path "$ROOT" -c release --arch x86_64
BIN="$(swift build --package-path "$ROOT" -c release --arch x86_64 --show-bin-path)"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/php/$PHP_SERIES/default" "$APP/Contents/Resources/builds"

install -m 755 "$BIN/PaddockApp" "$APP/Contents/MacOS/PaddockApp"
install -m 755 "$BIN/paddockd" "$APP/Contents/MacOS/paddockd"
install -m 755 "$BIN/paddock" "$APP/Contents/MacOS/paddock"
# The port helper the setup prompt installs as /Library/PrivilegedHelperTools/app.paddock.ports.
install -m 755 "$BIN/paddock-ports" "$APP/Contents/MacOS/paddock-ports"

RES="$APP/Contents/Resources"
install -m 755 "$VENDOR/caddy" "$RES/caddy"
install -m 644 "$VENDOR/composer.phar" "$RES/composer.phar"
install -m 644 "$VENDOR/php-manifest.json" "$RES/php-manifest.json"
# The services Paddock can add; they are downloaded from their publishers when added, not bundled.
plutil -convert json -o /dev/null "$ROOT/Resources/services-catalog.json" \
  || fail "Resources/services-catalog.json is not valid JSON."
install -m 644 "$ROOT/Resources/services-catalog.json" "$RES/services-catalog.json"
install -m 644 "$ROOT/LICENSE" "$RES/LICENSE"
install -m 644 "$ROOT/THIRD-PARTY-NOTICES" "$RES/THIRD-PARTY-NOTICES"
# Built from Resources/AppIcon.svg by Scripts/make-icon.swift.
install -m 644 "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
# Vendor/router is a symlink into Resources/; copy real files.
cp -RL "$VENDOR/router" "$RES/router"
# Only the bundled series: Vendor/php may hold other versions cached for tests.
install -m 755 "$VENDOR/php/$PHP_SERIES/default/php" "$RES/php/$PHP_SERIES/default/php"
install -m 755 "$VENDOR/php/$PHP_SERIES/default/php-fpm" "$RES/php/$PHP_SERIES/default/php-fpm"
install -m 644 "$VENDOR/php/$PHP_SERIES/default/build.json" "$RES/php/$PHP_SERIES/default/build.json"
BUNDLED_MODULES="$("$RES/php/$PHP_SERIES/default/php" -n -m)"
if grep -qix swoole <<< "$BUNDLED_MODULES"; then
  fail "the bundled PHP contains Swoole; Paddock ships only its own builds (Scripts/build-php.sh)."
fi
# Paddock's own PHP archives, verified against the lock.
while IFS=$'\t' read -r file sha; do
  [ -f "$VENDOR/builds/$file" ] || fail "Vendor/builds/$file is missing. Build it with Scripts/build-php.sh."
  [ "$(shasum -a 256 "$VENDOR/builds/$file" | awk '{print $1}')" = "$sha" ] \
    || fail "Vendor/builds/$file does not match the checksum in Scripts/versions.lock."
  install -m 644 "$VENDOR/builds/$file" "$RES/builds/$file"
done <<< "$PHP_ARCHIVES"
# Paddock's PostGIS add-ons, verified against the lock.
while IFS=$'\t' read -r file sha; do
  [ -f "$VENDOR/builds/$file" ] || fail "Vendor/builds/$file is missing. Build it with Scripts/build-postgis.sh."
  [ "$(shasum -a 256 "$VENDOR/builds/$file" | awk '{print $1}')" = "$sha" ] \
    || fail "Vendor/builds/$file does not match the checksum in Scripts/versions.lock."
  install -m 644 "$VENDOR/builds/$file" "$RES/builds/$file"
done <<< "$POSTGIS_ARCHIVES"
# Paddock's Valkey build, verified against the lock.
while IFS=$'\t' read -r file sha; do
  [ -f "$VENDOR/builds/$file" ] || fail "Vendor/builds/$file is missing. Build it with Scripts/build-valkey.sh."
  [ "$(shasum -a 256 "$VENDOR/builds/$file" | awk '{print $1}')" = "$sha" ] \
    || fail "Vendor/builds/$file does not match the checksum in Scripts/versions.lock."
  install -m 644 "$VENDOR/builds/$file" "$RES/builds/$file"
done <<< "$VALKEY_ARCHIVES"
# Paddock's Xdebug for each PHP series, the same way: switching it on needs no network.
while IFS=$'\t' read -r file sha; do
  [ -f "$VENDOR/builds/$file" ] || fail "Vendor/builds/$file is missing. Build it with Scripts/build-xdebug.sh."
  [ "$(shasum -a 256 "$VENDOR/builds/$file" | awk '{print $1}')" = "$sha" ] \
    || fail "Vendor/builds/$file does not match the checksum in Scripts/versions.lock."
  install -m 644 "$VENDOR/builds/$file" "$RES/builds/$file"
done <<< "$XDEBUG_ARCHIVES"

sed "s/VERSION_PLACEHOLDER/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Signing (ad hoc)…"
# Nested executables first, then the bundle, which seals everything inside it.
for exe in "$RES/caddy" "$RES/php/$PHP_SERIES/default/php" "$RES/php/$PHP_SERIES/default/php-fpm" \
           "$APP/Contents/MacOS/paddockd" "$APP/Contents/MacOS/paddock" "$APP/Contents/MacOS/paddock-ports"; do
  codesign --force -s - "$exe"
done
codesign --force -s - --deep "$APP"
codesign --verify --deep --strict "$APP"

cp "$ROOT/LICENSE" "$ROOT/dist/LICENSE.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Paddock-$VERSION.zip"

echo "dist/Paddock.app is ready (version $VERSION, PHP $PHP_SERIES)."
