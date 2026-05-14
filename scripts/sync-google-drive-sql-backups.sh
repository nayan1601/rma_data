#!/usr/bin/env bash
#
# Sync Google Drive SQL backups to a VPS folder named dailybackups.
#
# This script is intentionally defensive because it is operational code.
# It supports two transfer strategies:
#
#   1. RETENTION_POLICY="latest_per_financial_year"
#      - Google Drive source is expected to contain financial-year folders as
#        top-level folders.
#      - The script lists remote backup files with rclone metadata, selects the
#        latest N files inside each financial-year folder by metadata timestamp,
#        copies only those selected files to the VPS, then prunes older local
#        files.
#
#   2. RETENTION_POLICY="none"
#      - The script runs a normal rclone sync or copy using SYNC_MODE.
#
# The default is latest_per_financial_year because the VPS should not keep an
# unlimited full history when Google Drive already holds the complete archive.

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
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
STATE_DIR_SAFE_FOR_SUMMARY="false"
REMOTE_FILE_COUNT="0"
SELECTED_REMOTE_FILES="0"
FILES_WITHOUT_RETENTION_TIMESTAMP="0"
LOCAL_PRUNE_CANDIDATES="0"
LOCAL_PRUNED_FILES="0"

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
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' is not installed or not in PATH. Re-run the installer from the repository: sudo bash scripts/install-rclone-google-drive-sync.sh"
}

strip_trailing_slashes() {
  local value="$1"

  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done

  printf '%s' "$value"
}

strip_leading_slashes() {
  local value="$1"

  while [[ "$value" == /* ]]; do
    value="${value#/}"
  done

  printf '%s' "$value"
}

collapse_repeated_slashes() {
  local value="$1"
  local result=""
  local char
  local previous_was_slash="false"
  local i

  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    if [[ "$char" == "/" ]]; then
      if [[ "$previous_was_slash" != "true" ]]; then
        result+="/"
        previous_was_slash="true"
      fi
    else
      result+="$char"
      previous_was_slash="false"
    fi
  done

  printf '%s' "$result"
}

normalize_managed_path() {
  local value="$1"

  value="$(collapse_repeated_slashes "$value")"
  strip_trailing_slashes "$value"
}

normalize_source_path() {
  local value="$1"

  value="$(strip_leading_slashes "$value")"
  value="$(collapse_repeated_slashes "$value")"
  strip_trailing_slashes "$value"
}

require_absolute_path() {
  local value="$1"
  local name="$2"

  [[ -n "$value" ]] || fail "$name must not be empty."
  [[ "$value" == /* ]] || fail "$name must be an absolute path. Current value: $value"
}

require_managed_path_safe() {
  local path
  local name="$2"

  path="$(normalize_managed_path "$1")"

  require_absolute_path "$path" "$name"

  case "$path" in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/backups | /var/lib | /var/log)
      fail "$name points at a broad system directory that this script must not manage: $path"
      ;;
  esac

  if [[ "$path" == *'/../'* || "$path" == */.. || "$path" == *'/./'* || "$path" == */. ]]; then
    fail "$name must not contain . or .. path segments: $path"
  fi
}

path_is_within() {
  local child
  local parent

  child="$(normalize_managed_path "$1")"
  parent="$(normalize_managed_path "$2")"

  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

validate_integer() {
  local value="$1"
  local name="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an integer. Current value: $value"
}

validate_bool() {
  local value="$1"
  local name="$2"

  case "$value" in
    true | TRUE | True | 1 | yes | YES | y | Y | false | FALSE | False | 0 | no | NO | n | N) ;;
    *) fail "$name must be true or false. Current value: $value" ;;
  esac
}

require_rclone_metadata_support() {
  if ! "$RCLONE_BIN" lsjson --metadata --help >/dev/null 2>&1; then
    fail "Installed rclone does not support 'lsjson --metadata'. Install a current rclone release before using financial-year metadata retention."
  fi
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

get_destination_mount_target() {
  local dir="$1"
  findmnt -n -T "$dir" -o TARGET
}

normalize_absolute_path_for_compare() {
  local path="$1"

  realpath -m -- "$path"
}

path_is_same_or_inside() {
  local child
  local parent

  child="$(normalize_absolute_path_for_compare "$1")"
  parent="$(normalize_absolute_path_for_compare "$2")"

  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

ensure_directory() {
  local path="$1"
  local mode="$2"
  local description="$3"
  local probe

  require_managed_path_safe "$path" "$description"

  if [[ -e "$path" && ! -d "$path" ]]; then
    fail "$description exists but is not a directory: $path"
  fi

  mkdir -p "$path"

  if [[ "${EUID}" -eq 0 ]]; then
    chmod "$mode" "$path"
  fi

  probe="${path}/.backup-sync-write-test"
  : >"$probe" || fail "$description is not writable: $path"
  rm -f -- "$probe"
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

  if [[ -z "${STATE_DIR:-}" || "$STATE_DIR_SAFE_FOR_SUMMARY" != "true" ]]; then
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
    write_kv "RETENTION_POLICY" "${RETENTION_POLICY:-}"
    write_kv "BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR" "${BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR:-}"
    write_kv "RETENTION_TIMESTAMP_MODE" "${RETENTION_TIMESTAMP_MODE:-}"
    write_kv "REMOTE_FILE_COUNT" "$REMOTE_FILE_COUNT"
    write_kv "SELECTED_REMOTE_FILES" "$SELECTED_REMOTE_FILES"
    write_kv "FILES_WITHOUT_RETENTION_TIMESTAMP" "$FILES_WITHOUT_RETENTION_TIMESTAMP"
    write_kv "LOCAL_PRUNE_CANDIDATES" "$LOCAL_PRUNE_CANDIDATES"
    write_kv "LOCAL_PRUNED_FILES" "$LOCAL_PRUNED_FILES"
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

build_remote_list_flags() {
  REMOTE_LIST_FLAGS=(
    --drive-skip-gdocs
    --log-level "$RCLONE_LOG_LEVEL"
    --metadata
  )

  if [[ -n "$RCLONE_FILTER_FILE" ]]; then
    REMOTE_LIST_FLAGS+=(--filter-from "$RCLONE_FILTER_FILE")
  fi
}

build_common_transfer_flags() {
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
}

select_latest_files_per_financial_year() {
  REMOTE_LIST_JSON="${STATE_DIR}/remote-files-${RUN_ID}.json"
  SELECTED_FILES_FILE="${STATE_DIR}/selected-files-${RUN_ID}.txt"
  FY_SELECTION_REPORT="${STATE_DIR}/financial-year-selection-${RUN_ID}.txt"

  print "Listing remote files for financial-year retention."
  "$RCLONE_BIN" lsjson "$SOURCE" -R --files-only "${REMOTE_LIST_FLAGS[@]}" >"$REMOTE_LIST_JSON"

  REMOTE_FILE_COUNT="$(jq '[.[]] | length' "$REMOTE_LIST_JSON")"
  print "Remote files after filters: $REMOTE_FILE_COUNT"

  ROOT_LEVEL_FILE_COUNT="$(
    jq '[.[] | select((.Path | contains("/")) | not)] | length' "$REMOTE_LIST_JSON"
  )"

  if (( ROOT_LEVEL_FILE_COUNT > 0 )) && ! is_true "$ALLOW_ROOT_LEVEL_BACKUP_FILES"; then
    print "Root-level files found in the source. They are not inside a financial-year folder:"
    jq -r '.[] | select((.Path | contains("/")) | not) | "  - " + .Path' "$REMOTE_LIST_JSON"
    fail "Refusing retention run because every backup file must be inside a top-level financial-year folder."
  fi

  FILES_WITHOUT_RETENTION_TIMESTAMP="$(
    jq -r --arg timestamp_mode "$RETENTION_TIMESTAMP_MODE" '
      def retention_time($mode):
        if $mode == "upload_time" then
          (.Metadata.btime? // "")
        elif $mode == "modified_time" then
          (.Metadata.mtime? // .ModTime? // "")
        elif $mode == "rclone_modtime" then
          (.ModTime? // "")
        elif $mode == "latest_metadata_time" then
          ([.Metadata.btime?, .Metadata.mtime?, .ModTime?]
            | map(select(. != null and . != ""))
            | max // "")
        else
          ""
        end;

      [
        .[]
        | select(.Path | contains("/"))
        | select((retention_time($timestamp_mode)) == "")
      ]
      | length
    ' "$REMOTE_LIST_JSON"
  )"

  if (( FILES_WITHOUT_RETENTION_TIMESTAMP > 0 )); then
    fail "Some remote files have no usable retention timestamp for RETENTION_TIMESTAMP_MODE=${RETENTION_TIMESTAMP_MODE}."
  fi

  jq -r \
    --argjson keep "$BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR" \
    --arg timestamp_mode "$RETENTION_TIMESTAMP_MODE" '
    def retention_time($mode):
      if $mode == "upload_time" then
        (.Metadata.btime? // "")
      elif $mode == "modified_time" then
        (.Metadata.mtime? // .ModTime? // "")
      elif $mode == "rclone_modtime" then
        (.ModTime? // "")
      elif $mode == "latest_metadata_time" then
        ([.Metadata.btime?, .Metadata.mtime?, .ModTime?]
          | map(select(. != null and . != ""))
          | max // "")
      else
        ""
      end;

    [
      .[]
      | select(.Path | contains("/"))
      | . + {
          financial_year: (.Path | split("/")[0]),
          retention_time: retention_time($timestamp_mode)
        }
    ]
    | sort_by(.financial_year)
    | group_by(.financial_year)
    | map(sort_by(.retention_time, .Path) | reverse | .[:$keep])
    | flatten
    | .[].Path
  ' "$REMOTE_LIST_JSON" >"$SELECTED_FILES_FILE"

  SELECTED_REMOTE_FILES="$(wc -l <"$SELECTED_FILES_FILE" | tr -d '[:space:]')"

  jq -r \
    --argjson keep "$BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR" \
    --arg timestamp_mode "$RETENTION_TIMESTAMP_MODE" '
    def retention_time($mode):
      if $mode == "upload_time" then
        (.Metadata.btime? // "")
      elif $mode == "modified_time" then
        (.Metadata.mtime? // .ModTime? // "")
      elif $mode == "rclone_modtime" then
        (.ModTime? // "")
      elif $mode == "latest_metadata_time" then
        ([.Metadata.btime?, .Metadata.mtime?, .ModTime?]
          | map(select(. != null and . != ""))
          | max // "")
      else
        ""
      end;

    [
      .[]
      | select(.Path | contains("/"))
      | . + {
          financial_year: (.Path | split("/")[0]),
          retention_time: retention_time($timestamp_mode)
        }
    ]
    | sort_by(.financial_year)
    | group_by(.financial_year)
    | .[]
    | . as $items
    | ($items | sort_by(.retention_time, .Path) | reverse | .[:$keep]) as $selected
    | "\($items[0].financial_year): total_remote_files=\($items | length), selected_for_vps=\($selected | length), newest_selected_metadata_time=\(($selected | map(.retention_time) | max) // ""), oldest_selected_metadata_time=\(($selected | map(.retention_time) | min) // "")"
  ' "$REMOTE_LIST_JSON" >"$FY_SELECTION_REPORT"

  print "Selected remote files for VPS retention: $SELECTED_REMOTE_FILES"
  print "Financial-year selection report:"
  sed 's/^/  /' "$FY_SELECTION_REPORT"

  if (( SELECTED_REMOTE_FILES == 0 )); then
    fail "No remote backup files were selected. Check GDRIVE_SOURCE_PATH and RCLONE_FILTER_FILE before running again."
  fi
}

prune_local_files_not_selected() {
  local local_file
  local rel_path
  local archive_file

  print "Pruning local files that are not in the selected latest-per-financial-year set."

  while IFS= read -r -d '' local_file; do
    rel_path="${local_file#"$VPS_DESTINATION_DIR"/}"

    if grep -Fxq -- "$rel_path" "$SELECTED_FILES_FILE"; then
      continue
    fi

    LOCAL_PRUNE_CANDIDATES="$((LOCAL_PRUNE_CANDIDATES + 1))"

    if is_true "$DRY_RUN"; then
      print "DRY RUN: would prune local file: $rel_path"
      continue
    fi

    if is_true "$ARCHIVE_DELETED_FILES"; then
      ARCHIVE_RUN_DIR="${ARCHIVE_RUN_DIR:-${ARCHIVE_BASE_DIR}/${RUN_ID}}"
      archive_file="${ARCHIVE_RUN_DIR}/${rel_path}.${RUN_ID}"
      mkdir -p "$(dirname "$archive_file")"
      mv -- "$local_file" "$archive_file"
      print "Archived pruned local file: $rel_path -> $archive_file"
    else
      rm -f -- "$local_file"
      print "Deleted pruned local file: $rel_path"
    fi

    LOCAL_PRUNED_FILES="$((LOCAL_PRUNED_FILES + 1))"
  done < <(find "$VPS_DESTINATION_DIR" -type f -print0)

  if ! is_true "$DRY_RUN"; then
    find "$VPS_DESTINATION_DIR" -mindepth 1 -depth -type d -empty -delete
  fi

  print "Local prune candidates: $LOCAL_PRUNE_CANDIDATES"
  print "Local files pruned: $LOCAL_PRUNED_FILES"
}

run_latest_per_financial_year_transfer() {
  select_latest_files_per_financial_year

  RCLONE_ARGS=(
    copy
    "$SOURCE"
    "$VPS_DESTINATION_DIR"
    --files-from "$SELECTED_FILES_FILE"
    "${COMMON_RCLONE_FLAGS[@]}"
  )

  if is_true "$DRY_RUN"; then
    RCLONE_ARGS+=(--dry-run)
  fi

  if is_true "$ARCHIVE_DELETED_FILES"; then
    ARCHIVE_RUN_DIR="${ARCHIVE_BASE_DIR}/${RUN_ID}"
    if ! is_true "$DRY_RUN"; then
      mkdir -p "$ARCHIVE_RUN_DIR"
    fi
    RCLONE_ARGS+=(--backup-dir "$ARCHIVE_RUN_DIR" --suffix ".${RUN_ID}")
    print "Overwritten copied files and pruned local files will be archived to: $ARCHIVE_RUN_DIR"
  fi

  print "Starting rclone copy of selected latest financial-year backup files."
  "$RCLONE_BIN" "${RCLONE_ARGS[@]}"
  print "rclone copy finished."

  prune_local_files_not_selected
}

run_standard_transfer() {
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
    if ! is_true "$DRY_RUN"; then
      mkdir -p "$ARCHIVE_RUN_DIR"
    fi
    RCLONE_ARGS+=(--backup-dir "$ARCHIVE_RUN_DIR" --suffix ".${RUN_ID}")
    print "Deleted/overwritten destination files will be archived to: $ARCHIVE_RUN_DIR"
  fi

  print "Starting rclone ${SYNC_MODE}."
  "$RCLONE_BIN" "${RCLONE_ARGS[@]}"
  print "rclone ${SYNC_MODE} finished."
}

run_post_sync_check() {
  CHECK_STATUS="running"

  CHECK_ARGS=(
    check
    "$SOURCE"
    "$VPS_DESTINATION_DIR"
    --one-way
    "${COMMON_RCLONE_FLAGS[@]}"
  )

  if [[ "$RETENTION_POLICY" == "latest_per_financial_year" ]]; then
    CHECK_ARGS+=(--files-from "$SELECTED_FILES_FILE")
  fi

  print "Starting post-sync rclone check."
  if "$RCLONE_BIN" "${CHECK_ARGS[@]}"; then
    CHECK_STATUS="success"
    print "Post-sync rclone check passed."
  else
    CHECK_STATUS="failed"
    fail "Post-sync rclone check failed."
  fi
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
RETENTION_POLICY="${RETENTION_POLICY:-latest_per_financial_year}"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="${BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR:-7}"
RETENTION_TIMESTAMP_MODE="${RETENTION_TIMESTAMP_MODE:-latest_metadata_time}"
ALLOW_ROOT_LEVEL_BACKUP_FILES="${ALLOW_ROOT_LEVEL_BACKUP_FILES:-false}"
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
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="${REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM:-false}"
LOG_DIR="${LOG_DIR:-/var/log/rclone-gdrive-sql-backup-sync}"
STATE_DIR="${STATE_DIR:-/var/lib/rclone-gdrive-sql-backup-sync}"
FILE_UMASK="${FILE_UMASK:-077}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-0}"

if [[ -n "${RCLONE_CONFIG:-}" ]]; then
  require_absolute_path "$RCLONE_CONFIG" "RCLONE_CONFIG"
  [[ -f "$RCLONE_CONFIG" ]] || fail "RCLONE_CONFIG is set but the file does not exist: $RCLONE_CONFIG"
  export RCLONE_CONFIG
fi

case "$RETENTION_POLICY" in
  latest_per_financial_year | none) ;;
  *) fail "RETENTION_POLICY must be latest_per_financial_year or none. Current value: $RETENTION_POLICY" ;;
esac

case "$SYNC_MODE" in
  sync | copy) ;;
  *) fail "SYNC_MODE must be either sync or copy. Current value: $SYNC_MODE" ;;
esac

validate_bool "$DRY_RUN" "DRY_RUN"
validate_bool "$ALLOW_NON_DAILYBACKUPS_DESTINATION" "ALLOW_NON_DAILYBACKUPS_DESTINATION"
validate_bool "$ARCHIVE_DELETED_FILES" "ARCHIVE_DELETED_FILES"
validate_bool "$RCLONE_FAST_LIST" "RCLONE_FAST_LIST"
validate_bool "$VERIFY_WITH_CHECKSUM" "VERIFY_WITH_CHECKSUM"
validate_bool "$POST_SYNC_CHECK" "POST_SYNC_CHECK"
validate_bool "$ALLOW_ROOT_LEVEL_BACKUP_FILES" "ALLOW_ROOT_LEVEL_BACKUP_FILES"
validate_bool "$REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM" "REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM"

validate_integer "$BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR" "BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR"
validate_integer "$RCLONE_TRANSFERS" "RCLONE_TRANSFERS"
validate_integer "$RCLONE_CHECKERS" "RCLONE_CHECKERS"
validate_integer "$RCLONE_RETRIES" "RCLONE_RETRIES"
validate_integer "$RCLONE_LOW_LEVEL_RETRIES" "RCLONE_LOW_LEVEL_RETRIES"
validate_integer "$MIN_FREE_SPACE_BYTES" "MIN_FREE_SPACE_BYTES"
validate_integer "$LOG_RETENTION_DAYS" "LOG_RETENTION_DAYS"
validate_integer "$ARCHIVE_RETENTION_DAYS" "ARCHIVE_RETENTION_DAYS"

if [[ ! "$FILE_UMASK" =~ ^[0-7]{3,4}$ ]]; then
  fail "FILE_UMASK must be a valid octal umask such as 077. Current value: $FILE_UMASK"
fi

if [[ "$RETENTION_POLICY" == "latest_per_financial_year" ]]; then
  if (( BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR < 5 || BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR > 7 )); then
    fail "BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR must be between 5 and 7."
  fi
fi

case "$RETENTION_TIMESTAMP_MODE" in
  latest_metadata_time | upload_time | modified_time | rclone_modtime) ;;
  *) fail "RETENTION_TIMESTAMP_MODE must be latest_metadata_time, upload_time, modified_time, or rclone_modtime. Current value: $RETENTION_TIMESTAMP_MODE" ;;
esac

VPS_DESTINATION_DIR="$(normalize_managed_path "$VPS_DESTINATION_DIR")"
LOG_DIR="$(normalize_managed_path "$LOG_DIR")"
STATE_DIR="$(normalize_managed_path "$STATE_DIR")"
ARCHIVE_BASE_DIR="$(normalize_managed_path "$ARCHIVE_BASE_DIR")"

destination_leaf="${VPS_DESTINATION_DIR##*/}"
if [[ "$destination_leaf" != "dailybackups" ]] && ! is_true "$ALLOW_NON_DAILYBACKUPS_DESTINATION"; then
  fail "VPS_DESTINATION_DIR must end in dailybackups. Current value: $VPS_DESTINATION_DIR"
fi

require_managed_path_safe "$VPS_DESTINATION_DIR" "VPS_DESTINATION_DIR"
require_managed_path_safe "$LOG_DIR" "LOG_DIR"
require_managed_path_safe "$STATE_DIR" "STATE_DIR"
require_managed_path_safe "$ARCHIVE_BASE_DIR" "ARCHIVE_BASE_DIR"

if path_is_within "$STATE_DIR" "$VPS_DESTINATION_DIR"; then
  fail "STATE_DIR must not be inside VPS_DESTINATION_DIR because retention pruning manages destination files: $STATE_DIR"
fi

if [[ "$STATE_DIR" == "$LOG_DIR" || "$STATE_DIR" == "$ARCHIVE_BASE_DIR" ]]; then
  fail "STATE_DIR must be separate from LOG_DIR and ARCHIVE_BASE_DIR."
fi

STATE_DIR_SAFE_FOR_SUMMARY="true"

for managed_path in "$LOG_DIR" "$ARCHIVE_BASE_DIR"; do
  if path_is_within "$managed_path" "$VPS_DESTINATION_DIR"; then
    fail "LOG_DIR, STATE_DIR, and ARCHIVE_BASE_DIR must not be inside VPS_DESTINATION_DIR because retention pruning manages destination files: $managed_path"
  fi
done

if [[ "$LOG_DIR" == "$ARCHIVE_BASE_DIR" ]]; then
  fail "LOG_DIR, STATE_DIR, and ARCHIVE_BASE_DIR must be separate directories."
fi

NORMALIZED_SOURCE_PATH="$(normalize_source_path "$GDRIVE_SOURCE_PATH")"
if [[ -z "$NORMALIZED_SOURCE_PATH" || "$NORMALIZED_SOURCE_PATH" == "." || "$NORMALIZED_SOURCE_PATH" == ./* || "$NORMALIZED_SOURCE_PATH" == *'/./'* || "$NORMALIZED_SOURCE_PATH" == */. || "$NORMALIZED_SOURCE_PATH" == *'/../'* || "$NORMALIZED_SOURCE_PATH" == ../* || "$NORMALIZED_SOURCE_PATH" == */.. || "$NORMALIZED_SOURCE_PATH" == '..' ]]; then
  fail "GDRIVE_SOURCE_PATH must point to a specific Google Drive backup folder. Refusing to use Drive root, dot segments, or parent-directory traversal."
fi

if [[ -n "$RCLONE_FILTER_FILE" ]]; then
  require_absolute_path "$RCLONE_FILTER_FILE" "RCLONE_FILTER_FILE"
fi

umask "$FILE_UMASK"

require_command "$RCLONE_BIN"
require_command "flock"
require_command "find"
require_command "wc"
require_command "du"
require_command "awk"
require_command "df"
require_command "findmnt"
require_command "mkdir"
require_command "chmod"
require_command "dirname"
require_command "mv"
require_command "rm"
require_command "tee"
require_command "grep"
require_command "sed"
require_command "realpath"

if [[ "$RETENTION_POLICY" == "latest_per_financial_year" ]]; then
  require_command "jq"
  require_rclone_metadata_support
fi

ensure_directory "$VPS_DESTINATION_DIR" "0750" "VPS_DESTINATION_DIR"
ensure_directory "$LOG_DIR" "0750" "LOG_DIR"
ensure_directory "$STATE_DIR" "0750" "STATE_DIR"
ensure_directory "$ARCHIVE_BASE_DIR" "0750" "ARCHIVE_BASE_DIR"

LOG_FILE="${LOG_DIR}/sync-${RUN_ID}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

LOCK_FILE="${STATE_DIR}/sync.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  fail "Another sync run already holds the lock: $LOCK_FILE"
fi

SOURCE="${RCLONE_REMOTE_NAME}:${NORMALIZED_SOURCE_PATH}"

print "Run ID: $RUN_ID"
print "Script: $SCRIPT_NAME"
print "Environment file: $ENV_FILE"
print "Source: $SOURCE"
print "Destination: $VPS_DESTINATION_DIR"
print "Retention policy: $RETENTION_POLICY"
print "Backups to keep per financial year: $BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR"
print "Retention timestamp mode: $RETENTION_TIMESTAMP_MODE"
print "Configured standard sync mode: $SYNC_MODE"
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

destination_mount_target="$(get_destination_mount_target "$VPS_DESTINATION_DIR")"
print "Destination filesystem mount target: $destination_mount_target"
if is_true "$REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM" && [[ "$destination_mount_target" == "/" ]]; then
  fail "Destination is on the root filesystem and REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM is true."
fi

FILES_BEFORE="$(count_files "$VPS_DESTINATION_DIR")"
BYTES_BEFORE="$(count_bytes "$VPS_DESTINATION_DIR")"

print "Destination files before transfer: $FILES_BEFORE"
print "Destination bytes before transfer: $BYTES_BEFORE"

build_common_transfer_flags
build_remote_list_flags

if [[ "$RETENTION_POLICY" == "latest_per_financial_year" ]]; then
  run_latest_per_financial_year_transfer
else
  run_standard_transfer
fi

if is_true "$POST_SYNC_CHECK"; then
  run_post_sync_check
fi

if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( LOG_RETENTION_DAYS > 0 )); then
  print "Deleting log files older than ${LOG_RETENTION_DAYS} days from $LOG_DIR."
  find "$LOG_DIR" -type f -name 'sync-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete
fi

if [[ "$ARCHIVE_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( ARCHIVE_RETENTION_DAYS > 0 )); then
  print "Deleting archive directories older than ${ARCHIVE_RETENTION_DAYS} days from $ARCHIVE_BASE_DIR."
  find "$ARCHIVE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$ARCHIVE_RETENTION_DAYS" -exec rm -rf -- {} \;
fi
