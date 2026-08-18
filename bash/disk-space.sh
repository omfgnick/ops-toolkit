#!/usr/bin/env bash
#
# disk-space.sh — Reports free space per mounted filesystem and flags anything
# at or below a threshold. Bash counterpart of powershell/Get-DiskSpaceReport.ps1.
#
# Usage:
#   ./disk-space.sh [options]
#
# Options:
#   -t PERCENT   Free-percent at or below which a filesystem is flagged (default: 15)
#   -j           Emit JSON instead of a table
#   -a           Include pseudo filesystems (tmpfs, devtmpfs, overlay...)
#   -h           Show this help
#
# Exit codes:
#   0 all above threshold · 1 at least one filesystem low · 2 bad usage
#
# Examples:
#   ./disk-space.sh -t 20
#   ./disk-space.sh -j | jq '.filesystems[] | select(.low)'
#
# Requires: df
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

THRESHOLD=15
AS_JSON=0
ALL_FS=0

while getopts ":t:jah" opt; do
  case "$opt" in
    t) THRESHOLD="$OPTARG" ;;
    j) AS_JSON=1 ;;
    a) ALL_FS=1 ;;
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

case "$THRESHOLD" in
  '' | *[!0-9]*)
    echo "Threshold must be an integer: $THRESHOLD" >&2
    exit 2
    ;;
esac
if [ "$THRESHOLD" -lt 0 ] || [ "$THRESHOLD" -gt 100 ]; then
  echo "Threshold must be 0-100." >&2
  exit 2
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

df_args=(-P -k)
[ "$ALL_FS" -eq 0 ] && df_args+=(-x tmpfs -x devtmpfs -x squashfs -x overlay)

low=0
rows=()

while read -r source size used avail capacity mount; do
  # Skips the header line emitted by df
  [ "$source" = "Filesystem" ] && continue
  used_pct="${capacity%\%}"
  free_pct=$((100 - used_pct))
  flag=0
  if [ "$free_pct" -le "$THRESHOLD" ]; then
    flag=1
    low=$((low + 1))
  fi
  rows+=("$source|$mount|$size|$used|$avail|$free_pct|$flag")
done < <(df "${df_args[@]}" 2>/dev/null)

# KiB -> human readable, without depending on df -h
human() {
  local kb=$1
  if [ "$kb" -ge 1073741824 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fT", k/1073741824 }'
  elif [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fG", k/1048576 }'
  elif [ "$kb" -ge 1024 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fM", k/1024 }'
  else
    printf '%dK' "$kb"
  fi
}

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"threshold_percent":%d,"low_count":%d,"filesystems":[' "$THRESHOLD" "$low"
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r source mount size used avail free_pct flag <<<"$row"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"filesystem":"%s","mount":"%s","size_kb":%s,"used_kb":%s,"available_kb":%s,"free_percent":%s,"low":%s}' \
      "$(json_escape "$source")" "$(json_escape "$mount")" "$size" "$used" "$avail" "$free_pct" \
      "$([ "$flag" -eq 1 ] && echo true || echo false)"
  done
  printf ']}\n'
else
  printf '%-24s %-20s %8s %8s %8s %6s  %s\n' "FILESYSTEM" "MOUNT" "SIZE" "USED" "AVAIL" "FREE%" "STATUS"
  for row in "${rows[@]}"; do
    IFS='|' read -r source mount size used avail free_pct flag <<<"$row"
    status="ok"
    [ "$flag" -eq 1 ] && status="LOW"
    printf '%-24s %-20s %8s %8s %8s %5s%%  %s\n' \
      "$source" "$mount" "$(human "$size")" "$(human "$used")" "$(human "$avail")" "$free_pct" "$status"
  done
  echo
  echo "$low filesystem(s) at or below ${THRESHOLD}% free."
fi

[ "$low" -eq 0 ] || exit 1
