#!/usr/bin/env bash
#
# install.sh — Installs the ops-toolkit Bash scripts as system commands.
#
# Each script becomes a command without the .sh extension: 'incident-triage'
# instead of './bash/incident-triage.sh'.
#
# Usage:
#   ./install.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/install.sh | bash
#
# Options:
#   -p DIR       Install directory (default: /usr/local/bin as root,
#                ~/.local/bin otherwise)
#   -u           Uninstall the commands this script installed
#   -n           Dry run: print what would happen, copy or delete nothing
#   -h           Show this help
#
# Exit codes:
#   0 success · 1 failure · 2 bad usage
#
# Examples:
#   sudo ./install.sh                 # /usr/local/bin
#   ./install.sh -p ~/bin             # your own directory
#   sudo ./install.sh -u              # uninstall
#
# Requires: coreutils. Uses git only when run outside a clone of the repository.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

REPO_URL="https://github.com/omfgnick/ops-toolkit"
PREFIX=""
UNINSTALL=0
DRY_RUN=0

case "${1:-}" in
  --help)
    usage
    exit 0
    ;;
esac

while getopts ":p:unh" opt; do
  case "$opt" in
    p) PREFIX="$OPTARG" ;;
    u) UNINSTALL=1 ;;
    n) DRY_RUN=1 ;;
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

# Without -p, pick by privilege: root installs for everyone, a regular user
# installs for themselves — instead of failing with "permission denied".
if [ -z "$PREFIX" ]; then
  if [ "$(id -u)" -eq 0 ]; then PREFIX=/usr/local/bin; else PREFIX="$HOME/.local/bin"; fi
fi

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] $*"
  else
    "$@"
  fi
}

# ---- Where the files come from -----------------------------------------------
# Run from inside the repository, it uses the local files. Run through
# 'curl | bash' there is no repository, so it clones into a temp directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
SRC_DIR=""
VERSION_FILE=""
CLONED=""

if [ -n "$HERE" ] && [ -d "$HERE/bash" ]; then
  SRC_DIR="$HERE/bash"
  VERSION_FILE="$HERE/VERSION"
elif [ "$UNINSTALL" -eq 0 ]; then
  command -v git >/dev/null 2>&1 || {
    echo "git not found; it is needed to download the toolkit." >&2
    exit 1
  }
  CLONED="$(mktemp -d)"
  say "Downloading from $REPO_URL..."
  git clone --depth 1 --quiet "$REPO_URL" "$CLONED" || {
    echo "Failed to clone $REPO_URL" >&2
    exit 1
  }
  SRC_DIR="$CLONED/bash"
  VERSION_FILE="$CLONED/VERSION"
fi
trap '[ -n "$CLONED" ] && rm -rf "$CLONED"' EXIT

# ---- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  say "Uninstalling from $PREFIX"
  removed=0
  for path in "$PREFIX"/*; do
    [ -f "$path" ] || continue
    # Only remove files carrying the toolkit marker, so a same-named command
    # from somewhere else is left alone. The marker sits after the help header,
    # which is well past line 30 in several scripts — so scan the whole file.
    if grep -q 'OPS_TOOLKIT_VERSION' "$path" 2>/dev/null; then
      run rm -f -- "$path"
      say "  removed: $(basename "$path")"
      removed=$((removed + 1))
    fi
  done
  say "$removed command(s) removed."
  exit 0
fi

# ---- Install -----------------------------------------------------------------
[ -d "$SRC_DIR" ] || {
  echo "Script directory not found." >&2
  exit 1
}

VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
say "ops-toolkit $VERSION → $PREFIX"

if [ ! -d "$PREFIX" ]; then
  run mkdir -p "$PREFIX"
fi
if [ "$DRY_RUN" -eq 0 ] && [ ! -w "$PREFIX" ]; then
  echo "No write permission on $PREFIX. Run with sudo or pass -p." >&2
  exit 1
fi

installed=0
for script in "$SRC_DIR"/*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script" .sh)"
  run install -m 0755 "$script" "$PREFIX/$name"
  say "  $name"
  installed=$((installed + 1))
done

say ""
say "$installed command(s) installed."

# A command installed outside PATH is a command nobody finds.
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    say ""
    say "WARNING: $PREFIX is not on your PATH. Add this to your shell:"
    say "  export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

say ""
say "Try:  incident-triage --version"
