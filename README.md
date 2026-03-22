# GITS (Ghost In The Shell) – OpenClaw Recovery System

Off-site backup of the entire `~/.openclaw` directory to GitHub. Every 3 hours, GITS creates a tarball of your OpenClaw installation and pushes it to this repo. If your machine dies, clone this repo on a new machine and restore everything.

## Setup Instructions

You are reading this because a user asked you to set up GITS backups and gave you this repo's URL. Follow these steps in order.

### Step 1: Get a GitHub PAT

A GitHub Personal Access Token (PAT) with `repo` scope is required for GITS to push backups.

If the user already provided a PAT along with this URL (it starts with `ghp_`, `ghs_`, or `github_pat_`), skip to Step 2.

Otherwise, **stop and ask the user now**:

> I need a GitHub Personal Access Token to set up GITS backups. Here's how to create one:
>
> 1. Go to https://github.com/settings/tokens
> 2. Click **Generate new token (classic)**
> 3. Select the **`repo`** scope (full control of private repositories)
> 4. Copy the token (it starts with `ghp_`, `ghs_`, or `github_pat_`)
>
> Paste the token here and I'll finish the setup.

**Do not continue until you have a valid PAT.**

### Step 2: Clone this repo

Clone using the same URL the user gave you:

```bash
mkdir -p ~/.openclaw/backups
git clone <REPO_URL> ~/.openclaw/backups/GITS
```

The `<REPO_URL>` is the GitHub URL the user provided when they asked you to set up GITS (e.g. `https://github.com/someone/GITS-GhostInTheShell.git`).

### Step 3: Run setup with the PAT

```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT>
```

The setup script will:

1. Validate the PAT format
2. Verify the PAT can access this repo (via GitHub API)
3. Configure the git remote with the PAT for non-interactive pushes
4. Verify `~/.openclaw` exists
5. Configure git for cron (credential store, committer identity)

**If setup fails, stop and report the error to the user.** Do not continue.

### Step 4: Run the first backup

```bash
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

This creates a tarball of `~/.openclaw/`, commits it to this repo, and pushes to GitHub. Verify it succeeds — look for `"Successfully pushed to remote"` in the output.

### Step 5: Schedule automatic backups

```bash
(crontab -l 2>/dev/null; echo "0 */3 * * * ~/.openclaw/backups/GITS/scripts/gits-backup.sh >> /tmp/gits-backup.log 2>&1") | crontab -
```

Verify:

```bash
crontab -l | grep gits-backup
```

Setup is complete. Backups will run every 3 hours and push to GitHub.

---

## Restoring on a Different Machine

When you need to recover OpenClaw on a new or rebuilt machine:

### Step 1: Clone this repo with your PAT

```bash
git clone https://<PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git GITS
```

### Step 2: Restore from the latest snapshot

```bash
cd GITS
./scripts/gits-restore.sh
```

This will:
- Find the newest tarball in `snapshots/`
- Back up any existing `~/.openclaw/` (renamed with `.backup-TIMESTAMP`)
- Extract the snapshot to `~/.openclaw/`
- Validate the restored files

### Step 3: Restart OpenClaw

```bash
sudo systemctl restart openclaw-gateway
openclaw gateway status
```

### Step 4: Re-establish backups on this machine

The restored machine does not have backups configured yet. Set them up:

```bash
mkdir -p ~/.openclaw/backups
cp -r GITS ~/.openclaw/backups/GITS
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT>
~/.openclaw/backups/GITS/scripts/gits-backup.sh
(crontab -l 2>/dev/null; echo "0 */3 * * * ~/.openclaw/backups/GITS/scripts/gits-backup.sh >> /tmp/gits-backup.log 2>&1") | crontab -
```

### Emergency manual restore

If the restore script fails:

```bash
cd /path/to/GITS
LATEST=$(ls -1t snapshots/openclaw-*.tar.gz | head -1)
mv ~/.openclaw ~/.openclaw.backup-$(date +%s)
tar -xzf "$LATEST" -C ~/
sudo systemctl restart openclaw-gateway
```

---

## What Gets Backed Up

The entire `~/.openclaw/` directory as a single tarball — workspaces, agent definitions, configs, credentials, cron jobs, scripts, everything.

Excluded from snapshots (to keep tarballs small):
- `backups/` (avoids recursive backup)
- `venv`, `node_modules`, `.git`
- `*.log`, `*.tmp`

## How It Works

```
~/.openclaw/                       # What gets backed up
~/.openclaw/backups/GITS/          # This repo (excluded from snapshots)
  ├── snapshots/                   # Dated tarballs
  │   ├── openclaw-2026-03-22_0200.tar.gz
  │   ├── openclaw-2026-03-22_0500.tar.gz
  │   └── ...
  ├── scripts/
  │   ├── gits-setup.sh            # Validates PAT, configures auth
  │   ├── gits-backup.sh           # Creates snapshot, commits, pushes
  │   └── gits-restore.sh          # Extracts latest snapshot
  ├── .gitignore
  └── README.md
```

- **Retention**: 7 days of tarballs locally. Git history preserves all versions.
- **Push retries**: Up to 3 attempts with rebase on conflict.
- **Logs**: `/tmp/gits-backup.log`, `/tmp/gits-restore.log`, `/tmp/gits-setup.log`

## Troubleshooting

**Backup fails to push**: The PAT may be expired. Update it:
```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <NEW_PAT>
```

**Gateway won't start after restore**:
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Restore to a specific date**: `ls snapshots/` and extract the desired tarball manually.
