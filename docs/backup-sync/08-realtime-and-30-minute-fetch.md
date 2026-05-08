# Realtime And 30-Minute Fetch

## Requirement

Backups uploaded to Google Drive must be fetched to the VPS automatically:

- in realtime if push is practical, or
- within 30 minutes.

## Implemented Production Behavior

The production implementation uses systemd polling every 30 minutes:

```ini
OnCalendar=*:0/30
OnBootSec=5m
AccuracySec=1s
RandomizedDelaySec=0
```

This means the VPS checks Google Drive at minute `00` and `30` of every hour. If a backup is uploaded just after a check finishes, the next scheduled check is within 30 minutes in normal operation.

## Why Polling Is The Default

This project uses rclone for transfer and metadata listing. rclone can check Google Drive reliably from the VPS, but rclone alone does not create a Google Drive push webhook receiver.

The 30-minute systemd timer has these operational advantages:

- no inbound public HTTPS endpoint required
- no public DNS or TLS certificate required
- no webhook authentication layer required
- no Google Drive notification channel renewal process required
- simple failure model using systemd, logs, and `last-run.env`
- works on a locked-down Ubuntu 24.04 bare-metal server

## Push Feasibility

Google Drive push notifications are possible through the Google Drive API, but they require a separate webhook service.

Requirements for true push:

- a public HTTPS callback URL with a valid TLS certificate
- a service that receives Google Drive notification `POST` requests
- Google Drive API `watch` channel setup for `files` or `changes`
- channel token validation
- renewal logic because notification channels expire
- code that triggers the same sync script after receiving a valid change notification
- monitoring for missed notifications and periodic reconciliation

Google Drive notification payloads do not contain full file details. The webhook should trigger the sync job, and the sync job should still run the metadata selection logic already implemented in this project.

## Recommended Architecture

Use this now:

```text
systemd timer every 30 minutes -> sync script -> rclone metadata selection -> /dailybackups
```

Use this only if leadership requires sub-minute behavior and the VPS can safely expose HTTPS:

```text
Google Drive changes.watch
  -> HTTPS webhook receiver
  -> validate Google headers/token
  -> systemctl start rclone-gdrive-sql-backup-sync.service
  -> periodic 30-minute timer remains as reconciliation fallback
```

Even with push, keep the 30-minute timer. Push systems can miss events due to expired channels, network issues, certificate issues, or webhook downtime. The timer is the safety net.

## Operational Checks

Check timer schedule:

```bash
systemctl list-timers --all rclone-gdrive-sql-backup-sync.timer
```

Check recent runs:

```bash
sudo journalctl -u rclone-gdrive-sql-backup-sync.service --since "2 hours ago" --no-pager
sudo ls -lh /var/log/rclone-gdrive-sql-backup-sync
sudo cat /var/lib/rclone-gdrive-sql-backup-sync/last-run.env
```

Expected:

- timer shows the next run within 30 minutes
- service exits successfully
- `STATUS=success`
- `EXIT_CODE=0`
- latest backup file exists under `/dailybackups/<financial-year>/`

## References

- Google Drive API push notifications: `https://developers.google.com/workspace/drive/api/guides/push`
- Ubuntu/systemd timer syntax should be verified on the VPS with `systemd-analyze verify`.
