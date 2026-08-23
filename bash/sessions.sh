#!/usr/bin/env bash
#
# sessions.sh — Reports who is logged on: terminals, remote sessions, idle time
# and the sessions that are still open with nobody at the other end.
#
# Answers the first question of almost every support ticket — "who is on this
# machine, and since when".
#
# The number that matters is not how many people are logged in: it is how many
# sessions are IDLE or came from a remote address. A shell parked for three
# days still holds locks, keeps a tmux alive and counts as a way in.
#
# Read-only: this script never changes anything and never kills a session.
#
# Usage:
#   ./sessions.sh [options]
#
# Options:
#   -j           Emit JSON instead of the readable report
#   -i HOURS     Treat a session as parked after this many idle hours (default 4)
#   -o FILE      Also write the output to FILE
#   -h           Show this help
#
# Exit codes:
#   0 nothing worth attention · 1 parked or remote session found · 2 bad usage
#
# Examples:
#   ./sessions.sh
#   ./sessions.sh -j | jq '.parked, .remote'
#   ./sessions.sh -i 1
#
# Requires: coreutils and 'who'. Uses 'w' and 'last' when available; whatever is
# missing is reported as unknown instead of failing.
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

AS_JSON=0
IDLE_WARN=4
OUT_FILE=""

while getopts ":ji:o:h" opt; do
  case "$opt" in
    j) AS_JSON=1 ;;
    i) IDLE_WARN="$OPTARG" ;;
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

# getopts stops at the first operand, so "sessions.sh foo -j" would print the
# readable report and silently ignore -j. Refuse instead of misleading.
if [ $# -gt 0 ]; then
  echo "Unexpected argument: $1" >&2
  exit 2
fi

case "$IDLE_WARN" in
  '' | *[!0-9]*)
    echo "-i expects a number of hours, got: $IDLE_WARN" >&2
    exit 2
    ;;
esac

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }

# 'w' reports idle as '.', '1:23', '12:34m', '3days'. Tratar tudo como numero
# daria 3 horas para uma sessao parada ha 3 dias.
idle_to_hours() {
  local v="$1"
  case "$v" in
    '' | '.' | '-') echo 0 ;;
    *days*) echo $((${v%%days*} * 24)) ;;
    *:*m)
      v="${v%m}"
      echo $((${v%%:*}))
      ;;
    *:*) echo $((${v%%:*})) ;;
    *m) echo 0 ;;
    *s) echo 0 ;;
    *) echo 0 ;;
  esac
}

sessions=()
SOURCE="who"

# 'w' traz ocioso e o que a sessao esta rodando; 'who' so traz o basico. Sem
# 'pipefail' desligado aqui, uma saida vazia derrubaria o script.
if have w; then
  SOURCE="w"
  while IFS= read -r line; do
    [ -n "$line" ] && sessions+=("$line")
  done < <(w -h 2>/dev/null | awk '{ user=$1; tty=$2; from=$3; idle=$5; $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print user "|" tty "|" from "|" idle "|" $0 }' || true)
elif have who; then
  while IFS= read -r line; do
    [ -n "$line" ] && sessions+=("$line")
  done < <(who 2>/dev/null | awk '{ print $1 "|" $2 "|" ($5 == "" ? "-" : $5) "|-|" }' || true)
else
  SOURCE="none"
fi

TOTAL=${#sessions[@]}
PARKED=0
REMOTE=0

# Um endereco na coluna de origem significa sessao vinda de outra maquina.
# ':0' e ':0.0' sao a sessao grafica local e nao contam.
is_remote() {
  case "$1" in
    '' | '-' | ':'* | 'tty'*) return 1 ;;
    *) return 0 ;;
  esac
}

rows=()
for s in ${sessions[@]+"${sessions[@]}"}; do
  IFS='|' read -r user tty from idle what <<<"$s"
  hours="$(idle_to_hours "$idle")"
  parked=false
  remote=false
  if [ "$hours" -ge "$IDLE_WARN" ]; then
    parked=true
    PARKED=$((PARKED + 1))
  fi
  if is_remote "$from"; then
    remote=true
    REMOTE=$((REMOTE + 1))
  fi
  rows+=("$user|$tty|$from|$idle|$hours|$parked|$remote|$what")
done

STATUS=0
if [ "$PARKED" -gt 0 ] || [ "$REMOTE" -gt 0 ]; then
  STATUS=1
fi

# Ultimos logins ajudam a explicar uma sessao que nao esta mais aberta
RECENT=""
if have last; then
  RECENT="$(last -n 5 2>/dev/null | grep -v '^$' | grep -v '^wtmp' | head -5 || true)"
fi

render_json() {
  local first=1 user tty from idle hours parked remote what r
  printf '{'
  printf '"host":"%s",' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
  printf '"generated_at":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '"source":"%s",' "$SOURCE"
  printf '"idle_warn_hours":%s,' "$IDLE_WARN"
  printf '"count":%s,' "$TOTAL"
  printf '"parked":%s,' "$PARKED"
  printf '"remote":%s,' "$REMOTE"
  printf '"items":['
  for r in ${rows[@]+"${rows[@]}"}; do
    IFS='|' read -r user tty from idle hours parked remote what <<<"$r"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"user":"%s","tty":"%s","from":"%s","idle":"%s","idle_hours":%s,"parked":%s,"remote":%s,"running":"%s"}' \
      "$(json_escape "$user")" "$(json_escape "$tty")" "$(json_escape "$from")" \
      "$(json_escape "$idle")" "$hours" "$parked" "$remote" "$(json_escape "$what")"
  done
  printf '],'
  printf '"status":%s' "$STATUS"
  printf '}\n'
}

render_text() {
  local user tty from idle hours parked remote what r marca

  echo "User sessions - $(hostname 2>/dev/null || echo unknown)"
  echo "Generated at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo

  if [ "$SOURCE" = none ]; then
    echo "  Neither 'w' nor 'who' is available here; no session could be read."
    return 0
  fi
  if [ "$TOTAL" -eq 0 ]; then
    echo "  Nobody is logged on."
    return 0
  fi

  printf '  %-16s %-10s %-18s %-7s %s\n' "USER" "TTY" "FROM" "IDLE" "RUNNING"
  for r in ${rows[@]+"${rows[@]}"}; do
    IFS='|' read -r user tty from idle hours parked remote what <<<"$r"
    marca=' '
    [ "$parked" = true ] && marca='!'
    [ "$remote" = true ] && marca='@'
    printf ' %s%-16s %-10s %-18s %-7s %s\n' "$marca" "$user" "$tty" "$from" "$idle" "$what"
  done
  echo
  printf '  %s session(s) - %s parked (idle >= %sh), %s remote\n' "$TOTAL" "$PARKED" "$IDLE_WARN" "$REMOTE"
  echo "  ! parked   @ from another machine"

  if [ -n "$RECENT" ]; then
    echo
    echo "  Recent logins"
    printf '%s\n' "$RECENT" | sed 's/^/    /'
  fi
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
if [ -n "$OUT_FILE" ]; then printf '%s\n' "$output" >"$OUT_FILE"; fi
exit "$STATUS"
