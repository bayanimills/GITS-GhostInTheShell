#!/usr/bin/env bash
set -euo pipefail

# GITS Restore Script
# Restores an OpenClaw system from a snapshot tarball

OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/agentbox-restore.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

check_prerequisites() {
    for cmd in tar git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done

    if [ "$(id -u)" -eq 0 ]; then
        log_message "WARNING: Running as root is not recommended"
    fi

    log_message "Prerequisites check passed"
}

find_latest_snapshot() {
    if [ ! -d "$SNAPSHOTS_DIR" ]; then
        log_message "ERROR: Snapshots directory not found at $SNAPSHOTS_DIR"
        exit 1
    fi

    local latest=$(ls -1t "$SNAPSHOTS_DIR"/openclaw-*.tar.gz 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        log_message "ERROR: No snapshot tarballs found"
        exit 1
    fi

    echo "$latest"
}

restore_snapshot() {
    local tarball="$1"
    local tarball_name=$(basename "$tarball")

    log_message "Restoring from $tarball_name..."

    # Back up existing installation if present
    if [ -d "$OPENCLAW_ROOT" ]; then
        local backup_name="${OPENCLAW_ROOT}.backup-$(date +%Y%m%d-%H%M%S)"
        log_message "Backing up existing installation to $backup_name"
        mv "$OPENCLAW_ROOT" "$backup_name"
    fi

    # Create parent directory and extract
    mkdir -p "$(dirname "$OPENCLAW_ROOT")"

    if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
        log_message "Snapshot extracted successfully"
    else
        log_message "ERROR: Failed to extract snapshot"
        # Attempt to restore backup if extraction failed
        if [ -d "$backup_name" ]; then
            log_message "Restoring previous installation from backup"
            mv "$backup_name" "$OPENCLAW_ROOT"
        fi
        exit 1
    fi
}

validate_restoration() {
    log_message "Validating restoration..."

    local issues=0

    if [ ! -f "$OPENCLAW_ROOT/openclaw.json" ]; then
        log_message "WARNING: openclaw.json not found"
        issues=$((issues + 1))
    fi

    local workspace_count=$(find "$OPENCLAW_ROOT" -maxdepth 1 -type d -name 'workspace*' | wc -l)
    if [ "$workspace_count" -eq 0 ]; then
        log_message "WARNING: No workspace directories found"
        issues=$((issues + 1))
    else
        log_message "Found $workspace_count workspace(s)"
    fi

    if [ -d "$OPENCLAW_ROOT/agents" ]; then
        local agent_count=$(find "$OPENCLAW_ROOT/agents" -maxdepth 1 -mindepth 1 -type d | wc -l)
        log_message "Found $agent_count agent definition(s)"
    fi

    if [ "$issues" -eq 0 ]; then
        log_message "Validation passed"
        return 0
    else
        log_message "Validation completed with $issues warning(s)"
        return 1
    fi
}

display_next_steps() {
    cat << EOF

=== RESTORATION COMPLETE ===

Next steps:
1. Restart the OpenClaw gateway:
   sudo systemctl restart openclaw-gateway

2. Verify gateway status:
   openclaw gateway status

3. Check agent sessions:
   openclaw sessions list

4. Restored files are in:
   $OPENCLAW_ROOT

Note: If a previous installation was found, it was backed up
with a .backup-TIMESTAMP suffix in the parent directory.

EOF
}

main() {
    log_message "=== Starting GITS restoration ==="

    check_prerequisites

    local snapshot=$(find_latest_snapshot)
    log_message "Using snapshot: $(basename "$snapshot")"

    restore_snapshot "$snapshot"

    if validate_restoration; then
        log_message "Restoration completed successfully"
    else
        log_message "Restoration completed with warnings"
    fi

    display_next_steps
    log_message "=== Restoration completed ==="
}

trap 'log_message "ERROR: Script failed at line $LINENO"; exit 1' ERR

main
