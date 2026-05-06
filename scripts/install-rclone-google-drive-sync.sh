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

install_packages() {
  if command -v rclone >/dev/null 2>&1; then
    printf 'rclone already installed: %s\n' "$(command -v rclone)"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      rclone util-linux coreutils findutils gawk grep
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y rclone util-linux coreutils findutils gawk grep
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y rclone util-linux coreutils findutils gawk grep
    return
  fi

  printf 'WARNING: Unsupported package manager. Install rclone, util-linux, coreutils, findutils, gawk, and grep manually.\n' >&2
}

[[ -f "$SYNC_SCRIPT_SOURCE" ]] || {
  printf 'ERROR: Missing source script: %s\n' "$SYNC_SCRIPT_SOURCE" >&2
  exit 1
}

[[ -f "$ENV_EXAMPLE_SOURCE" ]] || {
  printf 'ERROR: Missing env example: %s\n' "$ENV_EXAMPLE_SOURCE" >&2
  exit 1
}

install_packages

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
