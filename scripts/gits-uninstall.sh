#!/usr/bin/env bash
set -euo pipefail

# GITS Uninstall Script
# Completely removes GITS from this machine.
# The GitHub backup repo is NOT deleted — your history is preserved.
#
# Usage:
#   ./scripts/gits-uninstall.sh          interactive (prompts for confirmation)
#   ./scripts/gits-uninstall.sh --yes    skip confirmation prompt

BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat << 'EOF'
Usage: gits-uninstall.sh [OPTIONS]

Completely removes GITS from this machine.

Options:
  -y, --yes    Skip confirmation prompt
  -h, --help   Show this help message

What gets removed:
  - Cron job (the scheduled backup entry)
  - Log files (/tmp/gits-setup.log, /tmp/gits-backup.log, /tmp/gits-restore.log)
  - Installation directory (~/.openclaw/backups/GITS)

What is NOT removed:
  - Your GitHub backup repo (all history is preserved)
  - Your ~/.openclaw directory (your OpenClaw installation)
EOF
    exit 0
}

# Parse args
AUTO_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) AUTO_YES=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Show what will be removed
echo "=== GITS Uninstall ==="
echo ""
echo "This will remove:"
echo ""

# Check for cron entry
CRON_ENTRY=$(crontab -l 2>/dev/null | grep 'gits-backup\.sh' || true)
if [ -n "$CRON_ENTRY" ]; then
    echo "  [cron]  $CRON_ENTRY"
else
    echo "  [cron]  (no GITS cron entry found)"
fi

# Check for log files
for logfile in /tmp/gits-setup.log /tmp/gits-backup.log /tmp/gits-restore.log; do
    if [ -f "$logfile" ]; then
        echo "  [log]   $logfile"
    fi
done

echo "  [dir]   $BACKUP_ROOT"
echo ""
echo "Your GitHub backup repo is NOT affected — all history is preserved."
echo ""

# Confirm
if [ "$AUTO_YES" = false ]; then
    printf "Proceed? [y/N] "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

# 1. Remove cron entry
if [ -n "$CRON_ENTRY" ]; then
    crontab -l 2>/dev/null | grep -v 'gits-backup\.sh' | crontab - 2>/dev/null || true
    echo "Removed cron job."
else
    echo "No cron job to remove."
fi

# 2. Remove log files
rm -f /tmp/gits-setup.log /tmp/gits-backup.log /tmp/gits-restore.log
echo "Removed log files."

# 3. Remove installation directory (this deletes the script itself — must be last)
rm -rf "$BACKUP_ROOT"
echo "Removed $BACKUP_ROOT"

echo ""
echo "GITS has been uninstalled."
echo "Your backup history on GitHub is still available if you need to restore."
