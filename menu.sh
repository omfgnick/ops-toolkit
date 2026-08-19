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
#   ./menu.sh -r NAME [args]  # run one script directly, no menu
#   bash <(curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh)
#
# Options:
#   -l           List the available scripts and exit
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

readonly OPS_TOOLKIT_VERSION="1.0.0"

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
RUN_NAME=""
# Parsing manual em vez de getopts: tudo depois de "-r NOME" pertence ao script
# escolhido, e o getopts tentaria interpretar essas opções como suas.
while [ $# -gt 0 ]; do
  case "$1" in
    -l)
      LIST_ONLY=1
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BASH_DIR="$HERE/bash"
[ -d "$BASH_DIR" ] || {
  echo "Script directory not found: $BASH_DIR" >&2
  echo "Run this from a clone of the repository." >&2
  exit 2
}

# Colours only when writing to a terminal, so piping to a file stays clean.
if [ -t 1 ]; then
  B=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  CYAN=$'\033[36m'
  R=$'\033[0m'
else
  B=''
  DIM=''
  GREEN=''
  CYAN=''
  R=''
fi

# One-line summary from the script's own header - the same text that feeds -h,
# so the menu can never describe a script differently from its documentation.
summary_of() {
  awk '
    NR == 1 { next }
    /^# [a-z0-9-]+\.sh —/ { sub(/^# [a-z0-9-]+\.sh — /, ""); buf = $0; next }
    buf != "" && /^#[[:space:]]*$/ { exit }
    buf != "" && /^# / { sub(/^# /, ""); buf = buf " " $0; next }
    buf != "" { exit }
    END { print buf }
  ' "$1" | sed 's/\([^.]*\.\).*/\1/'
}

names=()
while IFS= read -r f; do
  names+=("$(basename "$f" .sh)")
done < <(find "$BASH_DIR" -maxdepth 1 -name '*.sh' | sort)

[ ${#names[@]} -gt 0 ] || {
  echo "No scripts found in $BASH_DIR" >&2
  exit 2
}

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${names[@]}"
  exit 0
fi

run_script() {
  local name=$1
  shift
  local path="$BASH_DIR/$name.sh"
  [ -f "$path" ] || {
    echo "No such script: $name" >&2
    return 2
  }
  echo
  echo "${CYAN}--- $name ${R}"
  echo
  # The exit code is reported rather than swallowed: several scripts use 1 to
  # signal a finding, which is information, not a crash.
  local rc=0
  bash "$path" "$@" || rc=$?
  echo
  if [ "$rc" -eq 0 ]; then
    echo "${GREEN}exit $rc${R}"
  else
    echo "${B}exit $rc${R} ${DIM}(1 = finding or failure, 2 = bad usage)${R}"
  fi
  return "$rc"
}

if [ -n "$RUN_NAME" ]; then
  run_script "$RUN_NAME" "$@"
  exit $?
fi

# With 'curl | bash' the script itself occupies stdin, so reading from stdin
# would consume the script instead of the user's answer - hence /dev/tty.
# Existence is not enough: inside a container without a TTY the device is there
# but cannot be opened, so try it for real and fall back to stdin, which is what
# a scripted "printf ... | menu.sh" needs anyway.
if [ -t 0 ]; then
  INPUT=/dev/stdin
elif (exec 3</dev/tty) 2>/dev/null; then
  INPUT=/dev/tty
else
  INPUT=/dev/stdin
fi

while true; do
  echo
  echo "${B}ops-toolkit${R} ${DIM}$OPS_TOOLKIT_VERSION${R}"
  echo "${DIM}$(uname -s) $(uname -r) · $(hostname)${R}"
  echo
  i=1
  for n in "${names[@]}"; do
    printf '  %s%2d%s  %-22s %s%s%s\n' "$CYAN" "$i" "$R" "$n" "$DIM" "$(summary_of "$BASH_DIR/$n.sh")" "$R"
    i=$((i + 1))
  done
  echo
  printf '  %s q%s  quit\n' "$CYAN" "$R"
  echo
  printf 'Choose a number (add arguments after it, e.g. "3 -t 20"): '

  IFS= read -r answer <"$INPUT" || {
    echo
    exit 0
  }
  case "$answer" in
    q | Q | quit | exit | '')
      echo
      exit 0
      ;;
  esac

  # Everything after the number is forwarded to the script as arguments.
  choice="${answer%% *}"
  rest=""
  [ "$answer" != "$choice" ] && rest="${answer#* }"

  case "$choice" in
    '' | *[!0-9]*)
      echo "Not a number: $choice"
      continue
      ;;
  esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#names[@]} ]; then
    echo "Out of range: $choice"
    continue
  fi

  selected="${names[$((choice - 1))]}"
  if [ -n "$rest" ]; then
    # shellcheck disable=SC2086
    run_script "$selected" $rest || true
  else
    run_script "$selected" || true
  fi

  printf '\n%sPress Enter to return to the menu...%s' "$DIM" "$R"
  IFS= read -r _ <"$INPUT" || exit 0
done
