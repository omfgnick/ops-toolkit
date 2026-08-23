#!/usr/bin/env bash
#
# compare-machines.sh — Answers "why does it only fail on that machine" by
# putting two machines side by side: OS, kernel, packages, services and network.
#
# It does NOT log into anything. Remote access needs credentials, and a script
# that asks for them is a script nobody should run. Instead it works in two
# steps: each machine exports its own fingerprint, and the comparison happens
# wherever you have both files.
#
#   on machine A:   ./compare-machines.sh -e a.fp
#   on machine B:   ./compare-machines.sh -e b.fp
#   anywhere:       ./compare-machines.sh -c a.fp b.fp
#
# The fingerprint is a plain sorted text file, one "section|key|value" per line.
# Plain text on purpose: comparing it needs nothing but coreutils, and you can
# read it, diff it and put it in a ticket without any tooling.
#
# Read-only: this script never changes a setting on either machine.
#
# Usage:
#   ./compare-machines.sh -e FILE           export this machine's fingerprint
#   ./compare-machines.sh -c FILE_A FILE_B  compare two fingerprints
#
# Options:
#   -e FILE      Export the fingerprint of this machine to FILE
#   -c           Compare mode: takes two fingerprint files as operands
#   -a           Show what is EQUAL too, not only the differences
#   -j           Emit JSON instead of the readable report
#   -h           Show this help
#
# Exit codes:
#   0 no differences (or export succeeded) · 1 differences found · 2 bad usage
#
# Examples:
#   ./compare-machines.sh -e /tmp/prod.fp
#   ./compare-machines.sh -c /tmp/prod.fp /tmp/homolog.fp
#   ./compare-machines.sh -c -j a.fp b.fp | jq '.differences[]'
#
# Requires: coreutils. Reads the package manager, systemd and ip when present;
# whatever is missing is simply absent from the fingerprint.
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

EXPORT_TO=""
COMPARE=0
SHOW_EQUAL=0
AS_JSON=0

while getopts ":e:cajh" opt; do
  case "$opt" in
    e) EXPORT_TO="$OPTARG" ;;
    c) COMPARE=1 ;;
    a) SHOW_EQUAL=1 ;;
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
shift $((OPTIND - 1))

if [ -n "$EXPORT_TO" ] && [ "$COMPARE" -eq 1 ]; then
  echo "Pick one: -e exports, -c compares." >&2
  exit 2
fi
if [ -z "$EXPORT_TO" ] && [ "$COMPARE" -eq 0 ]; then
  echo "Nothing to do: use -e FILE to export, or -c FILE_A FILE_B to compare." >&2
  exit 2
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }

# Uma linha do fingerprint. O '|' separa; qualquer '|' no valor viraria coluna
# extra na comparacao, entao vira '/'.
emit() {
  printf '%s|%s|%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '|' '/' | tr -d '\n')"
}

coletar() {
  local v

  emit os hostname "$(hostname 2>/dev/null || echo unknown)"
  emit os kernel "$(uname -r 2>/dev/null || echo unknown)"
  emit os arch "$(uname -m 2>/dev/null || echo unknown)"
  if [ -r /etc/os-release ]; then
    v="$(awk -F= '$1 == "PRETTY_NAME" { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release)"
    emit os name "${v:-unknown}"
    v="$(awk -F= '$1 == "VERSION_ID" { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release)"
    emit os version "${v:-unknown}"
  fi

  if [ -r /proc/cpuinfo ]; then
    emit hw cpu_model "$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo || echo unknown)"
  fi
  emit hw cpu_count "$(nproc 2>/dev/null || echo 0)"
  if [ -r /proc/meminfo ]; then
    emit hw memory_gb "$(awk '/^MemTotal:/ { printf "%.1f", $2/1048576 }' /proc/meminfo)"
  fi

  # Pacotes: nome e versao. E onde quase sempre esta a diferenca que importa.
  if have dpkg-query; then
    dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null |
      while read -r nome versao; do emit pkg "$nome" "$versao"; done || true
  elif have rpm; then
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null |
      while read -r nome versao; do emit pkg "$nome" "$versao"; done || true
  elif have apk; then
    apk info -v 2>/dev/null | while read -r linha; do
      emit pkg "${linha%-*-*}" "$linha"
    done || true
  fi

  # Servicos habilitados, nao os que estao rodando agora: o que esta no ar varia
  # com o momento, o que esta habilitado e configuracao.
  if have systemctl; then
    systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null |
      awk '{ print $1 }' | while read -r s; do emit service "$s" enabled; done || true
  fi

  if have ip; then
    ip -o -4 addr show 2>/dev/null | awk '{ print $2, $4 }' |
      while read -r iface cidr; do emit net "$iface" "$cidr"; done || true
  fi

  # Limites que costumam explicar "so nessa maquina trava"
  emit limits open_files "$(ulimit -n 2>/dev/null || echo unknown)"
  emit limits max_procs "$(ulimit -u 2>/dev/null || echo unknown)"
}

# ---- Exportar ---------------------------------------------------------------
if [ -n "$EXPORT_TO" ]; then
  coletar | sort >"$EXPORT_TO"
  linhas="$(wc -l <"$EXPORT_TO" | tr -d ' ')"
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"mode":"export","file":"%s","lines":%s,"host":"%s","generated_at":"%s","status":0}\n' \
      "$(json_escape "$EXPORT_TO")" "$linhas" \
      "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    echo "Fingerprint of $(hostname 2>/dev/null || echo unknown) written to $EXPORT_TO ($linhas entries)."
    echo "Run the same on the other machine, then compare:"
    echo "  $(basename "$0") -c $EXPORT_TO outra.fp"
  fi
  exit 0
fi

# ---- Comparar ---------------------------------------------------------------
if [ $# -ne 2 ]; then
  echo "Compare mode needs exactly two fingerprint files." >&2
  echo "Usage: $(basename "$0") -c FILE_A FILE_B" >&2
  exit 2
fi

A="$1"
B="$2"
for f in "$A" "$B"; do
  if [ ! -r "$f" ]; then
    echo "Cannot read fingerprint: $f" >&2
    exit 2
  fi
done

HOST_A="$(awk -F'|' '$1 == "os" && $2 == "hostname" { print $3; exit }' "$A")"
HOST_B="$(awk -F'|' '$1 == "os" && $2 == "hostname" { print $3; exit }' "$B")"
[ -n "$HOST_A" ] || HOST_A="$(basename "$A")"
[ -n "$HOST_B" ] || HOST_B="$(basename "$B")"

# join precisa das duas entradas ordenadas pela MESMA chave. A chave e
# "secao|item", entao ela e montada antes e o valor fica no segundo campo.
chave() { awk -F'|' '{ printf "%s\x1f%s\t%s\n", $1, $2, $3 }' "$1" | sort -t$'\t' -k1,1; }

TA="$(mktemp)"
TB="$(mktemp)"
trap 'rm -f "$TA" "$TB"' EXIT
chave "$A" >"$TA"
chave "$B" >"$TB"

DIFFS=()
SO_A=()
SO_B=()
IGUAIS=0

while IFS=$'\t' read -r k va vb; do
  secao="${k%%$'\x1f'*}"
  item="${k#*$'\x1f'}"
  if [ "$va" = "$vb" ]; then
    IGUAIS=$((IGUAIS + 1))
    [ "$SHOW_EQUAL" -eq 1 ] && DIFFS+=("same|$secao|$item|$va|$vb")
  else
    DIFFS+=("differs|$secao|$item|$va|$vb")
  fi
done < <(join -t$'\t' -j1 -o 0,1.2,2.2 "$TA" "$TB" 2>/dev/null || true)

while IFS=$'\t' read -r k v; do
  secao="${k%%$'\x1f'*}"
  item="${k#*$'\x1f'}"
  SO_A+=("$secao|$item|$v")
done < <(join -t$'\t' -j1 -v1 -o 0,1.2 "$TA" "$TB" 2>/dev/null || true)

while IFS=$'\t' read -r k v; do
  secao="${k%%$'\x1f'*}"
  item="${k#*$'\x1f'}"
  SO_B+=("$secao|$item|$v")
done < <(join -t$'\t' -j1 -v2 -o 0,2.2 "$TA" "$TB" 2>/dev/null || true)

N_DIFF=0
for d in ${DIFFS[@]+"${DIFFS[@]}"}; do
  case "$d" in differs\|*) N_DIFF=$((N_DIFF + 1)) ;; esac
done
TOTAL=$((N_DIFF + ${#SO_A[@]} + ${#SO_B[@]}))

STATUS=0
[ "$TOTAL" -gt 0 ] && STATUS=1

render_json() {
  local first=1 d tipo secao item va vb
  printf '{'
  printf '"generated_at":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '"host_a":"%s","host_b":"%s",' "$(json_escape "$HOST_A")" "$(json_escape "$HOST_B")"
  printf '"same_count":%s,"differ_count":%s,' "$IGUAIS" "$N_DIFF"
  printf '"only_a_count":%s,"only_b_count":%s,' "${#SO_A[@]}" "${#SO_B[@]}"
  printf '"differences":['
  for d in ${DIFFS[@]+"${DIFFS[@]}"}; do
    IFS='|' read -r tipo secao item va vb <<<"$d"
    [ "$tipo" = differs ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"section":"%s","key":"%s","a":"%s","b":"%s"}' \
      "$(json_escape "$secao")" "$(json_escape "$item")" "$(json_escape "$va")" "$(json_escape "$vb")"
  done
  printf '],'
  local f2=1
  printf '"only_in_a":['
  for d in ${SO_A[@]+"${SO_A[@]}"}; do
    IFS='|' read -r secao item va <<<"$d"
    [ "$f2" -eq 1 ] || printf ','
    f2=0
    printf '{"section":"%s","key":"%s","value":"%s"}' "$(json_escape "$secao")" "$(json_escape "$item")" "$(json_escape "$va")"
  done
  printf '],'
  local f3=1
  printf '"only_in_b":['
  for d in ${SO_B[@]+"${SO_B[@]}"}; do
    IFS='|' read -r secao item vb <<<"$d"
    [ "$f3" -eq 1 ] || printf ','
    f3=0
    printf '{"section":"%s","key":"%s","value":"%s"}' "$(json_escape "$secao")" "$(json_escape "$item")" "$(json_escape "$vb")"
  done
  printf '],'
  printf '"status":%s}\n' "$STATUS"
}

render_text() {
  local d tipo secao item va vb atual=""

  echo "Machine comparison"
  echo "Generated at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "  A: $HOST_A   ($A)"
  echo "  B: $HOST_B   ($B)"
  echo

  if [ "$N_DIFF" -gt 0 ]; then
    echo "  DIFFERENT ($N_DIFF)"
    for d in ${DIFFS[@]+"${DIFFS[@]}"}; do
      IFS='|' read -r tipo secao item va vb <<<"$d"
      [ "$tipo" = differs ] || continue
      if [ "$secao" != "$atual" ]; then
        atual="$secao"
        echo "    [$secao]"
      fi
      printf '      %-32s A: %s\n' "$item" "$va"
      printf '      %-32s B: %s\n' '' "$vb"
    done
    echo
  fi

  if [ ${#SO_A[@]} -gt 0 ]; then
    echo "  ONLY ON A (${#SO_A[@]})"
    for d in ${SO_A[@]+"${SO_A[@]}"}; do
      IFS='|' read -r secao item va <<<"$d"
      printf '      %-10s %-32s %s\n' "$secao" "$item" "$va"
    done
    echo
  fi

  if [ ${#SO_B[@]} -gt 0 ]; then
    echo "  ONLY ON B (${#SO_B[@]})"
    for d in ${SO_B[@]+"${SO_B[@]}"}; do
      IFS='|' read -r secao item vb <<<"$d"
      printf '      %-10s %-32s %s\n' "$secao" "$item" "$vb"
    done
    echo
  fi

  if [ "$SHOW_EQUAL" -eq 1 ]; then
    echo "  IDENTICAL ($IGUAIS)"
    for d in ${DIFFS[@]+"${DIFFS[@]}"}; do
      IFS='|' read -r tipo secao item va vb <<<"$d"
      [ "$tipo" = same ] || continue
      printf '      %-10s %-32s %s\n' "$secao" "$item" "$va"
    done
    echo
  fi

  printf '  %s identical, %s different, %s only on A, %s only on B\n' \
    "$IGUAIS" "$N_DIFF" "${#SO_A[@]}" "${#SO_B[@]}"
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
exit "$STATUS"
