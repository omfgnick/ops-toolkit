#!/usr/bin/env bash
#
# validate-schemas.sh — Roda cada script com --json e valida a saída real
# contra o schema correspondente em schemas/.
#
# É teste de integração de verdade: sobe um servidor HTTP e um servidor TLS
# locais para exercitar os scripts de rede sem depender da internet.
#
# Usage:
#   ./tests/validate-schemas.sh
#
# Exit codes:
#   0 tudo validou · 1 alguma saída não bate com o schema
#
# Requires: python3 com jsonschema, openssl
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
if [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_DIR="$ROOT/bash"
SCHEMA_DIR="$ROOT/schemas"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT

pass=0
fail=0
skip=0

# Valida um JSON contra um schema. $1 = nome, $2 = arquivo com a saída
validate() {
  local name=$1 out=$2
  local schema="$SCHEMA_DIR/$name.schema.json"
  if [ ! -f "$schema" ]; then
    echo "  SEM SCHEMA  $name"
    fail=$((fail + 1))
    return
  fi
  if python3 -c "
import json, sys
from jsonschema import validate, ValidationError
schema = json.load(open('$schema'))
data = json.load(open('$out'))
try:
    validate(instance=data, schema=schema)
except ValidationError as e:
    print('    ' + e.message)
    print('    caminho: ' + '/'.join(str(p) for p in e.absolute_path))
    sys.exit(1)
"; then
    echo "  OK          $name"
    pass=$((pass + 1))
  else
    echo "  FALHOU      $name"
    fail=$((fail + 1))
  fi
}

# Roda um script (ignorando o código de saída, que sinaliza achados e não erro)
run_json() {
  local name=$1
  shift
  local out="$WORK/$name.json"
  if "$BASH_DIR/$name.sh" -j "$@" >"$out" 2>"$WORK/$name.err"; then :; else :; fi
  if [ ! -s "$out" ]; then
    echo "  VAZIO       $name  (stderr: $(head -1 "$WORK/$name.err" || true))"
    fail=$((fail + 1))
    return 1
  fi
  validate "$name" "$out"
}

echo "== Scripts locais =="
run_json disk-space || true
run_json incident-triage || true

# audit-hardening com um sshd_config controlado (o bug que motivou os testes)
printf 'PermitRootLogin yes\nPasswordAuthentication no\n' >"$WORK/sshd_config"
SSHD_CONFIG="$WORK/sshd_config" run_json audit-hardening || true

run_json inventory || true
run_json net-diagnose || true
run_json support-bundle -o "$WORK/bundle.tar.gz" || true

mkdir -p "$WORK/logs"
echo conteudo >"$WORK/logs/velho.log"
touch -d '30 days ago' "$WORK/logs/velho.log"
run_json rotate-logs -d "$WORK/logs" || true

# backup-verify: cria, restaura e compara — precisa de origem de verdade
mkdir -p "$WORK/src/sub"
echo alfa >"$WORK/src/a.txt"
echo beta >"$WORK/src/sub/b.txt"
run_json backup-verify -s "$WORK/src" -d "$WORK/bkp" || true

# metrics-collector agrega a saída dos outros
run_json metrics-collector -s disk-space,incident-triage || true

echo
echo "== Integração: servidor HTTP local =="
python3 -m http.server 18080 --directory "$WORK" >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
if kill -0 "$HTTP_PID" 2>/dev/null; then
  # um alvo que responde 200 e outro que não existe: exercita os dois ramos
  run_json check-endpoints "http://127.0.0.1:18080/" "http://127.0.0.1:19999/" || true
  kill "$HTTP_PID" 2>/dev/null || true
else
  echo "  PULADO      check-endpoints (não subiu o servidor HTTP)"
  skip=$((skip + 1))
fi

echo
echo "== Integração: servidor TLS local =="
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=localhost" >/dev/null 2>&1
  openssl s_server -quiet -accept 18443 -cert "$WORK/cert.pem" -key "$WORK/key.pem" >/dev/null 2>&1 &
  TLS_PID=$!
  sleep 1
  if kill -0 "$TLS_PID" 2>/dev/null; then
    # certificado de 30 dias com janela de aviso de 45: deve sair como EXPIRING
    run_json check-tls-expiry -w 45 localhost:18443 || true
    kill "$TLS_PID" 2>/dev/null || true
  else
    echo "  PULADO      check-tls-expiry (não subiu o servidor TLS)"
    skip=$((skip + 1))
  fi
else
  echo "  PULADO      check-tls-expiry (openssl ausente)"
  skip=$((skip + 1))
fi

echo
echo "== Dependentes do ambiente =="
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  run_json check-services systemd-journald || true
else
  echo "  PULADO      check-services (sem systemd neste ambiente)"
  skip=$((skip + 1))
fi

if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then
  run_json net-monitor -c 1 127.0.0.1 || true
else
  echo "  PULADO      net-monitor (ping indisponível neste ambiente)"
  skip=$((skip + 1))
fi

echo
echo "validados=$pass falharam=$fail pulados=$skip"
[ "$fail" -eq 0 ]
