#!/usr/bin/env bash
#
# backup-verify.sh — Faz um backup compactado e o verifica restaurando de volta
# num diretório temporário e comparando as somas de verificação, arquivo por
# arquivo, com a origem.
#
# A diferença para o backup-folder.sh é essa: aqui o backup só é considerado bom
# depois de ter sido restaurado. Backup que nunca foi restaurado não é backup —
# é um arquivo grande em que se confia por fé.
#
# Usage:
#   ./backup-verify.sh -s ORIGEM -d DESTINO [opções]
#
# Options:
#   -s DIR       Diretório de origem (obrigatório)
#   -d DIR       Onde gravar o .tar.gz (obrigatório; criado se não existir)
#   -k N         Manter os N backups mais recentes deste conjunto (0 = todos)
#   -n           Dry-run: mostra o que faria, sem criar nem apagar nada
#   -j           Emite JSON em vez do relatório legível
#   -h           Mostra esta ajuda
#
# Exit codes:
#   0 backup criado e verificado · 1 falha na criação ou na verificação · 2 uso incorreto
#
# Examples:
#   ./backup-verify.sh -s /etc -d /backup
#   ./backup-verify.sh -s /var/www -d /backup -k 7
#   ./backup-verify.sh -s /etc -d /backup -j | jq '.verification'
#
# Requires: tar, gzip, sha256sum
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

SRC=""
DST=""
KEEP=0
DRY_RUN=0
AS_JSON=0

while getopts ":s:d:k:njh" opt; do
  case "$opt" in
    s) SRC="$OPTARG" ;;
    d) DST="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    j) AS_JSON=1 ;;
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

[ -n "$SRC" ] && [ -n "$DST" ] || {
  echo "-s (origem) e -d (destino) são obrigatórios. Use -h." >&2
  exit 2
}
[ -d "$SRC" ] || {
  echo "Origem não existe: $SRC" >&2
  exit 2
}
case "$KEEP" in '' | *[!0-9]*)
  echo "-k deve ser um inteiro." >&2
  exit 2
  ;;
esac
for tool in tar gzip sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool não encontrado." >&2
    exit 2
  }
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

BASE="$(basename "$(cd "$SRC" && pwd)")"
STAMP="$(date '+%Y-%m-%d_%H%M%S')"
ARCHIVE="$DST/${BASE}-${STAMP}.tar.gz"

# Conta o que existe na origem, para o relatório e para a comparação
src_files=$(find "$SRC" -type f | wc -l)
src_bytes=$(du -sb "$SRC" 2>/dev/null | cut -f1 || echo 0)

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$AS_JSON" -eq 1 ]; then
    printf '{"dry_run":true,"source":"%s","archive":"%s","source_files":%s,"source_bytes":%s,"verification":null}\n' \
      "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")" "$src_files" "$src_bytes"
  else
    echo "DRY RUN — nada foi criado."
    echo "  origem   : $SRC ($src_files arquivo(s), $src_bytes bytes)"
    echo "  criaria  : $ARCHIVE"
    [ "$KEEP" -gt 0 ] && echo "  retenção : manteria os $KEEP mais recentes"
  fi
  exit 0
fi

mkdir -p "$DST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. Criar ----------------------------------------------------------------
created=false
if tar -czf "$ARCHIVE" -C "$(dirname "$SRC")" "$(basename "$SRC")" 2>"$WORK/tar.err"; then
  created=true
else
  # tar avisa quando um arquivo muda durante a leitura; isso não invalida o
  # backup, e a verificação a seguir é quem dá o veredito.
  if [ -s "$ARCHIVE" ]; then
    created=true
    echo "aviso: tar reportou avisos: $(head -1 "$WORK/tar.err")" >&2
  fi
fi

if [ "$created" != true ]; then
  echo "ERRO: falha ao criar o arquivo." >&2
  [ "$AS_JSON" -eq 1 ] && printf '{"dry_run":false,"source":"%s","archive":"%s","created":false,"verification":null}\n' \
    "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")"
  exit 1
fi

archive_bytes=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)

# ---- 2. Restaurar e comparar -------------------------------------------------
# É aqui que o backup deixa de ser uma suposição.
restored_dir="$WORK/restore"
mkdir -p "$restored_dir"
verified=false
compared=0
mismatched=0
mismatch_examples=""

if tar -xzf "$ARCHIVE" -C "$restored_dir" 2>/dev/null; then
  src_root="$(cd "$SRC" && pwd)"
  rest_root="$restored_dir/$(basename "$SRC")"
  while IFS= read -r file; do
    rel="${file#"$src_root"/}"
    other="$rest_root/$rel"
    compared=$((compared + 1))
    if [ ! -f "$other" ]; then
      mismatched=$((mismatched + 1))
      [ "$mismatched" -le 5 ] && mismatch_examples="${mismatch_examples}ausente: $rel"$'\n'
      continue
    fi
    a="$(sha256sum "$file" | cut -d' ' -f1)"
    b="$(sha256sum "$other" | cut -d' ' -f1)"
    if [ "$a" != "$b" ]; then
      mismatched=$((mismatched + 1))
      [ "$mismatched" -le 5 ] && mismatch_examples="${mismatch_examples}difere: $rel"$'\n'
    fi
  done < <(find "$src_root" -type f)
  [ "$mismatched" -eq 0 ] && verified=true
else
  echo "ERRO: o arquivo não pôde ser extraído — backup inutilizável." >&2
fi

# ---- 3. Retenção (só depois de verificar) ------------------------------------
removed=0
if [ "$KEEP" -gt 0 ] && [ "$verified" = true ]; then
  while IFS= read -r old; do
    rm -f -- "$old" && removed=$((removed + 1))
  done < <(find "$DST" -maxdepth 1 -type f -name "${BASE}-*.tar.gz" -printf '%T@ %p\n' |
    sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
fi

# ---- Relatório ---------------------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  printf '{"dry_run":false,"source":"%s","archive":"%s","created":true,' \
    "$(json_escape "$SRC")" "$(json_escape "$ARCHIVE")"
  printf '"source_files":%s,"source_bytes":%s,"archive_bytes":%s,' \
    "$src_files" "$src_bytes" "$archive_bytes"
  printf '"verification":{"restored":%s,"files_compared":%d,"mismatched":%d},' \
    "$([ "$verified" = true ] && echo true || echo false)" "$compared" "$mismatched"
  printf '"removed_by_retention":%d}\n' "$removed"
else
  echo "Backup: $ARCHIVE"
  echo "  origem       : $SRC ($src_files arquivo(s), $src_bytes bytes)"
  echo "  arquivo      : $archive_bytes bytes"
  echo "  verificação  : $compared arquivo(s) restaurados e conferidos por sha256"
  if [ "$verified" = true ]; then
    echo "  resultado    : OK — restaurado e idêntico à origem"
  else
    echo "  resultado    : FALHOU — $mismatched divergência(s)"
    [ -n "$mismatch_examples" ] && printf '%s' "$mismatch_examples" | sed 's/^/      /'
  fi
  [ "$removed" -gt 0 ] && echo "  retenção     : $removed backup(s) antigo(s) removido(s)"
fi

[ "$verified" = true ]
