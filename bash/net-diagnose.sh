#!/usr/bin/env bash
#
# net-diagnose.sh — Walks the network path from the inside out and says where it
# breaks: interface, gateway, DNS resolution, then the internet.
#
# Answers the question behind most "the internet is down" tickets: which layer
# actually failed. Checking them in order means the report points at the first
# broken link instead of just saying nothing works.
#
# Read-only: it never changes the configuration.
#
# Usage:
#   ./net-diagnose.sh [options]
#
# Options:
#   -t HOST      Host used for the internet check (default: 1.1.1.1)
#   -d NAME      Name used for the DNS check (default: github.com)
#   -j           Emit JSON instead of the readable report
#   -h           Show this help
#
# Exit codes:
#   0 everything answered · 1 something failed · 2 bad usage
#
# Examples:
#   ./net-diagnose.sh
#   ./net-diagnose.sh -t 8.8.8.8 -d intranet.empresa.local
#   ./net-diagnose.sh -j | jq '.steps[] | select(.ok == false)'
#
# Requires: iproute2 (ip). Uses ping, getent and curl when available.
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

TARGET="1.1.1.1"
DNS_NAME="github.com"
AS_JSON=0

while getopts ":t:d:jh" opt; do
  case "$opt" in
    t) TARGET="$OPTARG" ;;
    d) DNS_NAME="$OPTARG" ;;
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

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
have() { command -v "$1" >/dev/null 2>&1; }

failures=0
steps=()

# step <name> <ok:0|1> <detail>
step() {
  steps+=("$1|$2|$3")
  [ "$2" -eq 0 ] || failures=$((failures + 1))
}

# ---- 1. Interface ------------------------------------------------------------
iface=""
ipaddr=""
if have ip; then
  read -r iface ipaddr <<<"$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { print $2, $4 }' || true)"
fi
if [ -n "$ipaddr" ]; then
  step interface 0 "$iface $ipaddr"
else
  step interface 1 "no interface with a global IPv4 address"
fi

# ---- 2. Gateway --------------------------------------------------------------
gw=""
have ip && gw="$(ip route 2>/dev/null | awk '/^default/ { print $3; exit }' || true)"
if [ -z "$gw" ]; then
  step gateway 1 "no default route"
elif have ping && ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
  step gateway 0 "$gw responds"
else
  step gateway 1 "$gw does not respond"
fi

# ---- 3. DNS ------------------------------------------------------------------
servers="$(awk '/^nameserver/ { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null || true)"
resolved=""
if have getent; then
  # getent exits 2 when the name does not resolve; with 'pipefail' that would
  # kill the script exactly in the case this report exists to describe.
  resolved="$(getent hosts "$DNS_NAME" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
fi
if [ -n "$resolved" ]; then
  step dns 0 "$DNS_NAME -> $resolved (servers: ${servers:-unknown})"
else
  step dns 1 "cannot resolve $DNS_NAME (servers: ${servers:-none configured})"
fi

# ---- 4. Internet -------------------------------------------------------------
if have ping && ping -c 2 -W 3 "$TARGET" >/dev/null 2>&1; then
  step internet 0 "$TARGET responds"
else
  step internet 1 "$TARGET does not respond"
fi

# ---- 5. HTTP (catches captive portals and proxies) ---------------------------
if have curl; then
  # curl already prints 000 when it cannot connect; appending another with
  # '|| echo 000' produced "000000". Fall back at the assignment instead.
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$DNS_NAME" 2>/dev/null)" || code="000"
  [ -n "$code" ] || code="000"
  case "$code" in
    2?? | 3??) step https 0 "https://$DNS_NAME -> $code" ;;
    000) step https 1 "https://$DNS_NAME unreachable" ;;
    *) step https 1 "https://$DNS_NAME -> $code (proxy or captive portal?)" ;;
  esac
fi

# ---- Proxy -------------------------------------------------------------------
proxy="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"

# ---- Output ------------------------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  printf '{"failures":%d,"proxy":%s,"steps":[' "$failures" \
    "$([ -n "$proxy" ] && printf '"%s"' "$(json_escape "$proxy")" || echo null)"
  first=1
  for s in "${steps[@]}"; do
    IFS='|' read -r name ok detail <<<"$s"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"step":"%s","ok":%s,"detail":"%s"}' \
      "$name" "$([ "$ok" -eq 0 ] && echo true || echo false)" "$(json_escape "$detail")"
  done
  printf ']}\n'
else
  echo "Network diagnosis - $(hostname 2>/dev/null || echo unknown)"
  echo
  for s in "${steps[@]}"; do
    IFS='|' read -r name ok detail <<<"$s"
    if [ "$ok" -eq 0 ]; then
      printf '  [ ok ] %-10s %s\n' "$name" "$detail"
    else
      printf '  [FAIL] %-10s %s\n' "$name" "$detail"
    fi
  done
  [ -n "$proxy" ] && echo && echo "  proxy configured: $proxy"
  echo
  if [ "$failures" -eq 0 ]; then
    echo "Every layer answered."
  else
    # The first failure is the one worth chasing; the rest usually follow from it.
    for s in "${steps[@]}"; do
      IFS='|' read -r name ok _ <<<"$s"
      if [ "$ok" -ne 0 ]; then
        echo "First failure: $name - start there."
        break
      fi
    done
  fi
fi

[ "$failures" -eq 0 ]
