#!/usr/bin/env bash
#
# menu.sh — Interactive launcher for the toolkit: pick a script from a numbered
# list instead of remembering names and flags.
#
# The list is built from the scripts themselves, so a new script shows up here
# with no change to this file.
#
# Usage:
#   ./menu.sh                 # interactive menu
#   ./menu.sh -l              # just list what is available, one per line
#   ./menu.sh -c              # the same catalogue the menu draws, as JSON
#   ./menu.sh -r NAME [args]  # run one script directly, no menu
#   curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh | bash
#
# Run straight from the web, it asks where to put the toolkit before downloading
# anything. Set DESTINATION=temp|keep|/some/path to skip the question.
#
# Options:
#   -l           List the available scripts and exit
#   -c           Print the catalogue as JSON (name, category, summary, prompts)
#   -r NAME      Run NAME (with any following arguments) and exit
#   -h           Show this help
#
# Exit codes:
#   0 success · 1 the chosen script failed · 2 bad usage
#
# Requires: bash 4+. Scripts live next to this file, in bash/.
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

LIST_ONLY=0
CATALOG_ONLY=0
RUN_NAME=""
# Parsing manual em vez de getopts: tudo depois de "-r NOME" pertence ao script
# escolhido, e o getopts tentaria interpretar essas opções como suas.
while [ $# -gt 0 ]; do
  case "$1" in
    -l)
      LIST_ONLY=1
      shift
      ;;
    -c)
      CATALOG_ONLY=1
      shift
      ;;
    -r)
      [ $# -ge 2 ] || {
        echo "Option -r requires a script name." >&2
        exit 2
      }
      RUN_NAME="$2"
      shift 2
      break # o resto é do script, não deste menu
      ;;
    -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

REPO="https://github.com/omfgnick/ops-toolkit"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BASH_DIR="$HERE/bash"

# Piped in ('curl ... | bash') there is no file on disk, so the scripts this
# menu launches are nowhere near it. Fetch the repository first - after asking,
# because downloading onto someone's machine is not a decision to make for them
# in silence.
if [ ! -d "$BASH_DIR" ]; then
  TMP_PATH="${TMPDIR:-/tmp}/ops-toolkit"
  KEEP_PATH="$HOME/ops-toolkit"

  # Where to read the answer: with 'curl | bash' stdin is the script itself.
  if [ -t 0 ]; then
    ASK=/dev/stdin
  elif (exec 3</dev/tty) 2>/dev/null; then
    ASK=/dev/tty
  else
    ASK=""
  fi

  if [ -n "${DESTINATION:-}" ]; then
    case "$DESTINATION" in
      temp | Temp) TARGET="$TMP_PATH" ;;
      keep | Keep) TARGET="$KEEP_PATH" ;;
      *) TARGET="$DESTINATION" ;;
    esac
    echo "Destination: $TARGET"
  elif [ -z "$ASK" ]; then
    echo "ops-toolkit is not here and there is no terminal to ask where to put it." >&2
    echo "Set DESTINATION=temp|keep|/some/path and run again." >&2
    exit 2
  else
    echo
    echo "ops-toolkit is not on this machine yet. Where should it go?"
    echo
    echo "   1  Temporary folder - just trying it out   $TMP_PATH"
    echo "   2  Keep it - installs for real             $KEEP_PATH"
    echo "   q  cancel"
    echo
    printf 'Choose: '
    IFS= read -r where <"$ASK" || where=""
    case "$where" in
      1) TARGET="$TMP_PATH" ;;
      2) TARGET="$KEEP_PATH" ;;
      *)
        echo "Cancelled - nothing was downloaded."
        exit 0
        ;;
    esac
  fi

  if [ ! -d "$TARGET/bash" ]; then
    command -v curl >/dev/null 2>&1 || {
      echo "curl not found; needed to download the toolkit." >&2
      exit 1
    }
    echo "Downloading ops-toolkit into $TARGET ..."
    unpack="$(mktemp -d)"
    if ! curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$unpack"; then
      echo "Could not download the toolkit." >&2
      rm -rf "$unpack"
      exit 1
    fi
    rm -rf "$TARGET"
    mkdir -p "$(dirname "$TARGET")"
    mv "$unpack/ops-toolkit-main" "$TARGET"
    rm -rf "$unpack"
    chmod +x "$TARGET"/bash/*.sh "$TARGET"/menu.sh 2>/dev/null || true
  else
    echo "Using the copy already in $TARGET"
  fi

  HERE="$TARGET"
  BASH_DIR="$HERE/bash"
  if [ "$TARGET" = "$TMP_PATH" ]; then
    echo "This copy is in a temporary folder and the system may delete it."
    echo "To keep it: git clone $REPO"
  fi
fi

[ -d "$BASH_DIR" ] || {
  echo "Script directory not found: $BASH_DIR" >&2
  exit 2
}

# Cor só quando a saída é um terminal, para "menu.sh > arquivo" sair limpo.
if [ -t 1 ]; then
  B=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  CYAN=$'\033[36m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  R=$'\033[0m'
else
  B=''
  DIM=''
  GREEN=''
  CYAN=''
  YELLOW=''
  RED=''
  R=''
fi

# ---- Leitura do cabeçalho dos scripts ----------------------------------------
#
# Resumo, categoria e perguntas saem todos do cabeçalho do próprio script, que é
# também o texto que o -h imprime. Um catálogo separado divergiria com o tempo —
# foi exatamente o que aconteceu com docs/, que chegou a documentar 2 dos 16
# scripts sem ninguém notar.

summary_of() {
  awk '
    NR == 1 { next }
    /^# [a-z0-9_-]+\.sh —/ { sub(/^# [a-z0-9_-]+\.sh — /, ""); buf = $0; next }
    buf != "" && /^#[[:space:]]*$/ { exit }
    buf != "" && /^# / { sub(/^# /, ""); buf = buf " " $0; next }
    buf != "" { exit }
    END { print buf }
  ' "$1" | sed 's/\([^.]*\.\).*/\1/'
}

category_of() {
  awk '/^# Category:/ { sub(/^# Category:[[:space:]]*/, ""); print; exit }' "$1"
}

# Uma pergunta por linha, no formato "flag|rótulo". O flag '@' significa
# argumento posicional, sem letra na frente.
asks_of() {
  awk '/^# Ask:/ {
    sub(/^# Ask:[[:space:]]*/, "")
    gsub(/[[:space:]]*\|[[:space:]]*/, "|")
    print
  }' "$1"
}

# ---- Catálogo ----------------------------------------------------------------
# Triagem primeiro porque é por onde todo chamado começa.
ORDEM="Triage Network Services Security Backup Inventory Other"

names=()
cats=()
sums=()
while IFS= read -r f; do
  names+=("$(basename "$f" .sh)")
  c="$(category_of "$f")"
  # Categoria fora da lista conhecida cai em "Outros" em vez de sumir: o laco
  # que desenha a tela so percorre as secoes de $ORDEM, entao um erro de
  # digitacao apagaria o script do menu sem avisar ninguem.
  case " $ORDEM " in
    *" $c "*) : ;;
    *) c="" ;;
  esac
  cats+=("${c:-Other}")
  sums+=("$(summary_of "$f")")
done < <(find "$BASH_DIR" -maxdepth 1 -name '*.sh' | sort)

[ ${#names[@]} -gt 0 ] || {
  echo "No script found in $BASH_DIR" >&2
  exit 2
}

# O catálogo em JSON não é só para os testes: é o que permite montar outro
# front-end sem reimplementar a leitura dos cabeçalhos.
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "$CATALOG_ONLY" -eq 1 ]; then
  # A ordem tem de ser a MESMA que a tela desenha: o numero que alguem le no
  # catalogo e o numero que vai digitar no menu.
  ordenados=()
  for secao in $ORDEM; do
    for i in "${!names[@]}"; do
      [ "${cats[$i]}" = "$secao" ] && ordenados+=("$i")
    done
  done

  printf '[\n'
  for pos in "${!ordenados[@]}"; do
    i="${ordenados[$pos]}"
    perguntas=""
    while IFS="|" read -r flag rotulo; do
      [ -n "$flag" ] || continue
      [ -z "$perguntas" ] || perguntas="$perguntas,"
      perguntas="$perguntas{\"flag\":\"$(json_escape "$flag")\",\"label\":\"$(json_escape "$rotulo")\"}"
    done < <(asks_of "$BASH_DIR/${names[$i]}.sh")
    printf '  {"name":"%s","category":"%s","summary":"%s","asks":[%s]}' \
      "$(json_escape "${names[$i]}")" "$(json_escape "${cats[$i]}")" \
      "$(json_escape "${sums[$i]}")" "$perguntas"
    [ "$pos" -lt $((${#ordenados[@]} - 1)) ] && printf ','
    printf '\n'
  done
  printf ']\n'
  exit 0
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${names[@]}"
  exit 0
fi

# ---- Execução ----------------------------------------------------------------

# A saída de cada execução fica aqui até o usuário decidir se guarda.
RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT

LAST_OUTPUT=""
INPUT=/dev/stdin

# Pergunta o que o script exige em vez de deixá-lo falhar com "uso incorreto".
# É o maior atrito do dia a dia: ter de saber a flag de cabeça.
prompt_args() {
  local path=$1 flag rotulo valor
  ARGS=()
  while IFS='|' read -r flag rotulo; do
    [ -n "$flag" ] || continue
    printf '  %s%s%s: ' "$CYAN" "$rotulo" "$R"
    IFS= read -u 3 -r valor || return 1
    [ -n "$valor" ] || continue
    if [ "$flag" = '@' ]; then
      # Posicional pode ser mais de um valor (várias URLs, por exemplo)
      # shellcheck disable=SC2206
      ARGS+=($valor)
    else
      ARGS+=("$flag" "$valor")
    fi
  done < <(asks_of "$path")
  # Fixa o contrato: só uma leitura cancelada (Ctrl-D) devolve não-zero daqui.
  # Sem isto o status seria o do último comando do laço, que muda conforme o
  # caminho percorrido — e quem chama decide RODAR ou não com base nele.
  return 0
}

regua() {
  local largura=$((52 - ${#1}))
  [ "$largura" -lt 1 ] && largura=1
  printf '%*s' "$largura" '' | tr ' ' '-'
}

run_script() {
  local name=$1
  shift
  local path="$BASH_DIR/$name.sh"
  [ -f "$path" ] || {
    echo "No such script: $name" >&2
    return 2
  }

  local saida="$RUN_DIR/$name-$(date +%H%M%S).txt"
  echo
  printf '%s+- %s %s%s\n' "$CYAN" "$name" "$(regua "$name")" "$R"
  echo

  # O código de saída é reportado, não engolido: em vários scripts 1 significa
  # "achou algo", que é informação e não falha.
  local rc=0
  bash "$path" "$@" 2>&1 | tee "$saida"
  rc=${PIPESTATUS[0]}

  echo
  case "$rc" in
    0) printf '%s+- done (0)%s\n' "$GREEN" "$R" ;;
    1) printf '%s+- finding or failure (1)%s\n' "$YELLOW" "$R" ;;
    2) printf '%s+- bad usage (2)%s\n' "$RED" "$R" ;;
    *) printf '%s+- exited with %s%s\n' "$RED" "$rc" "$R" ;;
  esac
  LAST_OUTPUT="$saida"
  return "$rc"
}

# ---- Modo direto -------------------------------------------------------------
if [ -n "$RUN_NAME" ]; then
  run_script "$RUN_NAME" "$@"
  exit $?
fi

# Com "curl | bash" o próprio script ocupa a entrada padrão, então ler dali
# consumiria o script em vez da resposta — daí /dev/tty. Existir não basta: num
# contêiner sem TTY o dispositivo está lá mas não abre, então a tentativa é real
# e o retorno é stdin, que é o que um "printf ... | menu.sh" precisa.
# O override existe para os testes: sem ele a origem depende de haver TTY, e
# a mesma suite passaria num runner e travaria noutro.
if [ -n "${OPS_MENU_INPUT:-}" ]; then
  INPUT="$OPS_MENU_INPUT"
elif [ -t 0 ]; then
  INPUT=/dev/stdin
elif (exec 3</dev/tty) 2>/dev/null; then
  INPUT=/dev/tty
else
  INPUT=/dev/stdin
fi

# Abrir uma vez só, e não a cada pergunta: reabrir /dev/stdin num cano dá EOF
# na segunda leitura em algumas plataformas, e o menu perdia a resposta logo
# depois de perguntar o argumento.
exec 3<"$INPUT"

FILTER=""

# A numeração é global e segue a ordem de exibição, então o número de um script
# só muda quando o filtro muda — e o filtro fica sempre visível no cabeçalho.
build_visible() {
  VIS_IDX=()
  local secao i
  for secao in $ORDEM; do
    for i in "${!names[@]}"; do
      [ "${cats[$i]}" = "$secao" ] || continue
      if [ -n "$FILTER" ]; then
        case "${names[$i]} ${sums[$i]}" in
          *"$FILTER"*) : ;;
          *) continue ;;
        esac
      fi
      VIS_IDX+=("$i")
    done
  done
}

# A lista é para escanear, não para ler: um resumo de três linhas some com a
# estrutura de categorias. A frase inteira continua no -l e no -h do script.
curto() {
  local t="$1"
  if [ ${#t} -gt 66 ]; then
    printf "%s..." "${t:0:63}"
  else
    printf "%s" "$t"
  fi
}

draw() {
  local atual="" num=1 i
  echo
  printf '%s+- ops-toolkit %s%s\n' "$CYAN" "$OPS_TOOLKIT_VERSION" "$R"
  printf '%s|%s  %s . %s . %s\n' "$CYAN" "$R" \
    "$(hostname 2>/dev/null || echo '?')" "$(uname -s) $(uname -r)" "$(date '+%H:%M')"
  if [ -n "$FILTER" ]; then
    printf '%s|%s  %sfilter: %s%s   %s(/ alone clears)%s\n' \
      "$CYAN" "$R" "$YELLOW" "$FILTER" "$R" "$DIM" "$R"
  fi
  printf '%s+%s\n' "$CYAN" "$R"

  if [ ${#VIS_IDX[@]} -eq 0 ]; then
    echo
    printf '  %snothing matches "%s"%s\n' "$DIM" "$FILTER" "$R"
  fi

  for i in ${VIS_IDX[@]+"${VIS_IDX[@]}"}; do
    if [ "${cats[$i]}" != "$atual" ]; then
      atual="${cats[$i]}"
      printf '\n  %s%s%s\n' "$B" "$atual" "$R"
    fi
    printf '  %s%2d%s  %-20s %s%s%s\n' \
      "$CYAN" "$num" "$R" "${names[$i]}" "$DIM" "$(curto "${sums[$i]}")" "$R"
    num=$((num + 1))
  done

  echo
  printf '  %s/text%s filter    %s3,7%s several    %ss%s save    %sq%s quit\n' \
    "$CYAN" "$R" "$CYAN" "$R" "$CYAN" "$R" "$CYAN" "$R"
  echo
}

# Guardar o relatório é metade do trabalho: anexar num chamado é o passo
# seguinte de quase toda execução.
save_last() {
  if [ -z "$LAST_OUTPUT" ] || [ ! -f "$LAST_OUTPUT" ]; then
    echo "  Nothing to save yet."
    return 0
  fi
  local destino padrao
  padrao="$PWD/$(basename "$LAST_OUTPUT")"
  printf '  %sSave to%s [%s]: ' "$CYAN" "$R" "$padrao"
  IFS= read -u 3 -r destino || return 0
  [ -n "$destino" ] || destino="$padrao"
  if cp "$LAST_OUTPUT" "$destino" 2>/dev/null; then
    printf '  %ssaved to %s%s\n' "$GREEN" "$destino" "$R"
  else
    printf '  %scould not write to %s%s\n' "$RED" "$destino" "$R"
  fi
}

executar_indice() {
  local num=$1 rest=$2
  local i="${VIS_IDX[$((num - 1))]}"
  local nome="${names[$i]}"
  local path="$BASH_DIR/$nome.sh"

  if [ -n "$rest" ]; then
    # shellcheck disable=SC2086
    run_script "$nome" $rest || true
    return 0
  fi

  # Sem argumento na linha: se o script exige algum, pergunta antes de rodar.
  if [ -n "$(asks_of "$path")" ]; then
    echo
    printf '  %s%s needs:%s\n' "$DIM" "$nome" "$R"
    prompt_args "$path" || return 0
    run_script "$nome" ${ARGS[@]+"${ARGS[@]}"} || true
  else
    run_script "$nome" || true
  fi
}

pausa() {
  printf '\n  %sEnter to go back' "$DIM"
  [ -n "$LAST_OUTPUT" ] && printf ', or "s" to save the output'
  printf '%s: ' "$R"
  IFS= read -u 3 -r depois || exit 0
  case "$depois" in
    s | S)
      save_last
      printf '\n  %sEnter to go back...%s' "$DIM" "$R"
      IFS= read -u 3 -r _ || exit 0
      ;;
  esac
}

while true; do
  build_visible
  draw

  printf '  Choose: '
  IFS= read -u 3 -r answer || {
    echo
    exit 0
  }

  case "$answer" in
    q | Q | quit | exit | '')
      echo
      exit 0
      ;;
    s | S)
      save_last
      printf '\n  %sEnter to go back...%s' "$DIM" "$R"
      IFS= read -u 3 -r _ || exit 0
      continue
      ;;
    /)
      FILTER=""
      continue
      ;;
    /*)
      FILTER="${answer#/}"
      continue
      ;;
  esac

  choice="${answer%% *}"
  rest=""
  [ "$answer" != "$choice" ] && rest="${answer#* }"

  # "3,7,9" roda os três em ordem: uma triagem inteira num comando só.
  case "$choice" in
    *,*)
      IFS=',' read -ra lote <<<"$choice"
      for num in "${lote[@]}"; do
        num="$(printf '%s' "$num" | tr -d ' ')"
        case "$num" in
          '' | *[!0-9]*)
            printf '  %signored: %s%s\n' "$DIM" "$num" "$R"
            continue
            ;;
        esac
        if [ "$num" -lt 1 ] || [ "$num" -gt ${#VIS_IDX[@]} ]; then
          printf '  %sout of range: %s%s\n' "$DIM" "$num" "$R"
          continue
        fi
        executar_indice "$num" ""
      done
      pausa
      continue
      ;;
    '' | *[!0-9]*)
      printf '  Not a number: %s\n' "$choice"
      continue
      ;;
  esac

  if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#VIS_IDX[@]} ]; then
    printf '  Out of range: %s\n' "$choice"
    continue
  fi

  executar_indice "$choice" "$rest"

  # A saída fica na tela até o usuário mandar voltar: redesenhar na hora
  # empurraria o relatório para cima antes de alguém ler.
  pausa
done
