# GITS (Ghost In The Shell) – OpenClaw Recovery System

Automated snapshots of the entire `~/.openclaw` directory every 3 hours, pushed to git. Full disaster recovery from a single repo.

## What Gets Backed Up

The entire `~/.openclaw/` directory as a single tarball — workspaces, agent definitions, configs, credentials, cron jobs, scripts, everything. Excludes `backups/` (to avoid recursion), `venv`, `node_modules`, `.git`, and log files.

## Prerequisites

A GitHub Personal Access Token (PAT) with `repo` scope is required. The PAT is used by git to push snapshots to GitHub — without it, cron jobs run non-interactively and have no way to authenticate.

Create one at: https://github.com/settings/tokens

## Setup (for AI agents)

You are an AI agent being asked to enable automated backups for this OpenClaw system. Follow these steps:

### 1. Clone this repo into the backup location

```bash
mkdir -p ~/.openclaw/backups
git clone https://<PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git ~/.openclaw/backups/GITS
```

Replace `<PAT>` with the GitHub Personal Access Token and `<OWNER>` with the GitHub username. Embedding the PAT in the clone URL ensures git stores it for future pushes.

### 2. Verify OpenClaw is installed

```bash
ls ~/.openclaw/openclaw.json
```

If this file doesn't exist, OpenClaw isn't configured yet — set that up first.

### 3. Configure git credentials

```bash
cd ~/.openclaw/backups/GITS
git config credential.helper store
```

This persists the PAT to `~/.git-credentials` so cron can push without interaction. Verify auth works:

```bash
git ls-remote origin
```

If this fails, the PAT is missing or expired. Re-clone with a valid token.

### 4. Run the first snapshot

```bash
~/.openclaw/backups/GITS/scripts/agentbox-backup.sh
```

This creates a tarball of `~/.openclaw/` in the `snapshots/` directory, commits, and pushes to GitHub. Check output for errors.

### 5. Schedule snapshots every 3 hours

```bash
(crontab -l 2>/dev/null; echo "0 */3 * * * ~/.openclaw/backups/GITS/scripts/agentbox-backup.sh >> /tmp/agentbox-backup.log 2>&1") | crontab -
```

Verify:
```bash
crontab -l | grep agentbox
```

Done. Snapshots run every 3 hours and push to GitHub.

## Restoring

On a new or recovered machine, clone with your PAT:

```bash
git clone https://<PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git GITS
cd GITS
./scripts/agentbox-restore.sh
sudo systemctl restart openclaw-gateway
```

The restore script:
- Finds the latest snapshot tarball
- Backs up any existing `~/.openclaw/` (renamed with `.backup-TIMESTAMP`)
- Extracts the snapshot
- Validates the result

Log: `/tmp/agentbox-restore.log`

### Emergency manual restore

```bash
cd /path/to/GITS
LATEST=$(ls -1t snapshots/openclaw-*.tar.gz | head -1)
mv ~/.openclaw ~/.openclaw.backup-$(date +%s)
tar -xzf "$LATEST" -C ~/
sudo systemctl restart openclaw-gateway
```

## How It Works

```
~/.openclaw/                    # What gets backed up (the whole directory)
~/.openclaw/backups/GITS/  # This repo (excluded from snapshots)
  ├── snapshots/                # Dated tarballs of ~/.openclaw
  │   ├── openclaw-2026-03-22_0200.tar.gz
  │   ├── openclaw-2026-03-22_0500.tar.gz
  │   └── ...
  ├── scripts/
  │   ├── agentbox-backup.sh    # Creates snapshot, commits, pushes
  │   └── agentbox-restore.sh   # Extracts latest snapshot
  ├── .gitignore
  └── README.md
```

- **Retention**: 7 days of tarballs locally. Git history preserves all versions.
- **Snapshot size**: Excludes `venv`, `node_modules`, `.git`, logs to keep tarballs small.
- **Push retries**: Up to 3 attempts with rebase on conflict.

## Troubleshooting

**Backup fails to push**: Check `git remote -v` — the URL should contain a PAT (`https://<token>@github.com/...`). If the PAT expired, update it:
```bash
cd ~/.openclaw/backups/GITS
git remote set-url origin https://<NEW_PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git
```

**Gateway won't start after restore**:
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Restore to a specific date**: `ls snapshots/` and extract the tarball manually.
