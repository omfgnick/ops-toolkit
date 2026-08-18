#!/usr/bin/env bash
#
# check-services.sh — Checks systemd services and optionally restarts the ones
# that are down. Bash counterpart of powershell/Test-ServiceHealth.ps1.
#
# Usage:
#   ./check-services.sh [options] SERVICE [SERVICE...]
#   ./check-services.sh [options] -f FILE
#
# Options:
#   -f FILE      Read service names from FILE, one per line ('#' starts a comment)
#   -r           Restart services found not running
#   -n           Dry run: report what would be restarted, change nothing
#   -j           Emit JSON instead of a table
#   -h           Show this help
#
# Exit codes:
#   0 all services running · 1 at least one down · 2 bad usage
#
# Examples:
#   ./check-services.sh nginx ssh
#   ./check-services.sh -f services.txt -r
#   ./check-services.sh -j nginx | jq .
#
# Requires: systemctl
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

RESTART=0
DRY_RUN=0
AS_JSON=0
INPUT_FILE=""

while getopts ":f:rnjh" opt; do
  case "$opt" in
    f) INPUT_FILE="$OPTARG" ;;
    r) RESTART=1 ;;
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
shift $((OPTIND - 1))

# getopts stops at the first operand: an option after it would silently be
# treated as an argument (e.g. "host -j" would print a table, not JSON).
for _arg in "$@"; do
  case "$_arg" in
    -*)
      echo "Options must come before arguments: '$_arg'. Use -h for help." >&2
      exit 2
      ;;
  esac
done

command -v systemctl >/dev/null 2>&1 || {
  echo "systemctl not found; this script needs systemd." >&2
  exit 2
}

services=("$@")
if [ -n "$INPUT_FILE" ]; then
  [ -r "$INPUT_FILE" ] || {
    echo "Cannot read file: $INPUT_FILE" >&2
    exit 2
  }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    if [ -n "$line" ]; then services+=("$line"); fi
  done <"$INPUT_FILE"
fi

if [ ${#services[@]} -eq 0 ]; then
  echo "No service given. Use -h for help." >&2
  exit 2
fi

# Escapes the few characters JSON forbids in a string.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

failures=0
rows=()

for svc in "${services[@]}"; do
  state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  [ -n "$state" ] || state="unknown"
  action="none"

  if [ "$state" != "active" ]; then
    failures=$((failures + 1))
    if [ "$RESTART" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        action="would-restart"
      elif systemctl restart "$svc" >/dev/null 2>&1; then
        action="restarted"
        state="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
        if [ "$state" = "active" ]; then failures=$((failures - 1)); fi
      else
        action="restart-failed"
      fi
    fi
  fi

  rows+=("$svc|$state|$action")
done

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"checked":%d,"down":%d,"services":[' "${#services[@]}" "$failures"
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r name state action <<<"$row"
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    printf '{"name":"%s","state":"%s","action":"%s"}' \
      "$(json_escape "$name")" "$(json_escape "$state")" "$(json_escape "$action")"
  done
  printf ']}\n'
else
  printf '%-28s %-12s %s\n' "SERVICE" "STATE" "ACTION"
  for row in "${rows[@]}"; do
    IFS='|' read -r name state action <<<"$row"
    printf '%-28s %-12s %s\n' "$name" "$state" "$action"
  done
  echo
  echo "Checked ${#services[@]} service(s); $failures not running."
fi

[ "$failures" -eq 0 ] || exit 1
