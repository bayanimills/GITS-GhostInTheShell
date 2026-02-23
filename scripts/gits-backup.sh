#!/usr/bin/env bash
set -euo pipefail

# GITS Backup Script
# Dynamically discovers everything inside ~/.openclaw and creates one
# tarball per top-level directory, plus one for loose root files.
# Writes a manifest.json describing what was captured.
# Run on a schedule via cron (frequency set by gits-setup.sh).

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/gits-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
DATE_TAG=$(date '+%Y-%m-%d_%H%M')

# Load retention setting from config (written by gits-setup.sh), default 7 days
RETENTION_DAYS=7
CONFIG_FILE="$BACKUP_ROOT/gits.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Standard exclusions — skip things that are regenerated or are the backup itself
TAR_EXCLUDES=(
    --exclude="backups"
    --exclude="venv"
    --exclude="node_modules"
    --exclude=".git"
    --exclude="*.log"
    --exclude="*.tmp"
)

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1" | tee -a "$LOG_FILE"
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

    if [[ "$remote_url" != *"@github.com"* ]]; then
        log_message "ERROR: Remote URL missing PAT. Run: scripts/gits-setup.sh <PAT>"
        return 1
    fi

    if ! git ls-remote origin >/dev/null 2>&1; then
        log_message "ERROR: Cannot authenticate with GitHub. PAT may be expired or revoked"
        return 1
    fi

    return 0
}

create_snapshot() {
    local snapshot_dir="$SNAPSHOTS_DIR/$DATE_TAG"
    mkdir -p "$snapshot_dir"

    log_message "Creating component snapshots of $OPENCLAW_ROOT..."

    local src_parent
    src_parent="$(dirname "$OPENCLAW_ROOT")"
    local src_base
    src_base="$(basename "$OPENCLAW_ROOT")"

    local manifest="$snapshot_dir/manifest.json"
    local total_size=0
    local component_count=0
    local first=true

    # Start manifest
    echo '{' > "$manifest"
    echo "  \"timestamp\": \"$TIMESTAMP\"," >> "$manifest"
    echo "  \"date_tag\": \"$DATE_TAG\"," >> "$manifest"
    echo "  \"source\": \"$OPENCLAW_ROOT\"," >> "$manifest"
    echo '  "components": {' >> "$manifest"

    # --- Snapshot each top-level directory as its own component ---
    for entry in "$OPENCLAW_ROOT"/*/; do
        [ -d "$entry" ] || continue
        local dirname
        dirname="$(basename "$entry")"

        # Skip excluded directories
        case "$dirname" in
            backups|venv|node_modules|.git) continue ;;
        esac

        local tarball_path="$snapshot_dir/${dirname}.tar.gz"

        if tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
            -C "$src_parent" "${src_base}/${dirname}" 2>/dev/null; then

            local size
            size=$(stat -c%s "$tarball_path" 2>/dev/null || echo "0")
            [ "$first" = true ] || echo ',' >> "$manifest"
            first=false
            printf '    "%s": {"file": "%s.tar.gz", "type": "directory", "bytes": %s}' \
                "$dirname" "$dirname" "$size" >> "$manifest"
            total_size=$((total_size + size))
            component_count=$((component_count + 1))
            log_message "  $dirname/: $(( size / 1024 )) KB"
        else
            log_message "  $dirname/: ERROR creating tarball, skipping"
            rm -f "$tarball_path"
        fi
    done

    # --- Snapshot loose root files as a single "root-files" component ---
    local root_files=()
    for f in "$OPENCLAW_ROOT"/*; do
        [ -f "$f" ] || continue
        local fname
        fname="$(basename "$f")"
        # Skip log/tmp by extension
        case "$fname" in
            *.log|*.tmp) continue ;;
        esac
        root_files+=("${src_base}/${fname}")
    done

    if [ ${#root_files[@]} -gt 0 ]; then
        local tarball_path="$snapshot_dir/root-files.tar.gz"

        if tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
            -C "$src_parent" "${root_files[@]}" 2>/dev/null; then

            local size
            size=$(stat -c%s "$tarball_path" 2>/dev/null || echo "0")
            [ "$first" = true ] || echo ',' >> "$manifest"
            first=false
            printf '    "root-files": {"file": "root-files.tar.gz", "type": "files", "bytes": %s}' \
                "$size" >> "$manifest"
            total_size=$((total_size + size))
            component_count=$((component_count + 1))
            log_message "  root-files: $(( size / 1024 )) KB"
        else
            log_message "  root-files: ERROR creating tarball, skipping"
            rm -f "$tarball_path"
        fi
    fi

    # Close manifest
    echo '' >> "$manifest"
    echo '  },' >> "$manifest"
    echo "  \"total_bytes\": $total_size," >> "$manifest"
    echo "  \"component_count\": $component_count" >> "$manifest"
    echo '}' >> "$manifest"

    log_message "Snapshot $DATE_TAG: $component_count components, $((total_size/1024/1024)) MB total"
}

prune_old_snapshots() {
    # Prune local snapshots past the configured retention period
    find "$SNAPSHOTS_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
    find "$SNAPSHOTS_DIR" -maxdepth 1 -name "openclaw-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    log_message "Pruned local snapshots older than $RETENTION_DAYS days"
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
