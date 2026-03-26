#!/usr/bin/env bash
set -euo pipefail

# GITS Restore Script
# Restores OpenClaw from the data/ directory (a direct mirror of ~/.openclaw).
# Point-in-time restores use git history — each backup commit is a snapshot.
#
# Usage:
#   gits-restore.sh                                    restore all from latest
#   gits-restore.sh --component agents                 restore one component
#   gits-restore.sh --component agents --item agentname    restore one item within a component
#   gits-restore.sh --from <commit|date>               pick a specific snapshot
#   gits-restore.sh --list                             list available snapshots (git history)
#   gits-restore.sh --show <commit>                    show manifest from a commit
#   gits-restore.sh --contents agents                  list items inside a component

OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$BACKUP_ROOT/data"
LOG_FILE="/tmp/gits-restore.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $1" | tee -a "$LOG_FILE"
}

usage() {
    cat << 'EOF'
Usage: gits-restore.sh [OPTIONS]

Options:
  --component NAME   Restore a single component by name (directory in data/)
  --item NAME        Restore a specific item within a component (e.g. an agent name)
  --from REF         Restore from a specific point in time.
                     Accepts: git commit hash, short hash, or date (YYYY-MM-DD)
  --list             List available snapshots from git history
  --show REF         Show the manifest from a specific commit
  --contents NAME    List the items inside a component
  -h, --help         Show this help message

Components are discovered from the data/ directory, not hardcoded.
Run --list to see available snapshots, --contents to see what's inside.

Examples:
  gits-restore.sh                                    Restore everything from latest
  gits-restore.sh --component agents                 Restore the entire agents directory
  gits-restore.sh --contents agents                  See which agents are in the backup
  gits-restore.sh --component agents --item agentname    Restore only the agentname agent
  gits-restore.sh --from 2026-03-22                  Restore from a specific date
  gits-restore.sh --from abc1234                     Restore from a specific commit
  gits-restore.sh --list                             See available snapshots
EOF
    exit 0
}

check_prerequisites() {
    for cmd in rsync git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done

    if [ "$(id -u)" -eq 0 ]; then
        log_message "WARNING: Running as root is not recommended"
    fi
}

# List component names from the data/ directory (or from a git ref).
list_components() {
    local ref="${1:-}"

    if [ -n "$ref" ]; then
        # List from git history
        git -C "$BACKUP_ROOT" ls-tree --name-only "$ref" -- data/ 2>/dev/null \
            | sed 's|^data/||' | grep -v '^$'
    else
        # List from current working tree
        for entry in "$DATA_DIR"/*/; do
            [ -d "$entry" ] || continue
            basename "$entry"
        done
    fi
}

# Check if a component exists.
has_component() {
    local name="$1"
    local ref="${2:-}"

    list_components "$ref" | grep -qx "$name"
}

# Resolve a --from argument to a git commit hash.
# Accepts: commit hash, short hash, or date string.
resolve_ref() {
    local input="$1"
    cd "$BACKUP_ROOT"

    # Try as a direct git ref first
    if git rev-parse --verify "$input^{commit}" >/dev/null 2>&1; then
        git rev-parse --verify "$input^{commit}"
        return 0
    fi

    # Try as a date — find the latest commit on or before that date
    local commit
    commit=$(git log --before="${input}T23:59:59" -1 --format='%H' 2>/dev/null || true)
    if [ -n "$commit" ]; then
        echo "$commit"
        return 0
    fi

    log_message "ERROR: Cannot resolve '$input' to a commit. Use a commit hash or date (YYYY-MM-DD)."
    exit 1
}

# Checkout data/ from a historical commit into a temporary location.
# Returns the path to the temporary directory.
checkout_historical_data() {
    local ref="$1"
    local tmpdir
    tmpdir=$(mktemp -d "/tmp/gits-restore-XXXXXX")

    cd "$BACKUP_ROOT"

    # Use git archive to extract data/ from the given ref
    if git archive "$ref" -- data/ 2>/dev/null | tar -x -C "$tmpdir"; then
        echo "$tmpdir/data"
        return 0
    else
        rm -rf "$tmpdir"
        log_message "ERROR: Failed to extract data/ from commit $ref"
        exit 1
    fi
}

# List available snapshots from git history.
list_snapshots() {
    echo "Available snapshots (recent git history):"
    echo ""

    cd "$BACKUP_ROOT"
    local count=0

    while IFS= read -r line; do
        echo "  $line"
        count=$((count + 1))
    done < <(git log --format='%h  %ai  %s' -20 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        echo "  (no snapshots found)"
    fi

    echo ""
    echo "Use --from <hash> to restore from a specific snapshot."
    echo "Use --show <hash> to see the manifest for a snapshot."
}

# Show the manifest for a specific commit.
show_manifest() {
    local ref="$1"
    cd "$BACKUP_ROOT"

    local commit
    commit=$(resolve_ref "$ref")

    git show "${commit}:manifest.json" 2>/dev/null || {
        log_message "ERROR: No manifest.json found in commit $commit"
        exit 1
    }
}

# List items inside a component.
list_component_contents() {
    local component="$1"
    local source_dir="$2"

    if [ ! -d "$source_dir/$component" ]; then
        log_message "ERROR: Component '$component' not found"
        log_message "Available components: $(ls "$source_dir" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    echo "Contents of '$component':"
    echo ""

    if [ "$component" = "root-files" ]; then
        # Show each file
        ls -1 "$source_dir/$component/" 2>/dev/null
    else
        # Show immediate children (subdirectories or files)
        for item in "$source_dir/$component"/*; do
            [ -e "$item" ] || continue
            local name
            name=$(basename "$item")
            if [ -d "$item" ]; then
                echo "  $name/"
            else
                echo "  $name"
            fi
        done
    fi
}

# Restore a specific item from within a component.
restore_item() {
    local component="$1"
    local item="$2"
    local source_dir="$3"

    if ! has_component "$component"; then
        log_message "ERROR: Component '$component' not found"
        log_message "Available components: $(list_components | tr '\n' ' ')"
        return 1
    fi

    local src_path="$source_dir/$component/$item"
    if [ ! -e "$src_path" ]; then
        log_message "ERROR: Item '$item' not found in component '$component'"
        echo ""
        echo "Available items in '$component':"
        list_component_contents "$component" "$source_dir" 2>/dev/null | tail -n +3
        return 1
    fi

    log_message "Restoring item '$item' from component '$component'"

    # Determine target path
    local target_path
    if [ "$component" = "root-files" ]; then
        target_path="$OPENCLAW_ROOT/$item"
    else
        target_path="$OPENCLAW_ROOT/$component/$item"
    fi

    # Back up existing before overwriting
    if [ -e "$target_path" ]; then
        local backup_path="${target_path}.pre-restore"
        if [ -d "$target_path" ]; then
            mv "$target_path" "$backup_path" 2>/dev/null || true
        else
            cp "$target_path" "$backup_path" 2>/dev/null || true
        fi
        log_message "  Backed up existing $target_path"
    fi

    # Copy the item
    mkdir -p "$(dirname "$target_path")"
    if [ -d "$src_path" ]; then
        if rsync -a "$src_path/" "$target_path/"; then
            log_message "  '$item' restored successfully from '$component'"
        else
            log_message "  ERROR copying '$item' from '$component'"
            # Rollback
            local backup_path="${target_path}.pre-restore"
            [ -e "$backup_path" ] && mv "$backup_path" "$target_path"
            return 1
        fi
    else
        if cp -a "$src_path" "$target_path"; then
            log_message "  '$item' restored successfully from '$component'"
        else
            log_message "  ERROR copying '$item' from '$component'"
            local backup_path="${target_path}.pre-restore"
            [ -e "$backup_path" ] && mv "$backup_path" "$target_path"
            return 1
        fi
    fi
}

# Restore a single component.
restore_component() {
    local component="$1"
    local source_dir="$2"

    if [ ! -d "$source_dir/$component" ]; then
        log_message "ERROR: Component '$component' not found"
        log_message "Available components: $(ls "$source_dir" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    log_message "Restoring component: $component"

    if [ "$component" = "root-files" ]; then
        # Back up existing root files
        for f in "$OPENCLAW_ROOT"/*; do
            [ -f "$f" ] && cp "$f" "${f}.pre-restore" 2>/dev/null || true
        done
        # Copy each root file
        for f in "$source_dir/root-files"/*; do
            [ -f "$f" ] || continue
            cp -a "$f" "$OPENCLAW_ROOT/" 2>/dev/null || true
        done
    else
        # Back up existing component
        if [ -d "$OPENCLAW_ROOT/$component" ]; then
            mv "$OPENCLAW_ROOT/$component" "$OPENCLAW_ROOT/${component}.pre-restore" 2>/dev/null || true
        fi

        mkdir -p "$OPENCLAW_ROOT/$component"
        if rsync -a "$source_dir/$component/" "$OPENCLAW_ROOT/$component/"; then
            log_message "  $component: restored successfully"
        else
            log_message "  $component: ERROR during restore"
            if [ -d "$OPENCLAW_ROOT/${component}.pre-restore" ]; then
                mv "$OPENCLAW_ROOT/${component}.pre-restore" "$OPENCLAW_ROOT/$component"
            fi
            return 1
        fi
    fi
}

# Restore all components.
restore_all() {
    local source_dir="$1"

    log_message "Restoring all components..."

    if [ -d "$OPENCLAW_ROOT" ]; then
        local backup_name="${OPENCLAW_ROOT}.backup-$(date +%Y%m%d-%H%M%S)"
        log_message "Backing up existing installation to $backup_name"
        mv "$OPENCLAW_ROOT" "$backup_name"
    fi

    mkdir -p "$OPENCLAW_ROOT"

    local failed=0
    for entry in "$source_dir"/*/; do
        [ -d "$entry" ] || continue
        local component
        component=$(basename "$entry")

        if [ "$component" = "root-files" ]; then
            # Copy root files to ~/.openclaw/
            for f in "$entry"/*; do
                [ -e "$f" ] || continue
                if ! cp -a "$f" "$OPENCLAW_ROOT/"; then
                    log_message "  root-files: ERROR copying $(basename "$f")"
                    failed=$((failed + 1))
                fi
            done
            log_message "  root-files: restored"
        else
            mkdir -p "$OPENCLAW_ROOT/$component"
            if rsync -a "$entry" "$OPENCLAW_ROOT/$component/"; then
                log_message "  $component: restored"
            else
                log_message "  $component: ERROR during restore"
                failed=$((failed + 1))
            fi
        fi
    done

    if [ "$failed" -gt 0 ]; then
        log_message "WARNING: $failed component(s) failed to restore"
        return 1
    fi
    return 0
}

validate_restoration() {
    log_message "Validating restoration..."

    local issues=0

    if [ ! -f "$OPENCLAW_ROOT/openclaw.json" ]; then
        log_message "WARNING: openclaw.json not found"
        issues=$((issues + 1))
    fi

    local workspace_count
    workspace_count=$(find "$OPENCLAW_ROOT" -maxdepth 1 -type d -name 'workspace*' 2>/dev/null | wc -l)
    if [ "$workspace_count" -eq 0 ]; then
        log_message "WARNING: No workspace directories found"
        issues=$((issues + 1))
    else
        log_message "Found $workspace_count workspace(s)"
    fi

    if [ -d "$OPENCLAW_ROOT/agents" ]; then
        local agent_count
        agent_count=$(find "$OPENCLAW_ROOT/agents" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
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

Restored files are in: $OPENCLAW_ROOT

Next steps:

1. Restart the OpenClaw gateway:
   sudo systemctl restart openclaw-gateway

2. Verify gateway status:
   openclaw gateway status

3. Re-establish automated backups on this machine:
   GITS_PAT='<YOUR_PAT>' $BACKUP_ROOT/scripts/gits-setup.sh <FREQUENCY> <RETENTION>

Without step 3, this machine will NOT push backups to GitHub.

Note: If existing files were found, they were backed up with a
.pre-restore or .backup-TIMESTAMP suffix.

EOF
}

main() {
    local component=""
    local item=""
    local from_ref=""
    local action="restore"
    local contents_component=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --component)
                component="$2"
                shift 2
                ;;
            --item)
                item="$2"
                shift 2
                ;;
            --from)
                from_ref="$2"
                shift 2
                ;;
            --list)
                action="list"
                shift
                ;;
            --show)
                action="show"
                from_ref="$2"
                shift 2
                ;;
            --contents)
                action="contents"
                contents_component="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_message "ERROR: Unknown option: $1"
                usage
                ;;
        esac
    done

    # --item requires --component
    if [ -n "$item" ] && [ -z "$component" ]; then
        log_message "ERROR: --item requires --component"
        exit 1
    fi

    case "$action" in
        list)
            list_snapshots
            return 0
            ;;
        show)
            show_manifest "$from_ref"
            return 0
            ;;
        contents)
            local source_dir="$DATA_DIR"
            local tmpdir=""
            if [ -n "$from_ref" ]; then
                local commit
                commit=$(resolve_ref "$from_ref")
                source_dir=$(checkout_historical_data "$commit")
                tmpdir="$(dirname "$source_dir")"
            fi
            list_component_contents "$contents_component" "$source_dir"
            [ -n "$tmpdir" ] && rm -rf "$tmpdir"
            return 0
            ;;
    esac

    log_message "=== Starting GITS restoration ==="
    check_prerequisites

    # Determine source directory (current data/ or historical)
    local source_dir="$DATA_DIR"
    local tmpdir=""

    if [ -n "$from_ref" ]; then
        local commit
        commit=$(resolve_ref "$from_ref")
        log_message "Restoring from commit: $commit"
        source_dir=$(checkout_historical_data "$commit")
        tmpdir="$(dirname "$source_dir")"
    fi

    # Verify data exists
    if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir" 2>/dev/null)" ]; then
        log_message "ERROR: No backup data found in $source_dir"
        [ -n "$tmpdir" ] && rm -rf "$tmpdir"
        exit 1
    fi

    log_message "Restoring from: $source_dir"

    if [ -n "$item" ]; then
        restore_item "$component" "$item" "$source_dir"
    elif [ -n "$component" ]; then
        restore_component "$component" "$source_dir"
    else
        restore_all "$source_dir"
    fi

    # Clean up temp dir if we used historical data
    [ -n "$tmpdir" ] && rm -rf "$tmpdir"

    if validate_restoration; then
        log_message "Restoration completed successfully"
    else
        log_message "Restoration completed with warnings"
    fi

    display_next_steps
    log_message "=== Restoration completed ==="
}

trap 'log_message "ERROR: Script failed at line $LINENO"; exit 1' ERR

main "$@"
