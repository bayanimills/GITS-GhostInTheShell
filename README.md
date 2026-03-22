# GITS (Ghost In The Shell) – OpenClaw Recovery System

Automated snapshots of the entire `~/.openclaw` directory every 3 hours, pushed to git. Full disaster recovery from a single repo.

## What Gets Backed Up

The entire `~/.openclaw/` directory as a single tarball — workspaces, agent definitions, configs, credentials, cron jobs, scripts, everything. Excludes `backups/` (to avoid recursion), `venv`, `node_modules`, `.git`, and log files.

## Setup

**A GitHub Personal Access Token (PAT) is required before setup can proceed.** Without a PAT, backups cannot push to GitHub and the entire system is useless.

### For the user (before running setup)

1. Go to https://github.com/settings/tokens
2. Click **Generate new token (classic)**
3. Select the **`repo`** scope (full control of private repositories)
4. Copy the token — it starts with `ghp_`, `ghs_`, or `github_pat_`

Provide this PAT to the agent or pass it directly to the setup script.

### For AI agents

You are an AI agent being asked to enable automated backups. **Do not proceed without a valid GitHub PAT from the user.** If no PAT has been provided, stop here and ask the user to create one using the instructions above.

Once you have a PAT, run:

```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT>
```

The setup script will:
1. Validate the PAT format
2. Verify the PAT has access to this GitHub repo
3. Configure the git remote with the PAT for non-interactive auth
4. Verify OpenClaw is installed
5. Configure git for cron (credential store, user identity)

If any step fails, the script exits with a clear error. Do not continue until setup succeeds.

### After setup succeeds

Run the first snapshot:
```bash
~/.openclaw/backups/GITS/scripts/agentbox-backup.sh
```

Schedule snapshots every 3 hours:
```bash
(crontab -l 2>/dev/null; echo "0 */3 * * * ~/.openclaw/backups/GITS/scripts/agentbox-backup.sh >> /tmp/agentbox-backup.log 2>&1") | crontab -
```

Verify:
```bash
crontab -l | grep agentbox
```

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
  │   ├── gits-setup.sh         # Validates PAT, configures auth
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
