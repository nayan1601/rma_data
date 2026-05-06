#!/usr/bin/env bash
#
# Install and enable the systemd timer for daily Google Drive SQL backup sync.
#
# Run after scripts/install-rclone-google-drive-sync.sh and after rclone config
# has been completed for the user that will run the service.

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERROR: Run as root, for example: sudo bash scripts/install-systemd-google-drive-sync.sh\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SERVICE_SOURCE="${REPO_ROOT}/systemd/rclone-gdrive-sql-backup-sync.service"
TIMER_SOURCE="${REPO_ROOT}/systemd/rclone-gdrive-sql-backup-sync.timer"
SERVICE_TARGET="/etc/systemd/system/rclone-gdrive-sql-backup-sync.service"
TIMER_TARGET="/etc/systemd/system/rclone-gdrive-sql-backup-sync.timer"

[[ -f "$SERVICE_SOURCE" ]] || {
  printf 'ERROR: Missing service unit: %s\n' "$SERVICE_SOURCE" >&2
  exit 1
}

[[ -f "$TIMER_SOURCE" ]] || {
  printf 'ERROR: Missing timer unit: %s\n' "$TIMER_SOURCE" >&2
  exit 1
}

[[ -x /usr/local/bin/rclone-gdrive-sql-backup-sync ]] || {
  printf 'ERROR: Missing /usr/local/bin/rclone-gdrive-sql-backup-sync. Run install-rclone-google-drive-sync.sh first.\n' >&2
  exit 1
}

install -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
install -m 0644 "$TIMER_SOURCE" "$TIMER_TARGET"

systemctl daemon-reload
systemctl enable --now rclone-gdrive-sql-backup-sync.timer

printf 'Installed and enabled systemd timer.\n'
printf 'Timer status:\n'
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer || true
printf '\nUseful commands:\n'
printf '  sudo systemctl start rclone-gdrive-sql-backup-sync.service\n'
printf '  sudo systemctl status rclone-gdrive-sql-backup-sync.service\n'
printf '  sudo journalctl -u rclone-gdrive-sql-backup-sync.service -n 100 --no-pager\n'
