#!/usr/bin/env bash
set -euo pipefail

# GITS Restore Script
# Restores OpenClaw from component-level snapshots.
# Components are discovered dynamically from the snapshot manifest —
# whatever the backup found in ~/.openclaw is what you can restore.
#
# Usage:
#   gits-restore.sh                                    restore all from latest
#   gits-restore.sh --component agents                 restore one component
#   gits-restore.sh --component agents --item kaira    restore one item within a component
#   gits-restore.sh --from 2026-03-22_1430             pick a specific snapshot
#   gits-restore.sh --list                             list available snapshots
#   gits-restore.sh --show 2026-03-22_1430             show manifest
#   gits-restore.sh --contents agents                  list items inside a component

OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/gits-restore.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

usage() {
    cat << 'EOF'
Usage: gits-restore.sh [OPTIONS]

Options:
  --component NAME   Restore a single component by name (as listed in manifest)
  --item NAME        Restore a specific item within a component (e.g. an agent name)
  --from TAG         Restore from a specific snapshot (e.g. 2026-03-22_1430)
  --list             List available snapshots with their components
  --show TAG         Show the manifest for a specific snapshot
  --contents NAME    List the items inside a component tarball
  -h, --help         Show this help message

Components are discovered from the snapshot, not hardcoded. Run --list or
--show to see what components are available in each snapshot.

Use --contents to see what's inside a component before restoring a
specific item with --item.

Examples:
  gits-restore.sh                                    Restore everything from latest
  gits-restore.sh --component agents                 Restore the entire agents directory
  gits-restore.sh --contents agents                  See which agents are in the backup
  gits-restore.sh --component agents --item kaira    Restore only the kaira agent
  gits-restore.sh --component agents --item kaira --from 2026-03-22_1430
  gits-restore.sh --list                             See what snapshots are available
EOF
    exit 0
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
}

# List component names from a manifest file (one per line).
manifest_components() {
    local manifest="$1"
    grep -oP '^\s*"\K[^"]+(?="\s*:\s*\{)' "$manifest" | grep -v 'components'
}

# Check if a component exists in a manifest.
manifest_has_component() {
    local manifest="$1"
    local name="$2"
    manifest_components "$manifest" | grep -qx "$name"
}

# Find the latest snapshot directory (or a legacy monolithic tarball).
find_latest_snapshot_dir() {
    if [ ! -d "$SNAPSHOTS_DIR" ]; then
        log_message "ERROR: Snapshots directory not found at $SNAPSHOTS_DIR"
        exit 1
    fi

    local latest_dir
    latest_dir=$(find "$SNAPSHOTS_DIR" -maxdepth 2 -name "manifest.json" -printf '%h\n' 2>/dev/null \
        | sort -r | head -1)

    if [ -n "$latest_dir" ]; then
        echo "$latest_dir"
        return 0
    fi

    local latest_tarball
    latest_tarball=$(ls -1t "$SNAPSHOTS_DIR"/openclaw-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$latest_tarball" ]; then
        echo "$latest_tarball"
        return 0
    fi

    log_message "ERROR: No snapshots found"
    exit 1
}

# Resolve a --from tag to a snapshot directory path.
resolve_snapshot_tag() {
    local tag="$1"
    local dir="$SNAPSHOTS_DIR/$tag"

    if [ -d "$dir" ] && [ -f "$dir/manifest.json" ]; then
        echo "$dir"
        return 0
    fi

    local tarball="$SNAPSHOTS_DIR/openclaw-${tag}.tar.gz"
    if [ -f "$tarball" ]; then
        echo "$tarball"
        return 0
    fi

    log_message "ERROR: Snapshot '$tag' not found"
    exit 1
}

# List all available snapshots.
list_snapshots() {
    echo "Available snapshots:"
    echo ""

    local found=0

    for manifest in "$SNAPSHOTS_DIR"/*/manifest.json; do
        [ -f "$manifest" ] || continue
        found=1
        local tag
        tag=$(basename "$(dirname "$manifest")")
        local ts total
        ts=$(grep '"timestamp"' "$manifest" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
        total=$(grep '"total_bytes"' "$manifest" | head -1 | sed 's/[^0-9]//g')
        local total_mb=$(( total / 1024 / 1024 ))

        echo "  $tag  ($ts)  ${total_mb} MB"
        echo "    components: $(manifest_components "$manifest" | tr '\n' ' ')"
        echo ""
    done

    for tarball in "$SNAPSHOTS_DIR"/openclaw-*.tar.gz; do
        [ -f "$tarball" ] || continue
        found=1
        local name size
        name=$(basename "$tarball" .tar.gz)
        size=$(stat -c%s "$tarball" 2>/dev/null || echo "0")
        echo "  $name  (legacy monolithic)  $((size/1024/1024)) MB"
    done

    if [ "$found" -eq 0 ]; then
        echo "  (none)"
    fi
}

# Show the manifest for a specific snapshot.
show_manifest() {
    local tag="$1"
    local manifest="$SNAPSHOTS_DIR/$tag/manifest.json"

    if [ ! -f "$manifest" ]; then
        log_message "ERROR: No manifest found for snapshot '$tag'"
        exit 1
    fi

    cat "$manifest"
}

# List the top-level items inside a component tarball.
# For a directory component like "agents", this shows each subdirectory (agent).
# For "root-files", this shows each file.
list_component_contents() {
    local component="$1"
    local snapshot_dir="$2"
    local manifest="$snapshot_dir/manifest.json"

    if ! manifest_has_component "$manifest" "$component"; then
        log_message "ERROR: Component '$component' not found in snapshot"
        log_message "Available components: $(manifest_components "$manifest" | tr '\n' ' ')"
        return 1
    fi

    local tarball="$snapshot_dir/${component}.tar.gz"
    if [ ! -f "$tarball" ]; then
        log_message "ERROR: Tarball for '$component' missing"
        return 1
    fi

    local src_base
    src_base="$(basename "$OPENCLAW_ROOT")"

    echo "Contents of '$component' in snapshot $(basename "$snapshot_dir"):"
    echo ""

    # List entries one level below the component root
    # Tarball paths look like: .openclaw/agents/kaira/... or .openclaw/openclaw.json
    if [ "$component" = "root-files" ]; then
        # Root files: show each file directly
        tar -tzf "$tarball" 2>/dev/null | sed "s|^${src_base}/||" | sort -u
    else
        # Directory component: show immediate children (dirs or files)
        tar -tzf "$tarball" 2>/dev/null \
            | sed "s|^${src_base}/${component}/||" \
            | grep -v '^$' \
            | cut -d'/' -f1 \
            | sort -u
    fi
}

# Resolve the snapshot to use for --contents or restore, given optional --from tag.
resolve_snapshot() {
    local from_tag="$1"
    if [ -n "$from_tag" ]; then
        resolve_snapshot_tag "$from_tag"
    else
        find_latest_snapshot_dir
    fi
}

# Restore a specific item from within a component tarball.
# e.g. restore just "kaira" from agents.tar.gz
restore_item() {
    local component="$1"
    local item="$2"
    local snapshot_dir="$3"
    local manifest="$snapshot_dir/manifest.json"

    if ! manifest_has_component "$manifest" "$component"; then
        log_message "ERROR: Component '$component' not found in snapshot"
        log_message "Available components: $(manifest_components "$manifest" | tr '\n' ' ')"
        return 1
    fi

    local tarball="$snapshot_dir/${component}.tar.gz"
    if [ ! -f "$tarball" ]; then
        log_message "ERROR: Tarball for '$component' missing"
        return 1
    fi

    local src_base
    src_base="$(basename "$OPENCLAW_ROOT")"

    # Build the path prefix to extract
    local extract_path
    if [ "$component" = "root-files" ]; then
        extract_path="${src_base}/${item}"
    else
        extract_path="${src_base}/${component}/${item}"
    fi

    # Verify the item exists in the tarball
    if ! tar -tzf "$tarball" 2>/dev/null | grep -q "^${extract_path}"; then
        log_message "ERROR: Item '$item' not found in component '$component'"
        echo ""
        echo "Available items in '$component':"
        list_component_contents "$component" "$snapshot_dir" 2>/dev/null | tail -n +3
        return 1
    fi

    log_message "Restoring item '$item' from component '$component'"

    # Back up the specific item before overwriting
    local target_path="$OPENCLAW_ROOT"
    if [ "$component" = "root-files" ]; then
        target_path="$OPENCLAW_ROOT/$item"
    else
        target_path="$OPENCLAW_ROOT/$component/$item"
    fi

    if [ -e "$target_path" ]; then
        local backup_path="${target_path}.pre-restore"
        if [ -d "$target_path" ]; then
            mv "$target_path" "$backup_path" 2>/dev/null || true
        else
            cp "$target_path" "$backup_path" 2>/dev/null || true
        fi
        log_message "  Backed up existing $target_path"
    fi

    # Extract just the matching paths
    mkdir -p "$OPENCLAW_ROOT"
    if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" --wildcards "${extract_path}" "${extract_path}/*" 2>/dev/null; then
        log_message "  '$item' restored successfully from '$component'"
    else
        log_message "  ERROR extracting '$item' from '$component'"
        # Rollback
        local backup_path="${target_path}.pre-restore"
        if [ -d "$backup_path" ]; then
            mv "$backup_path" "$target_path"
        elif [ -f "$backup_path" ]; then
            mv "$backup_path" "$target_path"
        fi
        return 1
    fi
}

# Restore a single component tarball into ~/.openclaw.
restore_component() {
    local component="$1"
    local snapshot_dir="$2"
    local manifest="$snapshot_dir/manifest.json"

    if ! manifest_has_component "$manifest" "$component"; then
        log_message "ERROR: Component '$component' not found in snapshot"
        log_message "Available components: $(manifest_components "$manifest" | tr '\n' ' ')"
        return 1
    fi

    local tarball="$snapshot_dir/${component}.tar.gz"
    if [ ! -f "$tarball" ]; then
        log_message "ERROR: Tarball for '$component' missing despite being in manifest"
        return 1
    fi

    log_message "Restoring component: $component"

    # Back up what's about to be overwritten
    if [ "$component" = "root-files" ]; then
        for f in "$OPENCLAW_ROOT"/*; do
            [ -f "$f" ] && cp "$f" "${f}.pre-restore" 2>/dev/null || true
        done
    elif [ -d "$OPENCLAW_ROOT/$component" ]; then
        mv "$OPENCLAW_ROOT/$component" "$OPENCLAW_ROOT/${component}.pre-restore" 2>/dev/null || true
    fi

    mkdir -p "$OPENCLAW_ROOT"
    if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
        log_message "  $component: restored successfully"
    else
        log_message "  $component: ERROR extracting tarball"
        if [ -d "$OPENCLAW_ROOT/${component}.pre-restore" ]; then
            mv "$OPENCLAW_ROOT/${component}.pre-restore" "$OPENCLAW_ROOT/$component"
        fi
        return 1
    fi
}

# Restore all components from a component-based snapshot.
restore_all_components() {
    local snapshot_dir="$1"
    local manifest="$snapshot_dir/manifest.json"

    log_message "Restoring all components from $(basename "$snapshot_dir")..."

    if [ -d "$OPENCLAW_ROOT" ]; then
        local backup_name="${OPENCLAW_ROOT}.backup-$(date +%Y%m%d-%H%M%S)"
        log_message "Backing up existing installation to $backup_name"
        mv "$OPENCLAW_ROOT" "$backup_name"
    fi

    mkdir -p "$OPENCLAW_ROOT"

    local failed=0
    while IFS= read -r component; do
        local tarball="$snapshot_dir/${component}.tar.gz"
        if [ -f "$tarball" ]; then
            if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
                log_message "  $component: restored"
            else
                log_message "  $component: ERROR extracting"
                failed=$((failed + 1))
            fi
        fi
    done < <(manifest_components "$manifest")

    if [ "$failed" -gt 0 ]; then
        log_message "WARNING: $failed component(s) failed to restore"
        return 1
    fi
    return 0
}

# Legacy restore: extract a monolithic tarball.
restore_legacy_snapshot() {
    local tarball="$1"
    local tarball_name
    tarball_name=$(basename "$tarball")

    log_message "Restoring from legacy snapshot $tarball_name..."

    if [ -d "$OPENCLAW_ROOT" ]; then
        local backup_name="${OPENCLAW_ROOT}.backup-$(date +%Y%m%d-%H%M%S)"
        log_message "Backing up existing installation to $backup_name"
        mv "$OPENCLAW_ROOT" "$backup_name"
    fi

    mkdir -p "$(dirname "$OPENCLAW_ROOT")"

    if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
        log_message "Legacy snapshot extracted successfully"
    else
        log_message "ERROR: Failed to extract legacy snapshot"
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
    local from_tag=""
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
                from_tag="$2"
                shift 2
                ;;
            --list)
                action="list"
                shift
                ;;
            --show)
                action="show"
                from_tag="$2"
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
            show_manifest "$from_tag"
            return 0
            ;;
        contents)
            local snapshot_path
            snapshot_path=$(resolve_snapshot "$from_tag")
            if [ ! -d "$snapshot_path" ]; then
                log_message "ERROR: --contents requires a component-based snapshot, not a legacy tarball"
                exit 1
            fi
            list_component_contents "$contents_component" "$snapshot_path"
            return 0
            ;;
    esac

    log_message "=== Starting GITS restoration ==="
    check_prerequisites

    local snapshot_path
    snapshot_path=$(resolve_snapshot "$from_tag")

    log_message "Using snapshot: $(basename "$snapshot_path")"

    if [ -d "$snapshot_path" ] && [ -f "$snapshot_path/manifest.json" ]; then
        # Component-based snapshot
        if [ -n "$item" ]; then
            restore_item "$component" "$item" "$snapshot_path"
        elif [ -n "$component" ]; then
            restore_component "$component" "$snapshot_path"
        else
            restore_all_components "$snapshot_path"
        fi
    elif [ -f "$snapshot_path" ]; then
        # Legacy monolithic tarball
        if [ -n "$component" ] || [ -n "$item" ]; then
            log_message "ERROR: Component/item-level restore not supported for legacy snapshots"
            log_message "Hint: Run a new backup first to create component-level snapshots"
            exit 1
        fi
        restore_legacy_snapshot "$snapshot_path"
    else
        log_message "ERROR: Cannot determine snapshot format"
        exit 1
    fi

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
