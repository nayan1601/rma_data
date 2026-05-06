# Runbook

This runbook is the practical step-by-step guide for installing, validating, running, and operating the Google Drive to VPS SQL backup sync.

The production target is Ubuntu 24.04 Server on bare metal.

Before installing, confirm the host:

```bash
cat /etc/os-release
systemctl --version
df -h
findmnt
```

If `/dailybackups` should use a dedicated disk, partition, LVM volume, or mounted storage path, mount that storage before running the sync in production.

## 1. Copy The Project To The VPS

Use whichever deployment method is standard for the VPS.

Example with git:

```bash
git clone <repository-url> backup-sync-project
cd backup-sync-project
```

Example with an uploaded zip:

```bash
unzip backup-sync-project.zip
cd backup-sync-project
```

## 2. Install The Sync Module

Run:

```bash
sudo bash scripts/install-rclone-google-drive-sync.sh
```

The installer is safe to rerun. It repairs the installation without overwriting the existing production env file.

This installs:

```text
/usr/local/bin/rclone-gdrive-sql-backup-sync
/etc/rclone-gdrive-sql-backup-sync.env
/etc/rclone-gdrive-sql-backup-sync/sql-backups.filter.example
```

The installer:

- Installs required Ubuntu packages.
- Installs or upgrades rclone if `rclone lsjson --metadata` is unavailable.
- Creates missing runtime folders.
- Repairs environment-file permissions to `0600`.
- Verifies runtime folders are writable.

It also creates:

```text
/dailybackups
/var/log/rclone-gdrive-sql-backup-sync
/var/lib/rclone-gdrive-sql-backup-sync
/var/backups/rclone-gdrive-sql-backup-sync/archive
```

## 3. Configure rclone For Google Drive

Run as root because the systemd service also runs as root:

```bash
sudo rclone config
```

Recommended choices:

```text
n) New remote
name> gdrive
Storage> drive
```

Follow rclone prompts for Google Drive authentication.

For a headless VPS, rclone may ask you to authorize from a machine with a browser. Follow the command it prints, then paste the authorization token back into the VPS prompt.

After configuration, confirm the remote exists:

```bash
sudo rclone listremotes
```

Expected:

```text
gdrive:
```

Check the backup folder can be listed:

```bash
sudo rclone lsd "gdrive:"
sudo rclone ls "gdrive:SQL Backups" --max-depth 1
```

Replace `SQL Backups` with the real Google Drive folder path.

## 4. Edit The Environment File

Open:

```bash
sudo nano /etc/rclone-gdrive-sql-backup-sync.env
```

Set at minimum:

```bash
RCLONE_REMOTE_NAME="gdrive"
GDRIVE_SOURCE_PATH="SQL Backups"
VPS_DESTINATION_DIR="/dailybackups"
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="7"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
DRY_RUN="true"
SYNC_MODE="sync"
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="false"
LOG_DIR="/var/log/rclone-gdrive-sql-backup-sync"
STATE_DIR="/var/lib/rclone-gdrive-sql-backup-sync"
ARCHIVE_BASE_DIR="/var/backups/rclone-gdrive-sql-backup-sync/archive"
```

Keep `DRY_RUN="true"` for the first run. Keep `LOG_DIR`, `STATE_DIR`, and `ARCHIVE_BASE_DIR` outside `/dailybackups`; the sync script rejects these paths if they are inside the managed destination tree.

For bare-metal deployments where `/dailybackups` is expected to be on separate storage, set:

```bash
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="true"
```

Then verify:

```bash
findmnt -T /dailybackups
```

Confirm the Google Drive folder has financial-year folders directly under it:

```text
SQL Backups/FY2024-25/
SQL Backups/FY2025-26/
```

The VPS will keep the same structure:

```text
/dailybackups/FY2024-25/
/dailybackups/FY2025-26/
```

## 5. Optional: Enable SQL File Filtering

If the Google Drive source folder contains only database backups, leave:

```bash
RCLONE_FILTER_FILE=""
```

If the source folder contains mixed content and only SQL backup file types should sync:

```bash
sudo cp /etc/rclone-gdrive-sql-backup-sync/sql-backups.filter.example \
  /etc/rclone-gdrive-sql-backup-sync/sql-backups.filter

sudo nano /etc/rclone-gdrive-sql-backup-sync/sql-backups.filter
```

Then set:

```bash
RCLONE_FILTER_FILE="/etc/rclone-gdrive-sql-backup-sync/sql-backups.filter"
```

## 6. Run A Dry Run

Run:

```bash
sudo /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

Review the output and the log:

```bash
sudo ls -lh /var/log/rclone-gdrive-sql-backup-sync
sudo tail -n 100 /var/log/rclone-gdrive-sql-backup-sync/sync-*.log
```

Confirm:

- Source is the correct Google Drive folder.
- Destination is `/dailybackups`.
- Financial-year folder names match Google Drive.
- Files selected for each financial year match latest Google Drive upload/update metadata.
- The selection report shows no more than `BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR` files per financial year.
- No unexpected delete or retention-prune actions are shown.
- No unrelated personal or business files are selected.

## 7. Run A Real Sync

Edit:

```bash
sudo nano /etc/rclone-gdrive-sql-backup-sync.env
```

Change:

```bash
DRY_RUN="false"
```

Run:

```bash
sudo /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

Check files:

```bash
sudo find /dailybackups -maxdepth 3 -type f | head -50
sudo du -sh /dailybackups
```

Check last-run state:

```bash
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/last-run.env
```

Expected:

```text
STATUS=success
EXIT_CODE=0
RETENTION_POLICY=latest_per_financial_year
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR=7
RETENTION_TIMESTAMP_MODE=latest_metadata_time
FILES_WITHOUT_RETENTION_TIMESTAMP=0
```

Check per-financial-year counts:

```bash
sudo find /dailybackups -mindepth 2 -maxdepth 2 -type f \
  | awk -F/ '{count[$3]++} END {for (fy in count) print fy, count[fy]}'
```

Each financial-year folder should normally show 7 or fewer selected files, unless there are nested folders. For nested folder layouts, use:

```bash
for fy in /dailybackups/*; do
  [ -d "$fy" ] && printf '%s %s\n' "$(basename "$fy")" "$(find "$fy" -type f | wc -l)"
done
```

## 8. Optional: Run Post-Sync Verification

For a stronger initial validation, edit:

```bash
POST_SYNC_CHECK="true"
```

Then run the sync manually again.

After the first production validation, decide whether to keep this enabled. It increases confidence but can increase runtime and Google API usage.

## 9. Enable Daily Scheduling

Run:

```bash
sudo bash scripts/install-systemd-google-drive-sync.sh
```

This script runs the base installer first if the installed binary or env file is missing.

Confirm timer:

```bash
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer
```

The default timer runs daily at:

```text
02:30 VPS local time
```

with up to 15 minutes randomized delay.

## 10. Run The systemd Service Manually

This is useful after config changes:

```bash
sudo systemctl start rclone-gdrive-sql-backup-sync.service
sudo systemctl status rclone-gdrive-sql-backup-sync.service
```

View logs:

```bash
sudo journalctl -u rclone-gdrive-sql-backup-sync.service -n 100 --no-pager
```

Also check script logs:

```bash
sudo ls -lh /var/log/rclone-gdrive-sql-backup-sync
sudo tail -n 100 /var/log/rclone-gdrive-sql-backup-sync/sync-*.log
```

## 11. Change The Schedule

Edit:

```bash
sudo nano /etc/systemd/system/rclone-gdrive-sql-backup-sync.timer
```

Example for daily 04:15:

```ini
OnCalendar=*-*-* 04:15:00
```

Reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart rclone-gdrive-sql-backup-sync.timer
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer
```

## 12. Disable Scheduling

```bash
sudo systemctl disable --now rclone-gdrive-sql-backup-sync.timer
```

Manual runs still work.

## 13. Check Daily Health

Daily operator checklist:

```bash
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/last-run.env
sudo du -sh /dailybackups
sudo find /dailybackups -type f -mtime -2 | head -20
sudo journalctl -u rclone-gdrive-sql-backup-sync.service --since "24 hours ago" --no-pager
```

Expected:

- `STATUS=success`
- `EXIT_CODE=0`
- Recent backup files exist.
- Disk usage is within expected range.
- No repeated rclone errors.

## 14. Emergency Manual Sync

If the timer did not run but the config is correct:

```bash
sudo /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

If there is concern about destructive behavior, temporarily set:

```bash
DRY_RUN="true"
```

then run the command and inspect the log before changing back.

## 15. Rollback Or Remove This Module

Disable timer:

```bash
sudo systemctl disable --now rclone-gdrive-sql-backup-sync.timer
```

Remove systemd files:

```bash
sudo rm -f /etc/systemd/system/rclone-gdrive-sql-backup-sync.service
sudo rm -f /etc/systemd/system/rclone-gdrive-sql-backup-sync.timer
sudo systemctl daemon-reload
```

Remove installed script:

```bash
sudo rm -f /usr/local/bin/rclone-gdrive-sql-backup-sync
```

Do not remove `/dailybackups` unless leadership explicitly confirms the local backup copy is no longer needed.
