# Google Drive SQL Backup Sync Project

This project starts with one production operations module:

- Sync SQL backup files from Google Drive to a VPS folder named `dailybackups`.
- Target production host: Ubuntu 24.04 Server on bare metal.
- Use `rclone` as the sync engine.
- Preserve Google Drive financial-year folders on the VPS.
- Keep only the latest 5-7 backup files per financial-year folder locally.
- Select latest files from Google Drive upload/update metadata, not filenames.
- Bootstrap missing Ubuntu requirements automatically during installation.
- Create and validate required folders and permissions.
- Run manually for validation, then automatically through `systemd` every 30 minutes.
- Keep implementation code and separate project documentation complete enough for interns, engineers, managers, and CTO-level review.

## Current Module

| Module | Purpose | Main Files |
| --- | --- | --- |
| Google Drive to VPS SQL Backup Sync | Copies latest backup files from each Google Drive financial-year folder into matching `/dailybackups/<financial-year>/` folders and prunes older local copies. Latest is determined from upload/update metadata, not file name. | `scripts/sync-google-drive-sql-backups.sh`, `config/rclone-gdrive-sql-backup-sync.env.example`, `systemd/rclone-gdrive-sql-backup-sync.*`, `docs/backup-sync/*` |

## Fast Start On The VPS

Run these commands after copying or cloning this repository onto the VPS:

```bash
sudo bash scripts/install-rclone-google-drive-sync.sh
sudo rclone config
sudo nano /etc/rclone-gdrive-sql-backup-sync.env
sudo /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

The installer is idempotent. Re-running it repairs missing packages, missing folders, installed script permissions, environment-file permissions, and the rclone binary if metadata support is missing.

When the dry run is correct, set `DRY_RUN="false"` in `/etc/rclone-gdrive-sql-backup-sync.env`, run the script once again, and then enable the 30-minute timer:

```bash
sudo bash scripts/install-systemd-google-drive-sync.sh
systemctl list-timers --all | grep rclone-gdrive-sql-backup-sync
```

## Local Validation Before Deployment

Run these checks from the repository root after changing scripts, systemd units, filters, or documentation examples:

```bash
bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
tests/test-sync-google-drive-sql-backups.sh
```

The test suite uses a fake `rclone` binary and temporary folders to verify financial-year selection, real-run pruning and archiving, dry-run safety, root-level source rejection, source-path validation, post-sync checks, summary writing, and the guards that keep runtime folders outside `VPS_DESTINATION_DIR`.

## Documentation Index

Read the documentation in this order:

1. `docs/backup-sync/01-scope-and-requirements.md`
2. `docs/backup-sync/02-inputs-calculations-outputs.md`
3. `docs/backup-sync/03-logic-and-interconnections.md`
4. `docs/backup-sync/04-runbook.md`
5. `docs/backup-sync/05-security-and-troubleshooting.md`
6. `docs/backup-sync/06-financial-year-retention.md`
7. `docs/backup-sync/07-ubuntu-2404-baremetal-deployment.md`
8. `docs/backup-sync/08-realtime-and-30-minute-fetch.md`

## Important Safety Rule

The default retention policy is `latest_per_financial_year`, which means the VPS keeps only the latest configured backup files from each Google Drive financial-year folder. Older local files are archived by default under:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/<run-id>
```

For first setup, the example environment file starts with:

```bash
DRY_RUN="true"
```

Do not set it to `false` until the source folder, destination folder, filters, and logs have been verified.
