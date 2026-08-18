#!/usr/bin/env bash
#
# backup-verify.sh — Creates a compressed backup and verifies it by restoring
# into a temporary directory and comparing checksums, file by file, against the
# source.
#
# That is the difference from backup-folder.sh: here the backup is only
# considered good after it has been restored. A backup that was never restored
# is not a backup — it is a large file taken on faith.
#
# Usage:
#   ./backup-verify.sh -s SOURCE -d DEST [options]
#
# Options:
#   -s DIR       Source directory (required)
#   -d DIR       Where to write the .tar.gz (required; created if missing)
#   -k N         Keep the N most recent backups of this set (0 = keep all)
#   -n           Dry run: show what would happen, create or delete nothing
#   -j           Emit JSON instead of the readable report
#   -h           Show this help
#
# Exit codes:
#   0 backup created and verified · 1 creation or verification failed · 2 bad usage
#
# Examples:
#   ./backup-verify.sh -s /etc -d /backup
#   ./backup-verify.sh -s /var/www -d /backup -k 7
#   ./backup-verify.sh -s /etc -d /backup -j | jq '.verification'
#
# Requires: tar, gzip, sha256sum
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.0.0"

# --version / --help before getopts: getopts only understands single-letter
# options, and these two are what people reach for by reflex.
case "${1:-}" in
  --version)
    echo "$(basename "$0") (ops-toolkit) $OPS_TOOLKIT_VERSION"
    exit 0
    ;;
  --help)
    usage
    exit 0
    ;;
esac

SRC=""
DST=""
KEEP=0
DRY_RUN=0
AS_JSON=0

while getopts ":s:d:k:njh" opt; do
  case "$opt" in
    s) SRC="$OPTARG" ;;
    d) DST="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    j) AS_JSON=1 ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 2
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      exit 2
      ;;
  esac
done

[ -n "$SRC" ] && [ -n "$DST" ] || {
  echo "-s (source) and -d (destination) are required. Use -h." >&2
  exit 2
}
[ -d "$SRC" ] || {
  echo "Source does not exist: $SRC" >&2
  exit 2
}
case "$KEEP" in '' | *[!0-9]*)
  echo "-k must be an integer." >&2
  exit 2
  ;;
esac
for tool in tar gzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool not found." >&2
    exit 2
  }
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

BASE="$(basename "$(cd "$SRC" && pwd)")"
STAMP="$(date '+%Y-%m-%d_%H%M%S')"
ARCHIVE="$DST/${BASE}-${STAMP}.tar.gz"

# Count what is in the source, for the report and for the comparison
src_files=$(find "$SRC" -type f | wc -l)
src_bytes=$(du -sb "$SRC" 2>/dev/null | cut -f1 || echo 0)

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"dry_run":true,"source":"%s","archive":"%s","source_files":%s,"source_bytes":%s,"verification":null}\n' \
      "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")" "$src_files" "$src_bytes"
  else
    echo "DRY RUN — nothing was created."
    echo "  source    : $SRC ($src_files file(s), $src_bytes bytes)"
    echo "  would create: $ARCHIVE"
    [ "$KEEP" -gt 0 ] && echo "  retention : would keep the $KEEP most recent"
  fi
  exit 0
fi

mkdir -p "$DST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. Create ---------------------------------------------------------------
created=false
if tar -czf "$ARCHIVE" -C "$(dirname "$SRC")" "$(basename "$SRC")" 2>"$WORK/tar.err"; then
  created=true
else
  # tar warns when a file changes while being read; that does not invalidate the
  # backup, and the verification below is what gives the verdict.
  if [ -s "$ARCHIVE" ]; then
    created=true
    echo "warning: tar reported: $(head -1 "$WORK/tar.err")" >&2
  fi
fi

if [ "$created" != true ]; then
  echo "ERROR: failed to create the archive." >&2
  [ "$AS_JSON" -eq 1 ] && printf '{"dry_run":false,"source":"%s","archive":"%s","created":false,"verification":null}\n' \
    "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")"
  exit 1
fi

archive_bytes=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)

# ---- 2. Restore and compare --------------------------------------------------
# This is where the backup stops being an assumption.
restored_dir="$WORK/restore"
mkdir -p "$restored_dir"
verified=false
compared=0
mismatched=0
mismatch_examples=""

if tar -xzf "$ARCHIVE" -C "$restored_dir" 2>/dev/null; then
  src_root="$(cd "$SRC" && pwd)"
  rest_root="$restored_dir/$(basename "$SRC")"
  while IFS= read -r file; do
    rel="${file#"$src_root"/}"
    other="$rest_root/$rel"
    compared=$((compared + 1))
    if [ ! -f "$other" ]; then
      mismatched=$((mismatched + 1))
      [ "$mismatched" -le 5 ] && mismatch_examples="${mismatch_examples}missing: $rel"$'\n'
      continue
    fi
    a="$(sha256sum "$file" | cut -d' ' -f1)"
    b="$(sha256sum "$other" | cut -d' ' -f1)"
    if [ "$a" != "$b" ]; then
      mismatched=$((mismatched + 1))
      [ "$mismatched" -le 5 ] && mismatch_examples="${mismatch_examples}differs: $rel"$'\n'
    fi
  done < <(find "$src_root" -type f)
  [ "$mismatched" -eq 0 ] && verified=true
else
  echo "ERROR: the archive could not be extracted — backup unusable." >&2
fi

# ---- 3. Retention (only after verification passes) ---------------------------
removed=0
if [ "$KEEP" -gt 0 ] && [ "$verified" = true ]; then
  while IFS= read -r old; do
    rm -f -- "$old" && removed=$((removed + 1))
  done < <(find "$DST" -maxdepth 1 -type f -name "${BASE}-*.tar.gz" -printf '%T@ %p\n' |
    sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
fi

# ---- Report ------------------------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  printf '{"dry_run":false,"source":"%s","archive":"%s","created":true,' \
    "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")"
  printf '"source_files":%s,"source_bytes":%s,"archive_bytes":%s,' \
    "$src_files" "$src_bytes" "$archive_bytes"
  printf '"verification":{"restored":%s,"files_compared":%d,"mismatched":%d},' \
    "$([ "$verified" = true ] && echo true || echo false)" "$compared" "$mismatched"
  printf '"removed_by_retention":%d}\n' "$removed"
else
  echo "Backup: $ARCHIVE"
  echo "  source       : $SRC ($src_files file(s), $src_bytes bytes)"
  echo "  archive      : $archive_bytes bytes"
  echo "  verification : $compared file(s) restored and checked with sha256"
  if [ "$verified" = true ]; then
    echo "  result       : OK — restored and identical to the source"
  else
    echo "  result       : FAILED — $mismatched mismatch(es)"
    [ -n "$mismatch_examples" ] && printf '%s' "$mismatch_examples" | sed 's/^/      /'
  fi
  [ "$removed" -gt 0 ] && echo "  retention    : $removed old backup(s) removed"
fi

[ "$verified" = true ]
