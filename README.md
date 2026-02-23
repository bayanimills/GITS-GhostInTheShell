# AgentBoxGITS - Full System Snapshot Backup

This repository contains daily snapshots of the entire OpenClaw system configuration, agent workspaces, and credentials for disaster recovery.

## Purpose
- **Full system restoration**: Clone this repository on a new machine to restore a complete OpenClaw agent system
- **Disaster recovery**: Recover from hardware failure, accidental deletion, or corruption
- **Agent migration**: Move agents between hosts with minimal downtime

## Contents
Each daily snapshot includes:
- **Configuration**: `openclaw.json`, `agents.list`, `cron/jobs.json`
- **Credentials**: Encrypted credentials directory (if applicable)
- **Agent workspaces**: Tarballs of each agent workspace (`workspace-*`)
- **Scripts**: Backup and restore automation scripts

## Structure
- `config/` - System configuration files
- `workspaces/` - Compressed tarballs of agent workspaces
- `credentials/` - Credential backups (if enabled)
- `scripts/` - Backup and restore utilities
- `logs/` - Backup execution logs

## Usage
### Restore from Backup
1. Clone this repository to a new machine
2. Run `scripts/agentbox-restore.sh`
3. Restart the OpenClaw gateway

### Manual Inspection
- Browse tarballs by date: `workspaces/workspace-aria-YYYY-MM-DD.tar.gz`
- View configuration history: `config/openclaw.json`

## Schedule
- **Daily at 2am Sydney time (16:00 UTC)**
- **Local retention**: 7 days of tarballs kept locally
- **Git history**: All snapshots preserved indefinitely

## Security
- Repository is private
- Sensitive files are stored as plaintext (by user decision)
- Access requires GitHub authentication

## Maintenance
- Automatic pruning of local tarballs older than 7 days
- Manual cleanup of Git history may be performed periodically
- Monitor backup logs for failures