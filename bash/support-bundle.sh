#!/usr/bin/env bash
#
# support-bundle.sh — Collects everything an escalation usually asks for into a
# single archive you can attach to the ticket.
#
# The point is to end the back-and-forth of "send me the output of...": one run,
# one file, and the person on the other side has the whole picture.
#
# Read-only: it copies and reads, never changes the machine.
#
# Usage:
#   ./support-bundle.sh [options]
#
# Options:
#   -o FILE      Where to write the archive (default: ./support-<host>-<date>.tar.gz)
#   -n LINES     Log lines to include per source (default: 500)
#   -s           Skip logs, collect only state (much smaller archive)
#   -j           Print a JSON summary of what was collected
#   -h           Show this help
#
# Exit codes:
#   0 archive created · 1 failed to create · 2 bad usage
#
# Examples:
#   ./support-bundle.sh
#   ./support-bundle.sh -o /tmp/ticket-4521.tar.gz -n 2000
#
# Privacy: shell history, SSH keys and /etc/shadow are never collected. Review
# the archive before sending it outside your organisation - configuration files
# can still contain hostnames, IPs and internal names.
#
# Requires: tar, gzip
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.2.0"

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

OUT_FILE=""
LINES=500
SKIP_LOGS=0
AS_JSON=0

while getopts ":o:n:sjh" opt; do
  case "$opt" in
    o) OUT_FILE="$OPTARG" ;;
    n) LINES="$OPTARG" ;;
    s) SKIP_LOGS=1 ;;
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

case "$LINES" in '' | *[!0-9]*)
  echo "-n must be an integer." >&2
  exit 2
  ;;
esac

HOST="$(hostname 2>/dev/null || echo unknown)"
STAMP="$(date '+%Y-%m-%d_%H%M%S')"
[ -n "$OUT_FILE" ] || OUT_FILE="./support-${HOST}-${STAMP}.tar.gz"

WORK="$(mktemp -d)"
BUNDLE="$WORK/support-${HOST}-${STAMP}"
mkdir -p "$BUNDLE"
trap 'rm -rf "$WORK"' EXIT

collected=()
have() { command -v "$1" >/dev/null 2>&1; }

# Saves a command's output, recording failures instead of aborting the bundle -
# a missing tool should never cost you the rest of the report.
grab() {
  local name=$1
  shift
  local dest="$BUNDLE/$name.txt"
  {
    echo "# $* "
    echo "# collected $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo
    if "$@" 2>&1; then :; else echo "(command failed with status $?)"; fi
  } >"$dest"
  collected+=("$name")
}

grab_file() {
  local name=$1 path=$2
  [ -r "$path" ] || return 0
  cp -- "$path" "$BUNDLE/$name" 2>/dev/null && collected+=("$name")
}

# ---- Identity and system -----------------------------------------------------
grab uname uname -a
grab uptime uptime
grab date date
have hostnamectl && grab hostnamectl hostnamectl
grab_file os-release /etc/os-release

# ---- Resources ---------------------------------------------------------------
grab disk df -h
grab inodes df -i
grab memory free -h
have lsblk && grab block lsblk
have top && grab processes top -b -n 1

# ---- Network -----------------------------------------------------------------
have ip && grab ip-addr ip addr
have ip && grab ip-route ip route
have ss && grab sockets ss -tulpn
grab_file resolv /etc/resolv.conf
grab_file hosts /etc/hosts

# ---- Services ----------------------------------------------------------------
if have systemctl; then
  grab systemd-failed systemctl list-units --state=failed --no-pager
  grab systemd-units systemctl list-units --type=service --no-pager
fi

# ---- Logs --------------------------------------------------------------------
if [ "$SKIP_LOGS" -eq 0 ]; then
  if have journalctl; then
    grab journal-errors journalctl -p err -n "$LINES" --no-pager
    grab journal-boot journalctl -b -n "$LINES" --no-pager
  fi
  for f in /var/log/syslog /var/log/messages /var/log/dmesg; do
    [ -r "$f" ] || continue
    tail -n "$LINES" "$f" >"$BUNDLE/$(basename "$f").txt" 2>/dev/null && collected+=("$(basename "$f")")
  done
fi

# ---- Toolkit's own reports ---------------------------------------------------
# If the toolkit is present, its reports go in too: they are the condensed view
# of the same data and are what the person reading this will look at first.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for report in incident-triage disk-space inventory; do
  script="$HERE/$report.sh"
  [ -x "$script" ] || continue
  "$script" >"$BUNDLE/report-$report.txt" 2>&1 || true
  collected+=("report-$report")
done

# ---- Manifest ----------------------------------------------------------------
{
  echo "host: $HOST"
  echo "created: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "collected_by: support-bundle.sh (ops-toolkit $OPS_TOOLKIT_VERSION)"
  echo "user: $(id -un 2>/dev/null || echo unknown) (uid $(id -u))"
  echo "logs_included: $([ "$SKIP_LOGS" -eq 0 ] && echo yes || echo no)"
  echo
  echo "files:"
  (cd "$BUNDLE" && find . -type f | sed 's|^\./|  |' | sort)
} >"$BUNDLE/MANIFEST.txt"

if ! tar -czf "$OUT_FILE" -C "$WORK" "$(basename "$BUNDLE")" 2>/dev/null; then
  echo "Failed to create the archive at $OUT_FILE" >&2
  exit 1
fi

size=$(stat -c %s "$OUT_FILE" 2>/dev/null || echo 0)

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"archive":"%s","host":"%s","size_bytes":%s,"logs_included":%s,"items":%d}\n' \
    "$OUT_FILE" "$HOST" "$size" \
    "$([ "$SKIP_LOGS" -eq 0 ] && echo true || echo false)" "${#collected[@]}"
else
  echo "Support bundle: $OUT_FILE"
  echo "  host   : $HOST"
  echo "  size   : $size bytes"
  echo "  items  : ${#collected[@]}"
  echo
  echo "Review the contents before sending it outside your organisation:"
  echo "  tar -tzf $OUT_FILE"
fi
