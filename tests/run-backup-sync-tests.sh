#!/usr/bin/env bash
# Compatibility wrapper for older docs/PRs. Keep the real coverage in one file.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/test-sync-google-drive-sql-backups.sh" "$@"
