#!/usr/bin/env bash
#
# check-endpoints.sh — Checks HTTP(S) endpoints for reachability, status code
# and latency. Bash counterpart of powershell/Test-Endpoints.ps1.
#
# Category: Network
# Ask: @ | URL(s) to check, separated by spaces
#
# Usage:
#   ./check-endpoints.sh [options] URL [URL...]
#   ./check-endpoints.sh [options] -f FILE
#
# Options:
#   -f FILE      Read targets from FILE, one per line ('#' starts a comment)
#   -t SECONDS   Per-request timeout (default: 10)
#   -c CODE      Status code considered healthy (default: any 2xx or 3xx)
#   -j           Emit JSON instead of a table
#   -h           Show this help
#
# Exit codes:
#   0 all healthy · 1 at least one failed · 2 bad usage
#
# Examples:
#   ./check-endpoints.sh https://example.com https://api.example.com/health
#   ./check-endpoints.sh -f endpoints.txt -t 5
#   ./check-endpoints.sh -j https://example.com | jq '.endpoints[]'
#
# Requires: curl
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.2.0"

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

TIMEOUT=10
EXPECT_CODE=""
AS_JSON=0
INPUT_FILE=""

while getopts ":f:t:c:jh" opt; do
  case "$opt" in
    f) INPUT_FILE="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    c) EXPECT_CODE="$OPTARG" ;;
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

command -v curl >/dev/null 2>&1 || {
  echo "curl not found." >&2
  exit 2
}
case "$TIMEOUT" in '' | *[!0-9]*)
  echo "Timeout must be an integer." >&2
  exit 2
  ;;
esac

targets=("$@")
if [ -n "$INPUT_FILE" ]; then
  [ -r "$INPUT_FILE" ] || {
    echo "Cannot read file: $INPUT_FILE" >&2
    exit 2
  }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    if [ -n "$line" ]; then targets+=("$line"); fi
  done <"$INPUT_FILE"
fi

[ ${#targets[@]} -gt 0 ] || {
  echo "No endpoint given. Use -h for help." >&2
  exit 2
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

failures=0
rows=()

for url in "${targets[@]}"; do
  # A URL without scheme is assumed to be https
  case "$url" in http://* | https://*) ;; *) url="https://$url" ;; esac

  if out="$(curl -sS -o /dev/null -m "$TIMEOUT" -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"; then
    code="${out%% *}"
    time_s="${out##* }"
    ms="$(awk -v t="$time_s" 'BEGIN { printf "%.0f", t * 1000 }')"
    if [ -n "$EXPECT_CODE" ]; then
      [ "$code" = "$EXPECT_CODE" ] && status="ok" || status="unexpected-code"
    else
      case "$code" in 2?? | 3??) status="ok" ;; *) status="bad-status" ;; esac
    fi
  else
    code="000"
    ms="0"
    status="unreachable"
  fi

  [ "$status" = "ok" ] || failures=$((failures + 1))
  rows+=("$url|$code|$ms|$status")
done

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"checked":%d,"failed":%d,"endpoints":[' "${#targets[@]}" "$failures"
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r url code ms status <<<"$row"
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    # '000' (unreachable) is not a valid JSON number: leading zeros are illegal.
    # 10# forces base ten — without it '008' would be read as octal and fail.
    printf '{"url":"%s","status_code":%s,"latency_ms":%s,"status":"%s"}' \
      "$(json_escape "$url")" "$((10#$code))" "$ms" "$status"
  done
  printf ']}\n'
else
  printf '%-52s %6s %10s  %s\n' "ENDPOINT" "CODE" "LATENCY" "STATUS"
  for row in "${rows[@]}"; do
    IFS='|' read -r url code ms status <<<"$row"
    printf '%-52s %6s %8sms  %s\n' "$url" "$code" "$ms" "$status"
  done
  echo
  echo "Checked ${#targets[@]} endpoint(s); $failures failed."
fi

[ "$failures" -eq 0 ] || exit 1
