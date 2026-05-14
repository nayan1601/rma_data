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
  command -v rclone >/dev/null 2>&1 &&
    rclone lsjson --help 2>/dev/null | grep -q -- '--metadata'
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

load_runtime_paths() {
  VPS_DESTINATION_DIR="$DEFAULT_DESTINATION_DIR"
  LOG_DIR="$DEFAULT_LOG_DIR"
  STATE_DIR="$DEFAULT_STATE_DIR"
  ARCHIVE_BASE_DIR="$DEFAULT_ARCHIVE_BASE_DIR"

  if [[ -f "$ENV_TARGET" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_TARGET"
  fi

  VPS_DESTINATION_DIR="${VPS_DESTINATION_DIR:-$DEFAULT_DESTINATION_DIR}"
  LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
  STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
  ARCHIVE_BASE_DIR="${ARCHIVE_BASE_DIR:-$DEFAULT_ARCHIVE_BASE_DIR}"
}

ensure_directory() {
  local path="$1"
  local mode="$2"
  local description="$3"

  [[ -n "$path" ]] || fail "$description path is empty."
  [[ "$path" == /* ]] || fail "$description path must be absolute: $path"

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
ensure_runtime_directories
print_next_steps
