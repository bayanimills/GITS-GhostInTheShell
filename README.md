# GITS (Ghost In The Shell) – OpenClaw Recovery System

Off-site backup of the entire `~/.openclaw` directory to GitHub. GITS creates per-component snapshots of your OpenClaw installation and pushes them to this repo on a schedule you choose. If your machine dies, clone this repo on a new machine and restore everything — or just the parts you need.

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

### Step 2: Ask for backup frequency

Ask the user how often they want backups to run:

> How often should GITS back up your OpenClaw installation?
>
> - **1h** — Every hour
> - **3h** — Every 3 hours (default)
> - **6h** — Every 6 hours
> - **12h** — Every 12 hours
> - **24h** — Once a day

If the user doesn't have a preference, use `3h`.

### Step 3: Clone this repo

Clone using the same URL the user gave you:

```bash
mkdir -p ~/.openclaw/backups
git clone <REPO_URL> ~/.openclaw/backups/GITS
```

The `<REPO_URL>` is the GitHub URL the user provided when they asked you to set up GITS (e.g. `https://github.com/someone/GITS-GhostInTheShell.git`).

### Step 4: Run setup with the PAT and frequency

```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> <FREQUENCY>
```

For example: `gits-setup.sh ghp_abc123 6h`

The setup script will:

1. Validate the PAT format
2. Verify the PAT can access this repo (via GitHub API)
3. Configure the git remote with the PAT for non-interactive pushes
4. Verify `~/.openclaw` exists
5. Configure git for cron (credential store, committer identity)
6. Install the cron job at the chosen frequency

**If setup fails, stop and report the error to the user.** Do not continue.

### Step 5: Run the first backup

```bash
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

This snapshots each component of `~/.openclaw/`, commits them to this repo, and pushes to GitHub. Verify it succeeds — look for `"Successfully pushed to remote"` in the output.

Setup is complete. Backups will run automatically at the chosen frequency and push to GitHub. Local snapshots are deleted after each successful push to save disk space.

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
- Find the newest snapshot
- Back up any existing `~/.openclaw/` (renamed with `.backup-TIMESTAMP`)
- Extract all components to `~/.openclaw/`
- Validate the restored files

### Selective restore

Restore only the component you need:

```bash
# See what's available
./scripts/gits-restore.sh --list

# Inspect a specific snapshot
./scripts/gits-restore.sh --show 2026-03-22_1430

# Restore just one component
./scripts/gits-restore.sh --component agents
./scripts/gits-restore.sh --component credentials --from 2026-03-22_1430
```

Components are discovered dynamically from the snapshot manifest — whatever directories and files were in `~/.openclaw/` at backup time are available as individual components.

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
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> <FREQUENCY>
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

### Emergency manual restore

If the restore script fails:

```bash
cd /path/to/GITS
ls snapshots/  # find the snapshot you want
# Extract a specific component
tar -xzf snapshots/<TAG>/agents.tar.gz -C ~/
# Or extract everything from a legacy monolithic tarball
tar -xzf snapshots/openclaw-<TAG>.tar.gz -C ~/
sudo systemctl restart openclaw-gateway
```

---

## What Gets Backed Up

Everything in `~/.openclaw/`, split into per-component tarballs:

- Each top-level directory (e.g. `agents/`, `credentials/`, workspace dirs) → its own `.tar.gz`
- Loose root files (e.g. `openclaw.json`, `jobs.json`) → `root-files.tar.gz`
- A `manifest.json` listing all components with sizes

Excluded from snapshots (to keep tarballs small):
- `backups/` (avoids recursive backup)
- `venv`, `node_modules`, `.git`
- `*.log`, `*.tmp`

## How It Works

```
~/.openclaw/                       # What gets backed up
~/.openclaw/backups/GITS/          # This repo (excluded from snapshots)
  ├── snapshots/                   # Temporary — cleared after push
  │   └── 2026-03-22_1430/
  │       ├── manifest.json
  │       ├── agents.tar.gz
  │       ├── credentials.tar.gz
  │       ├── root-files.tar.gz
  │       └── ...
  ├── scripts/
  │   ├── gits-setup.sh            # Validates PAT, configures auth + cron
  │   ├── gits-backup.sh           # Creates snapshots, commits, pushes, cleans up
  │   └── gits-restore.sh          # Restores all or individual components
  ├── .gitignore
  └── README.md
```

- **Frequency**: Configurable during setup (1h, 3h, 6h, 12h, 24h)
- **Local cleanup**: Snapshots are deleted after successful push to GitHub
- **Push retries**: Up to 3 attempts with rebase on conflict
- **Logs**: `/tmp/gits-backup.log`, `/tmp/gits-restore.log`, `/tmp/gits-setup.log`

## Troubleshooting

**Backup fails to push**: The PAT may be expired. Update it:
```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <NEW_PAT> <FREQUENCY>
```

**Change backup frequency**:
```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> 6h
```
This replaces the existing cron job with the new schedule.

**Gateway won't start after restore**:
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Restore to a specific date**: Use `--list` and `--from`:
```bash
./scripts/gits-restore.sh --list
./scripts/gits-restore.sh --from 2026-03-22_1430
```
