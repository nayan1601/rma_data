# Logic And Interconnections

## System Components

| Component | File Or Location | Responsibility |
| --- | --- | --- |
| rclone remote | rclone config, usually `/root/.config/rclone/rclone.conf` | Authenticates to Google Drive and exposes it as `gdrive:`. |
| Environment file | `/etc/rclone-gdrive-sql-backup-sync.env` | Holds source path, destination path, dry-run setting, and runtime options. |
| Sync script | `/usr/local/bin/rclone-gdrive-sql-backup-sync` | Performs validation, locking, rclone execution, logging, and summary writing. |
| Destination folder | `/dailybackups` | Stores the latest selected SQL backup files under financial-year folders. |
| Log folder | `/var/log/rclone-gdrive-sql-backup-sync` | Stores per-run text logs. |
| State folder | `/var/lib/rclone-gdrive-sql-backup-sync` | Stores lock file and last-run summary. |
| Archive folder | `/var/backups/rclone-gdrive-sql-backup-sync/archive` | Stores destination files deleted or overwritten by sync. |
| systemd service | `/etc/systemd/system/rclone-gdrive-sql-backup-sync.service` | Runs one sync job. |
| systemd timer | `/etc/systemd/system/rclone-gdrive-sql-backup-sync.timer` | Starts the service daily. |

## Data Flow

```mermaid
flowchart LR
    A["SQL backup files in Google Drive"] --> B["rclone Google Drive remote"]
    B --> C["sync-google-drive-sql-backups.sh"]
    D["/etc/rclone-gdrive-sql-backup-sync.env"] --> C
    E["optional rclone filter file"] --> C
    C --> F["/dailybackups/<financial-year>/latest selected files"]
    C --> G["/var/log/rclone-gdrive-sql-backup-sync/sync-<run-id>.log"]
    C --> H["/var/lib/rclone-gdrive-sql-backup-sync/last-run.env"]
    C --> I["/var/backups/rclone-gdrive-sql-backup-sync/archive/<run-id>"]
    J["systemd timer"] --> K["systemd service"]
    K --> C
```

## Execution Sequence

```text
1. systemd timer fires, or an operator runs the script manually.
2. systemd service starts the sync script.
3. Sync script loads /etc/rclone-gdrive-sql-backup-sync.env.
4. Script validates:
   - environment file exists
   - booleans, integers, umask, and absolute paths are valid
   - rclone exists
   - rclone remote exists
   - Google Drive source path is specific
   - destination folder ends in dailybackups
   - optional filter file exists
   - destination filesystem has minimum required free space
5. Script creates required runtime directories if missing and verifies write access.
6. Script opens a lock file with flock.
7. Script calculates destination files and bytes before sync.
8. Script builds rclone arguments.
9. If financial-year retention is enabled, script lists remote files with metadata, selects latest N per financial year by metadata timestamp, copies selected files, and prunes older local files.
10. If financial-year retention is disabled, script runs standard rclone sync or copy.
11. If enabled, script runs rclone check --one-way.
12. Script removes old logs and old archive folders if retention is enabled.
13. Script calculates destination files and bytes after sync.
14. Script writes /var/lib/rclone-gdrive-sql-backup-sync/last-run.env.
15. Script exits with success or failure.
```

## Pseudocode

```text
load ENV_FILE

set defaults for optional values

if GDRIVE_SOURCE_PATH is empty or root:
    fail

if basename(VPS_DESTINATION_DIR) != "dailybackups":
    fail unless explicitly allowed

create destination, log, state, and archive directories
verify destination, log, state, and archive directories are writable

open log file

acquire lock
if lock already held:
    fail

if rclone remote does not exist:
    fail

if free space is below MIN_FREE_SPACE_BYTES:
    fail

files_before = count destination files
bytes_before = count destination bytes

common_flags = logging + retries + transfer settings

if filter file is configured:
    common_flags += filter file

if checksum verification is configured:
    common_flags += --checksum

if retention policy is latest_per_financial_year:
    remote_files = rclone lsjson --metadata source recursively
    retention_time = upload/create and update metadata, depending on RETENTION_TIMESTAMP_MODE
    selected_files = latest N files per top-level financial-year folder by retention_time
    run rclone copy source destination --files-from selected_files
    prune local files that are not in selected_files
else:
    run rclone sync or copy according to SYNC_MODE

if post-sync check is enabled:
    run rclone check --one-way

files_after = count destination files
bytes_after = count destination bytes
bytes_delta = bytes_after - bytes_before

write last-run.env
exit
```

## Why The Default Uses Selected rclone copy

The current storage requirement is:

```text
keep only the latest 5-7 backups on the VPS for each financial year
```

Google Drive remains the full source archive. If the VPS used plain `rclone sync` against the full Google Drive folder, older files pruned locally would be downloaded again on the next run because they still exist in Google Drive.

For that reason, the default policy uses:

```text
rclone lsjson --metadata -> select latest N per financial year -> rclone copy --files-from -> local prune
```

This still uses rclone for Google Drive transfer, but the effective VPS state is intentionally smaller than the full Google Drive archive.

## Standard rclone sync Mode

The requirement says the VPS should sync from Google Drive. In rclone terms:

```bash
rclone sync source destination
```

means:

- Copy files that are new in source.
- Update files that changed in source.
- Delete destination files that no longer exist in source.

That is the correct behavior for a mirror, but it is risky for backups if someone deletes files from Google Drive by mistake. Therefore, the script uses `--backup-dir` by default so deleted or overwritten destination files are archived.

## sync Mode Versus copy Mode

| Mode | Command | Deletes Destination Files? | Use Case |
| --- | --- | --- | --- |
| `sync` | `rclone sync` | Yes, unless protected by archive behavior. | Keep VPS folder as exact mirror of Drive folder. |
| `copy` | `rclone copy` | No. | Safer one-way accumulation where old local files remain. |

`SYNC_MODE` is used only when `RETENTION_POLICY="none"`.

## Financial-Year Retention Logic

The script expects financial-year folders as top-level folders under `GDRIVE_SOURCE_PATH`.

Example:

```text
SQL Backups/FY2024-25/file-a.sql.gz
SQL Backups/FY2025-26/file-b.sql.gz
```

The script groups by the first path segment:

```text
FY2024-25
FY2025-26
```

Inside each group, files are sorted by the configured metadata timestamp descending. The default `RETENTION_TIMESTAMP_MODE="latest_metadata_time"` uses the newest available value among Google Drive upload/create metadata, Google Drive update metadata, and rclone `ModTime`. The newest `BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR` files are copied to the VPS. Local files not in that selected set are archived or deleted depending on `ARCHIVE_DELETED_FILES`.

## Locking Logic

The script uses:

```bash
flock -n
```

on:

```text
/var/lib/rclone-gdrive-sql-backup-sync/sync.lock
```

If a second run starts while the first run is active, the second run exits. This prevents two rclone processes from writing to the same destination at the same time.

## Logging Logic

The script creates one log file per run:

```text
sync-<run-id>.log
```

`RUN_ID` uses UTC time:

```text
YYYYMMDDTHHMMSSZ
```

Example:

```text
20260506T023000Z
```

The script redirects both standard output and standard error into the log while still printing to the terminal or systemd journal.

## Summary Logic

The `EXIT` trap writes `last-run.env` even if the script fails after the state directory has been configured. This helps operators see the last known status without reading every log line.

Possible status values:

```text
success
failed
```

Possible check status values:

```text
skipped
running
success
failed
```

## Interconnection With systemd

The timer starts the service:

```text
rclone-gdrive-sql-backup-sync.timer
  -> rclone-gdrive-sql-backup-sync.service
      -> /usr/local/bin/rclone-gdrive-sql-backup-sync /etc/rclone-gdrive-sql-backup-sync.env
```

The timer uses:

```text
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=15m
```

Meaning:

- Run daily at 02:30 VPS local time.
- If the VPS was down at the scheduled time, run after it comes back.
- Add up to 15 minutes of random delay to avoid all servers hitting external services at exactly the same second.

## Failure Boundaries

| Failure | Result |
| --- | --- |
| Missing env file | Script exits before sync. |
| Missing rclone binary | Script exits before sync. |
| Missing remote | Script exits before sync. |
| Bad destination folder name | Script exits before sync. |
| Not enough free space | Script exits before sync. |
| rclone transfer failure | Script exits non-zero and writes failed summary. |
| post-sync check failure | Script exits non-zero and writes failed summary. |
| Lock already held | Script exits before sync. |
