#!/usr/bin/env bash
#
# Install the Google Drive SQL backup sync module on a Linux VPS.
#
# This script is intended to be run from the repository root:
#   sudo bash scripts/install-rclone-google-drive-sync.sh
#
# It installs the sync runner, copies the example environment file if the real
# one does not exist, creates runtime directories, and installs an optional
# rclone filter example.

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERROR: Run as root, for example: sudo bash scripts/install-rclone-google-drive-sync.sh\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SYNC_SCRIPT_SOURCE="${REPO_ROOT}/scripts/sync-google-drive-sql-backups.sh"
ENV_EXAMPLE_SOURCE="${REPO_ROOT}/config/rclone-gdrive-sql-backup-sync.env.example"
FILTER_EXAMPLE_SOURCE="${REPO_ROOT}/filters/sql-backups.filter.example"

SYNC_SCRIPT_TARGET="/usr/local/bin/rclone-gdrive-sql-backup-sync"
ENV_TARGET="/etc/rclone-gdrive-sql-backup-sync.env"
FILTER_DIR="/etc/rclone-gdrive-sql-backup-sync"
FILTER_EXAMPLE_TARGET="${FILTER_DIR}/sql-backups.filter.example"

print_os_context() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'Detected OS: %s\n' "${PRETTY_NAME:-unknown}"

    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      printf 'Target OS confirmed: Ubuntu 24.04 Server.\n'
    else
      printf 'WARNING: Production target is Ubuntu 24.04 Server bare metal; this host reports %s %s.\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
    fi
  else
    printf 'WARNING: /etc/os-release not found. Cannot confirm Ubuntu 24.04 target.\n' >&2
  fi
}

install_packages() {
  if command -v rclone >/dev/null 2>&1; then
    printf 'rclone already installed: %s\n' "$(command -v rclone)"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      rclone util-linux coreutils findutils gawk grep jq
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y rclone util-linux coreutils findutils gawk grep jq
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y rclone util-linux coreutils findutils gawk grep jq
    return
  fi

  printf 'WARNING: Unsupported package manager. Install rclone, util-linux, coreutils, findutils, gawk, grep, and jq manually.\n' >&2
}

validate_rclone_capabilities() {
  if ! command -v rclone >/dev/null 2>&1; then
    printf 'ERROR: rclone is not installed or not in PATH.\n' >&2
    exit 1
  fi

  if ! rclone lsjson --help 2>/dev/null | grep -q -- '--metadata'; then
    printf 'ERROR: installed rclone does not support lsjson --metadata.\n' >&2
    printf 'Install a current rclone release from https://rclone.org/downloads/ and rerun this script.\n' >&2
    exit 1
  fi
}

[[ -f "$SYNC_SCRIPT_SOURCE" ]] || {
  printf 'ERROR: Missing source script: %s\n' "$SYNC_SCRIPT_SOURCE" >&2
  exit 1
}

[[ -f "$ENV_EXAMPLE_SOURCE" ]] || {
  printf 'ERROR: Missing env example: %s\n' "$ENV_EXAMPLE_SOURCE" >&2
  exit 1
}

print_os_context
install_packages
validate_rclone_capabilities

install -m 0755 "$SYNC_SCRIPT_SOURCE" "$SYNC_SCRIPT_TARGET"

if [[ ! -f "$ENV_TARGET" ]]; then
  install -m 0600 "$ENV_EXAMPLE_SOURCE" "$ENV_TARGET"
  printf 'Created environment file: %s\n' "$ENV_TARGET"
else
  printf 'Preserved existing environment file: %s\n' "$ENV_TARGET"
fi

install -d -m 0755 "$FILTER_DIR"
install -m 0644 "$FILTER_EXAMPLE_SOURCE" "$FILTER_EXAMPLE_TARGET"

install -d -m 0750 /dailybackups
install -d -m 0750 /var/log/rclone-gdrive-sql-backup-sync
install -d -m 0750 /var/lib/rclone-gdrive-sql-backup-sync
install -d -m 0750 /var/backups/rclone-gdrive-sql-backup-sync/archive

printf '\nInstallation complete.\n'
printf 'Next steps:\n'
printf '  1. Run: rclone config\n'
printf '  2. Edit: %s\n' "$ENV_TARGET"
printf '  3. Dry run: %s %s\n' "$SYNC_SCRIPT_TARGET" "$ENV_TARGET"
printf '  4. Set DRY_RUN="false" after validation.\n'
printf '  5. Enable scheduling with: sudo bash scripts/install-systemd-google-drive-sync.sh\n'
