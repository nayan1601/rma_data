# Ubuntu 24.04 Bare-Metal Deployment

## Target

This project is intended to run on:

```text
Ubuntu 24.04 Server
Bare-metal VPS/server
systemd
```

The sync job should run as root through systemd unless the server has a deliberate backup service user design.

## Why Bare Metal Matters

On bare metal, storage layout is operationally important. If `/dailybackups` is on the root filesystem and backups grow unexpectedly, the server can run out of root disk space. That can affect logging, package operations, database processes, and SSH access.

Retention already limits local files to the latest 5-7 backups per financial-year folder. The additional storage control is to decide whether `/dailybackups` should be on:

- root filesystem, acceptable only for small backup volumes and sufficient free space
- a separate mounted disk or partition
- an LVM volume
- a mounted storage path such as `/mnt/backups/dailybackups`

## Preflight Commands

Run:

```bash
cat /etc/os-release
uname -a
systemctl --version
df -h
lsblk -f
findmnt
```

Confirm:

- OS is Ubuntu 24.04.
- systemd is available.
- destination storage has enough capacity for the selected retention set.
- the server can reach Google Drive APIs.

## Recommended Ubuntu Package Baseline

The installer uses apt on Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y rclone util-linux coreutils findutils gawk grep jq
```

The project installer also installs `ca-certificates`, `curl`, and `unzip` because they are needed for robust bootstrapping and official rclone installation.

The installer then validates:

```bash
rclone lsjson --help | grep -- --metadata
```

If the Ubuntu package does not support `lsjson --metadata`, the installer downloads and runs the official rclone install script automatically:

```bash
curl -fsSL https://rclone.org/install.sh -o /tmp/install-rclone.sh
bash /tmp/install-rclone.sh
```

The command above is shown for clarity; the project installer handles it. Re-run:

```bash
sudo bash scripts/install-rclone-google-drive-sync.sh
```

The sync script refuses financial-year metadata retention without `lsjson --metadata`.

## Destination Storage Options

Default simple path:

```text
/dailybackups
```

Mounted storage path example:

```text
/mnt/backups/dailybackups
```

If the destination must not be on `/`, configure:

```bash
REQUIRE_DESTINATION_NOT_ON_ROOT_FILESYSTEM="true"
```

in:

```text
/etc/rclone-gdrive-sql-backup-sync.env
```

The script checks:

```bash
findmnt -n -T "$VPS_DESTINATION_DIR" -o TARGET
```

and fails if the destination is backed by `/`.

## systemd Expectations

Installed units:

```text
/etc/systemd/system/rclone-gdrive-sql-backup-sync.service
/etc/systemd/system/rclone-gdrive-sql-backup-sync.timer
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rclone-gdrive-sql-backup-sync.timer
```

Inspect:

```bash
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer
sudo systemctl status rclone-gdrive-sql-backup-sync.service
sudo journalctl -u rclone-gdrive-sql-backup-sync.service -n 100 --no-pager
```

## Bare-Metal Health Checks

Daily or after first production deployment:

```bash
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/last-run.env
df -h
findmnt -T /dailybackups
sudo du -sh /dailybackups
sudo du -sh /var/backups/rclone-gdrive-sql-backup-sync/archive
```

Expected:

- `STATUS=success`
- `EXIT_CODE=0`
- `FILES_WITHOUT_RETENTION_TIMESTAMP=0`
- `/dailybackups` file count per financial year is within configured retention
- root filesystem has healthy free space
