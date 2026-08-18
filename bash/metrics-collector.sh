#!/usr/bin/env bash
#
# metrics-collector.sh — Roda os scripts de relatório, junta a saída --json num
# documento só e, opcionalmente, escreve métricas no formato do Prometheus para
# o textfile collector do node_exporter.
#
# É a ponte entre os scripts e a monitoração: em vez de cada um ser chamado à
# mão, um cron chama este e o Grafana/Zabbix lê o resultado.
#
# Somente leitura: nenhum dos scripts invocados altera estado.
#
# Usage:
#   ./metrics-collector.sh [options]
#
# Options:
#   -o FILE      Escreve a saída em FILE em vez de stdout (gravação atômica)
#   -p           Formato Prometheus (textfile collector) em vez de JSON
#   -j           JSON (já é o padrão; aceito para uniformidade com os demais)
#   -s LIST      Scripts a executar, separados por vírgula
#                (padrão: disk-space,incident-triage,audit-hardening)
#   -t SEGUNDOS  Tempo máximo por script (padrão: 30)
#   -h           Mostra esta ajuda
#
# Exit codes:
#   0 tudo coletado · 1 algum script falhou · 2 uso incorreto
#
# Examples:
#   ./metrics-collector.sh | jq .
#   ./metrics-collector.sh -p -o /var/lib/node_exporter/textfile/ops.prom
#   ./metrics-collector.sh -s disk-space,net-monitor
#
# Cron sugerido (a cada 5 minutos):
#   */5 * * * * /usr/local/bin/metrics-collector.sh -p -o /var/lib/node_exporter/textfile/ops.prom
#
# Requires: jq
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

OUT_FILE=""
AS_PROM=0
SCRIPTS="disk-space,incident-triage,audit-hardening"
TIMEOUT=30

while getopts ":o:pjs:t:h" opt; do
  case "$opt" in
    o) OUT_FILE="$OPTARG" ;;
    p) AS_PROM=1 ;;
    # JSON já é o padrão aqui; -j existe só para manter o contrato uniforme
    # com os demais scripts do toolkit.
    j) AS_PROM=0 ;;
    s) SCRIPTS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
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

command -v jq >/dev/null 2>&1 || {
  echo "jq não encontrado; este script precisa dele para juntar os JSONs." >&2
  exit 2
}
case "$TIMEOUT" in '' | *[!0-9]*)
  echo "-t deve ser um inteiro." >&2
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
    echo "aviso: $name.sh não encontrado ou não executável; ignorando." >&2
    failed=$((failed + 1))
    continue
  fi
  # O código de saída destes scripts sinaliza achados (1 = há alerta), não erro
  # de execução. O que importa aqui é ter JSON válido de volta.
  if timeout "$TIMEOUT" "$script" -j >"$WORK/$name.json" 2>"$WORK/$name.err" || true; then :; fi
  if [ -s "$WORK/$name.json" ] && jq -e . "$WORK/$name.json" >/dev/null 2>&1; then
    collected+=("$name")
  else
    echo "aviso: $name não devolveu JSON válido: $(head -1 "$WORK/$name.err" 2>/dev/null || true)" >&2
    failed=$((failed + 1))
  fi
done

# ---- Monta o documento agregado ---------------------------------------------
build_json() {
  # $ts e $host abaixo são variáveis do jq (passadas com --arg), não do shell —
  # por isso o filtro fica entre aspas simples de propósito.
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

# ---- Formato Prometheus ------------------------------------------------------
# Só o que faz sentido como série temporal: contadores e percentuais.
build_prom() {
  local ts
  ts="$(date +%s)"
  echo "# HELP ops_toolkit_up 1 quando a coleta terminou sem falha"
  echo "# TYPE ops_toolkit_up gauge"
  echo "ops_toolkit_up $([ "$failed" -eq 0 ] && echo 1 || echo 0)"
  echo "# HELP ops_toolkit_collect_timestamp_seconds Momento da coleta"
  echo "# TYPE ops_toolkit_collect_timestamp_seconds gauge"
  echo "ops_toolkit_collect_timestamp_seconds $ts"

  if [ -s "$WORK/disk-space.json" ]; then
    echo "# HELP ops_toolkit_fs_free_percent Espaço livre por ponto de montagem"
    echo "# TYPE ops_toolkit_fs_free_percent gauge"
    jq -r '.filesystems[] | "ops_toolkit_fs_free_percent{mount=\(.mount|@json),filesystem=\(.filesystem|@json)} \(.free_percent)"' \
      "$WORK/disk-space.json"
    echo "# HELP ops_toolkit_fs_low_total Filesystems no ou abaixo do limiar"
    echo "# TYPE ops_toolkit_fs_low_total gauge"
    jq -r '"ops_toolkit_fs_low_total \(.low_count)"' "$WORK/disk-space.json"
  fi

  if [ -s "$WORK/incident-triage.json" ]; then
    echo "# HELP ops_toolkit_load_per_core Carga de 1 minuto dividida pelas CPUs"
    echo "# TYPE ops_toolkit_load_per_core gauge"
    jq -r '"ops_toolkit_load_per_core \(.load.per_core)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_memory_used_percent Memória em uso"
    echo "# TYPE ops_toolkit_memory_used_percent gauge"
    jq -r '"ops_toolkit_memory_used_percent \(.memory.used_percent)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_failed_units_total Unidades systemd em falha"
    echo "# TYPE ops_toolkit_failed_units_total gauge"
    jq -r '"ops_toolkit_failed_units_total \(.failed_units | length)"' "$WORK/incident-triage.json"
    echo "# HELP ops_toolkit_alerts_total Alertas abertos pela triagem"
    echo "# TYPE ops_toolkit_alerts_total gauge"
    jq -r '"ops_toolkit_alerts_total \(.alerts | length)"' "$WORK/incident-triage.json"
  fi

  if [ -s "$WORK/audit-hardening.json" ]; then
    echo "# HELP ops_toolkit_audit_findings_total Achados da auditoria por severidade"
    echo "# TYPE ops_toolkit_audit_findings_total gauge"
    jq -r '.summary | to_entries[] | "ops_toolkit_audit_findings_total{severity=\(.key|@json)} \(.value)"' \
      "$WORK/audit-hardening.json"
  fi

  if [ -s "$WORK/net-monitor.json" ]; then
    echo "# HELP ops_toolkit_ping_loss_percent Perda de pacotes por host"
    echo "# TYPE ops_toolkit_ping_loss_percent gauge"
    jq -r '.hosts[] | "ops_toolkit_ping_loss_percent{host=\(.host|@json)} \(.loss_percent)"' "$WORK/net-monitor.json"
  fi

  if [ -s "$WORK/check-endpoints.json" ]; then
    echo "# HELP ops_toolkit_endpoint_latency_ms Latência por endpoint"
    echo "# TYPE ops_toolkit_endpoint_latency_ms gauge"
    jq -r '.endpoints[] | "ops_toolkit_endpoint_latency_ms{url=\(.url|@json)} \(.latency_ms)"' "$WORK/check-endpoints.json"
  fi
}

if [ "$AS_PROM" -eq 1 ]; then output="$(build_prom)"; else output="$(build_json)"; fi

if [ -n "$OUT_FILE" ]; then
  # Gravação atômica: o node_exporter lê este diretório continuamente e não
  # pode pegar um arquivo pela metade.
  tmp="$(mktemp "${OUT_FILE}.XXXXXX")"
  printf '%s\n' "$output" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$OUT_FILE"
else
  printf '%s\n' "$output"
fi

[ "$failed" -eq 0 ]
