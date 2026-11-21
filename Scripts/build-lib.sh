# Shell functions shared by Paddock's build scripts (build-php.sh, build-postgis.sh, build-valkey.sh), which
# source this file. Each script defines fail() before sourcing it. Nothing here runs on its own.

# build_host_names: prints this Mac's host names, one per line, for the privacy check: `hostname -s`, which
# must answer with a name, and the LocalHostName and ComputerName that scutil reports. scutil is optional
# only when it is not installed; when it is, a failure to answer fails the build (a name left out would
# let it slip into an archive unnoticed).
build_host_names() {
  local name key
  name="$(hostname -s)" || fail "hostname -s failed; the privacy check needs this Mac's host name."
  [ -n "$name" ] || fail "hostname -s printed nothing; the privacy check needs this Mac's host name."
  echo "$name"
  if command -v scutil >/dev/null; then
    for key in LocalHostName ComputerName; do
      name="$(scutil --get "$key")" || fail "scutil --get $key failed; the privacy check needs this Mac's names."
      [ -n "$name" ] || fail "scutil --get $key printed nothing; the privacy check needs this Mac's names."
      echo "$name"
    done
  fi
}

# newest_mtime DIR: the newest modification time (seconds since 1970) of the files in DIR, such as a
# verified source tree unpacked from its pinned tarball: a date that is the same on every build of it.
newest_mtime() {
  local dir="$1" times newest=0 t
  [ -d "$dir" ] || fail "newest_mtime: $dir is not a folder"
  times="$(find "$dir" -type f -exec stat -f %m {} +)" || fail "could not read the file times in $dir"
  while IFS= read -r t; do
    if [ -n "$t" ] && [ "$t" -gt "$newest" ]; then newest="$t"; fi
  done <<< "$times"
  [ "$newest" -gt 0 ] || fail "newest_mtime: no files in $dir"
  echo "$newest"
}

# reproducible_archive DIR EPOCH OUT ENTRY...: writes OUT (a .tar.gz) holding ENTRY... (paths relative to DIR,
# with everything under them) so that the same files always give the same bytes: every file and folder
# gets the time EPOCH and the modes u=rwX,go=rX, entries are listed in byte order, owned by root:wheel, in
# plain ustar (no extended headers, extended attributes, ACLs, flags or AppleDouble files), and the gzip
# header carries no time or name. DIR's contents are modified (times and modes). OUT is written beside
# itself as OUT.part and moved into place only when complete.
reproducible_archive() {
  local dir="$1" epoch="$2" out="$3" stamp list sorted
  shift 3
  [ "$#" -gt 0 ] || fail "reproducible_archive: nothing to archive"
  [ -d "$dir" ] || fail "reproducible_archive: $dir is not a folder"
  case "$epoch" in ''|*[!0-9]*) fail "reproducible_archive: '$epoch' is not a time in seconds" ;; esac
  stamp="$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)" || fail "reproducible_archive: bad time $epoch"
  list="$out.list"
  sorted="$out.sorted"
  (cd "$dir" && find "$@" -print0) > "$list" || fail "could not list the files for $out"
  [ -s "$list" ] || fail "reproducible_archive: no files for $out"
  LC_ALL=C sort -z "$list" > "$sorted" || fail "could not sort the files for $out"
  (cd "$dir" && chmod -R u=rwX,go=rX "$@") || fail "could not set the modes of the files for $out"
  (cd "$dir" && TZ=UTC xargs -0 touch -h -t "$stamp" < "$sorted") || fail "could not set the times of the files for $out"
  COPYFILE_DISABLE=1 tar -C "$dir" --format ustar --uid 0 --gid 0 --uname root --gname wheel \
    --no-mac-metadata --no-xattrs --no-acls --no-fflags --options 'gzip:!timestamp' \
    -n --null -T "$sorted" -czf "$out.part" || fail "could not write $out"
  rm -f "$list" "$sorted"
  mv "$out.part" "$out" || fail "could not move $out into place"
}
