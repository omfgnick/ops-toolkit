#!/usr/bin/env bash
#
# metrics-collector.sh — Runs the report scripts, merges their --json output
# into a single document and, optionally, writes metrics in Prometheus format
# for the node_exporter textfile collector.
#
# This is the bridge between the toolkit and your monitoring: instead of calling
# each script by hand, a cron job calls this one and Grafana/Zabbix reads the
# result.
#
# Read-only: none of the invoked scripts change state.
#
# Usage:
#   ./metrics-collector.sh [options]
#
# Options:
#   -o FILE      Write output to FILE instead of stdout (written atomically)
#   -p           Prometheus textfile format instead of JSON
#   -j           JSON (already the default; accepted for consistency)
#   -s LIST      Comma-separated scripts to run
#                (default: disk-space,incident-triage,audit-hardening)
#   -t SECONDS   Time limit per script (default: 30)
#   -h           Show this help
#
# Exit codes:
#   0 everything collected · 1 a script failed · 2 bad usage
#
# Examples:
#   ./metrics-collector.sh | jq .
#   ./metrics-collector.sh -p -o /var/lib/node_exporter/textfile/ops.prom
#   ./metrics-collector.sh -s disk-space,net-monitor
#
# Suggested cron (every 5 minutes):
#   */5 * * * * /usr/local/bin/metrics-collector -p -o /var/lib/node_exporter/textfile/ops.prom
#
# Requires: jq
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

OUT_FILE=""
AS_PROM=0
SCRIPTS="disk-space,incident-triage,audit-hardening"
TIMEOUT=30

while getopts ":o:pjs:t:h" opt; do
  case "$opt" in
    o) OUT_FILE="$OPTARG" ;;
    p) AS_PROM=1 ;;
    # JSON is already the default here; -j exists only to keep the contract
    # uniform with the rest of the toolkit.
    j) AS_PROM=0 ;;
    s) SCRIPTS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
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

command -v jq >/dev/null 2>&1 || {
  echo "jq not found; it is needed to merge the JSON documents." >&2
  exit 2
}
case "$TIMEOUT" in '' | *[!0-9]*)
  echo "-t must be an integer." >&2
  exit 2
  ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failed=0
collected=()

IFS=',' read -ra want <<<"$SCRIPTS"
for name in "${want[@]}"; do
  name="$(echo "$name" | tr -d '[:space:]')"
  [ -n "$name" ] || continue
  script="$HERE/$name.sh"
  if [ ! -x "$script" ]; then
    echo "warning: $name.sh not found or not executable; skipping." >&2
    failed=$((failed + 1))
    continue
  fi
  # The exit code of these scripts signals findings (1 = something to look at),
  # not an execution error. What matters here is getting valid JSON back.
  if timeout "$TIMEOUT" "$script" -j >"$WORK/$name.json" 2>"$WORK/$name.err" || true; then :; fi
  if [ -s "$WORK/$name.json" ] && jq -e . "$WORK/$name.json" >/dev/null 2>&1; then
    collected+=("$name")
  else
    echo "warning: $name returned no valid JSON: $(head -1 "$WORK/$name.err" 2>/dev/null || true)" >&2
    failed=$((failed + 1))
  fi
done

# ---- Aggregated document -----------------------------------------------------
build_json() {
  # $ts and $host below are jq variables (passed with --arg), not shell ones —
  # that is why the filter is single-quoted on purpose.
  # shellcheck disable=SC2016
  local args=() filter='{ "collected_at": $ts, "host": $host, "reports": {} }'
  args+=(--arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
  args+=(--arg host "$(hostname 2>/dev/null || echo unknown)")
  for name in ${collected+"${collected[@]}"}; do
    args+=(--slurpfile "r_${name//-/_}" "$WORK/$name.json")
    filter="$filter | .reports[\"$name\"] = \$r_${name//-/_}[0]"
  done
  jq -n "${args[@]}" "$filter"
}

# ---- Prometheus format -------------------------------------------------------
# Only what makes sense as a time series: counters and percentages.
# Label values go through @json, which emits a properly escaped, quoted string.
# Without it a filesystem named 'C:\' would produce filesystem="C:\", where the
# backslash escapes the closing quote and corrupts the whole file for the parser.
build_prom() {
  local ts
  ts="$(date +%s)"
  echo "# HELP ops_toolkit_up 1 when collection finished without failures"
  echo "# TYPE ops_toolkit_up gauge"
  echo "ops_toolkit_up $([ "$failed" -eq 0 ] && echo 1 || echo 0)"
  echo "# HELP ops_toolkit_collect_timestamp_seconds When the collection ran"
  echo "# TYPE ops_toolkit_collect_timestamp_seconds gauge"
  echo "ops_toolkit_collect_timestamp_seconds $ts"

  if [ -s "$WORK/disk-space.json" ]; then
    echo "# HELP ops_toolkit_fs_free_percent Free space per mount point"
    echo "# TYPE ops_toolkit_fs_free_percent gauge"
    jq -r '.filesystems[] | "ops_toolkit_fs_free_percent{mount=\(.mount|@json),filesystem=\(.filesystem|@json)} \(.free_percent)"' \
      "$WORK/disk-space.json"
    echo "# HELP ops_toolkit_fs_low_total Filesystems at or below the threshold"
    echo "# TYPE ops_toolkit_fs_low_total gauge"
    jq -r '"ops_toolkit_fs_low_total \(.low_count)"' "$WORK/disk-space.json"
  fi

  if [ -s "$WORK/incident-triage.json" ]; then
    echo "# HELP ops_toolkit_load_per_core 1-minute load divided by CPU count"
    echo "# TYPE ops_toolkit_load_per_core gauge"
    jq -r '"ops_toolkit_load_per_core \(.load.per_core)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_memory_used_percent Memory in use"
    echo "# TYPE ops_toolkit_memory_used_percent gauge"
    jq -r '"ops_toolkit_memory_used_percent \(.memory.used_percent)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_failed_units_total systemd units in failed state"
    echo "# TYPE ops_toolkit_failed_units_total gauge"
    jq -r '"ops_toolkit_failed_units_total \(.failed_units | length)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_alerts_total Alerts raised by the triage"
    echo "# TYPE ops_toolkit_alerts_total gauge"
    jq -r '"ops_toolkit_alerts_total \(.alerts | length)"' "$WORK/incident-triage.json"
  fi

  if [ -s "$WORK/audit-hardening.json" ]; then
    echo "# HELP ops_toolkit_audit_findings_total Audit findings by severity"
    echo "# TYPE ops_toolkit_audit_findings_total gauge"
    jq -r '.summary | to_entries[] | "ops_toolkit_audit_findings_total{severity=\(.key|@json)} \(.value)"' \
      "$WORK/audit-hardening.json"
  fi

  if [ -s "$WORK/net-monitor.json" ]; then
    echo "# HELP ops_toolkit_ping_loss_percent Packet loss per host"
    echo "# TYPE ops_toolkit_ping_loss_percent gauge"
    jq -r '.hosts[] | "ops_toolkit_ping_loss_percent{host=\(.host|@json)} \(.loss_percent)"' "$WORK/net-monitor.json"
  fi

  if [ -s "$WORK/check-endpoints.json" ]; then
    echo "# HELP ops_toolkit_endpoint_latency_ms Latency per endpoint"
    echo "# TYPE ops_toolkit_endpoint_latency_ms gauge"
    jq -r '.endpoints[] | "ops_toolkit_endpoint_latency_ms{url=\(.url|@json)} \(.latency_ms)"' "$WORK/check-endpoints.json"
  fi
}

if [ "$AS_PROM" -eq 1 ]; then output="$(build_prom)"; else output="$(build_json)"; fi

if [ -n "$OUT_FILE" ]; then
  # Atomic write: node_exporter reads this directory continuously and must never
  # pick up a half-written file.
  tmp="$(mktemp "${OUT_FILE}.XXXXXX")"
  printf '%s\n' "$output" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$OUT_FILE"
else
  printf '%s\n' "$output"
fi

[ "$failed" -eq 0 ]
