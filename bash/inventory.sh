#!/usr/bin/env bash
#
# inventory.sh — Levanta o inventário da máquina num relatório só: identificação,
# sistema operacional, CPU, memória, discos, rede e pacotes instalados.
#
# Serve para alimentar CMDB e para anexar em chamado com fornecedor, onde a
# primeira pergunta costuma ser "qual é o modelo, o serial e a versão".
#
# Somente leitura: não altera nada.
#
# Usage:
#   ./inventory.sh [options]
#
# Options:
#   -j           Emite JSON em vez do relatório legível
#   -o FILE      Também grava a saída em FILE
#   -h           Mostra esta ajuda
#
# Exit codes:
#   0 sucesso · 2 uso incorreto
#
# Examples:
#   ./inventory.sh
#   ./inventory.sh -j | jq '.os, .cpu'
#   ./inventory.sh -o "/var/tmp/inv-$(hostname).txt"
#
# Requires: coreutils. Usa dmidecode, lsblk e o gerenciador de pacotes quando
# disponíveis; o que faltar aparece como null/desconhecido em vez de quebrar.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

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
      echo "A opção -$OPTARG exige um argumento." >&2
      exit 2
      ;;
    \?)
      echo "Opção desconhecida: -$OPTARG" >&2
      exit 2
      ;;
  esac
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }

# Lê um campo do /etc/os-release sem executar o arquivo
os_field() {
  [ -r /etc/os-release ] || return 0
  awk -F= -v k="$1" '$1 == k { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release | head -1
}

# ---- Identificação -----------------------------------------------------------
HOSTNAME_S="$(hostname 2>/dev/null || echo desconhecido)"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME_S")"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# dmidecode exige root; sem ele os campos ficam vazios, e tudo bem
VENDOR=""
MODEL=""
SERIAL=""
if have dmidecode && [ "$(id -u)" -eq 0 ]; then
  VENDOR="$(dmidecode -s system-manufacturer 2>/dev/null | head -1 || true)"
  MODEL="$(dmidecode -s system-product-name 2>/dev/null | head -1 || true)"
  SERIAL="$(dmidecode -s system-serial-number 2>/dev/null | head -1 || true)"
fi

# ---- Sistema operacional -----------------------------------------------------
OS_NAME="$(os_field PRETTY_NAME)"
[ -n "$OS_NAME" ] || OS_NAME="$(uname -s)"
OS_ID="$(os_field ID)"
OS_VERSION="$(os_field VERSION_ID)"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
UPTIME_S="$(uptime -p 2>/dev/null || echo desconhecido)"

# ---- CPU ---------------------------------------------------------------------
CPU_MODEL="desconhecido"
if [ -r /proc/cpuinfo ]; then
  CPU_MODEL="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(awk -F': ' '/^Model/ { print $2; exit }' /proc/cpuinfo)"
  [ -n "$CPU_MODEL" ] || CPU_MODEL="desconhecido"
fi
CPU_COUNT="$(nproc 2>/dev/null || echo 1)"

# ---- Memória -----------------------------------------------------------------
MEM_TOTAL_KB=0
if [ -r /proc/meminfo ]; then
  MEM_TOTAL_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
fi

# ---- Discos ------------------------------------------------------------------
disks=()
if have lsblk; then
  while IFS= read -r line; do
    [ -n "$line" ] && disks+=("$line")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3 == "disk" { name=$1; size=$2; $1=$2=$3=""; sub(/^ +/, ""); print name "|" size "|" $0 }')
fi

# ---- Rede --------------------------------------------------------------------
ifaces=()
if have ip; then
  while IFS= read -r line; do
    [ -n "$line" ] && ifaces+=("$line")
  done < <(ip -o -4 addr show 2>/dev/null | awk '{ print $2 "|" $4 }')
fi

# ---- Pacotes -----------------------------------------------------------------
PKG_MANAGER="desconhecido"
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

# ---- Saída -------------------------------------------------------------------
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
  echo " INVENTÁRIO — $HOSTNAME_S"
  echo " $NOW"
  echo "==============================================================="
  echo
  echo "-- Identificação -----------------------------------------------"
  printf '  Hostname    : %s\n' "$HOSTNAME_S"
  printf '  FQDN        : %s\n' "$FQDN"
  printf '  Fabricante  : %s\n' "${VENDOR:-(precisa de root/dmidecode)}"
  printf '  Modelo      : %s\n' "${MODEL:-(precisa de root/dmidecode)}"
  printf '  Serial      : %s\n' "${SERIAL:-(precisa de root/dmidecode)}"
  echo
  echo "-- Sistema -----------------------------------------------------"
  printf '  SO          : %s\n' "$OS_NAME"
  printf '  Kernel      : %s (%s)\n' "$KERNEL" "$ARCH"
  printf '  Uptime      : %s\n' "$UPTIME_S"
  printf '  Pacotes     : %s (%s)\n' "$PKG_COUNT" "$PKG_MANAGER"
  echo
  echo "-- Hardware ----------------------------------------------------"
  printf '  CPU         : %s x%s\n' "$CPU_MODEL" "$CPU_COUNT"
  printf '  Memória     : %s kB\n' "$MEM_TOTAL_KB"
  echo
  echo "-- Discos ------------------------------------------------------"
  if [ ${#disks[@]} -eq 0 ]; then
    echo "  (lsblk indisponível)"
  else
    for d in "${disks[@]}"; do
      IFS='|' read -r name size model <<<"$d"
      printf '  %-10s %-10s %s\n' "$name" "$size" "$model"
    done
  fi
  echo
  echo "-- Rede --------------------------------------------------------"
  if [ ${#ifaces[@]} -eq 0 ]; then
    echo "  (ip indisponível)"
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
