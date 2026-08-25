#!/usr/bin/env bash
#
# gen-docs.sh — Gera as referências em docs/ a partir do cabeçalho dos scripts.
#
# Existe pelo mesmo motivo do gen-man.sh: o cabeçalho já é a fonte da ajuda
# (-h no Bash, Get-Help no PowerShell), e uma segunda descrição escrita à mão
# diverge. E divergiu: o README apontava "referência completa" para um arquivo
# que documentava 2 dos 16 scripts Bash, e o do PowerShell parou nos 12 que
# existiam quando foi escrito.
#
# Usage:
#   ./tools/gen-docs.sh [-c]
#
# Options:
#   -c           Não grava nada; falha se o que está em docs/ estiver
#                desatualizado (é assim que o CI usa)
#   -h           Mostra esta ajuda
#
# Exit codes:
#   0 sucesso · 1 docs/ desatualizado (só com -c) · 2 uso incorreto
#
# Examples:
#   ./tools/gen-docs.sh
#   ./tools/gen-docs.sh -c
#
# Requires: coreutils
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

CHECK_ONLY=0
while getopts ":ch" opt; do
  case "$opt" in
    c) CHECK_ONLY=1 ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Opção desconhecida: -$OPTARG" >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
  echo "Argumento inesperado: $1" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$ROOT/docs"

# ---- Extração ----------------------------------------------------------------
#
# Nenhum awk daqui sai antes de ler tudo, e isso NAO e estilo.
#
# Quem sai cedo no meio de um pipeline fecha a propria entrada; o estagio
# anterior leva SIGPIPE, e com 'set -o pipefail' o pipeline inteiro devolve
# nao-zero — o 'set -e' derruba o script sem imprimir uma linha sequer. Foi
# assim que o gen-docs morreu no meio do quarto arquivo, no rockylinux e nao no
# debian: gawk e mawk esvaziam o buffer em momentos diferentes, entao o
# resultado dependia de quem o kernel escalonava primeiro.
#
# O padrao aqui e sempre 'fim = 1; next': marca e le ate o fim. Custa alguns kB
# de leitura a mais e tira a corrida do caminho.

# O bloco de cabeçalho de um script Bash: tudo entre o shebang e a primeira
# linha que não é comentário. É exatamente o que o -h imprime.
bash_header() {
  # O 'trim' tira as linhas em branco das pontas: a linha 2 do script é sempre
  # um '#' sozinho, e sem isso todo bloco de código começava com um vazio.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1" |
    sem_metadados_do_menu | trim_blank
}

# Category: e Ask: sao para o menu montar a tela, nao para a referencia. Os
# rotulos sao escritos em portugues e vazariam para o docs/*.en.md, que e
# justamente o que a checagem de idioma existe para impedir.
#
# O .NOTES precisa de olhar adiante: em 16 scripts ele SO tem o Category:, e
# imprimi-lo deixaria um titulo de secao sem nada embaixo.
sem_metadados_do_menu() {
  awk '
    { l[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (l[i] ~ /^[[:space:]]*(Category|Ask):/) { corta = 1; continue }

        if (l[i] ~ /^[[:space:]]*\.NOTES[[:space:]]*$/) {
          vazia = 1
          for (j = i + 1; j <= NR; j++) {
            if (l[j] ~ /^[[:space:]]*$/) continue
            if (l[j] ~ /^[[:space:]]*(Category|Ask):/) continue
            if (l[j] ~ /^[[:space:]]*\./) break
            vazia = 0
            break
          }
          if (vazia) { corta = 1; continue }
        }

        # Uma linha em branco logo apos o que foi cortado viraria vazio duplo
        if (corta && l[i] ~ /^[[:space:]]*$/) continue
        corta = 0
        print l[i]
      }
    }
  '
}

# Remove linhas em branco do começo e do fim, preservando as do meio.
trim_blank() {
  awk '
    { lines[NR] = $0 }
    END {
      first = 1
      last = NR
      while (first <= NR && lines[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  '
}

# A primeira frase do cabeçalho, usada como resumo na lista.
bash_summary() {
  bash_header "$1" | awk '
    fim { next }
    /^[a-z0-9-]+\.sh — / { sub(/^[a-z0-9-]+\.sh — /, ""); buf = $0; next }
    buf != "" && /^[[:space:]]*$/ { fim = 1; next }
    buf != "" { buf = buf " " $0; next }
    END { print buf }
  ' | sed 's/\([^.]*\.\).*/\1/'
}

# O bloco <# ... #> no topo de um script PowerShell, sem os delimitadores.
ps_header() {
  # Os .ps1 sao CRLF por politica do repositorio (o .gitattributes garante), e
  # sem tirar o CR a saida gerada no Windows difere da gerada no Linux em toda
  # linha - o check do CI acusaria divergencia que nao existe.
  tr -d '\015' <"$1" | awk '
    fim { next }
    /^<#/ { inblock = 1; next }
    inblock && /^#>/ { inblock = 0; fim = 1; next }
    inblock { sub(/^    /, ""); print }
  ' | sem_metadados_do_menu | trim_blank
}

ps_summary() {
  ps_header "$1" | awk '
    fim { next }
    /^\.SYNOPSIS/ { grab = 1; next }
    grab && /^\./ { fim = 1; next }
    grab && /^[[:space:]]*$/ { if (buf != "") fim = 1; next }
    grab { sub(/^[[:space:]]+/, ""); buf = (buf == "" ? $0 : buf " " $0) }
    END { print buf }
  ' | sed 's/\([^.]*\.\).*/\1/'
}

# ---- Geração -----------------------------------------------------------------

# $1 = arquivo de saída, $2 = 'bash'|'powershell', $3 = 'en'|'pt-BR'
generate() {
  local out=$1 kind=$2 lang=$3
  local other title intro listing note

  if [ "$kind" = bash ]; then
    title="Bash Scripts"
    other="bash"
  else
    title="PowerShell Scripts"
    other="powershell"
  fi

  if [ "$lang" = en ]; then
    other="[Português (BR)]($other.pt-BR.md)"
    intro="**English** · $other"
    listing="## Scripts"
    note="Every entry below is the script's own header — the same text \`-h\` prints — so this page cannot describe a script differently from the script itself. Generated by [\`tools/gen-docs.sh\`](../tools/gen-docs.sh); edit the script header, not this file."
  else
    other="[English]($other.en.md)"
    intro="**Português (BR)** · $other"
    listing="## Scripts"
    note="Cada entrada abaixo é o cabeçalho do próprio script — o mesmo texto que o \`-h\` imprime, em inglês — para que esta página não possa descrever um script de forma diferente do script. Gerada por [\`tools/gen-docs.sh\`](../tools/gen-docs.sh); edite o cabeçalho do script, não este arquivo."
  fi

  if [ "$kind" = powershell ] && [ "$lang" = pt-BR ]; then
    note="Cada entrada abaixo é a ajuda do próprio script — a mesma que o \`Get-Help\` mostra, em inglês — para que esta página não possa descrever um script de forma diferente do script. Gerada por [\`tools/gen-docs.sh\`](../tools/gen-docs.sh); edite o cabeçalho do script, não este arquivo."
  fi

  {
    echo "# $title"
    echo
    echo "$intro"
    echo
    echo "$note"
    echo
    echo "$listing"
    echo

    if [ "$kind" = bash ]; then
      for f in "$ROOT"/bash/*.sh; do
        local name
        name="$(basename "$f")"
        echo "### \`$name\`"
        echo
        bash_summary "$f"
        echo
        echo '```'
        bash_header "$f"
        echo '```'
        echo
      done
    else
      for f in "$ROOT"/powershell/*.ps1; do
        local name
        name="$(basename "$f")"
        echo "### \`$name\`"
        echo
        ps_summary "$f"
        echo
        echo '```'
        ps_header "$f"
        echo '```'
        echo
      done
    fi
  } >"$out"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

targets=(
  "bash.en.md:bash:en"
  "bash.pt-BR.md:bash:pt-BR"
  "powershell.en.md:powershell:en"
  "powershell.pt-BR.md:powershell:pt-BR"
)

drift=0
for t in "${targets[@]}"; do
  IFS=':' read -r file kind lang <<<"$t"
  generate "$TMP/$file" "$kind" "$lang"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    # Comparacao sem 'diff': a imagem rockylinux:9 nao traz o diffutils, e o
    # check falhava por ferramenta ausente em vez de por divergencia real.
    if [ ! -f "$DOCS/$file" ] || [ "$(cat "$DOCS/$file")" != "$(cat "$TMP/$file")" ]; then
      echo "DESATUALIZADO  docs/$file"
      # O detalhe e util quando existe, mas nunca decide o resultado.
      if command -v diff >/dev/null 2>&1; then
        diff -u "$DOCS/$file" "$TMP/$file" | head -20 || true
      fi
      drift=1
    else
      echo "OK             docs/$file"
    fi
  else
    mkdir -p "$DOCS"
    cp "$TMP/$file" "$DOCS/$file"
    echo "gerado  docs/$file"
  fi
done

if [ "$CHECK_ONLY" -eq 1 ] && [ "$drift" -eq 1 ]; then
  echo
  echo "Rode ./tools/gen-docs.sh e faça commit do resultado." >&2
  exit 1
fi
