#!/usr/bin/env bash
#
# incident-triage.sh — Single-shot snapshot of a machine's state, meant to be
# the first command you run when a ticket lands: load, memory, disk, network,
# failed services and recent errors, in one report you can paste into the call.
#
# Read-only: this script never changes anything.
#
# Usage:
#   ./incident-triage.sh [options]
#
# Options:
#   -n COUNT     Number of recent log errors to include (default: 15)
#   -o FILE      Also write the report to FILE
#   -j           Emit JSON instead of the readable report
#   -h           Show this help
#
# Exit codes:
#   0 nothing alarming · 1 something needs attention · 2 bad usage
#
# Examples:
#   ./incident-triage.sh
#   ./incident-triage.sh -o /tmp/triage-$(hostname).txt
#   ./incident-triage.sh -j | jq '.alerts'
#
# Requires: coreutils. Uses systemctl / journalctl / ss when available.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

LOG_LINES=15
OUT_FILE=""
AS_JSON=0

while getopts ":n:o:jh" opt; do
  case "$opt" in
    n) LOG_LINES="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
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

case "$LOG_LINES" in '' | *[!0-9]*)
  echo "-n must be an integer." >&2
  exit 2
  ;;
esac

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---- Collect -----------------------------------------------------------------
HOSTNAME_S="$(hostname 2>/dev/null || echo unknown)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
UPTIME_S="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
KERNEL="$(uname -sr 2>/dev/null || echo unknown)"

read -r load1 load5 load15 _ </proc/loadavg 2>/dev/null || {
  load1=0
  load5=0
  load15=0
}
CPUS="$(nproc 2>/dev/null || echo 1)"
# Load per core above 1.0 means the queue is longer than the machine can serve
LOAD_RATIO="$(awk -v l="$load1" -v c="$CPUS" 'BEGIN { printf "%.2f", l / c }')"

MEM_TOTAL=0
MEM_AVAIL=0
if [ -r /proc/meminfo ]; then
  MEM_TOTAL="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  MEM_AVAIL="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
fi
MEM_USED_PCT=0
[ "$MEM_TOTAL" -gt 0 ] && MEM_USED_PCT=$(((MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL))

# Fullest filesystem
DISK_WORST_PCT=0
DISK_WORST_MOUNT="-"
while read -r _ _ _ _ capacity mount; do
  [ "$capacity" = "Capacity" ] && continue
  pct="${capacity%\%}"
  case "$pct" in '' | *[!0-9]*) continue ;; esac
  if [ "$pct" -gt "$DISK_WORST_PCT" ]; then
    DISK_WORST_PCT="$pct"
    DISK_WORST_MOUNT="$mount"
  fi
done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null)

FAILED_UNITS=""
FAILED_COUNT=0
if have systemctl; then
  FAILED_UNITS="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' || true)"
  [ -n "$FAILED_UNITS" ] && FAILED_COUNT="$(printf '%s\n' "$FAILED_UNITS" | grep -c . || true)"
fi

LISTENING=""
if have ss; then
  LISTENING="$(ss -tlnH 2>/dev/null | awk '{ print $4 }' | sort -u || true)"
fi

RECENT_ERRORS=""
if have journalctl; then
  RECENT_ERRORS="$(journalctl -p err -n "$LOG_LINES" --no-pager -q 2>/dev/null || true)"
fi

# ---- Alerts ------------------------------------------------------------------
alerts=()
awk -v r="$LOAD_RATIO" 'BEGIN { exit !(r > 1.0) }' && alerts+=("load per core is ${LOAD_RATIO} (>1.00)")
[ "$MEM_USED_PCT" -ge 90 ] && alerts+=("memory at ${MEM_USED_PCT}%")
[ "$DISK_WORST_PCT" -ge 85 ] && alerts+=("filesystem ${DISK_WORST_MOUNT} at ${DISK_WORST_PCT}%")
[ "$FAILED_COUNT" -gt 0 ] && alerts+=("${FAILED_COUNT} failed systemd unit(s)")

# ---- Render ------------------------------------------------------------------
render_text() {
  echo "==============================================================="
  echo " INCIDENT TRIAGE — $HOSTNAME_S"
  echo " $NOW"
  echo "==============================================================="
  echo
  echo "-- System ------------------------------------------------------"
  printf '  Kernel      : %s\n' "$KERNEL"
  printf '  Uptime      : %s\n' "$UPTIME_S"
  printf '  Load        : %s %s %s  (%s per core, %s CPUs)\n' "$load1" "$load5" "$load15" "$LOAD_RATIO" "$CPUS"
  printf '  Memory      : %s%% used\n' "$MEM_USED_PCT"
  printf '  Fullest FS  : %s at %s%%\n' "$DISK_WORST_MOUNT" "$DISK_WORST_PCT"
  echo
  echo "-- Failed units ------------------------------------------------"
  if [ -n "$FAILED_UNITS" ]; then printf '%s\n' "$FAILED_UNITS" | sed 's/^/  /'; else echo "  none"; fi
  echo
  echo "-- Listening sockets -------------------------------------------"
  if [ -n "$LISTENING" ]; then printf '%s\n' "$LISTENING" | sed 's/^/  /'; else echo "  (ss unavailable)"; fi
  echo
  echo "-- Recent errors (last $LOG_LINES) ------------------------------"
  if [ -n "$RECENT_ERRORS" ]; then printf '%s\n' "$RECENT_ERRORS" | sed 's/^/  /'; else echo "  none (or journalctl unavailable)"; fi
  echo
  echo "-- Summary -----------------------------------------------------"
  if [ ${#alerts[@]} -eq 0 ]; then
    echo "  Nothing alarming found."
  else
    for a in "${alerts[@]}"; do echo "  ALERT: $a"; done
  fi
}

render_json() {
  printf '{"hostname":"%s","timestamp":"%s","kernel":"%s","uptime":"%s",' \
    "$(json_escape "$HOSTNAME_S")" "$(json_escape "$NOW")" \
    "$(json_escape "$KERNEL")" "$(json_escape "$UPTIME_S")"
  printf '"load":{"1m":%s,"5m":%s,"15m":%s,"per_core":%s,"cpus":%s},' \
    "$load1" "$load5" "$load15" "$LOAD_RATIO" "$CPUS"
  printf '"memory":{"total_kb":%s,"available_kb":%s,"used_percent":%s},' \
    "$MEM_TOTAL" "$MEM_AVAIL" "$MEM_USED_PCT"
  printf '"disk":{"fullest_mount":"%s","used_percent":%s},' \
    "$(json_escape "$DISK_WORST_MOUNT")" "$DISK_WORST_PCT"
  printf '"failed_units":['
  local first=1
  if [ -n "$FAILED_UNITS" ]; then
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      [ $first -eq 0 ] && printf ','
      first=0
      printf '"%s"' "$(json_escape "$u")"
    done <<<"$FAILED_UNITS"
  fi
  printf '],"alerts":['
  first=1
  for a in ${alerts+"${alerts[@]}"}; do
    [ $first -eq 0 ] && printf ','
    first=0
    printf '"%s"' "$(json_escape "$a")"
  done
  printf ']}\n'
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
[ -n "$OUT_FILE" ] && printf '%s\n' "$output" >"$OUT_FILE"

[ ${#alerts[@]} -eq 0 ] || exit 1
exit 0
