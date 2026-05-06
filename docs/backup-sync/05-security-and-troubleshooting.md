# Security And Troubleshooting

## Credential Storage

rclone stores Google Drive credentials in its config file.

Common location when running as root:

```text
/root/.config/rclone/rclone.conf
```

If systemd runs the service as root, configure the Google Drive remote as root or set:

```bash
RCLONE_CONFIG="/path/to/rclone.conf"
```

in:

```text
/etc/rclone-gdrive-sql-backup-sync.env
```

## File Permissions

The install script creates the production env file with:

```text
0600
```

Meaning only root can read and write it.

The sync script uses:

```bash
FILE_UMASK="077"
```

Meaning newly created files are private by default. If another Linux user or application must read `/dailybackups`, configure Linux groups or ACLs deliberately instead of weakening permissions globally.

## Secrets Policy

Never commit:

- `/etc/rclone-gdrive-sql-backup-sync.env`
- `rclone.conf`
- OAuth tokens
- Google service account JSON files
- Logs that reveal private folder names or file names, unless approved for internal operational records

The repository includes `.gitignore` entries for common local secret files.

## Deletion Safety

`rclone sync` can delete files from the destination when they are absent from the source.

The default financial-year retention policy also removes older local files from the VPS even when they still exist in Google Drive. This is intentional to control VPS storage.

This module protects against immediate permanent deletion with:

```bash
ARCHIVE_DELETED_FILES="true"
```

which adds rclone:

```bash
--backup-dir
```

Deleted or overwritten local files move to:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/<run-id>
```

Important: this archive still consumes VPS disk space. Decide on an archive retention policy before enabling `ARCHIVE_RETENTION_DAYS`.

## Financial-Year Retention Safety

When:

```bash
RETENTION_POLICY="latest_per_financial_year"
```

the VPS is not a full mirror of Google Drive. It is a local working set containing the latest selected backups per financial-year folder.

Important assumptions:

- Google Drive remains the full backup archive.
- Each backup file is inside a top-level financial-year folder.
- Google Drive/rclone upload or update metadata is the source of truth for latest-file selection.
- `/dailybackups` is dedicated to this sync job.
- Local files not selected by the retention calculation can be pruned.

## Recommended Production Controls

- Use a dedicated Google account or service account where possible.
- Grant access only to the exact Google Drive backup folder.
- Keep `/dailybackups` readable only by required operators or services.
- Monitor disk space.
- Review logs after the first week of scheduled runs.
- Run a restore drill in a separate project module.
- Define business retention for both Google Drive backups and VPS local archives.

## Installer Repair Behavior

The installer can be rerun after partial setup or package drift. It repairs:

- Missing apt packages.
- Missing or old rclone binary.
- Missing installed sync script.
- Missing runtime folders.
- Unsafe env file permissions.
- Missing filter example.

It does not overwrite an existing `/etc/rclone-gdrive-sql-backup-sync.env` file.

## Troubleshooting: rclone remote not found

Symptom:

```text
ERROR: rclone remote 'gdrive:' was not found.
```

Causes:

- `rclone config` has not been run.
- Remote has a different name.
- Remote was configured under a different Linux user.
- systemd runs as root but remote was configured as another user.

Fix:

```bash
sudo rclone config
sudo rclone listremotes
```

or set:

```bash
RCLONE_CONFIG="/path/to/rclone.conf"
```

## Troubleshooting: Google Drive path is wrong

Symptom:

```text
directory not found
```

or rclone transfers nothing.

Check:

```bash
rclone lsd "gdrive:"
rclone lsd "gdrive:Parent Folder"
rclone ls "gdrive:SQL Backups" --max-depth 1
```

Then update:

```bash
GDRIVE_SOURCE_PATH="correct/folder/path"
```

## Troubleshooting: root-level files rejected

Symptom:

```text
Root-level files found in the source.
Refusing retention run because every backup file must be inside a top-level financial-year folder.
```

Cause:

The source contains files directly under `GDRIVE_SOURCE_PATH` instead of inside a financial-year folder.

Fix the Google Drive layout:

```text
SQL Backups/FY2025-26/prod-2026-05-06.sql.gz
```

If root-level files are intentional, set:

```bash
ALLOW_ROOT_LEVEL_BACKUP_FILES="true"
```

This is not recommended for production because those files are excluded from financial-year retention selection.

## Troubleshooting: destination folder rejected

Symptom:

```text
VPS_DESTINATION_DIR must end in dailybackups.
```

Fix:

Use:

```bash
VPS_DESTINATION_DIR="/dailybackups"
```

or:

```bash
VPS_DESTINATION_DIR="/mnt/storage/dailybackups"
```

Only set this if the architecture intentionally uses another folder name:

```bash
ALLOW_NON_DAILYBACKUPS_DESTINATION="true"
```

## Troubleshooting: not enough free space

Symptom:

```text
Destination filesystem free space is below MIN_FREE_SPACE_BYTES.
```

Check:

```bash
df -h /dailybackups
sudo du -sh /dailybackups
sudo du -sh /var/backups/rclone-gdrive-sql-backup-sync/archive
```

Fix options:

- Increase VPS disk.
- Move destination to a larger mounted volume ending in `dailybackups`.
- Review archive retention.
- Lower `MIN_FREE_SPACE_BYTES` only after confirming the risk.

## Troubleshooting: timer did not run

Check:

```bash
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer
systemctl status rclone-gdrive-sql-backup-sync.timer
systemctl status rclone-gdrive-sql-backup-sync.service
journalctl -u rclone-gdrive-sql-backup-sync.service -n 100 --no-pager
```

If needed, run manually:

```bash
sudo systemctl start rclone-gdrive-sql-backup-sync.service
```

## Troubleshooting: dry run never writes files

Check:

```bash
grep '^DRY_RUN=' /etc/rclone-gdrive-sql-backup-sync.env
```

If it says:

```bash
DRY_RUN="true"
```

then the script is intentionally only simulating changes.

After verifying source and destination, set:

```bash
DRY_RUN="false"
```

## Troubleshooting: post-sync check is slow

If:

```bash
POST_SYNC_CHECK="true"
```

the script runs:

```bash
rclone check --one-way
```

This can take time for large backup folders. Options:

- Keep enabled for first production validation.
- Disable after confidence is established.
- Run it weekly through a separate future verification job.

## Incident Response Checklist

If a backup sync fails:

1. Preserve the latest log file.
2. Read `/var/lib/rclone-gdrive-sql-backup-sync/last-run.env`.
3. Confirm whether the failure happened before or during rclone.
4. Check VPS disk space.
5. Check Google Drive availability and permissions.
6. Run a dry run manually.
7. If deletions occurred unexpectedly, inspect the archive folder for that run ID.
8. Do not delete archives until the incident is closed.

## CTO-Level Open Items For Future Modules

- Database backup creation standard.
- Backup encryption standard.
- Restore testing process.
- Offsite copy beyond Google Drive and one VPS.
- Monitoring and alerting.
- Recovery point objective.
- Recovery time objective.
- Formal retention policy.
- Evidence pack for audits.
