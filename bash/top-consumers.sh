#!/usr/bin/env bash
#
# top-consumers.sh — Lists the processes using the most CPU, memory and disk,
# with the account each one runs under.
#
# The second question of every "this machine is slow" ticket, right after "who
# is logged on".
#
# A note on the CPU column, because it is a common trap: the %CPU that ps
# prints is an AVERAGE OVER THE PROCESS LIFETIME, not usage right now. Sorting
# by it lists whatever has been busy since boot, which on a server is usually
# the database — busy or not at this moment.
#
# This script samples /proc twice and reports the difference, which is real
# usage during the window, normalised by core count so 100% means the whole
# machine and not one core. Where /proc is unavailable it falls back to ps and
# says so, instead of pretending the number means something else.
#
# Read-only: this script never kills or renices anything.
#
# Usage:
#   ./top-consumers.sh [options]
#
# Options:
#   -n COUNT     How many processes per category (default 5)
#   -s SECONDS   CPU sample window (default 2)
#   -j           Emit JSON instead of the readable report
#   -o FILE      Also write the output to FILE
#   -h           Show this help
#
# Exit codes:
#   0 success · 2 bad usage
#
# Examples:
#   ./top-consumers.sh
#   ./top-consumers.sh -n 10 -s 5
#   ./top-consumers.sh -j | jq '.top_cpu[0]'
#
# Requires: coreutils and ps. Uses /proc for sampled CPU and per-process I/O
# when available.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.1.0"

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

TOP=5
SAMPLE=2
AS_JSON=0
OUT_FILE=""

while getopts ":n:s:jo:h" opt; do
  case "$opt" in
    n) TOP="$OPTARG" ;;
    s) SAMPLE="$OPTARG" ;;
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
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
  echo "Unexpected argument: $1" >&2
  exit 2
fi

for par in "TOP:$TOP" "SAMPLE:$SAMPLE"; do
  nome="${par%%:*}"
  valor="${par#*:}"
  case "$valor" in
    '' | *[!0-9]* | 0)
      echo "-${nome:0:1} expects a positive number, got: $valor" >&2
      exit 2
      ;;
  esac
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}

CORES="$(nproc 2>/dev/null || echo 1)"
[ "$CORES" -ge 1 ] 2>/dev/null || CORES=1

CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
[ "$CLK" -ge 1 ] 2>/dev/null || CLK=100

# ---- CPU: duas amostras de /proc, ou ps como reserva --------------------------
CPU_SOURCE="proc-sampled"
declare -A ANTES=()

amostra_proc() {
  # utime + stime por PID, em ticks
  local pid stat campos
  # Glob em vez de 'ls | grep': nome de diretorio com caractere estranho
  # quebraria o pipe, e o shellcheck reprova o padrao com razao.
  local caminho
  for caminho in /proc/[0-9]*; do
    pid="${caminho##*/}"
    [ -r "/proc/$pid/stat" ] || continue
    stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    [ -n "$stat" ] || continue
    # O nome do processo vem entre parenteses e pode conter espacos: corta ate
    # o ultimo ')' antes de separar os campos, senao o indice sai errado.
    campos="${stat##*) }"
    # shellcheck disable=SC2206
    local arr=($campos)
    # apos o ')', utime e o campo 12 e stime o 13 (indices 11 e 12 aqui)
    echo "$pid ${arr[11]:-0} ${arr[12]:-0}"
  done
}

if [ -r /proc/1/stat ]; then
  while read -r pid u s; do
    ANTES["$pid"]=$((u + s))
  done < <(amostra_proc)
  sleep "$SAMPLE"
else
  CPU_SOURCE="ps-lifetime"
fi

rows=()

if [ "$CPU_SOURCE" = "proc-sampled" ]; then
  while read -r pid u s; do
    total=$((u + s))
    antes="${ANTES[$pid]:-$total}"
    delta=$((total - antes))
    [ "$delta" -lt 0 ] && delta=0
    # ticks -> segundos -> fracao da janela -> fracao da maquina
    pct=$(awk -v d="$delta" -v clk="$CLK" -v w="$SAMPLE" -v c="$CORES" \
      'BEGIN { printf "%.1f", (d / clk) / w / c * 100 }')
    nome="$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo '?')"
    rssk="$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || echo 0)"
    [ -n "$rssk" ] || rssk=0
    memmb=$(awk -v k="$rssk" 'BEGIN { printf "%.1f", k / 1024 }')
    dono="$(stat -c %U "/proc/$pid" 2>/dev/null || echo '?')"
    # /proc/PID/io exige privilegio para processo de outro usuario
    io=0
    if [ -r "/proc/$pid/io" ]; then
      io="$(awk '/^read_bytes:|^write_bytes:/ { s += $2 } END { printf "%.1f", s / 1048576 }' "/proc/$pid/io" 2>/dev/null || echo 0)"
    fi
    rows+=("$pid|$nome|$pct|$memmb|$io|$dono")
  done < <(amostra_proc)
else
  # Sem /proc: ps devolve a media de vida do processo, e o relatorio diz isso
  while IFS= read -r linha; do
    [ -n "$linha" ] && rows+=("$linha")
  done < <(ps -eo pid=,comm=,pcpu=,rss=,user= 2>/dev/null |
    awk '{ printf "%s|%s|%s|%.1f|0|%s\n", $1, $2, $3, $4/1024, $5 }' || true)
fi

TOTAL=${#rows[@]}

ordena() {
  # $1 = indice do campo (1-based) para ordenar desc
  printf '%s\n' ${rows[@]+"${rows[@]}"} | sort -t'|' -k"$1","$1"gr | head -n "$TOP"
}

TOP_CPU="$(ordena 3)"
TOP_MEM="$(ordena 4)"
TOP_IO="$(ordena 5)"

MEM_TOTAL=0
MEM_FREE=0
if [ -r /proc/meminfo ]; then
  MEM_TOTAL="$(awk '/^MemTotal:/ { printf "%.1f", $2/1048576 }' /proc/meminfo)"
  # MemAvailable nao existe em kernel antigo nem no /proc parcial do Git Bash.
  # Vazio aqui vira '"memory_free_gb":,' e quebra o JSON inteiro - o mesmo
  # tipo de furo que ja mordeu o check-endpoints com o codigo 000.
  MEM_FREE="$(awk '/^MemAvailable:/ { printf "%.1f", $2/1048576 }' /proc/meminfo)"
fi
# Rede de seguranca: campo numerico do JSON nunca pode sair vazio
case "$MEM_TOTAL" in '' | *[!0-9.]*) MEM_TOTAL=0 ;; esac
case "$MEM_FREE" in '' | *[!0-9.]*) MEM_FREE=0 ;; esac

emite_json_lista() {
  local first=1 linha pid nome pct mem io dono
  printf '['
  while IFS= read -r linha; do
    [ -n "$linha" ] || continue
    IFS='|' read -r pid nome pct mem io dono <<<"$linha"
    # Mesma protecao por item: um campo vazio invalidaria o documento todo
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    case "$pct" in '' | *[!0-9.]*) pct=0 ;; esac
    case "$mem" in '' | *[!0-9.]*) mem=0 ;; esac
    case "$io" in '' | *[!0-9.]*) io=0 ;; esac
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"pid":%s,"name":"%s","cpu_pct":%s,"memory_mb":%s,"io_mb":%s,"user":"%s"}' \
      "$pid" "$(json_escape "$nome")" "$pct" "$mem" "$io" "$(json_escape "$dono")"
  done <<<"$1"
  printf ']'
}

render_json() {
  printf '{'
  printf '"host":"%s",' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
  printf '"generated_at":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '"cpu_source":"%s",' "$CPU_SOURCE"
  printf '"cores":%s,' "$CORES"
  printf '"sample_seconds":%s,' "$SAMPLE"
  printf '"memory_total_gb":%s,' "$MEM_TOTAL"
  printf '"memory_free_gb":%s,' "$MEM_FREE"
  printf '"process_count":%s,' "$TOTAL"
  printf '"top_cpu":'
  emite_json_lista "$TOP_CPU"
  printf ','
  printf '"top_memory":'
  emite_json_lista "$TOP_MEM"
  printf ','
  printf '"top_io":'
  emite_json_lista "$TOP_IO"
  printf ',"status":0}\n'
}

tabela() {
  local titulo="$1" dados="$2" campo="$3" unidade="$4"
  local linha pid nome pct mem io dono valor
  echo "  $titulo"
  if [ -z "$dados" ]; then
    echo "    (nothing to show)"
    echo
    return 0
  fi
  while IFS= read -r linha; do
    [ -n "$linha" ] || continue
    IFS='|' read -r pid nome pct mem io dono <<<"$linha"
    case "$campo" in
      cpu) valor="$pct" ;;
      mem) valor="$mem" ;;
      io) valor="$io" ;;
    esac
    printf '    %8s %-26s %9s%s  %s\n' "$pid" "$nome" "$valor" "$unidade" "$dono"
  done <<<"$dados"
  echo
}

render_text() {
  echo "Top consumers - $(hostname 2>/dev/null || echo unknown)"
  echo "Generated at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if [ "$CPU_SOURCE" = "proc-sampled" ]; then
    echo "$CORES core(s) - CPU sampled over ${SAMPLE}s - 100% means the whole machine"
  else
    echo "$CORES core(s) - /proc unavailable: CPU is the process LIFETIME average, not current use"
  fi
  if [ "$MEM_TOTAL" != "0" ]; then
    echo "Memory: ${MEM_FREE} GB available of ${MEM_TOTAL} GB"
  fi
  echo

  tabela 'BY CPU' "$TOP_CPU" cpu '%'
  tabela 'BY MEMORY (resident)' "$TOP_MEM" mem ' MB'
  tabela 'BY DISK I/O (accumulated; needs privilege for other users)' "$TOP_IO" io ' MB'
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
if [ -n "$OUT_FILE" ]; then printf '%s\n' "$output" >"$OUT_FILE"; fi
exit 0
