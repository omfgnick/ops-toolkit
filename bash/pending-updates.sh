#!/usr/bin/env bash
#
# pending-updates.sh — Reports pending package updates, how many of them are
# security updates, and whether the machine is waiting for a reboot.
#
# The number that matters most here is not the package count: it is how old the
# package list is. A machine that has not refreshed its metadata in three weeks
# reports "nothing pending" and looks healthy, which is exactly the report you
# do not want to trust. This script always says when it last refreshed.
#
# Read-only: this script never installs, removes or upgrades anything.
# Refreshing the metadata (-r) is the only action it can take, and only when
# asked for it explicitly.
#
# Usage:
#   ./pending-updates.sh [options]
#
# Options:
#   -j           Emit JSON instead of the readable report
#   -r           Refresh the package metadata first (needs root)
#   -d DAYS      Treat the metadata as stale once it is DAYS days old
#                (default 7; -d 0 always warns, which is useful in tests)
#   -o FILE      Also write the output to FILE
#   -h           Show this help
#
# Exit codes:
#   0 up to date · 1 updates, reboot or stale metadata · 2 bad usage
#
# Examples:
#   ./pending-updates.sh
#   ./pending-updates.sh -j | jq '.security_count, .reboot_required'
#   sudo ./pending-updates.sh -r -d 3
#
# Requires: coreutils and the system package manager (apt, dnf, yum, zypper,
# pacman or apk). An unknown package manager is reported as such, not guessed.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.0.0"

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

AS_JSON=0
REFRESH=0
STALE_DAYS=7
OUT_FILE=""

while getopts ":jrd:o:h" opt; do
  case "$opt" in
    j) AS_JSON=1 ;;
    r) REFRESH=1 ;;
    d) STALE_DAYS="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
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

# getopts stops at the first operand, so "pending-updates.sh foo -j" would print
# the readable report and silently ignore -j. Refuse instead of misleading.
if [ $# -gt 0 ]; then
  echo "Unexpected argument: $1" >&2
  exit 2
fi

case "$STALE_DAYS" in
  '' | *[!0-9]*)
    echo "-d expects a number of days, got: $STALE_DAYS" >&2
    exit 2
    ;;
esac

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }
bool() { [ "$1" -eq 1 ] && echo true || echo false; }

# Age in whole days of a path, or -1 when it is missing. The file to look at
# differs per package manager, so the caller picks it.
file_age_days() {
  if [ ! -e "$1" ]; then
    echo -1
    return 0
  fi
  local mtime now
  mtime="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
  if [ "$mtime" -le 0 ]; then
    echo -1
    return 0
  fi
  now="$(date +%s)"
  echo $(((now - mtime) / 86400))
}

# ---- Which package manager ---------------------------------------------------
PKG_MANAGER="unknown"
if have apt-get && have dpkg-query; then
  PKG_MANAGER="apt"
elif have dnf; then
  PKG_MANAGER="dnf"
elif have yum; then
  PKG_MANAGER="yum"
elif have zypper; then
  PKG_MANAGER="zypper"
elif have pacman; then
  PKG_MANAGER="pacman"
elif have apk; then
  PKG_MANAGER="apk"
fi

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# ---- Optional refresh --------------------------------------------------------
REFRESH_DONE=0
NOTE=""
if [ "$REFRESH" -eq 1 ]; then
  if [ "$IS_ROOT" -eq 0 ]; then
    NOTE="refresh needs root; used the existing metadata"
  else
    case "$PKG_MANAGER" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="apt-get update failed" ;;
      dnf) dnf -q makecache >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="dnf makecache failed" ;;
      yum) yum -q makecache >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="yum makecache failed" ;;
      zypper) zypper -q refresh >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="zypper refresh failed" ;;
      pacman) pacman -Sy --noconfirm >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="pacman -Sy failed" ;;
      apk) apk update >/dev/null 2>&1 && REFRESH_DONE=1 || NOTE="apk update failed" ;;
      *) NOTE="unknown package manager; nothing to refresh" ;;
    esac
  fi
fi

# ---- How old is the metadata -------------------------------------------------
METADATA_AGE_DAYS=-1
case "$PKG_MANAGER" in
  apt)
    METADATA_AGE_DAYS="$(file_age_days /var/lib/apt/periodic/update-success-stamp)"
    if [ "$METADATA_AGE_DAYS" -lt 0 ]; then
      METADATA_AGE_DAYS="$(file_age_days /var/cache/apt/pkgcache.bin)"
    fi
    ;;
  dnf | yum) METADATA_AGE_DAYS="$(file_age_days /var/cache/dnf)" ;;
  zypper) METADATA_AGE_DAYS="$(file_age_days /var/cache/zypp/raw)" ;;
  pacman) METADATA_AGE_DAYS="$(file_age_days /var/lib/pacman/sync)" ;;
  apk) METADATA_AGE_DAYS="$(file_age_days /var/cache/apk)" ;;
esac
[ "$REFRESH_DONE" -eq 1 ] && METADATA_AGE_DAYS=0

# The comparison is inclusive: at exactly the threshold the list already counts
# as stale. Being one day early with the warning costs nothing; being one day
# late means reporting "0 pending" from a list nobody refreshed. It also gives
# '-d 0' a defined meaning - always warn - which is what makes this testable.
STALE=0
if [ "$METADATA_AGE_DAYS" -lt 0 ] || [ "$METADATA_AGE_DAYS" -ge "$STALE_DAYS" ]; then
  STALE=1
fi

# ---- What is pending ---------------------------------------------------------
# Every listing below runs under 'pipefail', and a package manager with nothing
# to report exits non-zero on several distros. The '|| true' keeps an empty list
# an empty list instead of killing the script on the healthy path.
packages=()
SECURITY_COUNT=0

collect() {
  while IFS= read -r line; do
    [ -n "$line" ] && packages+=("$line")
  done
}

case "$PKG_MANAGER" in
  apt)
    collect < <(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null |
      awk '/^Inst /{ name = $2; ver = "-"; for (i = 3; i <= NF; i++) if ($i ~ /^\(/) { ver = substr($i, 2); break } print name "|" ver }' || true)
    SECURITY_COUNT="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c -i '^Inst .*security' || true)"
    ;;
  dnf | yum)
    collect < <("$PKG_MANAGER" -q check-update 2>/dev/null |
      awk 'NF == 3 && $1 !~ /^(Last|Obsoleting|Security:)/ { print $1 "|" $2 }' || true)
    SECURITY_COUNT="$("$PKG_MANAGER" -q --security check-update 2>/dev/null |
      awk 'NF == 3 && $1 !~ /^(Last|Obsoleting|Security:)/' | wc -l || true)"
    ;;
  zypper)
    collect < <(zypper --quiet list-updates 2>/dev/null |
      awk -F'|' 'NR > 2 && NF >= 5 { gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $5); print $3 "|" $5 }' || true)
    SECURITY_COUNT="$(zypper --quiet list-patches --category security 2>/dev/null | grep -c '|' || true)"
    ;;
  pacman)
    collect < <(pacman -Qu 2>/dev/null | awk '{ print $1 "|" $NF }' || true)
    ;;
  apk)
    collect < <(apk version -l '<' 2>/dev/null | awk 'NR > 1 && NF >= 3 { print $1 "|" $3 }' || true)
    ;;
esac

# 'grep -c' prints 0 and exits 1 when nothing matches; the '|| true' above keeps
# the run alive, and this keeps the value a number even if nothing was printed.
[ -n "$SECURITY_COUNT" ] || SECURITY_COUNT=0
case "$SECURITY_COUNT" in
  '' | *[!0-9]*) SECURITY_COUNT=0 ;;
esac

PENDING_COUNT=${#packages[@]}

# ---- Is a reboot waiting -----------------------------------------------------
REBOOT_REQUIRED=0
REBOOT_REASON=""
if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
  REBOOT_REQUIRED=1
  REBOOT_REASON="/run/reboot-required exists"
elif have needs-restarting; then
  # 'needs-restarting -r' exits non-zero precisely when a reboot is needed
  if ! needs-restarting -r >/dev/null 2>&1; then
    REBOOT_REQUIRED=1
    REBOOT_REASON="needs-restarting -r says so"
  fi
elif [ -d /boot ]; then
  # A kernel newer than the running one means the reboot is what is missing
  running="$(uname -r)"
  newest="$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1 || true)"
  if [ -n "$newest" ] && [ "$newest" != "$running" ]; then
    REBOOT_REQUIRED=1
    REBOOT_REASON="kernel $newest installed, running $running"
  fi
fi

# ---- Exit status -------------------------------------------------------------
STATUS=0
if [ "$PENDING_COUNT" -gt 0 ] || [ "$REBOOT_REQUIRED" -eq 1 ] || [ "$STALE" -eq 1 ]; then
  STATUS=1
fi

render_json() {
  local first=1 name ver p
  printf '{'
  printf '"host":"%s",' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
  printf '"generated_at":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '"package_manager":"%s",' "$(json_escape "$PKG_MANAGER")"
  printf '"metadata_age_days":%s,' "$METADATA_AGE_DAYS"
  printf '"metadata_stale":%s,' "$(bool "$STALE")"
  printf '"stale_after_days":%s,' "$STALE_DAYS"
  printf '"refreshed":%s,' "$(bool "$REFRESH_DONE")"
  printf '"note":"%s",' "$(json_escape "$NOTE")"
  printf '"pending_count":%s,' "$PENDING_COUNT"
  printf '"security_count":%s,' "$SECURITY_COUNT"
  printf '"reboot_required":%s,' "$(bool "$REBOOT_REQUIRED")"
  printf '"reboot_reason":"%s",' "$(json_escape "$REBOOT_REASON")"
  printf '"packages":['
  for p in ${packages[@]+"${packages[@]}"}; do
    IFS='|' read -r name ver <<<"$p"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"name":"%s","available":"%s"}' "$(json_escape "$name")" "$(json_escape "$ver")"
  done
  printf '],'
  printf '"status":%s' "$STATUS"
  printf '}\n'
}

render_text() {
  local name ver p reboot_txt
  reboot_txt="$(bool "$REBOOT_REQUIRED")"

  echo "Pending updates - $(hostname 2>/dev/null || echo unknown)"
  echo "Generated at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  printf '  Package manager : %s\n' "$PKG_MANAGER"
  if [ "$METADATA_AGE_DAYS" -lt 0 ]; then
    printf '  Metadata        : age unknown\n'
  else
    printf '  Metadata        : %s day(s) old\n' "$METADATA_AGE_DAYS"
  fi
  [ -n "$NOTE" ] && printf '  Note            : %s\n' "$NOTE"
  printf '  Pending         : %s package(s)\n' "$PENDING_COUNT"
  printf '  Security        : %s\n' "$SECURITY_COUNT"
  if [ -n "$REBOOT_REASON" ]; then
    printf '  Reboot required : %s (%s)\n' "$reboot_txt" "$REBOOT_REASON"
  else
    printf '  Reboot required : %s\n' "$reboot_txt"
  fi
  echo

  # Sem gerenciador conhecido não há lista para atualizar, então mandar rodar
  # -r seria conselho inútil. O status continua 1: não dá para afirmar que a
  # máquina está em dia, e afirmar isso seria pior do que dizer que não se sabe.
  if [ "$PKG_MANAGER" = unknown ]; then
    echo "  No supported package manager found, so nothing here was checked."
    echo "  Reported as pending rather than up to date, on purpose."
    return 0
  fi

  if [ "$STALE" -eq 1 ]; then
    echo "  WARNING: the package list is $METADATA_AGE_DAYS day(s) old (threshold: $STALE_DAYS)."
    echo "  A count of 0 means nothing until it is refreshed (-r, as root)."
    echo
  fi

  if [ "$PENDING_COUNT" -eq 0 ]; then
    echo "  Nothing to upgrade."
    return 0
  fi

  printf '  %-42s %s\n' "PACKAGE" "AVAILABLE"
  for p in ${packages[@]+"${packages[@]}"}; do
    IFS='|' read -r name ver <<<"$p"
    printf '  %-42s %s\n' "$name" "$ver"
  done
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
if [ -n "$OUT_FILE" ]; then printf '%s\n' "$output" >"$OUT_FILE"; fi
exit "$STATUS"
