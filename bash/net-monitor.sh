#!/usr/bin/env bash
#
# net-monitor.sh — Measures reachability and latency to a set of hosts and
# optionally checks TCP ports, flagging anything above a latency threshold or
# losing packets. Built for link/carrier monitoring in a NOC routine.
#
# Read-only: this script never changes anything.
#
# Usage:
#   ./net-monitor.sh [options] HOST [HOST...]
#   ./net-monitor.sh [options] -f FILE
#
# Options:
#   -f FILE      Read hosts from FILE, one per line ('#' starts a comment)
#   -c COUNT     Pings per host (default: 4)
#   -l MS        Flag hosts whose average latency is above MS (default: 150)
#   -p PORTS     Also test these TCP ports, comma separated (e.g. 22,443)
#   -j           Emit JSON instead of a table
#   -h           Show this help
#
# Exit codes:
#   0 all healthy · 1 loss, high latency or closed port · 2 bad usage
#
# Examples:
#   ./net-monitor.sh 8.8.8.8 1.1.1.1
#   ./net-monitor.sh -f links.txt -l 80 -p 443
#   ./net-monitor.sh -j gateway.local | jq '.hosts[] | select(.loss_percent > 0)'
#
# Requires: ping. Port checks use bash /dev/tcp (no extra tooling).
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.1.0"

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

COUNT=4
MAX_MS=150
PORTS=""
AS_JSON=0
INPUT_FILE=""

while getopts ":f:c:l:p:jh" opt; do
  case "$opt" in
    f) INPUT_FILE="$OPTARG" ;;
    c) COUNT="$OPTARG" ;;
    l) MAX_MS="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
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

command -v ping >/dev/null 2>&1 || {
  echo "ping not found." >&2
  exit 2
}
for v in "$COUNT" "$MAX_MS"; do
  case "$v" in '' | *[!0-9]*)
    echo "-c and -l must be integers." >&2
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
    if [ -n "$line" ]; then hosts+=("$line"); fi
  done <"$INPUT_FILE"
fi

[ ${#hosts[@]} -gt 0 ] || {
  echo "No host given. Use -h for help." >&2
  exit 2
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Opens a TCP connection with a timeout, without needing nc or nmap.
port_open() {
  local host=$1 port=$2
  timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

problems=0
rows=()
port_rows=()

for host in "${hosts[@]}"; do
  loss=100
  avg="-"
  if out="$(ping -c "$COUNT" -W 2 "$host" 2>/dev/null)"; then
    loss="$(printf '%s' "$out" | sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p' | head -1)"
    [ -n "$loss" ] || loss=0
    # rtt min/avg/max/mdev = 1.234/5.678/9.012/3.456 ms
    avg="$(printf '%s' "$out" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p' | head -1)"
    [ -n "$avg" ] || avg="-"
  fi

  status="ok"
  if [ "$loss" -eq 100 ]; then
    status="unreachable"
  elif [ "$loss" -gt 0 ]; then
    status="packet-loss"
  elif [ "$avg" != "-" ] && awk -v a="$avg" -v m="$MAX_MS" 'BEGIN { exit !(a > m) }'; then
    status="high-latency"
  fi
  [ "$status" = "ok" ] || problems=$((problems + 1))
  rows+=("$host|$loss|$avg|$status")

  if [ -n "$PORTS" ]; then
    IFS=',' read -ra plist <<<"$PORTS"
    for p in "${plist[@]}"; do
      p="$(echo "$p" | tr -d '[:space:]')"
      [ -n "$p" ] || continue
      if port_open "$host" "$p"; then
        port_rows+=("$host|$p|open")
      else
        port_rows+=("$host|$p|closed")
        problems=$((problems + 1))
      fi
    done
  fi
done

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"pings":%d,"latency_threshold_ms":%d,"problems":%d,"hosts":[' "$COUNT" "$MAX_MS" "$problems"
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r host loss avg status <<<"$row"
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    if [ "$avg" = "-" ]; then avg_json=null; else avg_json="$avg"; fi
    printf '{"host":"%s","loss_percent":%s,"avg_ms":%s,"status":"%s"}' \
      "$(json_escape "$host")" "$loss" "$avg_json" "$status"
  done
  printf '],"ports":['
  first=1
  for row in ${port_rows+"${port_rows[@]}"}; do
    IFS='|' read -r host port state <<<"$row"
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    printf '{"host":"%s","port":%s,"state":"%s"}' "$(json_escape "$host")" "$port" "$state"
  done
  printf ']}\n'
else
  printf '%-34s %6s %10s  %s\n' "HOST" "LOSS" "AVG" "STATUS"
  for row in "${rows[@]}"; do
    IFS='|' read -r host loss avg status <<<"$row"
    printf '%-34s %5s%% %8sms  %s\n' "$host" "$loss" "$avg" "$status"
  done
  if [ ${#port_rows[@]} -gt 0 ]; then
    echo
    printf '%-34s %6s  %s\n' "HOST" "PORT" "STATE"
    for row in "${port_rows[@]}"; do
      IFS='|' read -r host port state <<<"$row"
      printf '%-34s %6s  %s\n' "$host" "$port" "$state"
    done
  fi
  echo
  echo "Checked ${#hosts[@]} host(s); $problems problem(s)."
fi

[ "$problems" -eq 0 ] || exit 1
