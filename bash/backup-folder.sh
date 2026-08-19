#!/usr/bin/env bash
#
# backup-folder.sh — Compressed backup of a directory with integrity check and
# optional e-mail notification.
#
# Usage:
#   ./backup-folder.sh [-s SRC_DIR] [-d DST_DIR] [-e EMAIL]
#
# Environment variables (used when the matching flag is not given):
#   SRC_DIR, DST_DIR, EMAIL_RECIPIENT
#
set -euo pipefail

# Print only the header block (skip the shebang, stop at the first command)
# instead of dumping every comment in the file.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.1.0"

# --version / --help before getopts: getopts only understands single-letter
# options, and these two are what people reach for by reflex.
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

# ---- Defaults / configuration ------------------------------------------------
SRC_DIR="${SRC_DIR:-/path/to/source/directory}"
DST_DIR="${DST_DIR:-/path/to/destination/directory}"
EMAIL_RECIPIENT="${EMAIL_RECIPIENT:-}" # empty => notification disabled
EMAIL_SUBJECT="Backup Status"

# ---- Parse arguments ---------------------------------------------------------
while getopts ":s:d:e:h" opt; do
  case "$opt" in
    s) SRC_DIR="$OPTARG" ;;
    d) DST_DIR="$OPTARG" ;;
    e) EMAIL_RECIPIENT="$OPTARG" ;;
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

# ---- Work area (always cleaned up) -------------------------------------------
TMP_DIR="$(mktemp -d)"
LOG_FILE="$TMP_DIR/backup.log"
trap 'rm -rf "$TMP_DIR"' EXIT

# Log to both stdout and the log file.
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ---- E-mail notification -----------------------------------------------------
# Sends a real message (headers + body) via sendmail when a recipient is set
# and the binary exists; otherwise it is a no-op.
send_email() {
  local status="$1"
  [ -n "$EMAIL_RECIPIENT" ] || return 0
  local sendmail_bin
  sendmail_bin="$(command -v sendmail || echo /usr/sbin/sendmail)"
  [ -x "$sendmail_bin" ] || {
    log "sendmail not found; skipping e-mail."
    return 0
  }

  {
    echo "To: $EMAIL_RECIPIENT"
    echo "Subject: $EMAIL_SUBJECT — $status"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo "Backup executed with status: $status"
    echo
    echo "----- Log -----"
    cat "$LOG_FILE"
  } | "$sendmail_bin" -t -i
}

# Report a failure, notify, and exit.
fail() {
  log "ERROR: $*"
  send_email "Failed"
  exit 1
}

# ---- Pre-flight checks -------------------------------------------------------
[ -d "$SRC_DIR" ] || fail "Source directory does not exist: $SRC_DIR"
mkdir -p "$DST_DIR" || fail "Cannot create destination directory: $DST_DIR"

# ---- Create the backup -------------------------------------------------------
BACKUP_FILE="$DST_DIR/backup-$(date +'%Y-%m-%d_%H%M%S').tar.gz"
log "Creating backup of '$SRC_DIR' -> '$BACKUP_FILE'..."
# -C so the archive stores paths relative to the source parent, not absolute.
tar -czf "$BACKUP_FILE" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" ||
  fail "tar failed while creating the backup."

# ---- Verify integrity --------------------------------------------------------
# The correct check is that the produced archive is itself valid and readable,
# not that its hash equals the hash of the source files (which never matches).
log "Verifying archive integrity..."
gzip -t "$BACKUP_FILE" || fail "Archive failed gzip integrity test."
tar -tzf "$BACKUP_FILE" >/dev/null || fail "Archive is not a readable tarball."

log "Backup completed successfully: $BACKUP_FILE"
send_email "Success"
