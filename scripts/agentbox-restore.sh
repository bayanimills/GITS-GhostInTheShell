#!/usr/bin/env bash
set -euo pipefail

# AgentBoxGITS Restore Script
# Restores a full OpenClaw system from a AgentBoxGITS backup repository

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="/tmp/agentbox-restore.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Function to log messages
log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# Function to check prerequisites
check_prerequisites() {
    # Check if running as appropriate user (not root)
    if [ "$(id -u)" -eq 0 ]; then
        log_message "WARNING: Running as root is not recommended"
    fi
    
    # Check if OpenClaw directory exists or should be created
    if [ ! -d "$OPENCLAW_ROOT" ]; then
        log_message "OpenClaw directory does not exist, will create"
        mkdir -p "$OPENCLAW_ROOT"
    fi
    
    # Check for required commands
    for cmd in tar git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done
    
    log_message "Prerequisites check passed"
}

# Function to find latest backup date
find_latest_backup() {
    local workspaces_dir="$BACKUP_ROOT/workspaces"
    if [ -d "$workspaces_dir" ]; then
        # Find the most recent workspace tarball
        local latest=$(ls -1 "$workspaces_dir"/workspace-*.tar.gz 2>/dev/null | sort -r | head -1)
        if [ -n "$latest" ]; then
            # Extract date from filename (workspace-NAME-YYYY-MM-DD.tar.gz)
            local basename=$(basename "$latest")
            local date_part=$(echo "$basename" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
            echo "$date_part"
            return 0
        fi
    fi
    log_message "ERROR: No backup tarballs found"
    exit 1
}

# Function to restore configuration files
restore_config_files() {
    local config_dir="$BACKUP_ROOT/config"
    local latest_date="$1"
    
    log_message "Restoring configuration files..."
    
    # List of critical configuration files
    local config_files=(
        "openclaw.json"
        "agents.list"
        "cron/jobs.json"
    )
    
    for config_file in "${config_files[@]}"; do
        local source_path="$config_dir/$(basename "$config_file")"
        local dest_path="$OPENCLAW_ROOT/$config_file"
        
        if [ -f "$source_path" ]; then
            # Backup existing file if it exists
            if [ -f "$dest_path" ]; then
                mv "$dest_path" "$dest_path.backup-$(date +%Y%m%d-%H%M%S)"
                log_message "Backed up existing $config_file"
            fi
            
            # Copy new file
            cp -p "$source_path" "$dest_path"
            log_message "Restored config: $config_file"
        else
            log_message "WARNING: Config file not found in backup: $config_file"
        fi
    done
}

# Function to restore workspace tarballs
restore_workspace_tarballs() {
    local workspaces_dir="$BACKUP_ROOT/workspaces"
    local latest_date="$1"
    
    log_message "Restoring workspace tarballs for date $latest_date..."
    
    # Find all tarballs for the latest date
    find "$workspaces_dir" -name "*-${latest_date}.tar.gz" | while read -r tarball; do
        local basename=$(basename "$tarball")
        
        # Determine workspace name (workspace-NAME-YYYY-MM-DD.tar.gz)
        local workspace_name=$(echo "$basename" | sed -E 's/-(20[0-9]{2}-[0-9]{2}-[0-9]{2})\.tar\.gz$//')
        
        log_message "Restoring $workspace_name..."
        
        # Extract tarball to OpenClaw root
        tar -xzf "$tarball" -C "$OPENCLAW_ROOT" 2>/dev/null || {
            log_message "ERROR: Failed to extract $tarball"
            exit 1
        }
        
        log_message "Restored $workspace_name"
    done
}

# Function to restore credentials
restore_credentials() {
    local credentials_dir="$BACKUP_ROOT/credentials"
    local latest_date="$1"
    
    local tarball="$credentials_dir/credentials-${latest_date}.tar.gz"
    
    if [ -f "$tarball" ]; then
        log_message "Restoring credentials..."
        
        # Backup existing credentials if they exist
        if [ -d "$OPENCLAW_ROOT/credentials" ]; then
            mv "$OPENCLAW_ROOT/credentials" "$OPENCLAW_ROOT/credentials.backup-$(date +%Y%m%d-%H%M%S)"
            log_message "Backed up existing credentials"
        fi
        
        # Extract credentials tarball
        tar -xzf "$tarball" -C "$OPENCLAW_ROOT" 2>/dev/null || {
            log_message "ERROR: Failed to extract credentials tarball"
            exit 1
        }
        
        log_message "Restored credentials"
    else
        log_message "No credentials backup found for date $latest_date"
    fi
}

# Function to validate restoration
validate_restoration() {
    log_message "Validating restoration..."
    
    # Check that critical files exist
    local critical_files=(
        "$OPENCLAW_ROOT/openclaw.json"
        "$OPENCLAW_ROOT/agents.list"
    )
    
    local missing_files=0
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_message "WARNING: Critical file missing: $file"
            missing_files=$((missing_files + 1))
        fi
    done
    
    # Check that at least one workspace exists
    local workspace_count=$(find "$OPENCLAW_ROOT" -maxdepth 1 -type d -name 'workspace-*' | wc -l)
    if [ "$workspace_count" -eq 0 ]; then
        log_message "WARNING: No workspace directories found"
        missing_files=$((missing_files + 1))
    fi
    
    if [ "$missing_files" -eq 0 ]; then
        log_message "Restoration validation passed"
        return 0
    else
        log_message "Restoration validation failed: $missing_files issues found"
        return 1
    fi
}

# Function to display next steps
display_next_steps() {
    cat << EOF

=== RESTORATION COMPLETE ===

Next steps:
1. Restart the OpenClaw gateway:
   sudo systemctl restart openclaw-gateway

2. Verify agent connectivity:
   openclaw gateway status

3. Check agent sessions:
   openclaw sessions list

4. Review restored files in:
   $OPENCLAW_ROOT

Important notes:
- Existing files were backed up with .backup-* extensions
- Credentials may need manual verification
- Workspace tarballs extracted to their original locations
- Cron jobs may need to be re-enabled if using systemd

EOF
}

# Main execution
main() {
    log_message "=== Starting AgentBoxGITS restoration ==="
    
    # Check prerequisites
    check_prerequisites
    
    # Find latest backup date
    LATEST_DATE=$(find_latest_backup)
    log_message "Using backup date: $LATEST_DATE"
    
    # Restore configuration files
    restore_config_files "$LATEST_DATE"
    
    # Restore workspace tarballs
    restore_workspace_tarballs "$LATEST_DATE"
    
    # Restore credentials
    restore_credentials "$LATEST_DATE"
    
    # Validate restoration
    if validate_restoration; then
        log_message "Restoration completed successfully"
        display_next_steps
    else
        log_message "ERROR: Restoration validation failed"
        exit 1
    fi
    
    log_message "=== Restoration completed ==="
}

# Handle errors
trap 'log_message "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Run main function
main