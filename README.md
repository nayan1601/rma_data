# Google Drive SQL Backup Sync Project

This project starts with one production operations module:

- Sync SQL backup files from Google Drive to a VPS folder named `dailybackups`.
- Use `rclone` as the sync engine.
- Run manually for validation, then automatically through `systemd`.
- Keep implementation code and separate project documentation complete enough for interns, engineers, managers, and CTO-level review.

## Current Module

| Module | Purpose | Main Files |
| --- | --- | --- |
| Google Drive to VPS SQL Backup Sync | Mirrors SQL backup files from a Google Drive folder into `/dailybackups` or another path ending in `dailybackups`. | `scripts/sync-google-drive-sql-backups.sh`, `config/rclone-gdrive-sql-backup-sync.env.example`, `systemd/rclone-gdrive-sql-backup-sync.*`, `docs/backup-sync/*` |

## Fast Start On The VPS

Run these commands after copying or cloning this repository onto the VPS:

```bash
sudo bash scripts/install-rclone-google-drive-sync.sh
rclone config
sudo nano /etc/rclone-gdrive-sql-backup-sync.env
sudo /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

When the dry run is correct, set `DRY_RUN="false"` in `/etc/rclone-gdrive-sql-backup-sync.env`, run the script once again, and then enable the daily timer:

```bash
sudo bash scripts/install-systemd-google-drive-sync.sh
systemctl list-timers --all | grep rclone-gdrive-sql-backup-sync
```

## Documentation Index

Read the documentation in this order:

1. `docs/backup-sync/01-scope-and-requirements.md`
2. `docs/backup-sync/02-inputs-calculations-outputs.md`
3. `docs/backup-sync/03-logic-and-interconnections.md`
4. `docs/backup-sync/04-runbook.md`
5. `docs/backup-sync/05-security-and-troubleshooting.md`

## Important Safety Rule

The default mode is `sync`, which means the VPS destination is made to match the Google Drive source. To reduce accidental data loss, deleted or overwritten destination files are archived by default under:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/<run-id>
```

For first setup, the example environment file starts with:

```bash
DRY_RUN="true"
```

Do not set it to `false` until the source folder, destination folder, filters, and logs have been verified.
