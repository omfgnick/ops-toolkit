#!/usr/bin/env bash
#
# gen-man.sh — Gera as páginas de manual a partir do cabeçalho dos scripts.
#
# O cabeçalho já é a fonte da ajuda (-h); aqui ele vira man page também, para
# não existirem duas descrições que divergem com o tempo.
#
# Usage:
#   ./tools/gen-man.sh [-o DIR]
#
# Options:
#   -o DIR       Onde gravar as páginas (padrão: man/man1)
#   -h           Mostra esta ajuda
#
# Exit codes:
#   0 sucesso · 2 uso incorreto
#
# Requires: coreutils
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

OUT_DIR="man/man1"
while getopts ":o:h" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
DATE="$(date '+%d %b %Y')"
mkdir -p "$OUT_DIR"

count=0
for script in "$ROOT"/bash/*.sh; do
  name="$(basename "$script" .sh)"
  page="$OUT_DIR/$name.1"

  # A seção NOME pede uma linha só. Junta o primeiro parágrafo do cabeçalho e
  # corta na primeira frase — pegar só a primeira linha partia a frase no meio.
  summary="$(awk '
    NR == 1 { next }
    /^# [a-z0-9-]+\.sh —/ { sub(/^# [a-z0-9-]+\.sh — /, ""); buf = $0; next }
    buf != "" && /^#[[:space:]]*$/ { exit }
    buf != "" && /^# / { sub(/^# /, ""); buf = buf " " $0; next }
    buf != "" { exit }
    END { print buf }
  ' "$script" | sed 's/\([^.]*\.\).*/\1/' | sed 's/[[:space:]]*$//')"
  [ -n "$summary" ] || summary="script do ops-toolkit"

  {
    printf '.TH %s 1 "%s" "ops-toolkit %s" "ops-toolkit manual"\n' \
      "$(echo "$name" | tr '[:lower:]' '[:upper:]')" "$DATE" "$VERSION"
    printf '.SH NAME\n%s \\- %s\n' "$name" "$summary"
    printf '.SH DESCRIPTION\n'
    # Reaproveita o bloco de cabeçalho, escapando o que o roff interpreta
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$script" |
      sed -e 's/\\/\\\\/g' -e "s/^'/\\\\&'/" -e 's/^\./\\\&./' |
      awk 'NF == 0 { print ".PP"; next } { print }'
    printf '.SH VERSION\nops-toolkit %s\n' "$VERSION"
    printf '.SH REPOSITORY\nhttps://github.com/omfgnick/ops-toolkit\n'
    printf '.SH LICENSE\nMIT\n'
  } >"$page"
  count=$((count + 1))
done

echo "$count página(s) geradas em $OUT_DIR"
