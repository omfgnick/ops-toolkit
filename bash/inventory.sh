#!/usr/bin/env bash
#
# inventory.sh — Collects the machine inventory in a single report: identity,
# operating system, CPU, memory, disks, network and installed packages.
#
# Meant for feeding a CMDB and for attaching to a vendor ticket, where the first
# question is usually "what is the model, the serial and the version".
#
# Read-only: this script never changes anything.
#
# Usage:
#   ./inventory.sh [options]
#
# Options:
#   -j           Emit JSON instead of the readable report
#   -o FILE      Also write the output to FILE
#   -h           Show this help
#
# Exit codes:
#   0 success · 2 bad usage
#
# Examples:
#   ./inventory.sh
#   ./inventory.sh -j | jq '.os, .cpu'
#   ./inventory.sh -o "/var/tmp/inv-$(hostname).txt"
#
# Requires: coreutils. Uses dmidecode, lsblk and the package manager when they
# are available; whatever is missing shows as null/unknown instead of failing.
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

AS_JSON=0
OUT_FILE=""

while getopts ":jo:h" opt; do
  case "$opt" in
    j) AS_JSON=1 ;;
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

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }

# Read a field from /etc/os-release without executing the file
os_field() {
  [ -r /etc/os-release ] || return 0
  awk -F= -v k="$1" '$1 == k { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release | head -1
}

# ---- Identity ----------------------------------------------------------------
HOSTNAME_S="$(hostname 2>/dev/null || echo unknown)"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_S")"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# dmidecode needs root; without it these fields stay empty, which is fine
VENDOR=""
MODEL=""
SERIAL=""
if have dmidecode && [ "$(id -u)" -eq 0 ]; then
  VENDOR="$(dmidecode -s system-manufacturer 2>/dev/null | head -1 || true)"
  MODEL="$(dmidecode -s system-product-name 2>/dev/null | head -1 || true)"
  SERIAL="$(dmidecode -s system-serial-number 2>/dev/null | head -1 || true)"
fi

# ---- Operating system --------------------------------------------------------
OS_NAME="$(os_field PRETTY_NAME)"
[ -n "$OS_NAME" ] || OS_NAME="$(uname -s)"
OS_ID="$(os_field ID)"
OS_VERSION="$(os_field VERSION_ID)"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
UPTIME_S="$(uptime -p 2>/dev/null || echo unknown)"

# ---- CPU ---------------------------------------------------------------------
CPU_MODEL="unknown"
if [ -r /proc/cpuinfo ]; then
  CPU_MODEL="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(awk -F': ' '/^Model/ { print $2; exit }' /proc/cpuinfo)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="unknown"
fi
CPU_COUNT="$(nproc 2>/dev/null || echo 1)"

# ---- Memory ------------------------------------------------------------------
MEM_TOTAL_KB=0
if [ -r /proc/meminfo ]; then
  MEM_TOTAL_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
fi

# ---- Disks -------------------------------------------------------------------
disks=()
if have lsblk; then
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3 == "disk" { name=$1; size=$2; $1=$2=$3=""; sub(/^ +/, ""); print name "|" size "|" $0 }')
fi

# ---- Network -----------------------------------------------------------------
ifaces=()
if have ip; then
  while IFS= read -r line; do
    [ -n "$line" ] && ifaces+=("$line")
  done < <(ip -o -4 addr show 2>/dev/null | awk '{ print $2 "|" $4 }')
fi

# ---- Packages ----------------------------------------------------------------
PKG_MANAGER="unknown"
PKG_COUNT=0
if have dpkg-query; then
  PKG_MANAGER="dpkg"
  PKG_COUNT="$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l || echo 0)"
elif have rpm; then
  PKG_MANAGER="rpm"
  PKG_COUNT="$(rpm -qa 2>/dev/null | wc -l || echo 0)"
elif have apk; then
  PKG_MANAGER="apk"
  PKG_COUNT="$(apk info 2>/dev/null | wc -l || echo 0)"
fi

# ---- Output ------------------------------------------------------------------
render_json() {
  printf '{"collected_at":"%s","identity":{"hostname":"%s","fqdn":"%s","vendor":%s,"model":%s,"serial":%s},' \
    "$(json_escape "$NOW")" "$(json_escape "$HOSTNAME_S")" "$(json_escape "$FQDN")" \
    "$([ -n "$VENDOR" ] && printf '"%s"' "$(json_escape "$VENDOR")" || echo null)" \
    "$([ -n "$MODEL" ] && printf '"%s"' "$(json_escape "$MODEL")" || echo null)" \
    "$([ -n "$SERIAL" ] && printf '"%s"' "$(json_escape "$SERIAL")" || echo null)"
  printf '"os":{"name":"%s","id":"%s","version":"%s","kernel":"%s","arch":"%s","uptime":"%s"},' \
    "$(json_escape "$OS_NAME")" "$(json_escape "$OS_ID")" "$(json_escape "$OS_VERSION")" \
    "$(json_escape "$KERNEL")" "$(json_escape "$ARCH")" "$(json_escape "$UPTIME_S")"
  printf '"cpu":{"model":"%s","count":%s},"memory":{"total_kb":%s},' \
    "$(json_escape "$CPU_MODEL")" "$CPU_COUNT" "$MEM_TOTAL_KB"

  printf '"disks":['
  local first=1
  for d in ${disks+"${disks[@]}"}; do
    IFS='|' read -r name size model <<<"$d"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"name":"%s","size":"%s","model":"%s"}' \
      "$(json_escape "$name")" "$(json_escape "$size")" "$(json_escape "$model")"
  done
  printf '],"interfaces":['
  first=1
  for i in ${ifaces+"${ifaces[@]}"}; do
    IFS='|' read -r name addr <<<"$i"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"name":"%s","address":"%s"}' "$(json_escape "$name")" "$(json_escape "$addr")"
  done
  printf '],"packages":{"manager":"%s","count":%s}}\n' "$(json_escape "$PKG_MANAGER")" "$PKG_COUNT"
}

render_text() {
  echo "==============================================================="
  echo " INVENTORY — $HOSTNAME_S"
  echo " $NOW"
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

  section "Identity"
  printf '  Hostname    : %s\n' "$HOSTNAME_S"
  printf '  FQDN        : %s\n' "$FQDN"
  printf '  Vendor      : %s\n' "${VENDOR:-(needs root/dmidecode)}"
  printf '  Model       : %s\n' "${MODEL:-(needs root/dmidecode)}"
  printf '  Serial      : %s\n' "${SERIAL:-(needs root/dmidecode)}"
  echo
  section "System"
  printf '  SO          : %s\n' "$OS_NAME"
  printf '  Kernel      : %s (%s)\n' "$KERNEL" "$ARCH"
  printf '  Uptime      : %s\n' "$UPTIME_S"
  printf '  Packages    : %s (%s)\n' "$PKG_COUNT" "$PKG_MANAGER"
  echo
  section "Hardware"
  printf '  CPU         : %s x%s\n' "$CPU_MODEL" "$CPU_COUNT"
  printf '  Memory      : %s kB\n' "$MEM_TOTAL_KB"
  echo
  section "Disks"
  if [ ${#disks[@]} -eq 0 ]; then
    echo "  (lsblk unavailable)"
  else
    for d in "${disks[@]}"; do
      IFS='|' read -r name size model <<<"$d"
      printf '  %-10s %-10s %s\n' "$name" "$size" "$model"
    done
  fi
  echo
  section "Network"
  if [ ${#ifaces[@]} -eq 0 ]; then
    echo "  (ip unavailable)"
  else
    for i in "${ifaces[@]}"; do
      IFS='|' read -r name addr <<<"$i"
      printf '  %-12s %s\n' "$name" "$addr"
    done
  fi
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
if [ -n "$OUT_FILE" ]; then printf '%s\n' "$output" >"$OUT_FILE"; fi
