#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/sync-google-drive-sql-backups.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "Expected file to exist: $1"
}

assert_file_missing() {
  [[ ! -e "$1" ]] || fail "Expected path to be absent: $1"
}

assert_dir_exists() {
  [[ -d "$1" ]] || fail "Expected directory to exist: $1"
}

assert_dir_missing() {
  [[ ! -d "$1" ]] || fail "Expected directory to be absent: $1"
}

make_fake_rclone() {
  local bin_dir="$1"
  local remote_json="$2"
  mkdir -p "$bin_dir"

  cat >"${bin_dir}/rclone" <<'FAKE_RCLONE'
#!/usr/bin/env bash
set -Eeuo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  lsjson)
    if [[ " ${*} " == *" --help "* ]]; then
      printf 'Usage: rclone lsjson [flags]\n      --metadata   Include metadata\n'
      exit 0
    fi
    cat "$FAKE_RCLONE_REMOTE_JSON"
    ;;
  listremotes)
    printf 'gdrive:\n'
    ;;
  copy)
    source_path="${1:-}"
    destination="${2:-}"
    shift 2 || true
    files_from=""
    dry_run="false"
    while (($#)); do
      case "$1" in
        --files-from)
          files_from="$2"
          shift 2
          ;;
        --dry-run)
          dry_run="true"
          shift
          ;;
        *)
          if (($# >= 2)) && [[ "$2" != --* ]]; then
            shift 2
          else
            shift
          fi
          ;;
      esac
    done
    [[ "$source_path" == gdrive:* ]] || exit 2
    [[ -n "$files_from" ]] || exit 2
    if [[ "$dry_run" == "false" ]]; then
      while IFS= read -r rel_path; do
        [[ -n "$rel_path" ]] || continue
        mkdir -p "$(dirname "${destination}/${rel_path}")"
        printf 'copied %s\n' "$rel_path" >"${destination}/${rel_path}"
      done <"$files_from"
    fi
    ;;
  check)
    exit 0
    ;;
  *)
    printf 'Unexpected fake rclone command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
FAKE_RCLONE

  chmod +x "${bin_dir}/rclone"
  export FAKE_RCLONE_REMOTE_JSON="$remote_json"
}

write_remote_json() {
  local path="$1"
  cat >"$path" <<'JSON'
[
  {"Path":"FY2024-25/backup-older.sql.gz","ModTime":"2026-04-01T00:00:00.000Z","Metadata":{"btime":"2026-04-01T00:00:00.000Z","mtime":"2026-04-01T00:00:00.000Z"}},
  {"Path":"FY2024-25/backup-newest.sql.gz","ModTime":"2026-04-03T00:00:00.000Z","Metadata":{"btime":"2026-04-03T00:00:00.000Z","mtime":"2026-04-03T00:00:00.000Z"}},
  {"Path":"FY2024-25/backup-middle.sql.gz","ModTime":"2026-04-02T00:00:00.000Z","Metadata":{"btime":"2026-04-02T00:00:00.000Z","mtime":"2026-04-02T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-a.sql.gz","ModTime":"2026-05-01T00:00:00.000Z","Metadata":{"btime":"2026-05-01T00:00:00.000Z","mtime":"2026-05-01T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-b.sql.gz","ModTime":"2026-05-02T00:00:00.000Z","Metadata":{"btime":"2026-05-02T00:00:00.000Z","mtime":"2026-05-02T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-c.sql.gz","ModTime":"2026-05-03T00:00:00.000Z","Metadata":{"btime":"2026-05-03T00:00:00.000Z","mtime":"2026-05-03T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-d.sql.gz","ModTime":"2026-05-04T00:00:00.000Z","Metadata":{"btime":"2026-05-04T00:00:00.000Z","mtime":"2026-05-04T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-e.sql.gz","ModTime":"2026-05-05T00:00:00.000Z","Metadata":{"btime":"2026-05-05T00:00:00.000Z","mtime":"2026-05-05T00:00:00.000Z"}},
  {"Path":"FY2025-26/backup-f.sql.gz","ModTime":"2026-05-06T00:00:00.000Z","Metadata":{"btime":"2026-05-06T00:00:00.000Z","mtime":"2026-05-06T00:00:00.000Z"}}
]
JSON
}

write_env() {
  local env_file="$1"
  local destination="$2"
  local state_dir="$3"
  local log_dir="$4"
  local archive_dir="$5"
  local dry_run="$6"

  cat >"$env_file" <<EOF_ENV
RCLONE_REMOTE_NAME="gdrive"
GDRIVE_SOURCE_PATH="SQL Backups"
VPS_DESTINATION_DIR="$destination"
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="5"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
DRY_RUN="$dry_run"
ARCHIVE_DELETED_FILES="true"
ARCHIVE_BASE_DIR="$archive_dir"
RCLONE_FILTER_FILE=""
RCLONE_TRANSFERS="1"
RCLONE_CHECKERS="1"
RCLONE_RETRIES="1"
RCLONE_LOW_LEVEL_RETRIES="1"
RCLONE_STATS_INTERVAL="1s"
RCLONE_LOG_LEVEL="ERROR"
RCLONE_FAST_LIST="false"
VERIFY_WITH_CHECKSUM="false"
POST_SYNC_CHECK="true"
MIN_FREE_SPACE_BYTES="0"
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="false"
LOG_DIR="$log_dir"
STATE_DIR="$state_dir"
FILE_UMASK="077"
LOG_RETENTION_DAYS="0"
ARCHIVE_RETENTION_DAYS="0"
RCLONE_BIN="rclone"
EOF_ENV
}

remote_json="${TMP_ROOT}/remote.json"
fake_bin="${TMP_ROOT}/bin"
write_remote_json "$remote_json"
make_fake_rclone "$fake_bin" "$remote_json"
export PATH="${fake_bin}:$PATH"

# Real run: copy selected latest files, prune stale local files, keep destination root.
real_root="${TMP_ROOT}/real"
real_dest="${real_root}/dailybackups"
real_state="${real_root}/state"
real_log="${real_root}/log"
real_archive="${real_root}/archive"
real_env="${real_root}/env"
mkdir -p "${real_dest}/FY2024-25" "${real_dest}/FY2025-26" "$real_state" "$real_log" "$real_archive"
printf 'stale\n' >"${real_dest}/FY2024-25/local-stale.sql.gz"
printf 'old\n' >"${real_dest}/FY2025-26/backup-a.sql.gz"
write_env "$real_env" "$real_dest" "$real_state" "$real_log" "$real_archive" "false"

bash "$SCRIPT_UNDER_TEST" "$real_env" >/"${real_root}/run.out"

assert_file_exists "${real_dest}/FY2024-25/backup-newest.sql.gz"
assert_file_exists "${real_dest}/FY2025-26/backup-f.sql.gz"
assert_file_missing "${real_dest}/FY2024-25/local-stale.sql.gz"
assert_file_missing "${real_dest}/FY2025-26/backup-a.sql.gz"
assert_file_exists "${real_archive}"/*/FY2024-25/local-stale.sql.gz.*
assert_dir_exists "$real_dest"
assert_file_exists "${real_state}/last-run.env"
grep -q 'SELECTED_REMOTE_FILES=8' "${real_state}/last-run.env" || fail "Expected 8 selected files across financial years."

# Dry run: do not copy, prune, or create a per-run archive directory.
dry_root="${TMP_ROOT}/dry"
dry_dest="${dry_root}/dailybackups"
dry_state="${dry_root}/state"
dry_log="${dry_root}/log"
dry_archive="${dry_root}/archive"
dry_env="${dry_root}/env"
mkdir -p "${dry_dest}/FY2024-25" "$dry_state" "$dry_log" "$dry_archive"
printf 'stale\n' >"${dry_dest}/FY2024-25/local-stale.sql.gz"
write_env "$dry_env" "$dry_dest" "$dry_state" "$dry_log" "$dry_archive" "true"

bash "$SCRIPT_UNDER_TEST" "$dry_env" >/"${dry_root}/run.out"

assert_file_exists "${dry_dest}/FY2024-25/local-stale.sql.gz"
assert_file_missing "${dry_dest}/FY2024-25/backup-newest.sql.gz"
if find "$dry_archive" -mindepth 1 -print -quit | grep -q .; then
  fail "Dry run created archive contents."
fi
assert_file_exists "${dry_state}/last-run.env"

# Safety guard: archive directory must not be inside the destination tree.
unsafe_root="${TMP_ROOT}/unsafe"
unsafe_dest="${unsafe_root}/dailybackups"
unsafe_state="${unsafe_root}/state"
unsafe_log="${unsafe_root}/log"
unsafe_env="${unsafe_root}/env"
mkdir -p "$unsafe_dest" "$unsafe_state" "$unsafe_log"
write_env "$unsafe_env" "$unsafe_dest" "$unsafe_state" "$unsafe_log" "${unsafe_dest}/archive" "true"
if bash "$SCRIPT_UNDER_TEST" "$unsafe_env" >/"${unsafe_root}/run.out" 2>&1; then
  fail "Expected archive-inside-destination configuration to fail."
fi
grep -q 'ARCHIVE_BASE_DIR must not be the destination folder or inside it' "${unsafe_root}/run.out" || fail "Expected archive safety error."

# Safety guard also canonicalizes paths so ../ cannot bypass containment checks.
unsafe_dotdot_root="${TMP_ROOT}/unsafe-dotdot"
unsafe_dotdot_dest="${unsafe_dotdot_root}/dailybackups"
unsafe_dotdot_state="${unsafe_dotdot_root}/state"
unsafe_dotdot_log="${unsafe_dotdot_root}/log"
unsafe_dotdot_env="${unsafe_dotdot_root}/env"
mkdir -p "$unsafe_dotdot_dest" "$unsafe_dotdot_state" "$unsafe_dotdot_log"
write_env "$unsafe_dotdot_env" "$unsafe_dotdot_dest" "$unsafe_dotdot_state" "$unsafe_dotdot_log" "${unsafe_dotdot_dest}/../dailybackups/archive" "true"
if bash "$SCRIPT_UNDER_TEST" "$unsafe_dotdot_env" >/"${unsafe_dotdot_root}/run.out" 2>&1; then
  fail "Expected canonicalized archive-inside-destination configuration to fail."
fi
grep -q 'ARCHIVE_BASE_DIR must not be the destination folder or inside it' "${unsafe_dotdot_root}/run.out" || fail "Expected canonicalized archive safety error."

printf 'All backup sync tests passed.\n'
