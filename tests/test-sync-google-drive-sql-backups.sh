#!/usr/bin/env bash
# Integration-style robustness tests for sync-google-drive-sql-backups.sh.
# The tests use a fake rclone binary so retention, pruning, validation, and
# summary behavior can be verified without Google Drive credentials or network.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-google-drive-sql-backups.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "Expected file to exist: $path"
}

assert_file_missing() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "Expected path to be absent: $path"
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  grep -Eq -- "$pattern" "$path" || fail "Expected $path to match regex: $pattern"
}

write_fake_rclone() {
  local fake_bin="$1"

  cat >"$fake_bin" <<'FAKE_RCLONE'
#!/usr/bin/env bash
set -Eeuo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  lsjson)
    if [[ " ${*} " == *" --help "* || "${1:-}" == "--help" ]]; then
      printf 'Usage: rclone lsjson [flags]\n      --metadata   read metadata\n'
      exit 0
    fi
    cat "$FAKE_RCLONE_JSON"
    ;;
  listremotes)
    printf 'gdrive:\n'
    ;;
  copy)
    source="${1:?missing source}"
    dest="${2:?missing destination}"
    shift 2
    files_from=""
    dry_run="false"
    while (($#)); do
      case "$1" in
        --files-from)
          files_from="${2:?missing --files-from value}"
          shift 2
          ;;
        --dry-run)
          dry_run="true"
          shift
          ;;
        *)
          if (($# > 1)) && [[ "$2" != --* ]]; then
            shift 2
          else
            shift
          fi
          ;;
      esac
    done

    [[ -n "$files_from" ]] || { printf 'fake rclone copy requires --files-from\n' >&2; exit 2; }
    [[ "$source" == gdrive:* ]] || { printf 'unexpected source: %s\n' "$source" >&2; exit 2; }

    source_path="${source#gdrive:}"
    while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
      [[ -n "$rel_path" ]] || continue
      if [[ "$dry_run" == "true" ]]; then
        printf 'DRY RUN: would copy %s\n' "$rel_path"
        continue
      fi
      mkdir -p "$(dirname "${dest}/${rel_path}")"
      cp "${FAKE_RCLONE_REMOTE_ROOT}/${source_path}/${rel_path}" "${dest}/${rel_path}"
    done <"$files_from"
    ;;
  check)
    exit 0
    ;;
  *)
    printf 'fake rclone received unsupported command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
FAKE_RCLONE

  chmod +x "$fake_bin"
}

create_remote_file() {
  local remote_root="$1"
  local rel_path="$2"
  mkdir -p "$(dirname "${remote_root}/SQL Backups/${rel_path}")"
  printf 'remote %s\n' "$rel_path" >"${remote_root}/SQL Backups/${rel_path}"
}

write_retention_json() {
  local json_path="$1"
  cat >"$json_path" <<'JSON'
[
  {"Path":"FY2025-26/a.sql.gz","ModTime":"2026-01-01T00:00:00Z","Metadata":{"btime":"2026-01-01T00:00:00Z","mtime":"2026-01-01T00:00:00Z"}},
  {"Path":"FY2025-26/b.sql.gz","ModTime":"2026-01-02T00:00:00Z","Metadata":{"btime":"2026-01-02T00:00:00Z","mtime":"2026-01-02T00:00:00Z"}},
  {"Path":"FY2025-26/c.sql.gz","ModTime":"2026-01-03T00:00:00Z","Metadata":{"btime":"2026-01-03T00:00:00Z","mtime":"2026-01-03T00:00:00Z"}},
  {"Path":"FY2025-26/d.sql.gz","ModTime":"2026-01-04T00:00:00Z","Metadata":{"btime":"2026-01-04T00:00:00Z","mtime":"2026-01-04T00:00:00Z"}},
  {"Path":"FY2025-26/e.sql.gz","ModTime":"2026-01-05T00:00:00Z","Metadata":{"btime":"2026-01-05T00:00:00Z","mtime":"2026-01-05T00:00:00Z"}},
  {"Path":"FY2025-26/f.sql.gz","ModTime":"2026-01-06T00:00:00Z","Metadata":{"btime":"2026-01-06T00:00:00Z","mtime":"2026-01-06T00:00:00Z"}},
  {"Path":"FY2025-26/g.sql.gz","ModTime":"2026-01-07T00:00:00Z","Metadata":{"btime":"2026-01-07T00:00:00Z","mtime":"2026-01-07T00:00:00Z"}},
  {"Path":"FY2025-26/h.sql.gz","ModTime":"2026-01-08T00:00:00Z","Metadata":{"btime":"2026-01-08T00:00:00Z","mtime":"2026-01-08T00:00:00Z"}}
]
JSON
}

write_root_level_json() {
  local json_path="$1"
  cat >"$json_path" <<'JSON'
[
  {"Path":"root.sql.gz","ModTime":"2026-01-08T00:00:00Z","Metadata":{"btime":"2026-01-08T00:00:00Z","mtime":"2026-01-08T00:00:00Z"}},
  {"Path":"FY2025-26/in-folder.sql.gz","ModTime":"2026-01-09T00:00:00Z","Metadata":{"btime":"2026-01-09T00:00:00Z","mtime":"2026-01-09T00:00:00Z"}}
]
JSON
}

write_env_file() {
  local env_path="$1"
  local dest_dir="$2"
  local log_dir="$3"
  local state_dir="$4"
  local archive_dir="$5"
  local fake_rclone="$6"

  cat >"$env_path" <<EOF_ENV
RCLONE_BIN="${fake_rclone}"
RCLONE_REMOTE_NAME="gdrive"
GDRIVE_SOURCE_PATH="SQL Backups"
VPS_DESTINATION_DIR="${dest_dir}"
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="5"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
ALLOW_ROOT_LEVEL_BACKUP_FILES="false"
DRY_RUN="false"
ALLOW_NON_DAILYBACKUPS_DESTINATION="false"
ARCHIVE_DELETED_FILES="true"
ARCHIVE_BASE_DIR="${archive_dir}"
RCLONE_FILTER_FILE=""
RCLONE_TRANSFERS="1"
RCLONE_CHECKERS="1"
RCLONE_RETRIES="1"
RCLONE_LOW_LEVEL_RETRIES="1"
RCLONE_STATS_INTERVAL="1s"
RCLONE_LOG_LEVEL="INFO"
RCLONE_FAST_LIST="false"
RCLONE_BWLIMIT=""
VERIFY_WITH_CHECKSUM="false"
POST_SYNC_CHECK="true"
MIN_FREE_SPACE_BYTES="0"
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="false"
LOG_DIR="${log_dir}"
STATE_DIR="${state_dir}"
FILE_UMASK="077"
LOG_RETENTION_DAYS="0"
ARCHIVE_RETENTION_DAYS="0"
EOF_ENV
}

run_retention_prune_test() {
  local case_dir="${TEST_ROOT}/retention"
  local fake_rclone="${case_dir}/fake-rclone"
  local remote_root="${case_dir}/remote"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${case_dir}/archive"
  local json_path="${case_dir}/remote.json"

  mkdir -p "$case_dir" "$dest_dir/FY2025-26" "$dest_dir/FY2023-24" "$log_dir" "$state_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_retention_json "$json_path"

  local file
  for file in a b c d e f g h; do
    create_remote_file "$remote_root" "FY2025-26/${file}.sql.gz"
  done
  printf 'old local a\n' >"${dest_dir}/FY2025-26/a.sql.gz"
  printf 'stale local orphan\n' >"${dest_dir}/FY2023-24/orphan.sql.gz"

  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"

  FAKE_RCLONE_JSON="$json_path" FAKE_RCLONE_REMOTE_ROOT="$remote_root" \
    bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1

  for file in d e f g h; do
    assert_file_exists "${dest_dir}/FY2025-26/${file}.sql.gz"
  done
  for file in a b c; do
    assert_file_missing "${dest_dir}/FY2025-26/${file}.sql.gz"
  done
  assert_file_missing "${dest_dir}/FY2023-24/orphan.sql.gz"

  assert_file_exists "${archive_dir}"/*/FY2025-26/a.sql.gz.*
  assert_file_exists "${archive_dir}"/*/FY2023-24/orphan.sql.gz.*
  assert_contains "${state_dir}/last-run.env" '^STATUS=success$'
  assert_contains "${state_dir}/last-run.env" '^SELECTED_REMOTE_FILES=5$'
  assert_contains "${state_dir}/last-run.env" '^LOCAL_PRUNED_FILES=2$'
  assert_contains "${case_dir}/run.out" 'Post-sync rclone check passed\.'
  printf 'ok - retention copy selects latest 5, prunes, archives, and writes summary\n'
}

run_dry_run_safety_test() {
  local case_dir="${TEST_ROOT}/dry-run"
  local fake_rclone="${case_dir}/fake-rclone"
  local remote_root="${case_dir}/remote"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${case_dir}/archive"
  local json_path="${case_dir}/remote.json"

  mkdir -p "$case_dir" "$dest_dir/FY2025-26" "$log_dir" "$state_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_retention_json "$json_path"

  local file
  for file in a b c d e f g h; do
    create_remote_file "$remote_root" "FY2025-26/${file}.sql.gz"
  done
  printf 'existing local a\n' >"${dest_dir}/FY2025-26/a.sql.gz"
  printf 'stale local b\n' >"${dest_dir}/FY2025-26/b.sql.gz"

  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"
  sed -i 's/^DRY_RUN="false"/DRY_RUN="true"/' "$env_file"

  FAKE_RCLONE_JSON="$json_path" FAKE_RCLONE_REMOTE_ROOT="$remote_root" \
    bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1

  assert_file_exists "${dest_dir}/FY2025-26/a.sql.gz"
  assert_file_exists "${dest_dir}/FY2025-26/b.sql.gz"
  assert_file_missing "${dest_dir}/FY2025-26/d.sql.gz"
  assert_file_missing "${archive_dir}"/*/FY2025-26/a.sql.gz.*
  assert_contains "${state_dir}/last-run.env" '^STATUS=success$'
  assert_contains "${state_dir}/last-run.env" '^LOCAL_PRUNED_FILES=0$'
  assert_contains "${case_dir}/run.out" 'DRY RUN: would prune local file: FY2025-26/a\.sql\.gz'
  printf 'ok - dry run leaves local files and archives unchanged\n'
}

run_root_level_rejection_test() {
  local case_dir="${TEST_ROOT}/root-level"
  local fake_rclone="${case_dir}/fake-rclone"
  local remote_root="${case_dir}/remote"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${case_dir}/archive"
  local json_path="${case_dir}/remote.json"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_root_level_json "$json_path"
  create_remote_file "$remote_root" "FY2025-26/in-folder.sql.gz"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"

  if FAKE_RCLONE_JSON="$json_path" FAKE_RCLONE_REMOTE_ROOT="$remote_root" \
    bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected root-level source file validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'Refusing retention run because every backup file must be inside a top-level financial-year folder\.'
  assert_contains "${state_dir}/last-run.env" '^STATUS=failed$'
  assert_contains "${state_dir}/last-run.env" '^EXIT_CODE=1$'
  printf 'ok - root-level backup files are rejected by default\n'
}

run_drive_root_path_rejection_test() {
  local case_dir="${TEST_ROOT}/drive-root"
  local fake_rclone="${case_dir}/fake-rclone"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${case_dir}/archive"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"
  sed -i 's|^GDRIVE_SOURCE_PATH=.*|GDRIVE_SOURCE_PATH="//"|' "$env_file"

  if bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected all-slashes Google Drive source path validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'GDRIVE_SOURCE_PATH must point to a specific Google Drive backup folder\.'
  assert_contains "${state_dir}/last-run.env" '^STATUS=failed$'
  printf 'ok - all-slashes Google Drive source paths are rejected\n'
}

run_drive_dot_segment_rejection_test() {
  local case_dir="${TEST_ROOT}/drive-dot-segment"
  local fake_rclone="${case_dir}/fake-rclone"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${case_dir}/archive"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"
  sed -i 's|^GDRIVE_SOURCE_PATH=.*|GDRIVE_SOURCE_PATH="./SQL Backups"|' "$env_file"

  if bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected Google Drive source path dot-segment validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'dot segments'
  assert_contains "${state_dir}/last-run.env" '^STATUS=failed$'
  printf 'ok - Google Drive source dot segments are rejected\n'
}

run_runtime_directory_inside_destination_rejection_test() {
  local case_dir="${TEST_ROOT}/unsafe-runtime-dir"
  local fake_rclone="${case_dir}/fake-rclone"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state"
  local archive_dir="${dest_dir}/archive"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$state_dir"
  write_fake_rclone "$fake_rclone"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"

  if bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected archive directory inside destination validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'must not be inside VPS_DESTINATION_DIR'
  assert_contains "${state_dir}/last-run.env" '^STATUS=failed$'
  printf 'ok - runtime directories inside the managed destination are rejected\n'
}

run_state_directory_inside_destination_no_summary_test() {
  local case_dir="${TEST_ROOT}/unsafe-state-inside-destination"
  local fake_rclone="${case_dir}/fake-rclone"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${dest_dir}/state"
  local archive_dir="${case_dir}/archive"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$archive_dir"
  write_fake_rclone "$fake_rclone"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"

  if bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected state directory inside destination validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'must not be inside VPS_DESTINATION_DIR'
  assert_file_missing "$state_dir"
  printf 'ok - unsafe state directories inside the destination do not receive summaries\n'
}

run_unsafe_state_directory_rejection_test() {
  local case_dir="${TEST_ROOT}/unsafe-state-dir"
  local fake_rclone="${case_dir}/fake-rclone"
  local env_file="${case_dir}/sync.env"
  local dest_dir="${case_dir}/dailybackups"
  local log_dir="${case_dir}/logs"
  local state_dir="${case_dir}/state/.."
  local archive_dir="${case_dir}/archive"

  mkdir -p "$case_dir" "$dest_dir" "$log_dir" "$archive_dir" "${case_dir}/state"
  write_fake_rclone "$fake_rclone"
  write_env_file "$env_file" "$dest_dir" "$log_dir" "$state_dir" "$archive_dir" "$fake_rclone"

  if bash "$SYNC_SCRIPT" "$env_file" >"${case_dir}/run.out" 2>&1; then
    fail "Expected unsafe state directory validation to fail"
  fi

  assert_contains "${case_dir}/run.out" 'STATE_DIR must not contain \. or \.\. path segments'
  assert_file_missing "${case_dir}/last-run.env"
  assert_file_missing "${case_dir}/state/last-run.env"
  printf 'ok - unsafe state directories are rejected without writing a summary there\n'
}

bash -n "$SYNC_SCRIPT"
run_retention_prune_test
run_dry_run_safety_test
run_root_level_rejection_test
run_drive_root_path_rejection_test
run_drive_dot_segment_rejection_test
run_runtime_directory_inside_destination_rejection_test
run_state_directory_inside_destination_no_summary_test
run_unsafe_state_directory_rejection_test
printf 'All sync robustness tests passed.\n'
