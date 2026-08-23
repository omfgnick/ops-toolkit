#!/usr/bin/env bash
#
# portscan-vuln.sh — Scan a host with nmap and print a simple risk rating for
# each open TCP port.
#
# Category: Network
# Ask: @ | Host to scan - only with authorisation
#
# Usage:
#   ./portscan-vuln.sh [-p PORTS] HOST
#     -p PORTS   Port spec passed to nmap (default: 1-65535). Examples: "1-1024",
#                "22,80,443", "-" (all ports).
#
# Requires: nmap. Only scan hosts you are authorised to test.
#
set -euo pipefail

# Print only the header block (skip the shebang, stop at the first command)
# instead of dumping every comment in the file.
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

PORTS="1-65535"

while getopts ":p:h" opt; do
  case "$opt" in
    p) PORTS="$OPTARG" ;;
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

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "Usage: $0 [-p PORTS] HOST" >&2
  exit 2
fi

command -v nmap >/dev/null 2>&1 || {
  echo "nmap is not installed." >&2
  exit 1
}

rating_for_port() {
  case "$1" in
    21) echo "FTP - Vulnerability rating: 8/10" ;;
    22) echo "SSH - Vulnerability rating: 6/10" ;;
    23) echo "Telnet - Vulnerability rating: 9/10" ;;
    80) echo "HTTP - Vulnerability rating: 5/10" ;;
    443) echo "HTTPS - Vulnerability rating: 4/10" ;;
    3389) echo "RDP - Vulnerability rating: 8/10" ;;
    *) echo "Unknown service - Vulnerability rating: 10/10" ;;
  esac
}

echo "Scanning $HOST (ports: $PORTS)..."

# Run nmap ONCE (not once per port), request grepable output, and extract the
# ports reported as open. This is orders of magnitude faster than looping.
open_ports="$(
  nmap -Pn -p "$PORTS" --open -oG - "$HOST" |
    awk -F'\t' '/Ports:/{print $2}' |
    tr ',' '\n' |
    awk -F/ '$2=="open"{gsub(/ /,"",$1); print $1}'
)"

if [ -z "$open_ports" ]; then
  echo "No open ports found."
  exit 0
fi

echo "Open ports:"
while IFS= read -r port; do
  [ -n "$port" ] || continue
  printf '  %-6s %s\n' "$port" "$(rating_for_port "$port")"
done <<<"$open_ports"
