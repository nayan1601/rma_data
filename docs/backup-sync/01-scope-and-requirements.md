# Scope And Requirements

## Purpose

This module syncs SQL backup files from a Google Drive folder to a Linux VPS folder named `dailybackups` using `rclone`.

The target outcome is:

```text
Google Drive backup folder  ->  rclone remote  ->  VPS /dailybackups folder
```

The module is designed for operational use. It includes:

- Shell scripts with defensive validation and comments.
- Example environment configuration.
- Optional SQL backup file filtering.
- systemd service and timer files for daily scheduling.
- Logs and machine-readable run summaries.
- Safety controls for dry runs, free-space checks, and deleted-file archival.

## In Scope

- One-way sync from Google Drive to VPS.
- Destination folder named `dailybackups`.
- Manual execution for first validation.
- Daily scheduled execution through systemd.
- rclone remote configuration documentation.
- Runtime logs in `/var/log/rclone-gdrive-sql-backup-sync`.
- State summary in `/var/lib/rclone-gdrive-sql-backup-sync/last-run.env`.
- Optional post-sync verification with `rclone check --one-way`.
- Optional include filter for common SQL backup file extensions.

## Out Of Scope

These items are intentionally not implemented in this first module:

- Creating SQL backups from the database server.
- Restoring SQL backups into a database.
- Encrypting or decrypting backup files.
- Cross-region replication from the VPS to another storage provider.
- Monitoring alerts through email, Slack, PagerDuty, or another alerting system.
- Google Workspace admin policy setup.

Those can become later modules after the sync foundation is stable.

## Users And Audiences

| Audience | What They Need |
| --- | --- |
| Intern or junior operator | Step-by-step setup, exact commands, what each file means, how to avoid destructive mistakes. |
| Backend or DevOps engineer | Script logic, failure behavior, logs, service scheduling, operational switches. |
| Security reviewer | Credential storage, permissions, deletion behavior, retention risks. |
| CTO or technical leader | Scope, reliability boundaries, data flow, operational controls, remaining risks. |

## Required VPS Environment

The VPS should be a Linux server with:

- Root or sudo access.
- Bash.
- systemd if automated scheduling is required.
- Enough disk space for the full backup folder plus archive overhead.
- Network access to Google Drive APIs.
- rclone installed and configured.

The install script supports common Debian/Ubuntu, Fedora, and CentOS/RHEL-style package managers.

## Required Google Drive Setup

Before production sync, identify the exact Drive folder that contains SQL backups. Example:

```text
SQL Backups
```

or:

```text
Company Backups/Production SQL
```

The folder path becomes `GDRIVE_SOURCE_PATH` in `/etc/rclone-gdrive-sql-backup-sync.env`.

## Required rclone Remote

The VPS must have an rclone remote configured for Google Drive.

Recommended remote name:

```text
gdrive
```

The configured source then becomes:

```text
gdrive:<GDRIVE_SOURCE_PATH>
```

Example:

```text
gdrive:SQL Backups
```

## Destination Folder Requirement

The default destination is:

```text
/dailybackups
```

The script requires the destination folder name to be `dailybackups`. These are accepted:

```text
/dailybackups
/mnt/backups/dailybackups
/home/backup/dailybackups
```

This is rejected unless explicitly allowed:

```text
/backups
```

The guard exists because the business requirement specifically names `dailybackups`, and accidental syncs to the wrong folder can be damaging.

## Reliability Goals

- Prevent accidental whole-Drive syncs.
- Prevent overlapping sync runs with a lock file.
- Prevent unexpected production writes during first setup by defaulting to dry-run mode.
- Archive destination files that would be deleted or overwritten during `sync`.
- Produce logs and state summaries after each run.
- Allow optional post-sync verification.

## Main Risks

| Risk | Control |
| --- | --- |
| Wrong Google Drive folder selected | Dry run, explicit `GDRIVE_SOURCE_PATH`, logs showing source and destination. |
| Destination files deleted by sync | `ARCHIVE_DELETED_FILES="true"` uses rclone `--backup-dir`. |
| VPS disk full | `MIN_FREE_SPACE_BYTES` free-space check before sync starts. |
| Multiple syncs running together | `flock` lock at `/var/lib/rclone-gdrive-sql-backup-sync/sync.lock`. |
| rclone configured for one user but service runs as another | Run `rclone config` as the same user used by systemd, or set `RCLONE_CONFIG`. |
| Google API or network failure | rclone retries plus non-zero exit code, logs, and failed state summary. |

## Success Criteria

The module is considered working when:

1. `rclone listremotes` shows the configured Google Drive remote.
2. A dry run prints expected files and no unexpected deletions.
3. A real run downloads or updates files into `/dailybackups`.
4. `/var/lib/rclone-gdrive-sql-backup-sync/last-run.env` shows `STATUS=success`.
5. The systemd timer is enabled and listed by `systemctl list-timers`.
6. Logs exist under `/var/log/rclone-gdrive-sql-backup-sync`.
