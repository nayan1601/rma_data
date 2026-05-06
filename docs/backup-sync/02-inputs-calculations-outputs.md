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
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="7"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
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
| `GDRIVE_SOURCE_PATH` | String | `SQL Backups` | Google Drive folder containing financial-year backup folders. |
| `VPS_DESTINATION_DIR` | Absolute Linux path | `/dailybackups` | Local VPS folder receiving backup files. |

## Operational Inputs

| Input | Values | Default | Meaning |
| --- | --- | --- | --- |
| `DRY_RUN` | `true`, `false` | `true` | If true, rclone does not write changes. |
| `RETENTION_POLICY` | `latest_per_financial_year`, `none` | `latest_per_financial_year` | Controls whether the VPS keeps only latest backups per financial year. |
| `BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR` | Integer `5` to `7` | `7` | Number of newest backup files kept locally in each financial-year folder. |
| `RETENTION_TIMESTAMP_MODE` | `latest_metadata_time`, `upload_time`, `modified_time`, `rclone_modtime` | `latest_metadata_time` | Controls which rclone/Google Drive metadata timestamp defines latest. Filename is never used. |
| `ALLOW_ROOT_LEVEL_BACKUP_FILES` | `true`, `false` | `false` | If false, source files not inside a financial-year folder cause failure. |
| `SYNC_MODE` | `sync`, `copy` | `sync` | Used only when `RETENTION_POLICY="none"`. |
| `ARCHIVE_DELETED_FILES` | `true`, `false` | `true` | Archives destination files deleted or overwritten by sync. |
| `ARCHIVE_BASE_DIR` | Absolute path | `/var/backups/rclone-gdrive-sql-backup-sync/archive` | Parent folder for deletion archives. |
| `RCLONE_FILTER_FILE` | File path or empty | empty | Optional rclone filter file. |
| `MIN_FREE_SPACE_BYTES` | Integer bytes | `10737418240` | Minimum free bytes required before sync starts. |
| `REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM` | `true`, `false` | `false` | If true, fails when `/dailybackups` is on the root filesystem. Useful on Ubuntu 24.04 bare metal. |

## Runtime Validation Inputs

The sync script validates configuration before contacting Google Drive.

Validation includes:

- Boolean values must be true/false style values.
- Count and retention values must be integers.
- `BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR` must be between 5 and 7.
- `VPS_DESTINATION_DIR`, `LOG_DIR`, `STATE_DIR`, and `ARCHIVE_BASE_DIR` must be absolute paths.
- `RCLONE_FILTER_FILE` must be an absolute path when set.
- `RCLONE_CONFIG` must be an absolute existing file when set.
- `FILE_UMASK` must be a valid octal umask.
- Required folders are created if missing.
- Required folders must be writable by the running user.

## Financial-Year Input Format

When:

```bash
RETENTION_POLICY="latest_per_financial_year"
```

the Google Drive source folder must use this structure:

```text
<GDRIVE_SOURCE_PATH>/<financial-year-folder>/<backup-file>
```

Example:

```text
SQL Backups/FY2024-25/prod-2025-03-31.sql.gz
SQL Backups/FY2025-26/prod-2026-05-06.sql.gz
```

The script treats the first path segment under `GDRIVE_SOURCE_PATH` as the financial year.

Examples:

| Remote file path relative to source | Financial year used by script |
| --- | --- |
| `FY2024-25/prod-2025-03-31.sql.gz` | `FY2024-25` |
| `2025-26/mysql/prod-2026-05-06.sql.gz` | `2025-26` |

Files directly under the source folder, such as `SQL Backups/prod.sql.gz`, are rejected by default because they cannot be assigned to a financial-year folder.

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

### Destination Filesystem Calculation

The script records which filesystem backs the destination:

```bash
findmnt -n -T "$VPS_DESTINATION_DIR" -o TARGET
```

If:

```bash
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="true"
```

and the mount target is:

```text
/
```

the script stops before transfer. This is an optional bare-metal guard to avoid filling the Ubuntu root filesystem with backups.

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

### Financial-Year Selection Calculation

When `RETENTION_POLICY="latest_per_financial_year"`, the script performs these calculations:

```text
1. rclone lsjson --metadata lists all remote files under the Google Drive source folder.
2. Optional rclone filters remove unwanted file types.
3. The first path segment is assigned as financial_year.
4. A retention timestamp is calculated from metadata according to RETENTION_TIMESTAMP_MODE.
5. Files are grouped by financial_year.
6. Each group is sorted by retention timestamp descending.
7. The first BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR files are selected.
8. rclone copy downloads only those selected files using --files-from.
9. Local destination files not in the selected list are pruned.
```

Default selection:

```text
latest 7 files per financial-year folder by upload/update metadata
```

The backup filename is not used for ordering.

Timestamp modes:

| Mode | Metadata used | Use case |
| --- | --- | --- |
| `latest_metadata_time` | Newest available value among Google Drive `btime`, Google Drive `mtime`, and rclone `ModTime`. | Recommended default when upload time or update time can both represent the newest backup. |
| `upload_time` | Google Drive `btime` only. | Use when the upload/create time is the strict source of truth. |
| `modified_time` | Google Drive `mtime`, falling back to rclone `ModTime`. | Use when updates to an existing Drive file should define latest. |
| `rclone_modtime` | rclone `ModTime` only. | Compatibility mode. |

For Google Drive, rclone metadata key `btime` represents file birth/creation time, and `mtime` represents last modification time. The script requests metadata explicitly with `rclone lsjson --metadata`.

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

The primary output is the local VPS backup set:

```text
/dailybackups
```

File names and financial-year folder structure match the configured Google Drive folder, subject to any filter file and retention selection.

Example:

```text
/dailybackups/
  FY2024-25/
    prod-2025-03-29.sql.gz
    prod-2025-03-30.sql.gz
    prod-2025-03-31.sql.gz
  FY2025-26/
    prod-2026-05-04.sql.gz
    prod-2026-05-05.sql.gz
    prod-2026-05-06.sql.gz
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
RETENTION_POLICY=latest_per_financial_year
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR=7
RETENTION_TIMESTAMP_MODE=latest_metadata_time
REMOTE_FILE_COUNT=366
SELECTED_REMOTE_FILES=21
FILES_WITHOUT_RETENTION_TIMESTAMP=0
LOCAL_PRUNE_CANDIDATES=9
LOCAL_PRUNED_FILES=9
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
RETENTION_POLICY="latest_per_financial_year"
ARCHIVE_DELETED_FILES="true"
```

older local files pruned from `/dailybackups` are moved to:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/<run-id>/<relative-backup-path>.<run-id>
```

When `RETENTION_POLICY="none"` and `SYNC_MODE="sync"`, the script adds:

```bash
--backup-dir "$ARCHIVE_BASE_DIR/$RUN_ID"
--suffix ".$RUN_ID"
```

This means destination files that would be deleted or replaced are moved into a run-specific archive folder instead of being permanently removed.

Example:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/20260506T023000Z/
```
