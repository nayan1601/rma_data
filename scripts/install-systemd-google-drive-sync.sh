#!/usr/bin/env bash
#
# Install and enable the systemd timer for daily Google Drive SQL backup sync.
#
# This script is idempotent. It installs the base sync module first if needed,
# validates systemd availability, verifies unit syntax when possible, then
# enables the timer.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_INSTALLER="${REPO_ROOT}/scripts/install-rclone-google-drive-sync.sh"
SERVICE_SOURCE="${REPO_ROOT}/systemd/rclone-gdrive-sql-backup-sync.service"
TIMER_SOURCE="${REPO_ROOT}/systemd/rclone-gdrive-sql-backup-sync.timer"
SERVICE_TARGET="/etc/systemd/system/rclone-gdrive-sql-backup-sync.service"
TIMER_TARGET="/etc/systemd/system/rclone-gdrive-sql-backup-sync.timer"
SYNC_SCRIPT_TARGET="/usr/local/bin/rclone-gdrive-sql-backup-sync"
ENV_TARGET="/etc/rclone-gdrive-sql-backup-sync.env"

print() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run as root, for example: sudo bash scripts/install-systemd-google-drive-sync.sh"
  fi
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required file: $path"
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

ensure_base_installation() {
  if [[ -x "$SYNC_SCRIPT_TARGET" && -f "$ENV_TARGET" ]]; then
    print "Base sync installation already present."
    return
  fi

  require_file "$BASE_INSTALLER"
  print "Base sync installation is incomplete. Running base installer first."
  bash "$BASE_INSTALLER"
}

validate_systemd() {
  require_command systemctl

  if [[ ! -d /run/systemd/system ]]; then
    fail "systemd does not appear to be PID 1 on this host. Timer installation requires systemd."
  fi
}

install_units() {
  require_file "$SERVICE_SOURCE"
  require_file "$TIMER_SOURCE"
  [[ -x "$SYNC_SCRIPT_TARGET" ]] || fail "Missing executable sync script: $SYNC_SCRIPT_TARGET"
  [[ -f "$ENV_TARGET" ]] || fail "Missing environment file: $ENV_TARGET"

  install -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
  install -m 0644 "$TIMER_SOURCE" "$TIMER_TARGET"
  chown root:root "$SERVICE_TARGET" "$TIMER_TARGET"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$SERVICE_TARGET" "$TIMER_TARGET"
  fi
}

enable_timer() {
  systemctl daemon-reload
  systemctl enable --now rclone-gdrive-sql-backup-sync.timer
}

print_status() {
  print "Installed and enabled systemd timer."
  print "Timer status:"
  systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer || true

  cat <<EOF

Useful commands:
  sudo systemctl start rclone-gdrive-sql-backup-sync.service
  sudo systemctl status rclone-gdrive-sql-backup-sync.service
  sudo journalctl -u rclone-gdrive-sql-backup-sync.service -n 100 --no-pager
EOF
}

require_root
validate_systemd
ensure_base_installation
install_units
enable_timer
print_status
