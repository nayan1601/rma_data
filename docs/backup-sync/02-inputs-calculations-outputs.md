# Inputs, Calculations, And Outputs

## Configuration Input Format

The primary input is a Bash environment file:

```text
/etc/rclone-gdrive-sql-backup-sync.env
```

It is created from:

```text
config/rclone-gdrive-sql-backup-sync.env.example
```

Format rules:

- One key-value pair per line.
- Values should be quoted.
- Comments start with `#`.
- Do not add spaces around variable names.
- Do not commit the real production file.

Valid example:

```bash
RCLONE_REMOTE_NAME="gdrive"
GDRIVE_SOURCE_PATH="SQL Backups"
VPS_DESTINATION_DIR="/dailybackups"
DRY_RUN="true"
SYNC_MODE="sync"
```

Invalid examples:

```bash
RCLONE_REMOTE_NAME = "gdrive"
GDRIVE_SOURCE_PATH=
VPS_DESTINATION_DIR="/backups"
```

## Required Inputs

| Input | Type | Example | Purpose |
| --- | --- | --- | --- |
| `RCLONE_REMOTE_NAME` | String | `gdrive` | Name of the rclone Google Drive remote. |
| `GDRIVE_SOURCE_PATH` | String | `SQL Backups` | Google Drive folder containing backup files. |
| `VPS_DESTINATION_DIR` | Absolute Linux path | `/dailybackups` | Local VPS folder receiving backup files. |

## Operational Inputs

| Input | Values | Default | Meaning |
| --- | --- | --- | --- |
| `DRY_RUN` | `true`, `false` | `true` | If true, rclone does not write changes. |
| `SYNC_MODE` | `sync`, `copy` | `sync` | `sync` mirrors source to destination. `copy` never deletes destination files. |
| `ARCHIVE_DELETED_FILES` | `true`, `false` | `true` | Archives destination files deleted or overwritten by sync. |
| `ARCHIVE_BASE_DIR` | Absolute path | `/var/backups/rclone-gdrive-sql-backup-sync/archive` | Parent folder for deletion archives. |
| `RCLONE_FILTER_FILE` | File path or empty | empty | Optional rclone filter file. |
| `MIN_FREE_SPACE_BYTES` | Integer bytes | `10737418240` | Minimum free bytes required before sync starts. |

## rclone Performance Inputs

| Input | Example | Notes |
| --- | --- | --- |
| `RCLONE_TRANSFERS` | `4` | Number of parallel file transfers. |
| `RCLONE_CHECKERS` | `8` | Number of parallel metadata checkers. |
| `RCLONE_RETRIES` | `3` | High-level retry attempts. |
| `RCLONE_LOW_LEVEL_RETRIES` | `10` | Low-level retry attempts for transient errors. |
| `RCLONE_STATS_INTERVAL` | `30s` | How often rclone prints stats. |
| `RCLONE_LOG_LEVEL` | `INFO` | Common values: `ERROR`, `NOTICE`, `INFO`, `DEBUG`. |
| `RCLONE_FAST_LIST` | `false` | Can speed large listings but increases memory use. |
| `RCLONE_BWLIMIT` | `10M` | Optional bandwidth cap. Empty means unlimited. |
| `VERIFY_WITH_CHECKSUM` | `false` | Uses checksum comparison when supported. |
| `POST_SYNC_CHECK` | `false` | Runs `rclone check --one-way` after sync. |

## Optional Filter Input Format

The optional filter file uses rclone filter syntax.

Example:

```text
+ */
+ *.sql
+ *.sql.gz
+ *.dump
+ *.bak
- *
```

Meaning:

- `+ */` allows traversal into subfolders.
- `+ *.sql` includes SQL files.
- `+ *.sql.gz` includes gzipped SQL dumps.
- `- *` excludes anything not already included.

If no filter file is configured, the whole configured Google Drive source folder is synced.

## Source Path Format

The source path is built by the script as:

```text
<RCLONE_REMOTE_NAME>:<GDRIVE_SOURCE_PATH>
```

Example:

```text
gdrive:SQL Backups
```

If `GDRIVE_SOURCE_PATH` starts with `/`, the script removes the first leading slash before passing it to rclone. This keeps Drive paths consistent.

The script refuses these source paths:

```text
""
"/"
"."
```

Reason: syncing the Google Drive root is too broad and risky.

## Destination Path Format

The destination must be an absolute Linux path and the folder name must be `dailybackups` by default.

Recommended:

```text
/dailybackups
```

Also valid:

```text
/mnt/storage/dailybackups
```

The script creates the destination folder if it does not exist.

## Calculations Performed By The Script

### Free Space Calculation

Before sync, if `MIN_FREE_SPACE_BYTES` is greater than `0`, the script runs:

```bash
df -PB1 "$VPS_DESTINATION_DIR"
```

It reads available bytes from the destination filesystem.

Logic:

```text
if available_bytes < MIN_FREE_SPACE_BYTES:
    stop before rclone starts
else:
    continue
```

### Destination File Count

Before and after sync, the script counts files:

```bash
find "$VPS_DESTINATION_DIR" -type f | wc -l
```

This count is written into the last-run summary as:

```text
FILES_BEFORE
FILES_AFTER
```

### Destination Byte Count

Before and after sync, the script estimates destination bytes:

```bash
du -sb "$VPS_DESTINATION_DIR"
```

This produces:

```text
BYTES_BEFORE
BYTES_AFTER
```

### Byte Delta Calculation

The script calculates:

```text
BYTES_DELTA = BYTES_AFTER - BYTES_BEFORE
```

Interpretation:

- Positive delta: destination uses more bytes after sync.
- Zero delta: no net size change.
- Negative delta: destination uses fewer bytes after sync.

If archive protection is enabled, deleted files may move to `ARCHIVE_BASE_DIR`, so destination delta alone is not total VPS storage growth.

### Duration Calculation

The script records Unix epoch seconds at start and finish:

```text
DURATION_SECONDS = finish_epoch - start_epoch
```

## rclone Change Detection

By default, rclone decides whether files need transfer using metadata such as size and modification time.

If:

```bash
VERIFY_WITH_CHECKSUM="true"
```

the script adds:

```bash
--checksum
```

rclone then compares checksums where Google Drive and the destination backend support them. This can improve confidence but may increase runtime.

## Main Output: Synced Backup Files

The primary output is the local VPS backup mirror:

```text
/dailybackups
```

File names and folder structure match the configured Google Drive folder, subject to any filter file.

Example:

```text
/dailybackups/
  production/
    prod-2026-05-06.sql.gz
  staging/
    staging-2026-05-06.sql.gz
```

## Log Output Format

Every run writes a timestamped log:

```text
/var/log/rclone-gdrive-sql-backup-sync/sync-<run-id>.log
```

Example:

```text
/var/log/rclone-gdrive-sql-backup-sync/sync-20260506T023000Z.log
```

The log contains:

- Run ID.
- Source and destination.
- Dry-run setting.
- Free-space check output.
- File and byte counts.
- rclone transfer output.
- Optional post-sync check output.
- Final success or failure message.

## State Output Format

Every run writes:

```text
/var/lib/rclone-gdrive-sql-backup-sync/last-run.env
```

Format:

```bash
RUN_ID=20260506T023000Z
STATUS=success
EXIT_CODE=0
SOURCE=gdrive:SQL\ Backups
DESTINATION=/dailybackups
STARTED_AT_UTC=2026-05-06T02:30:00Z
FINISHED_AT_UTC=2026-05-06T02:32:18Z
DURATION_SECONDS=138
FILES_BEFORE=140
FILES_AFTER=141
BYTES_BEFORE=84155271220
BYTES_AFTER=84834110221
BYTES_DELTA=678839001
LOG_FILE=/var/log/rclone-gdrive-sql-backup-sync/sync-20260506T023000Z.log
ARCHIVE_DIR=/var/backups/rclone-gdrive-sql-backup-sync/archive/20260506T023000Z
CHECK_STATUS=skipped
```

This file is suitable for simple monitoring scripts because it can be sourced by Bash.

## Exit Codes

| Exit Code | Meaning |
| --- | --- |
| `0` | Sync completed successfully. |
| `1` | Validation, rclone, free-space, check, or runtime failure. |

rclone can return its own non-zero codes. The wrapper records the final code in `EXIT_CODE`.

## Archive Output

When:

```bash
SYNC_MODE="sync"
ARCHIVE_DELETED_FILES="true"
```

the script adds:

```bash
--backup-dir "$ARCHIVE_BASE_DIR/$RUN_ID"
--suffix ".$RUN_ID"
```

This means destination files that would be deleted or replaced are moved into a run-specific archive folder instead of being permanently removed.

Example:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/20260506T023000Z/
```
