#!/usr/bin/env bash
set -euo pipefail

# GITS Backup Script
# Syncs ~/.openclaw directly into data/ and lets git handle compression,
# deduplication, and history.  No tarballs — every file is a first-class
# git object, so unchanged files cost zero across commits.
#
# Run on a schedule via cron (frequency set by gits-setup.sh).

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$BACKUP_ROOT/data"
LOG_FILE="/tmp/gits-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Standard exclusions — skip things that are regenerated or bulky ephemeral data
RSYNC_EXCLUDES=(
    --exclude="backups"
    --exclude="venv/"
    --exclude="node_modules/"
    --exclude=".git/"
    --exclude="*.log"
    --exclude="*.tmp"
    --exclude="__pycache__/"
    --exclude="*.pyc"
    --exclude="Cache/"
    --exclude="CacheStorage/"
    --exclude="GPUCache/"
    --exclude="Service Worker/"
    --exclude="*.sqlite-wal"
    --exclude="*.sqlite-shm"
    --exclude="*.pack"
    --exclude="*.wasm"
)

# Top-level directories to skip entirely — these are regenerable or too large
# for a GitHub-based backup. Override in gits.conf with GITS_SKIP_COMPONENTS.
DEFAULT_SKIP_COMPONENTS="browser"

# Maximum individual file size in MB. Files exceeding this are excluded from
# the sync (GitHub rejects files > 100 MB). Override in gits.conf with MAX_FILE_MB=0 to disable.
MAX_FILE_MB=90

# Load config (written by gits-setup.sh)
RETENTION_DAYS=7  # legacy — kept for backward compat, not used by backup
CONFIG_FILE="$BACKUP_ROOT/gits.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Merge default and user-configured skip lists
SKIP_COMPONENTS="${GITS_SKIP_COMPONENTS:-$DEFAULT_SKIP_COMPONENTS}"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1" | tee -a "$LOG_FILE"
}

check_prerequisites() {
    if [ ! -d "$OPENCLAW_ROOT" ]; then
        log_message "ERROR: OpenClaw directory not found at $OPENCLAW_ROOT"
        exit 1
    fi

    for cmd in rsync git; do
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

# One-time migration from tar-based snapshots to direct-file backup.
migrate_from_tar() {
    if [ -d "$BACKUP_ROOT/snapshots" ]; then
        log_message "Migrating from tar-based snapshots to direct-file backup..."
        cd "$BACKUP_ROOT"
        git rm -r --cached snapshots/ 2>/dev/null || true
        rm -rf "$BACKUP_ROOT/snapshots"
        log_message "Migration complete. Old snapshots removed from working tree."
        log_message "They remain accessible in git history if needed."
    fi
}

# Build a list of oversized files to exclude from the sync.
find_oversized_files() {
    local source_dir="$1"
    local max_bytes=$(( MAX_FILE_MB * 1024 * 1024 ))

    if [ "$MAX_FILE_MB" -le 0 ] 2>/dev/null; then
        return
    fi

    find "$source_dir" -type f -size +"${max_bytes}c" 2>/dev/null | while IFS= read -r filepath; do
        # Make path relative to source_dir's parent for rsync exclude
        local relpath="${filepath#"$source_dir"/}"
        echo "$relpath"
    done
}

sync_data() {
    mkdir -p "$DATA_DIR"

    log_message "Syncing $OPENCLAW_ROOT to $DATA_DIR..."

    local total_size=0
    local component_count=0
    local skipped_components=""
    local skipped_large_files=()

    # Build per-component skip excludes for rsync
    local skip_excludes=()
    for skip in $SKIP_COMPONENTS; do
        skip_excludes+=(--exclude="$skip/")
        if [ -z "$skipped_components" ]; then
            skipped_components="$skip"
        else
            skipped_components="$skipped_components $skip"
        fi
    done

    # Find oversized files to exclude
    local oversize_excludes=()
    if [ "$MAX_FILE_MB" -gt 0 ] 2>/dev/null; then
        while IFS= read -r bigfile; do
            [ -z "$bigfile" ] && continue
            oversize_excludes+=(--exclude="$bigfile")
            skipped_large_files+=("$bigfile")
            local fsize
            fsize=$(stat -c%s "$OPENCLAW_ROOT/$bigfile" 2>/dev/null || echo "0")
            log_message "  SKIPPED (>${MAX_FILE_MB} MB): $bigfile ($(( fsize / 1024 / 1024 )) MB)"
        done < <(find_oversized_files "$OPENCLAW_ROOT")
    fi

    # --- Sync each top-level directory as its own component ---
    for entry in "$OPENCLAW_ROOT"/*/; do
        [ -d "$entry" ] || continue
        local dirname
        dirname="$(basename "$entry")"

        # Skip standard exclusions
        case "$dirname" in
            backups|venv|node_modules|.git) continue ;;
        esac

        # Skip components in the skip list
        if echo " $SKIP_COMPONENTS " | grep -q " $dirname "; then
            log_message "  $dirname/: skipped (in GITS_SKIP_COMPONENTS)"
            continue
        fi

        mkdir -p "$DATA_DIR/$dirname"
        rsync -a --delete \
            "${RSYNC_EXCLUDES[@]}" \
            "${oversize_excludes[@]}" \
            "$entry" "$DATA_DIR/$dirname/" 2>/dev/null || {
            log_message "  $dirname/: ERROR during sync, skipping"
            continue
        }

        local size
        size=$(du -sb "$DATA_DIR/$dirname" 2>/dev/null | cut -f1)
        local file_count
        file_count=$(find "$DATA_DIR/$dirname" -type f 2>/dev/null | wc -l)
        component_count=$((component_count + 1))
        total_size=$((total_size + size))
        log_message "  $dirname/: $file_count files, $(( size / 1024 )) KB"
    done

    # --- Sync loose root files ---
    mkdir -p "$DATA_DIR/root-files"
    # Clear old root-files first, then copy current ones
    rm -rf "$DATA_DIR/root-files/"*

    local root_file_count=0
    for f in "$OPENCLAW_ROOT"/*; do
        [ -f "$f" ] || continue
        local fname
        fname="$(basename "$f")"
        case "$fname" in
            *.log|*.tmp) continue ;;
        esac

        # Check file size
        if [ "$MAX_FILE_MB" -gt 0 ] 2>/dev/null; then
            local fsize
            fsize=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local max_bytes=$(( MAX_FILE_MB * 1024 * 1024 ))
            if [ "$fsize" -gt "$max_bytes" ]; then
                skipped_large_files+=("$fname")
                log_message "  SKIPPED (>${MAX_FILE_MB} MB): $fname ($(( fsize / 1024 / 1024 )) MB)"
                continue
            fi
        fi

        cp -a "$f" "$DATA_DIR/root-files/"
        root_file_count=$((root_file_count + 1))
    done

    if [ "$root_file_count" -gt 0 ]; then
        local size
        size=$(du -sb "$DATA_DIR/root-files" 2>/dev/null | cut -f1)
        component_count=$((component_count + 1))
        total_size=$((total_size + size))
        log_message "  root-files/: $root_file_count files, $(( size / 1024 )) KB"
    fi

    # --- Remove data/ directories for components that no longer exist in source ---
    for data_entry in "$DATA_DIR"/*/; do
        [ -d "$data_entry" ] || continue
        local dname
        dname="$(basename "$data_entry")"
        [ "$dname" = "root-files" ] && continue

        if [ ! -d "$OPENCLAW_ROOT/$dname" ]; then
            log_message "  $dname/: removed (no longer in source)"
            rm -rf "$data_entry"
        fi
    done

    # --- Write manifest.json ---
    local manifest="$BACKUP_ROOT/manifest.json"
    {
        echo '{'
        echo "  \"timestamp\": \"$TIMESTAMP\","
        echo "  \"source\": \"$OPENCLAW_ROOT\","
        echo "  \"components\": {"

        local first=true
        for data_entry in "$DATA_DIR"/*/; do
            [ -d "$data_entry" ] || continue
            local dname
            dname="$(basename "$data_entry")"
            local dsize
            dsize=$(du -sb "$data_entry" 2>/dev/null | cut -f1)
            local dfiles
            dfiles=$(find "$data_entry" -type f 2>/dev/null | wc -l)
            local dtype="directory"
            [ "$dname" = "root-files" ] && dtype="files"

            [ "$first" = true ] || echo ','
            first=false
            printf '    "%s": {"type": "%s", "files": %s, "bytes": %s}' \
                "$dname" "$dtype" "$dfiles" "$dsize"
        done

        echo ''
        echo '  },'
        echo "  \"total_bytes\": $total_size,"
        echo "  \"component_count\": $component_count,"

        # Skipped large files
        printf '  "skipped_large_files": ['
        local sfirst=true
        for sf in "${skipped_large_files[@]+"${skipped_large_files[@]}"}"; do
            [ "$sfirst" = true ] || printf ', '
            sfirst=false
            printf '"%s"' "$sf"
        done
        echo ']'
        echo '}'
    } > "$manifest"

    log_message "Sync complete: $component_count components, $((total_size/1024/1024)) MB total"
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

    migrate_from_tar
    sync_data

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
