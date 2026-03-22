#!/usr/bin/env bash
set -euo pipefail

# GITS Backup Script
# Creates per-component snapshots of ~/.openclaw and pushes to git.
# Components: config, agents, workspaces, credentials
# Run every 3 hours via cron.

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/gits-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
DATE_TAG=$(date '+%Y-%m-%d_%H%M')
RETENTION_DAYS=7

COMPONENTS=(config agents workspaces credentials)

# Standard exclusions applied to all component tarballs
TAR_EXCLUDES=(
    --exclude="backups"
    --exclude="venv"
    --exclude="node_modules"
    --exclude=".git"
    --exclude="*.log"
    --exclude="*.tmp"
)

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
        log_message "ERROR: Remote URL missing PAT. Run: scripts/gits-setup.sh <PAT>"
        return 1
    fi

    if ! git ls-remote origin >/dev/null 2>&1; then
        log_message "ERROR: Cannot authenticate with GitHub. PAT may be expired or revoked"
        return 1
    fi

    return 0
}

# Create a tarball for a single component.
# Usage: snapshot_component <component_name> <snapshot_dir>
# Returns the size in bytes via stdout, or 0 if the component was skipped.
snapshot_component() {
    local component="$1"
    local snapshot_dir="$2"
    local tarball_path="$snapshot_dir/${component}.tar.gz"
    local src_parent
    src_parent="$(dirname "$OPENCLAW_ROOT")"
    local src_base
    src_base="$(basename "$OPENCLAW_ROOT")"

    case "$component" in
        config)
            # Top-level config files (openclaw.json, jobs.json, etc.)
            local config_files=()
            for f in "$OPENCLAW_ROOT"/*.json "$OPENCLAW_ROOT"/*.yaml "$OPENCLAW_ROOT"/*.yml "$OPENCLAW_ROOT"/*.conf; do
                [ -e "$f" ] && config_files+=("${src_base}/$(basename "$f")")
            done
            if [ ${#config_files[@]} -eq 0 ]; then
                log_message "  config: no config files found, skipping"
                echo 0
                return 0
            fi
            tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
                -C "$src_parent" "${config_files[@]}" 2>/dev/null || {
                    log_message "  config: ERROR creating tarball"
                    rm -f "$tarball_path"
                    echo 0
                    return 1
                }
            ;;
        agents)
            if [ ! -d "$OPENCLAW_ROOT/agents" ]; then
                log_message "  agents: directory not found, skipping"
                echo 0
                return 0
            fi
            tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
                -C "$src_parent" "${src_base}/agents" 2>/dev/null || {
                    log_message "  agents: ERROR creating tarball"
                    rm -f "$tarball_path"
                    echo 0
                    return 1
                }
            ;;
        workspaces)
            local ws_dirs=()
            for d in "$OPENCLAW_ROOT"/workspace*; do
                [ -d "$d" ] && ws_dirs+=("${src_base}/$(basename "$d")")
            done
            if [ ${#ws_dirs[@]} -eq 0 ]; then
                log_message "  workspaces: no workspace directories found, skipping"
                echo 0
                return 0
            fi
            tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
                -C "$src_parent" "${ws_dirs[@]}" 2>/dev/null || {
                    log_message "  workspaces: ERROR creating tarball"
                    rm -f "$tarball_path"
                    echo 0
                    return 1
                }
            ;;
        credentials)
            if [ ! -d "$OPENCLAW_ROOT/credentials" ]; then
                log_message "  credentials: directory not found, skipping"
                echo 0
                return 0
            fi
            tar -czf "$tarball_path" "${TAR_EXCLUDES[@]}" \
                -C "$src_parent" "${src_base}/credentials" 2>/dev/null || {
                    log_message "  credentials: ERROR creating tarball"
                    rm -f "$tarball_path"
                    echo 0
                    return 1
                }
            ;;
        *)
            log_message "  $component: unknown component, skipping"
            echo 0
            return 0
            ;;
    esac

    local size
    size=$(stat -c%s "$tarball_path" 2>/dev/null || echo "0")
    echo "$size"
}

create_snapshot() {
    local snapshot_dir="$SNAPSHOTS_DIR/$DATE_TAG"
    mkdir -p "$snapshot_dir"

    log_message "Creating component snapshots of $OPENCLAW_ROOT..."

    local manifest="$snapshot_dir/manifest.json"
    local total_size=0
    local component_count=0

    # Start building manifest
    echo '{' > "$manifest"
    echo "  \"timestamp\": \"$TIMESTAMP\"," >> "$manifest"
    echo "  \"date_tag\": \"$DATE_TAG\"," >> "$manifest"
    echo "  \"source\": \"$OPENCLAW_ROOT\"," >> "$manifest"
    echo '  "components": {' >> "$manifest"

    local first=true
    for component in "${COMPONENTS[@]}"; do
        local size
        size=$(snapshot_component "$component" "$snapshot_dir")

        if [ "$size" -gt 0 ]; then
            [ "$first" = true ] || echo ',' >> "$manifest"
            first=false
            printf '    "%s": {"file": "%s.tar.gz", "bytes": %s}' \
                "$component" "$component" "$size" >> "$manifest"
            total_size=$((total_size + size))
            component_count=$((component_count + 1))
            log_message "  $component: $(( size / 1024 )) KB"
        fi
    done

    echo '' >> "$manifest"
    echo '  },' >> "$manifest"
    echo "  \"total_bytes\": $total_size," >> "$manifest"
    echo "  \"component_count\": $component_count" >> "$manifest"
    echo '}' >> "$manifest"

    log_message "Snapshot $DATE_TAG: $component_count components, $((total_size/1024/1024)) MB total"
}

prune_old_snapshots() {
    # Remove snapshot directories older than retention period
    find "$SNAPSHOTS_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
    # Also clean up any legacy monolithic tarballs
    find "$SNAPSHOTS_DIR" -maxdepth 1 -name "openclaw-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
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
