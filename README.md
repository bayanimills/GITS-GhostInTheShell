# AgentBoxGITS – Automated Backup & Disaster Recovery for OpenClaw

Automated daily snapshots of your entire OpenClaw agent system — workspaces, configs, credentials, and cron jobs — committed to git so you can restore everything from a single repository.

## Prerequisites

- Linux (tested on Ubuntu/Debian)
- `bash` 4.0+, `tar`, `git`, `curl`
- OpenClaw installed at `$HOME/.openclaw`
- A GitHub repo (fork this one or create your own)

## Initial Setup

### 1. Fork or clone this repo

```bash
# Fork on GitHub first, then:
git clone https://github.com/YOUR_USERNAME/AgentBoxGITS.git
cd AgentBoxGITS
```

### 2. Create your config files from the examples

```bash
cp config/openclaw.json.example config/openclaw.json
cp config/agents.list.example config/agents.list
cp config/jobs.json.example config/jobs.json
```

Edit each file with your own values:
- **`config/openclaw.json`** — your API keys, bot tokens, agent definitions, gateway settings
- **`config/agents.list`** — your agent IDs, names, and paths
- **`config/jobs.json`** — your scheduled cron jobs (or leave empty)

These files are `.gitignore`d so your secrets stay local.

### 3. Place the repo where the backup script expects it

```bash
mkdir -p ~/.openclaw/backups
mv AgentBoxGITS ~/.openclaw/backups/AgentBoxGITS
```

Or symlink if you prefer keeping it elsewhere:
```bash
ln -s /path/to/AgentBoxGITS ~/.openclaw/backups/AgentBoxGITS
```

### 4. Run your first backup manually

```bash
cd ~/.openclaw/backups/AgentBoxGITS
./scripts/agentbox-backup.sh
```

This will:
- Create tarballs of each `workspace-*` directory in `~/.openclaw/`
- Copy your config files into the repo
- Create credential backups
- Commit and push to GitHub

Check the output for errors. If it succeeds, your first snapshot is saved.

### 5. Schedule daily backups with cron

```bash
# Edit crontab
crontab -e

# Add this line (runs at 2am daily, adjust timezone as needed):
0 2 * * * cd ~/.openclaw/backups/AgentBoxGITS && ./scripts/agentbox-backup.sh >> /tmp/agentbox-backup.log 2>&1
```

You now have automated daily backups pushed to GitHub.

## Restoring from Backup

When you need to recover (new machine, corrupted install, migration):

```bash
# 1. Clone your backup repo
git clone https://github.com/YOUR_USERNAME/AgentBoxGITS.git
cd AgentBoxGITS

# 2. Run the restore script (auto-detects latest backup date)
./scripts/agentbox-restore.sh

# 3. Restart the gateway
sudo systemctl restart openclaw-gateway
```

The restore script will:
- Find the most recent backup date from workspace tarballs
- Copy config files to `~/.openclaw/` (backing up any existing files first)
- Extract all workspace tarballs
- Restore credentials if a backup exists
- Validate and print results

Log: `/tmp/agentbox-restore.log`

## How the Backup Works

`scripts/agentbox-backup.sh` runs daily and:

1. Validates git remote is configured and authenticated
2. Creates `.tar.gz` of each `~/.openclaw/workspace-*` directory (excludes `venv`, `node_modules`, `.git`, logs)
3. Copies `openclaw.json`, `agents.list`, and `cron/jobs.json` into the repo
4. Creates a credential tarball from `~/.openclaw/credentials/`
5. Prunes tarballs older than 7 days (git history preserves all versions)
6. Commits and pushes to GitHub (retries up to 3 times on failure)

## How the Restore Works

`scripts/agentbox-restore.sh`:

1. Checks prerequisites (`tar`, `git` installed; creates `~/.openclaw/` if missing)
2. Finds the latest backup date from workspace filenames
3. Restores config files (skips any that aren't present in the backup)
4. Extracts all workspace tarballs for that date
5. Restores credentials if available
6. Validates the result

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Missing prerequisites or general failure |

## Repository Structure

```
AgentBoxGITS/
├── README.md
├── config/
│   ├── openclaw.json.example   # Template — copy to openclaw.json
│   ├── agents.list.example     # Template — copy to agents.list
│   └── jobs.json.example       # Template — copy to jobs.json
├── workspaces/                 # Daily workspace tarballs (auto-generated)
├── credentials/                # Daily credential tarballs (auto-generated)
├── scripts/
│   ├── agentbox-backup.sh      # Run daily via cron
│   └── agentbox-restore.sh     # Run to recover
└── .gitignore                  # Excludes personal configs and credentials
```

## Post-Restore Verification

```bash
# Check critical files exist
ls ~/.openclaw/openclaw.json ~/.openclaw/agents.list

# Count restored workspaces
ls -d ~/.openclaw/workspace-* | wc -l

# Check gateway
sudo systemctl restart openclaw-gateway
sleep 5
curl -s http://localhost:18789/status

# Test agent sessions
openclaw sessions list --limit 1
```

**Checklist:**
- [ ] Gateway responds to status requests
- [ ] Agents can spawn sessions
- [ ] Cron jobs scheduled (`openclaw cron list`)
- [ ] Telegram bots responding
- [ ] Backup cron job is in `crontab -l`

## Emergency Manual Recovery

If the restore script fails:

```bash
cd /path/to/AgentBoxGITS

LATEST_DATE=$(ls workspaces/workspace-*.tar.gz | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -ru | head -1)

# Restore configs (if they exist in the backup)
mkdir -p ~/.openclaw/cron
[ -f config/openclaw.json ] && cp config/openclaw.json ~/.openclaw/
[ -f config/agents.list ]   && cp config/agents.list ~/.openclaw/
[ -f config/jobs.json ]     && cp config/jobs.json ~/.openclaw/cron/jobs.json

# Restore workspaces
for TAR in workspaces/workspace-*-"$LATEST_DATE".tar.gz; do
    tar -xzf "$TAR" -C ~/.openclaw/
done

# Restore credentials
[ -f credentials/credentials-"$LATEST_DATE".tar.gz ] && \
    tar -xzf credentials/credentials-"$LATEST_DATE".tar.gz -C ~/.openclaw/

sudo systemctl restart openclaw-gateway
```

## Troubleshooting

**Gateway won't start:**
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
tail -100 ~/.openclaw/logs/gateway.log
```

**Backup script fails to push:**
- Check `git remote -v` points to your fork
- Check GitHub authentication (`gh auth status` or SSH keys)
- Check disk space (`df -h`)

**Missing workspaces after restore:**
- Check which dates are available: `ls workspaces/ | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u`
- Try an older date by editing the script or restoring manually
