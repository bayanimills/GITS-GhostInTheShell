#!/usr/bin/env bash
set -euo pipefail

# GITS Backup Script
# Snapshots the entire ~/.openclaw directory into a single dated tarball
# and pushes to git. Run every 3 hours via cron.

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/agentbox-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
DATE_TAG=$(date '+%Y-%m-%d_%H%M')
RETENTION_DAYS=7

log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

check_prerequisites() {
    if [ ! -d "$OPENCLAW_ROOT" ]; then
        log_message "ERROR: OpenClaw directory not found at $OPENCLAW_ROOT"
        exit 1
    fi

    for cmd in tar git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done
}

check_git_config() {
    cd "$BACKUP_ROOT"

    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null) || {
        log_message "ERROR: Git remote 'origin' not configured"
        return 1
    }

    # Verify the remote URL contains a PAT for non-interactive auth
    if [[ "$remote_url" != *"@github.com"* ]]; then
        log_message "ERROR: Remote URL missing PAT. Update with: git remote set-url origin https://<PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git"
        return 1
    fi

    if ! git ls-remote origin >/dev/null 2>&1; then
        log_message "ERROR: Cannot authenticate with GitHub. PAT may be expired or revoked"
        return 1
    fi

    return 0
}

create_snapshot() {
    mkdir -p "$SNAPSHOTS_DIR"

    local tarball_name="openclaw-${DATE_TAG}.tar.gz"
    local tarball_path="$SNAPSHOTS_DIR/$tarball_name"

    log_message "Creating snapshot of $OPENCLAW_ROOT..."

    tar -czf "$tarball_path" \
        --exclude="backups" \
        --exclude="venv" \
        --exclude="node_modules" \
        --exclude=".git" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        -C "$(dirname "$OPENCLAW_ROOT")" "$(basename "$OPENCLAW_ROOT")" 2>/dev/null || {
            log_message "ERROR: Failed to create snapshot"
            rm -f "$tarball_path"
            exit 1
        }

    local size=$(stat -c%s "$tarball_path" 2>/dev/null || echo "0")
    log_message "Created $tarball_name ($((size/1024/1024)) MB)"
}

prune_old_snapshots() {
    find "$SNAPSHOTS_DIR" -name "openclaw-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    log_message "Pruned snapshots older than $RETENTION_DAYS days"
}

commit_and_push() {
    cd "$BACKUP_ROOT"

    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT_BRANCH" != "main" ]; then
        log_message "Switching from branch '$CURRENT_BRANCH' to 'main'"
        git checkout main 2>/dev/null || git checkout -b main
    fi

    git add --force .

    if git status --porcelain | grep -q '.'; then
        COMMIT_MSG="GITS snapshot: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        git commit -m "$COMMIT_MSG"
        log_message "Committed: $COMMIT_MSG"

        local max_retries=3
        local retry_count=0

        while [ $retry_count -lt $max_retries ]; do
            if git push origin main; then
                log_message "Successfully pushed to remote"
                return 0
            else
                retry_count=$((retry_count + 1))
                log_message "Push failed (attempt $retry_count/$max_retries)"

                if [ $retry_count -lt $max_retries ]; then
                    sleep 10
                    git pull --rebase origin main 2>/dev/null || true
                fi
            fi
        done

        log_message "ERROR: Failed to push after $max_retries attempts"
        return 1
    else
        log_message "No changes to commit"
        return 0
    fi
}

main() {
    log_message "=== Starting GITS backup ==="

    check_prerequisites
    check_git_config || exit 1

    create_snapshot
    prune_old_snapshots

    if commit_and_push; then
        log_message "Backup completed successfully"
    else
        log_message "ERROR: Backup failed"
        exit 1
    fi

    log_message "=== Backup completed ==="
}

trap 'log_message "ERROR: Script failed at line $LINENO"; exit 1' ERR

main
