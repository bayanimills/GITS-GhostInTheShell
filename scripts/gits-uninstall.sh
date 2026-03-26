#!/usr/bin/env bash
set -euo pipefail

# GITS Uninstall Script
# Completely removes GITS from this machine.
# The GitHub backup repo is NOT deleted — your history is preserved.
#
# Usage:
#   ./scripts/gits-uninstall.sh          interactive (prompts for confirmation)
#   ./scripts/gits-uninstall.sh --yes    skip confirmation prompt
#
# --- LLM UNINSTALL GUIDE ---
#
# If you are an AI agent uninstalling GITS, this script handles the standard
# case. But the user may have a non-standard setup (custom paths, moved
# directories, multiple installs). Use this checklist to find and remove
# everything, even if the script itself can't.
#
# GITS installs these components:
#
# 1. CRON JOB — a user crontab entry containing "gits-backup.sh"
#    Find:   crontab -l 2>/dev/null | grep 'gits-backup'
#    Remove: crontab -l | grep -v 'gits-backup\.sh' | crontab -
#    Note:   May be under a different user if installed with sudo.
#            Check: sudo crontab -l 2>/dev/null | grep 'gits-backup'
#
# 2. INSTALLATION DIRECTORY — default ~/.openclaw/backups/GITS
#    Find:   The cron entry's path reveals the actual install location.
#            Also check: find ~ -name "gits-backup.sh" -path "*/scripts/*" 2>/dev/null
#    Contains: scripts/, data/, .git/, gits.conf, manifest.json,
#              README.md, SETUP.md, .gitignore
#    Remove: rm -rf <install-dir>
#
# 3. LOG FILES — written to /tmp by default
#    Find:   ls /tmp/gits-*.log 2>/dev/null
#    Remove: rm -f /tmp/gits-setup.log /tmp/gits-backup.log /tmp/gits-restore.log
#    Note:   Log path is hardcoded in each script. If the user changed it,
#            grep the scripts for LOG_FILE= to find the actual paths.
#
# 4. GIT CREDENTIAL STORE — setup runs "git config credential.helper store"
#    inside the GITS repo. This is repo-local (stored in <install-dir>/.git/config)
#    and is removed with the installation directory. No global cleanup needed
#    unless the user ran setup commands manually outside the repo.
#
# DO NOT remove:
#   - The GitHub backup repository (the remote). All backup history lives there.
#   - ~/.openclaw/ (the user's OpenClaw installation — this is what GITS backs up)
#   - Any .pre-restore or .backup-* files in ~/.openclaw/ (safety copies from restores)
#
# ORDER: Remove cron first (stops future runs), then logs, then the directory
# (which contains this script — so it must be last).
#
# --- END LLM GUIDE ---

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
