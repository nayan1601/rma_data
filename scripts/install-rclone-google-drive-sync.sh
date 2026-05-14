#!/usr/bin/env bash
#
# Bootstrap and install the Google Drive SQL backup sync module.
#
# Target production host:
#   Ubuntu 24.04 Server, bare metal, systemd.
#
# This script is intentionally idempotent. Running it again should repair
# missing packages, missing directories, missing installed scripts, and unsafe
# permissions without overwriting the production environment file.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SYNC_SCRIPT_SOURCE="${REPO_ROOT}/scripts/sync-google-drive-sql-backups.sh"
ENV_EXAMPLE_SOURCE="${REPO_ROOT}/config/rclone-gdrive-sql-backup-sync.env.example"
FILTER_EXAMPLE_SOURCE="${REPO_ROOT}/filters/sql-backups.filter.example"

SYNC_SCRIPT_TARGET="/usr/local/bin/rclone-gdrive-sql-backup-sync"
ENV_TARGET="/etc/rclone-gdrive-sql-backup-sync.env"
FILTER_DIR="/etc/rclone-gdrive-sql-backup-sync"
FILTER_EXAMPLE_TARGET="${FILTER_DIR}/sql-backups.filter.example"

DEFAULT_DESTINATION_DIR="/dailybackups"
DEFAULT_LOG_DIR="/var/log/rclone-gdrive-sql-backup-sync"
DEFAULT_STATE_DIR="/var/lib/rclone-gdrive-sql-backup-sync"
DEFAULT_ARCHIVE_BASE_DIR="/var/backups/rclone-gdrive-sql-backup-sync/archive"
ALLOW_NON_DAILYBACKUPS_DESTINATION="false"

APT_PACKAGES=(
  ca-certificates
  curl
  unzip
  rclone
  util-linux
  coreutils
  findutils
  gawk
  grep
  jq
)

REQUIRED_COMMANDS=(
  awk
  bash
  curl
  date
  df
  du
  find
  findmnt
  flock
  grep
  jq
  rclone
  realpath
  sed
  tee
  wc
)

print() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run as root, for example: sudo bash scripts/install-rclone-google-drive-sync.sh"
  fi
}

require_source_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required repository file: $path"
}

print_os_context() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    print "Detected OS: ${PRETTY_NAME:-unknown}"

    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      print "Target OS confirmed: Ubuntu 24.04 Server."
    else
      print "WARNING: production target is Ubuntu 24.04 Server bare metal; this host reports ${ID:-unknown} ${VERSION_ID:-unknown}." >&2
    fi
  else
    print "WARNING: /etc/os-release not found. Cannot confirm Ubuntu 24.04 target." >&2
  fi
}

install_apt_packages() {
  command -v apt-get >/dev/null 2>&1 || fail "apt-get not found. This installer is designed for Ubuntu 24.04 Server."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${APT_PACKAGES[@]}"
}

rclone_supports_metadata() {
  command -v rclone >/dev/null 2>&1 || return 1
  rclone lsjson --metadata --help >/dev/null 2>&1
}

install_or_upgrade_rclone_from_official_script() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  print "Installing/upgrading rclone with the official rclone installer because metadata support is required."
  curl -fsSL https://rclone.org/install.sh -o "${tmp_dir}/install-rclone.sh"
  bash "${tmp_dir}/install-rclone.sh"
  rm -rf -- "$tmp_dir"

  hash -r
}

ensure_rclone_metadata_support() {
  if rclone_supports_metadata; then
    print "rclone metadata support confirmed: $(command -v rclone)"
    rclone version | head -n 1 || true
    return
  fi

  install_or_upgrade_rclone_from_official_script

  if ! rclone_supports_metadata; then
    fail "rclone still does not support 'lsjson --metadata' after install/upgrade."
  fi

  print "rclone metadata support confirmed after upgrade: $(command -v rclone)"
  rclone version | head -n 1 || true
}

validate_required_commands() {
  local missing=()
  local cmd

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    fail "Missing required commands after installation: ${missing[*]}"
  fi
}

install_project_files() {
  install -m 0755 "$SYNC_SCRIPT_SOURCE" "$SYNC_SCRIPT_TARGET"
  chown root:root "$SYNC_SCRIPT_TARGET"

  if [[ ! -f "$ENV_TARGET" ]]; then
    install -m 0600 "$ENV_EXAMPLE_SOURCE" "$ENV_TARGET"
    chown root:root "$ENV_TARGET"
    print "Created environment file: $ENV_TARGET"
  else
    chown root:root "$ENV_TARGET"
    chmod 0600 "$ENV_TARGET"
    print "Preserved existing environment file and repaired permissions: $ENV_TARGET"
  fi

  install -d -m 0755 "$FILTER_DIR"
  chown root:root "$FILTER_DIR"
  install -m 0644 "$FILTER_EXAMPLE_SOURCE" "$FILTER_EXAMPLE_TARGET"
  chown root:root "$FILTER_EXAMPLE_TARGET"
}

strip_trailing_slashes() {
  local value="$1"

  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
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

is_true() {
  case "${1:-}" in
    true | TRUE | True | 1 | yes | YES | y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_managed_path_safe() {
  local path
  local description="$2"

  path="$(normalize_managed_path "$1")"

  [[ -n "$path" ]] || fail "$description path is empty."
  [[ "$path" == /* ]] || fail "$description path must be absolute: $path"

  case "$path" in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/backups | /var/lib | /var/log)
      fail "$description path points at a broad system directory that this installer must not manage: $path"
      ;;
  esac

  if [[ "$path" == *'/../'* || "$path" == */.. || "$path" == *'/./'* || "$path" == */. ]]; then
    fail "$description path must not contain . or .. path segments: $path"
  fi
}

path_is_within() {
  local child
  local parent

  child="$(normalize_managed_path "$1")"
  parent="$(normalize_managed_path "$2")"

  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

load_runtime_paths() {
  VPS_DESTINATION_DIR="$DEFAULT_DESTINATION_DIR"
  LOG_DIR="$DEFAULT_LOG_DIR"
  STATE_DIR="$DEFAULT_STATE_DIR"
  ARCHIVE_BASE_DIR="$DEFAULT_ARCHIVE_BASE_DIR"
  ALLOW_NON_DAILYBACKUPS_DESTINATION="false"

  if [[ -f "$ENV_TARGET" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_TARGET"
  fi

  VPS_DESTINATION_DIR="$(normalize_managed_path "${VPS_DESTINATION_DIR:-$DEFAULT_DESTINATION_DIR}")"
  LOG_DIR="$(normalize_managed_path "${LOG_DIR:-$DEFAULT_LOG_DIR}")"
  STATE_DIR="$(normalize_managed_path "${STATE_DIR:-$DEFAULT_STATE_DIR}")"
  ARCHIVE_BASE_DIR="$(normalize_managed_path "${ARCHIVE_BASE_DIR:-$DEFAULT_ARCHIVE_BASE_DIR}")"
  ALLOW_NON_DAILYBACKUPS_DESTINATION="${ALLOW_NON_DAILYBACKUPS_DESTINATION:-false}"
}

validate_runtime_paths() {
  local destination_leaf
  local managed_path

  destination_leaf="${VPS_DESTINATION_DIR##*/}"
  if [[ "$destination_leaf" != "dailybackups" ]] && ! is_true "$ALLOW_NON_DAILYBACKUPS_DESTINATION"; then
    fail "Backup destination path must end in dailybackups. Current value: $VPS_DESTINATION_DIR"
  fi

  require_managed_path_safe "$VPS_DESTINATION_DIR" "Backup destination"
  require_managed_path_safe "$LOG_DIR" "Log directory"
  require_managed_path_safe "$STATE_DIR" "State directory"
  require_managed_path_safe "$ARCHIVE_BASE_DIR" "Archive directory"

  for managed_path in "$LOG_DIR" "$STATE_DIR" "$ARCHIVE_BASE_DIR"; do
    if path_is_within "$managed_path" "$VPS_DESTINATION_DIR"; then
      fail "Log, state, and archive directories must not be inside the backup destination because retention pruning manages destination files: $managed_path"
    fi
  done

  if [[ "$LOG_DIR" == "$STATE_DIR" || "$LOG_DIR" == "$ARCHIVE_BASE_DIR" || "$STATE_DIR" == "$ARCHIVE_BASE_DIR" ]]; then
    fail "Log, state, and archive directories must be separate directories."
  fi
}

ensure_directory() {
  local path="$1"
  local mode="$2"
  local description="$3"

  require_managed_path_safe "$path" "$description"

  if [[ -e "$path" && ! -d "$path" ]]; then
    fail "$description path exists but is not a directory: $path"
  fi

  install -d -m "$mode" "$path"
  chown root:root "$path"
  chmod "$mode" "$path"
}

validate_directory_writable() {
  local path="$1"
  local probe="${path}/.backup-sync-write-test"

  : >"$probe"
  rm -f -- "$probe"
}

ensure_runtime_directories() {
  ensure_directory "$VPS_DESTINATION_DIR" "0750" "Backup destination"
  ensure_directory "$LOG_DIR" "0750" "Log directory"
  ensure_directory "$STATE_DIR" "0750" "State directory"
  ensure_directory "$ARCHIVE_BASE_DIR" "0750" "Archive directory"

  validate_directory_writable "$VPS_DESTINATION_DIR"
  validate_directory_writable "$LOG_DIR"
  validate_directory_writable "$STATE_DIR"
  validate_directory_writable "$ARCHIVE_BASE_DIR"
}

print_next_steps() {
  cat <<EOF

Installation complete.

Installed:
  $SYNC_SCRIPT_TARGET
  $ENV_TARGET
  $FILTER_EXAMPLE_TARGET

Runtime folders verified:
  $VPS_DESTINATION_DIR
  $LOG_DIR
  $STATE_DIR
  $ARCHIVE_BASE_DIR

Next steps:
  1. Configure Google Drive auth as the service user:
       sudo rclone config
  2. Edit production settings:
       sudo nano $ENV_TARGET
  3. Run a dry run:
       sudo $SYNC_SCRIPT_TARGET $ENV_TARGET
  4. Set DRY_RUN="false" only after dry-run validation.
  5. Enable scheduling:
       sudo bash scripts/install-systemd-google-drive-sync.sh
EOF
}

require_root
require_source_file "$SYNC_SCRIPT_SOURCE"
require_source_file "$ENV_EXAMPLE_SOURCE"
require_source_file "$FILTER_EXAMPLE_SOURCE"

print_os_context
install_apt_packages
ensure_rclone_metadata_support
validate_required_commands
install_project_files
load_runtime_paths
validate_runtime_paths
ensure_runtime_directories
print_next_steps
