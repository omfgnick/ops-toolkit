#!/usr/bin/env bash
#
# audit-hardening.sh — Read-only security review of a Linux host: accounts that
# can log in, sudo rights, SSH daemon settings, world-writable files, SUID
# binaries and listening sockets.
#
# Reports only. It never changes a setting, so it is safe to run in production.
# Findings are advisory: review each one in context before acting.
#
# Usage:
#   ./audit-hardening.sh [options]
#
# Options:
#   -d DIR       Directory scanned for world-writable/SUID files (default: /etc /usr/bin /usr/sbin)
#   -j           Emit JSON instead of the readable report
#   -h           Show this help
#
# Exit codes:
#   0 no findings · 1 at least one finding · 2 bad usage
#
# Examples:
#   ./audit-hardening.sh
#   ./audit-hardening.sh -j | jq '.findings[]'
#
# Requires: coreutils. Uses ss and sshd config when available.
# Some checks need root to be complete; without it they are reported as skipped.
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

SCAN_DIRS=()
AS_JSON=0

while getopts ":d:jh" opt; do
  case "$opt" in
    d) SCAN_DIRS+=("$OPTARG") ;;
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

[ ${#SCAN_DIRS[@]} -gt 0 ] || SCAN_DIRS=(/etc /usr/bin /usr/sbin)

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}

findings=()
add_finding() { findings+=("$1|$2"); } # severity|message

IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then IS_ROOT=1; fi

# ---- Accounts ----------------------------------------------------------------
login_users=""
if [ -r /etc/passwd ]; then
  login_users="$(awk -F: '$7 !~ /(nologin|false|sync)$/ { print $1 ":" $3 ":" $7 }' /etc/passwd)"
fi

# UID 0 accounts other than root are a classic backdoor
while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi
  user="${line%%:*}"
  uid="$(printf '%s' "$line" | cut -d: -f2)"
  if [ "$uid" = "0" ] && [ "$user" != "root" ]; then
    add_finding "high" "account '$user' has UID 0 (root-equivalent)"
  fi
done <<<"$login_users"

# Empty passwords
if [ "$IS_ROOT" -eq 1 ] && [ -r /etc/shadow ]; then
  while IFS=: read -r user hash _; do
    if [ -z "${hash:-}" ]; then add_finding "high" "account '$user' has an empty password"; fi
  done </etc/shadow
else
  add_finding "info" "empty-password check skipped (needs root)"
fi

# ---- sudo --------------------------------------------------------------------
if [ -r /etc/sudoers ]; then
  if grep -Eq '^[^#]*NOPASSWD' /etc/sudoers 2>/dev/null; then
    add_finding "medium" "/etc/sudoers grants NOPASSWD to at least one entry"
  fi
else
  add_finding "info" "/etc/sudoers not readable (needs root)"
fi

# ---- SSH ---------------------------------------------------------------------
# Overridable so tests can point at a sample file
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
if [ -r "$SSHD_CONFIG" ]; then
  # The effective value is the FIRST occurrence; commented lines do not count
  sshd_value() {
    # grep returns 1 when nothing matches and, with 'pipefail', that would kill
    grep -Ei "^[[:space:]]*$1[[:space:]]+" "$SSHD_CONFIG" 2>/dev/null | head -1 | awk '{ print tolower($2) }' || true
  }
  permit_root="$(sshd_value PermitRootLogin)"
  pass_auth="$(sshd_value PasswordAuthentication)"
  if [ "$permit_root" = "yes" ]; then
    add_finding "high" "sshd allows direct root login (PermitRootLogin yes)"
  fi
  if [ "$pass_auth" = "yes" ]; then
    add_finding "medium" "sshd allows password authentication"
  fi
else
  add_finding "info" "sshd_config not readable (needs root, or SSH not installed)"
fi

# ---- Dangerous file modes ----------------------------------------------------
ww_count=0
suid_count=0
ww_examples=""
suid_examples=""
for dir in "${SCAN_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ww_count=$((ww_count + 1))
    if [ "$ww_count" -le 5 ]; then ww_examples="${ww_examples}${f}"$'\n'; fi
  done < <(find "$dir" -xdev -type f -perm -0002 2>/dev/null | head -50)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    suid_count=$((suid_count + 1))
    if [ "$suid_count" -le 5 ]; then suid_examples="${suid_examples}${f}"$'\n'; fi
  done < <(find "$dir" -xdev -type f -perm -4000 2>/dev/null | head -50)
done
if [ "$ww_count" -gt 0 ]; then
  add_finding "medium" "$ww_count world-writable file(s) found"
fi

# ---- Listening sockets -------------------------------------------------------
listening=""
if command -v ss >/dev/null 2>&1; then
  listening="$(ss -tlnH 2>/dev/null | awk '{ print $4 }' | sort -u || true)"
  # Anything bound to 0.0.0.0 / [::] is reachable from outside the host
  ext="$(printf '%s\n' "$listening" | grep -cE '^(0\.0\.0\.0|\[::\])' || true)"
  if [ "${ext:-0}" -gt 0 ]; then add_finding "info" "$ext socket(s) listening on all interfaces"; fi
fi

# ---- Render ------------------------------------------------------------------
count_sev() {
  local sev=$1 n=0
  for f in ${findings+"${findings[@]}"}; do
    if [ "${f%%|*}" = "$sev" ]; then n=$((n + 1)); fi
  done
  printf '%d' "$n"
}

if [ "$AS_JSON" -eq 1 ]; then
  printf '{"hostname":"%s","as_root":%s,"suid_count":%d,"world_writable_count":%d,"findings":[' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$([ "$IS_ROOT" -eq 1 ] && echo true || echo false)" "$suid_count" "$ww_count"
  first=1
  for f in ${findings+"${findings[@]}"}; do
    if [ $first -eq 0 ]; then printf ','; fi
    first=0
    printf '{"severity":"%s","message":"%s"}' "${f%%|*}" "$(json_escape "${f#*|}")"
  done
  printf '],"summary":{"high":%s,"medium":%s,"info":%s}}\n' \
    "$(count_sev high)" "$(count_sev medium)" "$(count_sev info)"
else
  echo "==============================================================="
  echo " HARDENING AUDIT — $(hostname 2>/dev/null || echo unknown)"
  echo " $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if [ "$IS_ROOT" -eq 0 ]; then echo " (running unprivileged — some checks were skipped)"; fi
  echo "==============================================================="
  echo
  # Section header padded to a fixed width. Done with padding rather than a fixed
  # run of dashes because some titles interpolate a variable and would misalign.
  section() {
    local title="-- $1 "
    local width=64
    local pad=$((width - ${#title}))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%s
' "$title" "$(printf '%*s' "$pad" '' | tr ' ' '-')"
  }

  section "Login-capable accounts"
  if [ -n "$login_users" ]; then printf '%s\n' "$login_users" | sed 's/^/  /'; else echo "  (unavailable)"; fi
  echo
  section "File modes"
  printf '  World-writable : %d\n' "$ww_count"
  if [ -n "$ww_examples" ]; then printf '%s' "$ww_examples" | sed 's/^/      /'; fi
  printf '  SUID binaries  : %d\n' "$suid_count"
  if [ -n "$suid_examples" ]; then printf '%s' "$suid_examples" | sed 's/^/      /'; fi
  echo
  section "Listening sockets"
  if [ -n "$listening" ]; then printf '%s\n' "$listening" | sed 's/^/  /'; else echo "  (ss unavailable)"; fi
  echo
  section "Findings"
  if [ ${#findings[@]} -eq 0 ]; then
    echo "  Nothing flagged."
  else
    for f in "${findings[@]}"; do
      printf '  [%-6s] %s\n' "${f%%|*}" "${f#*|}"
    done
  fi
  echo
  echo "high=$(count_sev high) medium=$(count_sev medium) info=$(count_sev info)"
fi

# 'info' entries are notes, not problems: only high/medium change the exit code
[ "$(count_sev high)" -eq 0 ] && [ "$(count_sev medium)" -eq 0 ] || exit 1
exit 0
