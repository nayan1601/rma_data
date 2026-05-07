# Scope And Requirements

## Purpose

This module syncs SQL backup files from a Google Drive folder to an Ubuntu 24.04 Server bare-metal VPS folder named `dailybackups` using `rclone`.

The target outcome is:

```text
Google Drive backup folder with financial-year subfolders
  -> rclone remote
  -> VPS /dailybackups/<same-financial-year-folder>
```

The module is designed for operational use. It includes:

- Shell scripts with defensive validation and comments.
- Example environment configuration.
- Optional SQL backup file filtering.
- systemd service and timer files for 30-minute automatic fetching.
- Logs and machine-readable run summaries.
- Safety controls for dry runs, free-space checks, and deleted-file archival.
- Financial-year based VPS retention to keep only the latest 5-7 backups per financial year.
- Metadata-based latest-file selection using Google Drive upload/create and update times, not filenames.

## In Scope

- One-way sync from Google Drive to VPS.
- Destination folder named `dailybackups`.
- Preservation of top-level Google Drive financial-year folders under `dailybackups`.
- Local VPS retention of only the latest configured backup files per financial-year folder.
- Manual execution for first validation.
- Automatic scheduled execution through systemd every 30 minutes.
- rclone remote configuration documentation.
- Runtime logs in `/var/log/rclone-gdrive-sql-backup-sync`.
- State summary in `/var/lib/rclone-gdrive-sql-backup-sync/last-run.env`.
- Optional post-sync verification with `rclone check --one-way`.
- Optional include filter for common SQL backup file extensions.
- Automated installation and repair of required Ubuntu packages, runtime folders, and file permissions.
- Near-realtime polling with a 30-minute maximum check interval in normal operation.

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

The production VPS environment is:

- Ubuntu 24.04 Server.
- Bare-metal hosting.
- systemd timer support.
- Root or sudo access.
- Bash.
- jq for structured JSON selection of latest backup files per financial-year folder.
- A current rclone release that supports `rclone lsjson --metadata`.
- Enough disk space for the full backup folder plus archive overhead.
- Network access to Google Drive APIs.
- rclone installed and configured.

The install script is aligned with Ubuntu apt-based installation. It installs required packages with apt and upgrades rclone through the official rclone installer when the Ubuntu package does not support required metadata output.

## Installer Responsibilities

`scripts/install-rclone-google-drive-sync.sh` is responsible for:

- Confirming it is running as root.
- Detecting Ubuntu 24.04 context.
- Installing required apt packages.
- Installing or upgrading rclone if `rclone lsjson --metadata` is unavailable.
- Installing `/usr/local/bin/rclone-gdrive-sql-backup-sync`.
- Creating `/etc/rclone-gdrive-sql-backup-sync.env` if missing.
- Preserving existing production env settings if the env file already exists.
- Repairing env file permissions to `0600`.
- Creating required runtime folders.
- Verifying the runtime folders are writable.

The installer cannot automate Google Drive authorization. `sudo rclone config` must still be completed by an operator.

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

By default, that source folder must contain financial-year folders as immediate child folders.

Example:

```text
SQL Backups/
  FY2023-24/
  FY2024-25/
  FY2025-26/
```

The same folders are created on the VPS:

```text
/dailybackups/
  FY2023-24/
  FY2024-25/
  FY2025-26/
```

Root-level files directly inside `SQL Backups/` are rejected by default when financial-year retention is enabled.

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
| Bare-metal root filesystem fills up | Optional `REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="true"` guard if `/dailybackups` should be on separate storage. |
| Multiple syncs running together | `flock` lock at `/var/lib/rclone-gdrive-sql-backup-sync/sync.lock`. |
| rclone configured for one user but service runs as another | Run `rclone config` as the same user used by systemd, or set `RCLONE_CONFIG`. |
| Google API or network failure | rclone retries plus non-zero exit code, logs, and failed state summary. |
| Backup filename does not contain a useful date | Retention selection ignores filename and uses rclone/Google Drive metadata timestamps. |
| Missing VPS dependency | Installer installs required packages; runtime fails clearly if a dependency is missing later. |

## Success Criteria

The module is considered working when:

1. `rclone listremotes` shows the configured Google Drive remote.
2. A dry run prints expected files and no unexpected deletions.
3. A real run downloads or updates files into `/dailybackups/<financial-year-folder>/`.
4. `/var/lib/rclone-gdrive-sql-backup-sync/last-run.env` shows `STATUS=success`.
5. Each financial-year folder on the VPS keeps no more than `BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR` selected backup files.
6. The systemd timer is enabled and listed by `systemctl list-timers`.
7. The next timer run is scheduled within 30 minutes.
8. Logs exist under `/var/log/rclone-gdrive-sql-backup-sync`.
