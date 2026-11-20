#!/bin/bash
# Downloads the programs Paddock bundles into Vendor/.
#
# First run: resolves the latest Caddy 2.x, composer.phar and PHP 8.5 (cli + fpm),
# downloads them and records "name<TAB>url<TAB>sha256" in Scripts/versions.lock.
# Later runs: downloads exactly the URLs in the lock and fails on a checksum mismatch.
# To upgrade, delete the relevant lines (or the whole file) and run again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/Scripts/versions.lock"
VENDOR="$ROOT/Vendor"
PHP_SERIES="8.5"
STATIC_PHP_BASE="https://dl.static-php.dev/static-php-cli/bulk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$VENDOR"
touch "$LOCK"

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

resolve_php() { # $1 = cli|fpm
  curl -fsSL "$STATIC_PHP_BASE/?format=json" \
    | grep -o "\"name\": *\"php-$PHP_SERIES\.[0-9]*-$1-macos-x86_64\.tar\.gz\"" \
    | sed -E 's/.*"(php-[^"]*)"/\1/' \
    | sort -t. -k3 -n | tail -n 1 \
    | sed "s#^#$STATIC_PHP_BASE/#"
}
resolve_php_cli() { resolve_php cli; }
resolve_php_fpm() { resolve_php fpm; }

# Caddy
fetch caddy resolve_caddy
mkdir -p "$TMP/caddy-x" && tar -xzf "$FETCHED" -C "$TMP/caddy-x" caddy
install -m 755 "$TMP/caddy-x/caddy" "$VENDOR/caddy"

# Composer
fetch composer resolve_composer
install -m 644 "$FETCHED" "$VENDOR/composer.phar"

# PHP
PHP_DIR="$VENDOR/php/$PHP_SERIES/default"
mkdir -p "$PHP_DIR"
for kind in cli fpm; do
  fetch "php-$PHP_SERIES-$kind" "resolve_php_$kind"
  mkdir -p "$TMP/php-$kind-x" && tar -xzf "$FETCHED" -C "$TMP/php-$kind-x"
  bin="php"; [ "$kind" = fpm ] && bin="php-fpm"
  install -m 755 "$TMP/php-$kind-x/$bin" "$PHP_DIR/$bin"
done

# Router and manifest
ln -sfn ../Resources/router "$VENDOR/router"
cp "$ROOT/Resources/php-manifest.json" "$VENDOR/php-manifest.json"

echo "Vendor/ is ready."
