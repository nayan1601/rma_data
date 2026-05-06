#!/usr/bin/env bash
#
# Sync Google Drive SQL backups to a VPS folder named dailybackups.
#
# This script is intentionally verbose and defensive because it is operational
# code. A new intern should be able to read the comments and understand what is
# happening; a senior reviewer should be able to see the failure boundaries.
#
# Main behavior:
#   1. Read settings from an environment file.
#   2. Validate rclone, the configured remote, and the destination folder.
#   3. Create runtime directories for logs, state, and delete archives.
#   4. Run `rclone sync` or `rclone copy`.
#   5. Optionally run `rclone check --one-way`.
#   6. Write a machine-readable last-run summary.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_ENV_FILE="/etc/rclone-gdrive-sql-backup-sync.env"
ENV_FILE="${1:-${BACKUP_SYNC_ENV_FILE:-$DEFAULT_ENV_FILE}}"

RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
STARTED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
START_EPOCH="$(date +"%s")"

# These variables are initialized early because the EXIT trap references them.
LOG_FILE=""
STATE_DIR=""
VPS_DESTINATION_DIR=""
SOURCE=""
ARCHIVE_RUN_DIR=""
CHECK_STATUS="skipped"
SUMMARY_WRITTEN="false"

print() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    true | TRUE | True | 1 | yes | YES | y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' is not installed or not in PATH."
}

count_files() {
  local dir="${1:-}"
  if [[ ! -d "$dir" ]]; then
    printf '0'
    return
  fi

  find "$dir" -type f | wc -l | tr -d '[:space:]'
}

count_bytes() {
  local dir="${1:-}"
  if [[ ! -d "$dir" ]]; then
    printf '0'
    return
  fi

  du -sb "$dir" 2>/dev/null | awk '{print $1}' || printf '0'
}

get_available_bytes() {
  local dir="$1"
  df -PB1 "$dir" | awk 'NR == 2 {print $4}'
}

write_kv() {
  local key="$1"
  local value="${2:-}"

  # %q writes shell-escaped values, so paths with spaces remain parseable.
  printf '%s=%q\n' "$key" "$value"
}

write_summary() {
  local status="$1"
  local exit_code="$2"
  local finished_at_utc="$3"
  local duration_seconds="$4"
  local files_before="$5"
  local files_after="$6"
  local bytes_before="$7"
  local bytes_after="$8"
  local bytes_delta="$9"

  if [[ -z "${STATE_DIR:-}" ]]; then
    return
  fi

  mkdir -p "$STATE_DIR"

  local tmp_file="${STATE_DIR}/last-run.env.tmp"
  local summary_file="${STATE_DIR}/last-run.env"

  {
    write_kv "RUN_ID" "$RUN_ID"
    write_kv "STATUS" "$status"
    write_kv "EXIT_CODE" "$exit_code"
    write_kv "SOURCE" "$SOURCE"
    write_kv "DESTINATION" "$VPS_DESTINATION_DIR"
    write_kv "STARTED_AT_UTC" "$STARTED_AT_UTC"
    write_kv "FINISHED_AT_UTC" "$finished_at_utc"
    write_kv "DURATION_SECONDS" "$duration_seconds"
    write_kv "FILES_BEFORE" "$files_before"
    write_kv "FILES_AFTER" "$files_after"
    write_kv "BYTES_BEFORE" "$bytes_before"
    write_kv "BYTES_AFTER" "$bytes_after"
    write_kv "BYTES_DELTA" "$bytes_delta"
    write_kv "LOG_FILE" "$LOG_FILE"
    write_kv "ARCHIVE_DIR" "$ARCHIVE_RUN_DIR"
    write_kv "CHECK_STATUS" "$CHECK_STATUS"
  } >"$tmp_file"

  mv "$tmp_file" "$summary_file"
  SUMMARY_WRITTEN="true"
}

on_exit() {
  local exit_code=$?
  trap - EXIT

  local finished_at_utc
  local finish_epoch
  local duration_seconds
  local files_before="${FILES_BEFORE:-0}"
  local bytes_before="${BYTES_BEFORE:-0}"
  local files_after="0"
  local bytes_after="0"
  local bytes_delta="0"
  local status="success"

  finished_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  finish_epoch="$(date +"%s")"
  duration_seconds="$((finish_epoch - START_EPOCH))"

  if [[ -n "${VPS_DESTINATION_DIR:-}" && -d "$VPS_DESTINATION_DIR" ]]; then
    files_after="$(count_files "$VPS_DESTINATION_DIR")"
    bytes_after="$(count_bytes "$VPS_DESTINATION_DIR")"
    bytes_delta="$((bytes_after - bytes_before))"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    status="failed"
  fi

  if [[ "$SUMMARY_WRITTEN" != "true" ]]; then
    write_summary "$status" "$exit_code" "$finished_at_utc" "$duration_seconds" \
      "$files_before" "$files_after" "$bytes_before" "$bytes_after" "$bytes_delta"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    print "Completed successfully. Summary: ${STATE_DIR}/last-run.env"
  else
    print "Failed with exit code ${exit_code}. See log: ${LOG_FILE:-not-created}"
  fi

  exit "$exit_code"
}

trap on_exit EXIT

if [[ ! -f "$ENV_FILE" ]]; then
  fail "Environment file not found: $ENV_FILE"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

RCLONE_BIN="${RCLONE_BIN:-rclone}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"
GDRIVE_SOURCE_PATH="${GDRIVE_SOURCE_PATH:-}"
VPS_DESTINATION_DIR="${VPS_DESTINATION_DIR:-/dailybackups}"
SYNC_MODE="${SYNC_MODE:-sync}"
DRY_RUN="${DRY_RUN:-true}"
ALLOW_NON_DAILYBACKUPS_DESTINATION="${ALLOW_NON_DAILYBACKUPS_DESTINATION:-false}"
ARCHIVE_DELETED_FILES="${ARCHIVE_DELETED_FILES:-true}"
ARCHIVE_BASE_DIR="${ARCHIVE_BASE_DIR:-/var/backups/rclone-gdrive-sql-backup-sync/archive}"
RCLONE_FILTER_FILE="${RCLONE_FILTER_FILE:-}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-4}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
RCLONE_RETRIES="${RCLONE_RETRIES:-3}"
RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-10}"
RCLONE_STATS_INTERVAL="${RCLONE_STATS_INTERVAL:-30s}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
RCLONE_FAST_LIST="${RCLONE_FAST_LIST:-false}"
RCLONE_BWLIMIT="${RCLONE_BWLIMIT:-}"
VERIFY_WITH_CHECKSUM="${VERIFY_WITH_CHECKSUM:-false}"
POST_SYNC_CHECK="${POST_SYNC_CHECK:-false}"
MIN_FREE_SPACE_BYTES="${MIN_FREE_SPACE_BYTES:-0}"
LOG_DIR="${LOG_DIR:-/var/log/rclone-gdrive-sql-backup-sync}"
STATE_DIR="${STATE_DIR:-/var/lib/rclone-gdrive-sql-backup-sync}"
FILE_UMASK="${FILE_UMASK:-077}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-0}"

case "$SYNC_MODE" in
  sync | copy) ;;
  *) fail "SYNC_MODE must be either sync or copy. Current value: $SYNC_MODE" ;;
esac

if [[ -z "$GDRIVE_SOURCE_PATH" || "$GDRIVE_SOURCE_PATH" == "/" || "$GDRIVE_SOURCE_PATH" == "." ]]; then
  fail "GDRIVE_SOURCE_PATH must point to a specific Google Drive backup folder. Refusing to use Drive root."
fi

destination_leaf="$(basename "$VPS_DESTINATION_DIR")"
if [[ "$destination_leaf" != "dailybackups" ]] && ! is_true "$ALLOW_NON_DAILYBACKUPS_DESTINATION"; then
  fail "VPS_DESTINATION_DIR must end in dailybackups. Current value: $VPS_DESTINATION_DIR"
fi

if [[ ! "$MIN_FREE_SPACE_BYTES" =~ ^[0-9]+$ ]]; then
  fail "MIN_FREE_SPACE_BYTES must be an integer number of bytes."
fi

umask "$FILE_UMASK"

require_command "$RCLONE_BIN"
require_command "flock"
require_command "find"
require_command "wc"
require_command "du"
require_command "awk"
require_command "df"
require_command "tee"
require_command "grep"

mkdir -p "$VPS_DESTINATION_DIR" "$LOG_DIR" "$STATE_DIR" "$ARCHIVE_BASE_DIR"

LOG_FILE="${LOG_DIR}/sync-${RUN_ID}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

LOCK_FILE="${STATE_DIR}/sync.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  fail "Another sync run already holds the lock: $LOCK_FILE"
fi

NORMALIZED_SOURCE_PATH="${GDRIVE_SOURCE_PATH#/}"
SOURCE="${RCLONE_REMOTE_NAME}:${NORMALIZED_SOURCE_PATH}"

print "Run ID: $RUN_ID"
print "Script: $SCRIPT_NAME"
print "Environment file: $ENV_FILE"
print "Source: $SOURCE"
print "Destination: $VPS_DESTINATION_DIR"
print "Mode: $SYNC_MODE"
print "Dry run: $DRY_RUN"

if ! "$RCLONE_BIN" listremotes | grep -Fxq "${RCLONE_REMOTE_NAME}:"; then
  fail "rclone remote '${RCLONE_REMOTE_NAME}:' was not found. Run 'rclone config' as the same user that runs this script."
fi

if [[ -n "$RCLONE_FILTER_FILE" && ! -f "$RCLONE_FILTER_FILE" ]]; then
  fail "RCLONE_FILTER_FILE is set but does not exist: $RCLONE_FILTER_FILE"
fi

if (( MIN_FREE_SPACE_BYTES > 0 )); then
  available="$(get_available_bytes "$VPS_DESTINATION_DIR")"
  print "Available destination bytes: $available"
  print "Minimum required bytes: $MIN_FREE_SPACE_BYTES"
  if (( available < MIN_FREE_SPACE_BYTES )); then
    fail "Destination filesystem free space is below MIN_FREE_SPACE_BYTES."
  fi
fi

FILES_BEFORE="$(count_files "$VPS_DESTINATION_DIR")"
BYTES_BEFORE="$(count_bytes "$VPS_DESTINATION_DIR")"

print "Destination files before sync: $FILES_BEFORE"
print "Destination bytes before sync: $BYTES_BEFORE"

COMMON_RCLONE_FLAGS=(
  --log-level "$RCLONE_LOG_LEVEL"
  --stats "$RCLONE_STATS_INTERVAL"
  --transfers "$RCLONE_TRANSFERS"
  --checkers "$RCLONE_CHECKERS"
  --retries "$RCLONE_RETRIES"
  --low-level-retries "$RCLONE_LOW_LEVEL_RETRIES"
  --drive-skip-gdocs
)

if is_true "$RCLONE_FAST_LIST"; then
  COMMON_RCLONE_FLAGS+=(--fast-list)
fi

if is_true "$VERIFY_WITH_CHECKSUM"; then
  COMMON_RCLONE_FLAGS+=(--checksum)
fi

if [[ -n "$RCLONE_BWLIMIT" ]]; then
  COMMON_RCLONE_FLAGS+=(--bwlimit "$RCLONE_BWLIMIT")
fi

if [[ -n "$RCLONE_FILTER_FILE" ]]; then
  COMMON_RCLONE_FLAGS+=(--filter-from "$RCLONE_FILTER_FILE")
fi

RCLONE_ARGS=(
  "$SYNC_MODE"
  "$SOURCE"
  "$VPS_DESTINATION_DIR"
  "${COMMON_RCLONE_FLAGS[@]}"
)

if is_true "$DRY_RUN"; then
  RCLONE_ARGS+=(--dry-run)
fi

if [[ "$SYNC_MODE" == "sync" ]] && is_true "$ARCHIVE_DELETED_FILES"; then
  ARCHIVE_RUN_DIR="${ARCHIVE_BASE_DIR}/${RUN_ID}"
  mkdir -p "$ARCHIVE_RUN_DIR"
  RCLONE_ARGS+=(--backup-dir "$ARCHIVE_RUN_DIR" --suffix ".${RUN_ID}")
  print "Deleted/overwritten destination files will be archived to: $ARCHIVE_RUN_DIR"
fi

print "Starting rclone ${SYNC_MODE}."
"$RCLONE_BIN" "${RCLONE_ARGS[@]}"
print "rclone ${SYNC_MODE} finished."

if is_true "$POST_SYNC_CHECK"; then
  CHECK_STATUS="running"
  CHECK_ARGS=(
    check
    "$SOURCE"
    "$VPS_DESTINATION_DIR"
    --one-way
    "${COMMON_RCLONE_FLAGS[@]}"
  )

  print "Starting post-sync rclone check."
  if "$RCLONE_BIN" "${CHECK_ARGS[@]}"; then
    CHECK_STATUS="success"
    print "Post-sync rclone check passed."
  else
    CHECK_STATUS="failed"
    fail "Post-sync rclone check failed."
  fi
fi

if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( LOG_RETENTION_DAYS > 0 )); then
  print "Deleting log files older than ${LOG_RETENTION_DAYS} days from $LOG_DIR."
  find "$LOG_DIR" -type f -name 'sync-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete
fi

if [[ "$ARCHIVE_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( ARCHIVE_RETENTION_DAYS > 0 )); then
  print "Deleting archive directories older than ${ARCHIVE_RETENTION_DAYS} days from $ARCHIVE_BASE_DIR."
  find "$ARCHIVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$ARCHIVE_RETENTION_DAYS" -exec rm -rf -- {} \;
fi
