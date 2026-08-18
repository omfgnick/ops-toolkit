#!/usr/bin/env bash
#
# rotate-logs.sh — Compresses log files older than N days and deletes archives
# older than a retention window. Bash counterpart of powershell/Rotate-Logs.ps1.
#
# Nothing is touched without -f: the default is a dry run, because this script
# deletes files.
#
# Usage:
#   ./rotate-logs.sh -d DIRECTORY [options]
#
# Options:
#   -d DIR       Directory holding the logs (required)
#   -p PATTERN   Filename pattern to rotate (default: *.log)
#   -a DAYS      Compress files older than DAYS (default: 7)
#   -k DAYS      Delete .gz archives older than DAYS (default: 90)
#   -f           Actually apply changes (without it, nothing is modified)
#   -j           Emit JSON instead of a table
#   -h           Show this help
#
# Exit codes:
#   0 success · 1 runtime failure · 2 bad usage
#
# Examples:
#   ./rotate-logs.sh -d /var/log/myapp              # dry run, shows the plan
#   ./rotate-logs.sh -d /var/log/myapp -a 3 -k 30 -f
#
# Requires: find, gzip
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

DIR=""
PATTERN="*.log"
AGE_DAYS=7
KEEP_DAYS=90
APPLY=0
AS_JSON=0

while getopts ":d:p:a:k:fjh" opt; do
  case "$opt" in
    d) DIR="$OPTARG" ;;
    p) PATTERN="$OPTARG" ;;
    a) AGE_DAYS="$OPTARG" ;;
    k) KEEP_DAYS="$OPTARG" ;;
    f) APPLY=1 ;;
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

[ -n "$DIR" ] || {
  echo "Option -d (directory) is required. Use -h for help." >&2
  exit 2
}
[ -d "$DIR" ] || {
  echo "Directory does not exist: $DIR" >&2
  exit 2
}
for v in "$AGE_DAYS" "$KEEP_DAYS"; do
  case "$v" in '' | *[!0-9]*)
    echo "Day counts must be integers." >&2
    exit 2
    ;;
  esac
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

compressed=0
deleted=0
failed=0
actions=()

# ---- Compress old logs -------------------------------------------------------
while IFS= read -r -d '' file; do
  if [ "$APPLY" -eq 1 ]; then
    if gzip -f -- "$file" 2>/dev/null; then
      actions+=("compress|$file|done")
      compressed=$((compressed + 1))
    else
      actions+=("compress|$file|failed")
      failed=$((failed + 1))
    fi
  else
    actions+=("compress|$file|planned")
    compressed=$((compressed + 1))
  fi
done < <(find "$DIR" -type f -name "$PATTERN" ! -name '*.gz' -mtime +"$AGE_DAYS" -print0 2>/dev/null)

# ---- Drop archives past retention -------------------------------------------
while IFS= read -r -d '' file; do
  if [ "$APPLY" -eq 1 ]; then
    if rm -f -- "$file" 2>/dev/null; then
      actions+=("delete|$file|done")
      deleted=$((deleted + 1))
    else
      actions+=("delete|$file|failed")
      failed=$((failed + 1))
    fi
  else
    actions+=("delete|$file|planned")
    deleted=$((deleted + 1))
  fi
done < <(find "$DIR" -type f -name '*.gz' -mtime +"$KEEP_DAYS" -print0 2>/dev/null)

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"directory":"%s","applied":%s,"compressed":%d,"deleted":%d,"failed":%d,"actions":[' \
    "$(json_escape "$DIR")" "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
    "$compressed" "$deleted" "$failed"
  first=1
  for a in "${actions[@]}"; do
    IFS='|' read -r kind path result <<<"$a"
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    printf '{"action":"%s","path":"%s","result":"%s"}' \
      "$kind" "$(json_escape "$path")" "$result"
  done
  printf ']}\n'
else
  if [ "$APPLY" -eq 0 ]; then
    echo "DRY RUN — nothing was modified. Add -f to apply."
    echo
  fi
  if [ ${#actions[@]} -eq 0 ]; then
    echo "Nothing to do in $DIR."
  else
    printf '%-10s %-10s %s\n' "ACTION" "RESULT" "PATH"
    for a in "${actions[@]}"; do
      IFS='|' read -r kind path result <<<"$a"
      printf '%-10s %-10s %s\n' "$kind" "$result" "$path"
    done
  fi
  echo
  echo "compressed=$compressed deleted=$deleted failed=$failed"
fi

[ "$failed" -eq 0 ] || exit 1
