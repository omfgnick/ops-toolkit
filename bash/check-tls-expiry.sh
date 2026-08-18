#!/usr/bin/env bash
#
# check-tls-expiry.sh — Reports how many days remain on the TLS certificate of
# each host. Bash counterpart of powershell/Get-TLSCertExpiry.ps1.
#
# Usage:
#   ./check-tls-expiry.sh [options] HOST[:PORT] [HOST[:PORT]...]
#   ./check-tls-expiry.sh [options] -f FILE
#
# Options:
#   -f FILE      Read hosts from FILE, one per line ('#' starts a comment)
#   -w DAYS      Warn at or below DAYS remaining (default: 30)
#   -t SECONDS   Connection timeout (default: 10)
#   -j           Emit JSON instead of a table
#   -h           Show this help
#
# Exit codes:
#   0 all above the warning window · 1 at least one expiring or failed · 2 bad usage
#
# Examples:
#   ./check-tls-expiry.sh example.com github.com:443
#   ./check-tls-expiry.sh -w 45 -f hosts.txt
#   ./check-tls-expiry.sh -j example.com | jq '.hosts[]'
#
# Requires: openssl
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

WARN_DAYS=30
TIMEOUT=10
AS_JSON=0
INPUT_FILE=""

while getopts ":f:w:t:jh" opt; do
  case "$opt" in
    f) INPUT_FILE="$OPTARG" ;;
    w) WARN_DAYS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
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

command -v openssl >/dev/null 2>&1 || {
  echo "openssl not found." >&2
  exit 2
}
for v in "$WARN_DAYS" "$TIMEOUT"; do
  case "$v" in '' | *[!0-9]*)
    echo "Day/second values must be integers." >&2
    exit 2
    ;;
  esac
done

hosts=("$@")
if [ -n "$INPUT_FILE" ]; then
  [ -r "$INPUT_FILE" ] || {
    echo "Cannot read file: $INPUT_FILE" >&2
    exit 2
  }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && hosts+=("$line")
  done <"$INPUT_FILE"
fi

[ ${#hosts[@]} -gt 0 ] || {
  echo "No host given. Use -h for help." >&2
  exit 2
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

problems=0
rows=()
now_epoch="$(date +%s)"

for entry in "${hosts[@]}"; do
  host="${entry%%:*}"
  port="${entry##*:}"
  [ "$port" = "$entry" ] && port=443

  end_date=""
  if cert="$(echo | timeout "$TIMEOUT" openssl s_client -servername "$host" -connect "$host:$port" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)"; then
    end_date="${cert#notAfter=}"
  fi

  if [ -z "$end_date" ]; then
    rows+=("$host|$port|-|-|unreachable")
    problems=$((problems + 1))
    continue
  fi

  if ! end_epoch="$(date -d "$end_date" +%s 2>/dev/null)"; then
    rows+=("$host|$port|$end_date|-|unparsed-date")
    problems=$((problems + 1))
    continue
  fi

  days_left=$(((end_epoch - now_epoch) / 86400))
  if [ "$days_left" -lt 0 ]; then
    status="EXPIRED"
    problems=$((problems + 1))
  elif [ "$days_left" -le "$WARN_DAYS" ]; then
    status="EXPIRING"
    problems=$((problems + 1))
  else
    status="ok"
  fi
  rows+=("$host|$port|$end_date|$days_left|$status")
done

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"warn_days":%d,"problems":%d,"hosts":[' "$WARN_DAYS" "$problems"
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r host port expires days status <<<"$row"
    [ $first -eq 0 ] && printf ','
    first=0
    if [ "$days" = "-" ]; then days_json=null; else days_json="$days"; fi
    printf '{"host":"%s","port":%s,"expires":"%s","days_left":%s,"status":"%s"}' \
      "$(json_escape "$host")" "$port" "$(json_escape "$expires")" "$days_json" "$status"
  done
  printf ']}\n'
else
  printf '%-34s %6s %-26s %6s  %s\n' "HOST" "PORT" "EXPIRES" "DAYS" "STATUS"
  for row in "${rows[@]}"; do
    IFS='|' read -r host port expires days status <<<"$row"
    printf '%-34s %6s %-26s %6s  %s\n' "$host" "$port" "$expires" "$days" "$status"
  done
  echo
  echo "Checked ${#hosts[@]} host(s); $problems need attention (window: ${WARN_DAYS}d)."
fi

[ "$problems" -eq 0 ] || exit 1
