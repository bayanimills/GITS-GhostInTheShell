# AgentBoxGITS – Automated Backup & Disaster Recovery for OpenClaw

Daily snapshots of an OpenClaw agent system — workspaces, configs, credentials, and cron jobs — committed to git for full disaster recovery from a single repository.

## How It Works

The backup script (`scripts/agentbox-backup.sh`) discovers your OpenClaw installation at `$HOME/.openclaw`, snapshots everything it finds, and pushes to this git repo. No manual configuration needed — the script reads whatever is on your system.

- **Workspaces**: Each `workspace-*` directory is tarred and dated
- **Config files**: `openclaw.json`, `agents.list`, `cron/jobs.json` are copied from your live system
- **Credentials**: The `credentials/` directory is tarred and dated
- **Retention**: 7 days of tarballs kept locally; git history preserves all versions
- **Personal files are gitignored**: Config files and credentials stay in the repo locally but are not pushed (they contain your API keys, bot tokens, etc.)

## Setup (for AI agents)

You are an AI agent being asked to set up automated backups for an OpenClaw system. Follow these steps:

### 1. Clone this repo into the backup location

```bash
mkdir -p ~/.openclaw/backups
git clone <REPO_URL> ~/.openclaw/backups/AgentBoxGITS
```

If this is a fresh fork with no backup history yet, that's fine — the first backup run will populate everything.

### 2. Verify the OpenClaw installation exists

Check that `$HOME/.openclaw` contains the expected structure:

```bash
# These should exist:
ls ~/.openclaw/openclaw.json      # Main config
ls ~/.openclaw/agents.list        # Agent definitions (may not exist on all installs)
ls -d ~/.openclaw/workspace-*     # At least one agent workspace
```

If `openclaw.json` doesn't exist, OpenClaw isn't installed or configured yet — that needs to happen first before backups make sense.

### 3. Run the first backup

```bash
cd ~/.openclaw/backups/AgentBoxGITS
./scripts/agentbox-backup.sh
```

This will:
1. Tar each `workspace-*` directory
2. Copy config files into `config/`
3. Tar the `credentials/` directory
4. Commit and push to the remote

Check the output. If it fails on git push, verify the remote is set and authenticated:
```bash
git remote -v
git ls-remote origin
```

### 4. Schedule daily backups

```bash
# Add to crontab (runs at 2am daily):
(crontab -l 2>/dev/null; echo "0 2 * * * cd ~/.openclaw/backups/AgentBoxGITS && ./scripts/agentbox-backup.sh >> /tmp/agentbox-backup.log 2>&1") | crontab -
```

Verify it was added:
```bash
crontab -l | grep agentbox
```

Setup is complete. Backups will run daily and push to git.

## Restoring from Backup

On a new or recovered machine:

```bash
# 1. Clone the backup repo
git clone <REPO_URL> AgentBoxGITS
cd AgentBoxGITS

# 2. Run the restore script
./scripts/agentbox-restore.sh

# 3. Restart the gateway
sudo systemctl restart openclaw-gateway
```

The restore script auto-detects the latest backup date and:
- Creates `~/.openclaw/` if it doesn't exist
- Copies config files (backing up any existing ones first)
- Extracts all workspace tarballs for the latest date
- Restores credentials if a backup exists
- Validates the result

Log: `/tmp/agentbox-restore.log`

### Post-restore verification

```bash
# Config files present?
ls ~/.openclaw/openclaw.json

# Workspaces restored?
ls -d ~/.openclaw/workspace-*

# Gateway responding?
sudo systemctl restart openclaw-gateway
sleep 5
curl -s http://localhost:18789/status

# Agent sessions work?
openclaw sessions list --limit 1

# Cron jobs loaded?
openclaw cron list
```

## Emergency Manual Recovery

If the restore script fails:

```bash
cd /path/to/AgentBoxGITS

LATEST_DATE=$(ls workspaces/workspace-*.tar.gz | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -ru | head -1)

# Configs
mkdir -p ~/.openclaw/cron
[ -f config/openclaw.json ] && cp config/openclaw.json ~/.openclaw/
[ -f config/agents.list ]   && cp config/agents.list ~/.openclaw/
[ -f config/jobs.json ]     && cp config/jobs.json ~/.openclaw/cron/jobs.json

# Workspaces
for TAR in workspaces/workspace-*-"$LATEST_DATE".tar.gz; do
    tar -xzf "$TAR" -C ~/.openclaw/
done

# Credentials
[ -f credentials/credentials-"$LATEST_DATE".tar.gz ] && \
    tar -xzf credentials/credentials-"$LATEST_DATE".tar.gz -C ~/.openclaw/

sudo systemctl restart openclaw-gateway
```

## Troubleshooting

**Gateway won't start:**
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Backup push fails:** Check `git remote -v` and `gh auth status`.

**No workspaces found:** Check available dates with `ls workspaces/ | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u`

## Repository Structure

```
AgentBoxGITS/
├── README.md
├── config/                  # Populated by backup script (gitignored)
├── workspaces/              # Daily workspace tarballs
├── credentials/             # Daily credential tarballs (gitignored)
├── scripts/
│   ├── agentbox-backup.sh   # Run daily via cron
│   └── agentbox-restore.sh  # Run to recover
└── .gitignore
```
