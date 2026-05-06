# Financial-Year Retention

## Requirement

The VPS must keep backup files under financial-year folders matching the Google Drive structure. To avoid filling VPS storage, the VPS should retain only the latest 5-7 backup files for each financial year.

Default implementation:

```bash
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="7"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
```

## Required Google Drive Layout

The configured Google Drive source folder must contain financial-year folders as immediate child folders.

Example:

```text
SQL Backups/
  FY2023-24/
    prod-2024-03-29.sql.gz
    prod-2024-03-30.sql.gz
    prod-2024-03-31.sql.gz
  FY2024-25/
    prod-2025-03-29.sql.gz
    prod-2025-03-30.sql.gz
    prod-2025-03-31.sql.gz
  FY2025-26/
    prod-2026-05-04.sql.gz
    prod-2026-05-05.sql.gz
    prod-2026-05-06.sql.gz
```

The script treats the first folder below `GDRIVE_SOURCE_PATH` as the financial year.

The script does not calculate the Indian financial year from backup dates. Google Drive folder structure is the source of truth because the user requirement says the financial-year folder already exists there.

The script also does not use filenames for latest-file selection. Filenames can be random, inconsistent, or business-specific. Latest-file selection is based on Google Drive/rclone metadata timestamps.

## VPS Output Layout

The VPS preserves the same folder names:

```text
/dailybackups/
  FY2023-24/
  FY2024-25/
  FY2025-26/
```

Each financial-year folder should contain no more than:

```text
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR
```

selected backup files, unless a backup file is archived outside `/dailybackups`.

## Selection Rule

For each financial-year folder:

```text
1. List remote files with `rclone lsjson --metadata`.
2. Apply the optional rclone filter file.
3. Group files by top-level financial-year folder.
4. Calculate retention timestamp from metadata.
5. Sort each group by retention timestamp descending.
6. Select the latest BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR files.
7. Copy selected files to the VPS with rclone copy --files-from.
8. Prune local files that are not selected.
```

Default timestamp mode:

```bash
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
```

This uses the newest available value among:

- Google Drive file birth/creation/upload metadata: rclone metadata key `btime`
- Google Drive update/modified metadata: rclone metadata key `mtime`
- Normal rclone object modification time: `ModTime`

Alternative modes:

| Mode | Meaning |
| --- | --- |
| `upload_time` | Sort strictly by Google Drive creation/upload metadata `btime`. |
| `modified_time` | Sort by Google Drive modified metadata `mtime`, falling back to `ModTime`. |
| `rclone_modtime` | Sort by rclone `ModTime` only. |

The recommended mode is `latest_metadata_time` because it handles both newly uploaded backup files and backup files updated in Google Drive after initial upload.

## Why Plain rclone sync Is Not Used For This Policy

Plain `rclone sync` mirrors the complete source. If Google Drive contains 300 backups and the VPS should keep only 7 per financial year, plain sync would either:

- copy all 300 files to the VPS, or
- re-copy older files after the local retention prune removes them.

Therefore this project uses rclone in a selected-copy pattern:

```text
rclone lsjson --metadata -> jq metadata timestamp selection -> rclone copy --files-from -> local prune
```

This gives the required VPS state while keeping Google Drive as the complete backup archive.

## Local Pruning Behavior

After selected files are copied, the script scans `/dailybackups`.

If a local file is not in the selected remote file list:

- With `DRY_RUN="true"`, it prints what would be pruned.
- With `ARCHIVE_DELETED_FILES="true"`, it moves the file to the archive folder.
- With `ARCHIVE_DELETED_FILES="false"`, it deletes the file.

Archive example:

```text
/var/backups/rclone-gdrive-sql-backup-sync/archive/20260506T023000Z/FY2024-25/prod-2025-03-01.sql.gz.20260506T023000Z
```

## Configuration

Recommended:

```bash
RETENTION_POLICY="latest_per_financial_year"
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="7"
RETENTION_TIMESTAMP_MODE="latest_metadata_time"
ALLOW_ROOT_LEVEL_BACKUP_FILES="false"
ARCHIVE_DELETED_FILES="true"
```

Use 5 only if VPS storage is tight:

```bash
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="5"
```

Use 6 for a middle position:

```bash
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR="6"
```

## Operational Checks

View the last run:

```bash
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/last-run.env
```

Important fields:

```text
RETENTION_POLICY=latest_per_financial_year
BACKUPS_TO_KEEP_PER_FINANCIAL_YEAR=7
RETENTION_TIMESTAMP_MODE=latest_metadata_time
REMOTE_FILE_COUNT=<all remote files after filters>
SELECTED_REMOTE_FILES=<files selected for VPS>
FILES_WITHOUT_RETENTION_TIMESTAMP=0
LOCAL_PRUNE_CANDIDATES=<local files not in selected set>
LOCAL_PRUNED_FILES=<files actually archived or deleted>
```

Count files per financial year:

```bash
for fy in /dailybackups/*; do
  [ -d "$fy" ] && printf '%s %s\n' "$(basename "$fy")" "$(find "$fy" -type f | wc -l)"
done
```

Review selection report for a run:

```bash
sudo ls -lh /var/lib/rclone-gdrive-sql-backup-sync/financial-year-selection-*.txt
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/financial-year-selection-<run-id>.txt
```

## Failure Cases

| Failure | Reason | Fix |
| --- | --- | --- |
| Root-level files are rejected | File is not inside a financial-year folder. | Move it into the correct Google Drive financial-year folder. |
| Zero selected files | Wrong Drive path or filter excluded everything. | Check `GDRIVE_SOURCE_PATH` and `RCLONE_FILTER_FILE`. |
| `jq` missing | Retention selection needs JSON parsing. | Install `jq` or rerun the install script. |
| `lsjson --metadata` unsupported | rclone is too old. | Install a current rclone release. |
| Files lack retention timestamp | Metadata was unavailable for the configured timestamp mode. | Use `latest_metadata_time`, upgrade rclone, or inspect `rclone lsjson --metadata`. |
| Too many local files remain | Dry run is enabled or files are in archive, not destination. | Set `DRY_RUN="false"` after validation and check `/dailybackups`. |
