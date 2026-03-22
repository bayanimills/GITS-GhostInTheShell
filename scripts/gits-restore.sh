#!/usr/bin/env bash
set -euo pipefail

# GITS Restore Script
# Restores OpenClaw from component-level snapshots.
#
# Usage:
#   gits-restore.sh                          # restore all components from latest snapshot
#   gits-restore.sh --component config       # restore only config from latest snapshot
#   gits-restore.sh --component agents       # restore only agents
#   gits-restore.sh --from 2026-03-22_1430   # restore all from a specific snapshot
#   gits-restore.sh --component config --from 2026-03-22_1430
#   gits-restore.sh --list                   # list available snapshots
#   gits-restore.sh --show 2026-03-22_1430   # show manifest for a snapshot

OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOTS_DIR="$BACKUP_ROOT/snapshots"
LOG_FILE="/tmp/gits-restore.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

VALID_COMPONENTS=(config agents workspaces credentials)

log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

usage() {
    cat << 'EOF'
Usage: gits-restore.sh [OPTIONS]

Options:
  --component NAME   Restore a single component (config, agents, workspaces, credentials)
  --from TAG         Restore from a specific snapshot (e.g. 2026-03-22_1430)
  --list             List available snapshots with their components
  --show TAG         Show the manifest for a specific snapshot
  -h, --help         Show this help message

Examples:
  gits-restore.sh                                    Restore everything from latest
  gits-restore.sh --component config                 Restore only config files
  gits-restore.sh --component agents --from 2026-03-22_1430
  gits-restore.sh --list
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

is_valid_component() {
    local name="$1"
    for c in "${VALID_COMPONENTS[@]}"; do
        [ "$c" = "$name" ] && return 0
    done
    return 1
}

# Find the latest snapshot directory (or a legacy monolithic tarball).
# Prints the path to stdout.
find_latest_snapshot_dir() {
    if [ ! -d "$SNAPSHOTS_DIR" ]; then
        log_message "ERROR: Snapshots directory not found at $SNAPSHOTS_DIR"
        exit 1
    fi

    # Prefer component-based snapshot directories (contain manifest.json)
    local latest_dir
    latest_dir=$(find "$SNAPSHOTS_DIR" -maxdepth 2 -name "manifest.json" -printf '%h\n' 2>/dev/null \
        | sort -r | head -1)

    if [ -n "$latest_dir" ]; then
        echo "$latest_dir"
        return 0
    fi

    # Fall back to legacy monolithic tarballs
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

    # Try legacy tarball
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

    # Component-based snapshots
    for manifest in "$SNAPSHOTS_DIR"/*/manifest.json; do
        [ -f "$manifest" ] || continue
        found=1
        local tag
        tag=$(basename "$(dirname "$manifest")")
        local ts components total
        ts=$(grep '"timestamp"' "$manifest" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
        components=$(grep '"component_count"' "$manifest" | head -1 | sed 's/[^0-9]//g')
        total=$(grep '"total_bytes"' "$manifest" | head -1 | sed 's/[^0-9]//g')
        local total_mb=$(( total / 1024 / 1024 ))
        echo "  $tag  ($ts)  ${components} components, ${total_mb} MB"
    done

    # Legacy monolithic tarballs
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

# Restore a single component tarball into ~/.openclaw.
# Only replaces the specific paths covered by that component.
restore_component() {
    local component="$1"
    local snapshot_dir="$2"
    local tarball="$snapshot_dir/${component}.tar.gz"

    if [ ! -f "$tarball" ]; then
        log_message "ERROR: Component '$component' not found in snapshot"
        return 1
    fi

    log_message "Restoring component: $component"

    local src_base
    src_base="$(basename "$OPENCLAW_ROOT")"

    # Back up the specific component before overwriting
    case "$component" in
        config)
            # Back up individual config files that will be overwritten
            for f in "$OPENCLAW_ROOT"/*.json "$OPENCLAW_ROOT"/*.yaml "$OPENCLAW_ROOT"/*.yml "$OPENCLAW_ROOT"/*.conf; do
                if [ -e "$f" ]; then
                    cp "$f" "${f}.pre-restore" 2>/dev/null || true
                fi
            done
            ;;
        agents)
            if [ -d "$OPENCLAW_ROOT/agents" ]; then
                mv "$OPENCLAW_ROOT/agents" "$OPENCLAW_ROOT/agents.pre-restore" 2>/dev/null || true
            fi
            ;;
        workspaces)
            for d in "$OPENCLAW_ROOT"/workspace*; do
                if [ -d "$d" ]; then
                    mv "$d" "${d}.pre-restore" 2>/dev/null || true
                fi
            done
            ;;
        credentials)
            if [ -d "$OPENCLAW_ROOT/credentials" ]; then
                mv "$OPENCLAW_ROOT/credentials" "$OPENCLAW_ROOT/credentials.pre-restore" 2>/dev/null || true
            fi
            ;;
    esac

    # Extract the component tarball — it contains paths relative to the parent of OPENCLAW_ROOT
    mkdir -p "$OPENCLAW_ROOT"
    if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
        log_message "  $component: restored successfully"
    else
        log_message "  $component: ERROR extracting tarball"
        # Attempt rollback
        case "$component" in
            agents)
                [ -d "$OPENCLAW_ROOT/agents.pre-restore" ] && mv "$OPENCLAW_ROOT/agents.pre-restore" "$OPENCLAW_ROOT/agents"
                ;;
            credentials)
                [ -d "$OPENCLAW_ROOT/credentials.pre-restore" ] && mv "$OPENCLAW_ROOT/credentials.pre-restore" "$OPENCLAW_ROOT/credentials"
                ;;
            workspaces)
                for d in "$OPENCLAW_ROOT"/*.pre-restore; do
                    [ -d "$d" ] && mv "$d" "${d%.pre-restore}"
                done
                ;;
        esac
        return 1
    fi
}

# Restore all components from a component-based snapshot directory.
restore_all_components() {
    local snapshot_dir="$1"

    log_message "Restoring all components from $(basename "$snapshot_dir")..."

    # Back up existing installation
    if [ -d "$OPENCLAW_ROOT" ]; then
        local backup_name="${OPENCLAW_ROOT}.backup-$(date +%Y%m%d-%H%M%S)"
        log_message "Backing up existing installation to $backup_name"
        mv "$OPENCLAW_ROOT" "$backup_name"
    fi

    mkdir -p "$OPENCLAW_ROOT"

    local failed=0
    for component in config agents workspaces credentials; do
        local tarball="$snapshot_dir/${component}.tar.gz"
        if [ -f "$tarball" ]; then
            if tar -xzf "$tarball" -C "$(dirname "$OPENCLAW_ROOT")" 2>/dev/null; then
                log_message "  $component: restored"
            else
                log_message "  $component: ERROR extracting"
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
    workspace_count=$(find "$OPENCLAW_ROOT" -maxdepth 1 -type d -name 'workspace*' | wc -l)
    if [ "$workspace_count" -eq 0 ]; then
        log_message "WARNING: No workspace directories found"
        issues=$((issues + 1))
    else
        log_message "Found $workspace_count workspace(s)"
    fi

    if [ -d "$OPENCLAW_ROOT/agents" ]; then
        local agent_count
        agent_count=$(find "$OPENCLAW_ROOT/agents" -maxdepth 1 -mindepth 1 -type d | wc -l)
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
   $BACKUP_ROOT/scripts/gits-setup.sh <YOUR_PAT>

4. Schedule backups every 3 hours:
   (crontab -l 2>/dev/null; echo "0 */3 * * * $BACKUP_ROOT/scripts/gits-backup.sh >> /tmp/gits-backup.log 2>&1") | crontab -

Without steps 3-4, this machine will NOT push backups to GitHub.

Note: If a previous installation was found, it was backed up
with a .backup-TIMESTAMP suffix in the parent directory.

EOF
}

main() {
    local component=""
    local from_tag=""
    local action="restore"

    while [ $# -gt 0 ]; do
        case "$1" in
            --component)
                component="$2"
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
            -h|--help)
                usage
                ;;
            *)
                log_message "ERROR: Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate component name if given
    if [ -n "$component" ] && ! is_valid_component "$component"; then
        log_message "ERROR: Invalid component '$component'. Valid: ${VALID_COMPONENTS[*]}"
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
    esac

    log_message "=== Starting GITS restoration ==="
    check_prerequisites

    # Resolve which snapshot to use
    local snapshot_path
    if [ -n "$from_tag" ]; then
        snapshot_path=$(resolve_snapshot_tag "$from_tag")
    else
        snapshot_path=$(find_latest_snapshot_dir)
    fi

    log_message "Using snapshot: $(basename "$snapshot_path")"

    # Determine if this is a component-based or legacy snapshot
    if [ -d "$snapshot_path" ] && [ -f "$snapshot_path/manifest.json" ]; then
        # Component-based snapshot
        if [ -n "$component" ]; then
            restore_component "$component" "$snapshot_path"
        else
            restore_all_components "$snapshot_path"
        fi
    elif [ -f "$snapshot_path" ]; then
        # Legacy monolithic tarball
        if [ -n "$component" ]; then
            log_message "ERROR: Component-level restore not supported for legacy snapshots"
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
