#!/usr/bin/env bash
set -euo pipefail

# AgentBoxGITS Backup Script
# Daily full system snapshot backup for OpenClaw agent restoration
# Run at 2am Sydney time (16:00 UTC)

# Configuration
OPENCLAW_ROOT="$HOME/.openclaw"
BACKUP_ROOT="$OPENCLAW_ROOT/backups/AgentBoxGITS"
LOG_FILE="$BACKUP_ROOT/logs/agentbox-backup.log"
MAX_LOG_SIZE=1048576  # 1MB
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
DATE_TAG=$(date '+%Y-%m-%d')
RETENTION_DAYS=7

# Function to log messages
log_message() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# Function to rotate log file if it gets too large
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        log_message "Rotated log file (exceeded $MAX_LOG_SIZE bytes)"
    fi
}

# Function to check git configuration
check_git_config() {
    cd "$BACKUP_ROOT"
    
    # Check if remote is configured
    if ! git remote get-url origin >/dev/null 2>&1; then
        log_message "ERROR: Git remote 'origin' not configured"
        return 1
    fi
    
    # Check if we can authenticate
    if ! git ls-remote origin >/dev/null 2>&1; then
        log_message "ERROR: Cannot authenticate with remote repository"
        return 1
    fi
    
    return 0
}

# Function to create workspace tarballs
create_workspace_tarballs() {
    local workspace_dir="$OPENCLAW_ROOT"
    local output_dir="$BACKUP_ROOT/workspaces"
    mkdir -p "$output_dir"

    # Find all workspace-* directories
    find "$workspace_dir" -maxdepth 1 -type d -name 'workspace-*' | while read -r workspace; do
        local workspace_name=$(basename "$workspace")
        local tarball_name="${workspace_name}-${DATE_TAG}.tar.gz"
        local tarball_path="$output_dir/$tarball_name"
        
        log_message "Creating tarball for $workspace_name..."
        
        # Create tarball, excluding common large directories
        tar -czf "$tarball_path" \
            --exclude="venv" \
            --exclude="node_modules" \
            --exclude=".git" \
            --exclude="logs" \
            --exclude="*.log" \
            --exclude="*.tmp" \
            -C "$workspace_dir" "$workspace_name" 2>/dev/null || {
                log_message "WARNING: Failed to create tarball for $workspace_name"
                rm -f "$tarball_path"
                continue
            }
        
        local size=$(stat -c%s "$tarball_path" 2>/dev/null || echo "0")
        log_message "Created $tarball_name ($((size/1024/1024)) MB)"
    done
}

# Function to backup configuration files
backup_config_files() {
    local config_dir="$BACKUP_ROOT/config"
    mkdir -p "$config_dir"

    # List of critical configuration files
    local config_files=(
        "openclaw.json"
        "agents.list"
        "cron/jobs.json"
    )
    
    for config_file in "${config_files[@]}"; do
        local source_path="$OPENCLAW_ROOT/$config_file"
        local dest_path="$config_dir/$(basename "$config_file")"
        
        if [ -f "$source_path" ]; then
            cp -p "$source_path" "$dest_path"
            log_message "Backed up config: $config_file"
        else
            log_message "WARNING: Config file not found: $config_file"
        fi
    done
}

# Function to backup credentials (if enabled)
backup_credentials() {
    local creds_source="$OPENCLAW_ROOT/credentials"
    local creds_dest="$BACKUP_ROOT/credentials"
    mkdir -p "$creds_dest"

    if [ -d "$creds_source" ]; then
        # Create tarball of credentials directory
        local tarball_name="credentials-${DATE_TAG}.tar.gz"
        local tarball_path="$creds_dest/$tarball_name"
        
        tar -czf "$tarball_path" -C "$OPENCLAW_ROOT" "credentials" 2>/dev/null || {
            log_message "WARNING: Failed to create credentials tarball"
            rm -f "$tarball_path"
            return 1
        }
        
        log_message "Backed up credentials ($(( $(stat -c%s "$tarball_path")/1024 )) KB)"
    else
        log_message "No credentials directory found"
    fi
}

# Function to prune old tarballs (local retention)
prune_old_tarballs() {
    local workspaces_dir="$BACKUP_ROOT/workspaces"
    local credentials_dir="$BACKUP_ROOT/credentials"
    
    # Prune workspace tarballs older than RETENTION_DAYS
    find "$workspaces_dir" -name "workspace-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    find "$credentials_dir" -name "credentials-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    
    log_message "Pruned tarballs older than $RETENTION_DAYS days"
}

# Function to commit and push changes
commit_and_push() {
    cd "$BACKUP_ROOT"
    
    # Ensure we're on main branch
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT_BRANCH" != "main" ]; then
        log_message "Switching from branch '$CURRENT_BRANCH' to 'main'"
        git checkout main 2>/dev/null || git checkout -b main
    fi
    
    # Add all changes (--force to include gitignored config/credential files)
    git add --force .
    
    # Check if there are changes to commit
    if git status --porcelain | grep -q '.'; then
        # Create commit message
        COMMIT_MSG="AgentBoxGITS backup: $DATE_TAG $(date '+%H:%M:%S %Z')"
        git commit -m "$COMMIT_MSG"
        log_message "Committed changes: $COMMIT_MSG"
        
        # Push to remote
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            if git push origin main; then
                log_message "Successfully pushed to GitHub"
                return 0
            else
                retry_count=$((retry_count + 1))
                log_message "Push failed (attempt $retry_count/$max_retries)"
                
                if [ $retry_count -lt $max_retries ]; then
                    sleep 10
                    # Try to pull and merge if there are remote changes
                    if git pull --rebase origin main; then
                        log_message "Successfully pulled and rebased remote changes"
                    else
                        log_message "Pull/rebase failed, will retry push"
                    fi
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

# Main execution
main() {
    log_message "=== Starting AgentBoxGITS backup ==="
    
    # Rotate log if needed
    rotate_log
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_ROOT/logs"
    
    # Check git configuration
    if ! check_git_config; then
        log_message "ERROR: Git configuration check failed"
        exit 1
    fi
    
    # Create workspace tarballs
    create_workspace_tarballs
    
    # Backup configuration files
    backup_config_files
    
    # Backup credentials
    backup_credentials
    
    # Prune old tarballs
    prune_old_tarballs
    
    # Commit and push changes
    if commit_and_push; then
        log_message "AgentBoxGITS backup completed successfully"
    else
        log_message "ERROR: AgentBoxGITS backup failed"
        exit 1
    fi
    
    log_message "=== Backup completed ==="
}

# Handle errors
trap 'log_message "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Run main function
main