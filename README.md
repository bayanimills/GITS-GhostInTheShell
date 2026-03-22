# GITS (Ghost In The Shell) – OpenClaw Recovery System

Off-site backup of the entire `~/.openclaw` directory to GitHub. GITS creates per-component snapshots of your OpenClaw installation and pushes them to this repo on a schedule you choose. Snapshots are kept locally (duration configurable) for fast restores. If your machine dies, clone this repo on a new machine and restore everything — or just the specific agent or file you need.

## Setup Instructions

You are reading this because a user asked you to set up GITS backups and gave you this repo's URL. Follow these steps in order.

**Before you begin**, tell the user what you'll need from them:

> To set up GITS backups, I'll need to ask you three things:
>
> 1. A **GitHub Personal Access Token** (PAT) for pushing backups
> 2. How **often** you want backups to run
> 3. How **long** to keep local snapshots on this machine
>
> Let's start with the first one.

Then proceed through the questions **one at a time**, waiting for each answer before asking the next.

### Step 1: Get a GitHub PAT

A GitHub Personal Access Token (PAT) with `repo` scope is required for GITS to push backups.

If the user already provided a PAT along with this URL (it starts with `ghp_`, `ghs_`, or `github_pat_`), skip to Step 2.

Otherwise, **stop and ask the user now**:

> I need a GitHub Personal Access Token (PAT) so GITS can push your
> backups to this repository. A PAT is like a password that gives
> specific, limited access to your GitHub account — it's safer than
> using your actual password because you control exactly what it can do
> and you can revoke it at any time.
>
> Here's how to create one:
>
> 1. Go to **https://github.com/settings/tokens** (you may need to log in)
> 2. Click **"Generate new token (classic)"**
> 3. Give it a descriptive name like **"GITS Backup"** so you remember what it's for
> 4. Set an **expiration** — 90 days is a good default, or "No expiration" if you prefer (you can always revoke it manually later)
> 5. Under **"Select scopes"**, check only the **`repo`** box — this grants read/write access to your private repositories, which GITS needs to push snapshot commits. You do **not** need any other scopes (no `admin`, `workflow`, `gist`, etc.)
> 6. Click **"Generate token"** at the bottom of the page
> 7. **Copy the token immediately** — GitHub will only show it once. It will start with `ghp_`, `ghs_`, or `github_pat_`
>
> Paste the token here and I'll move on to the next question.

**Do not continue until you have a valid PAT.**

### Step 2: Ask for backup frequency

Ask the user how often they want backups to run:

> How often should GITS back up your OpenClaw installation?
>
> - **1h** — Every hour
> - **3h** — Every 3 hours (recommended)
> - **6h** — Every 6 hours
> - **12h** — Every 12 hours
> - **24h** — Once a day

If the user doesn't have a preference, use `3h`.

### Step 3: Ask for local retention period

Ask the user how long to keep snapshots on the local machine:

> How long should GITS keep backup snapshots on this machine? Local
> snapshots let you restore quickly without pulling from GitHub. Older
> snapshots are pruned from disk but stay in the GitHub repo's git
> history forever.
>
> - **1 day** — Minimal disk usage
> - **3 days** — Short-term safety net
> - **7 days** — Good balance of coverage and disk usage (recommended)
> - **2 weeks** — Extra local history
> - **1 month** — Maximum local coverage

If the user doesn't have a preference, use `7d` (7 days).

### Step 4: Clone this repo

Clone using the same URL the user gave you:

```bash
mkdir -p ~/.openclaw/backups
git clone <REPO_URL> ~/.openclaw/backups/GITS
```

The `<REPO_URL>` is the GitHub URL the user provided when they asked you to set up GITS (e.g. `https://github.com/someone/GITS-GhostInTheShell.git`).

### Step 5: Run setup with the PAT, frequency, and retention

```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> <FREQUENCY> <RETENTION>
```

For example: `gits-setup.sh ghp_abc123 6h 7d`

The setup script will:

1. Validate the PAT format and verify access to the repo
2. Configure the git remote with the PAT for non-interactive pushes
3. Verify `~/.openclaw` exists
4. Configure git for cron (credential store, committer identity)
5. Install the cron job at the chosen frequency
6. Save the retention setting to `gits.conf`

**If setup fails, stop and report the error to the user.** Do not continue.

### Step 6: Run the first backup

```bash
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

This snapshots each component of `~/.openclaw/`, commits them to this repo, and pushes to GitHub. Verify it succeeds — look for `"Successfully pushed to remote"` in the output.

Setup is complete. Tell the user:
- Backups will run automatically at the chosen frequency
- Local snapshots are kept for the chosen retention period for fast restores
- Older snapshots are pruned locally but remain in the GitHub repo's git history indefinitely

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

### Selective restore — by component

Restore only the component you need:

```bash
# See what snapshots are available
./scripts/gits-restore.sh --list

# Inspect a specific snapshot's manifest
./scripts/gits-restore.sh --show 2026-03-22_1430

# Restore just one component
./scripts/gits-restore.sh --component agents
./scripts/gits-restore.sh --component credentials --from 2026-03-22_1430
```

### Selective restore — by specific item

Restore a single agent, workspace, or file from within a component:

```bash
# See what's inside the agents component
./scripts/gits-restore.sh --contents agents

# Restore just the kaira agent
./scripts/gits-restore.sh --component agents --item kaira

# Restore a specific agent from a specific snapshot
./scripts/gits-restore.sh --component agents --item kaira --from 2026-03-22_1430

# Restore a specific root-level config file
./scripts/gits-restore.sh --component root-files --item openclaw.json
```

Existing files are backed up with a `.pre-restore` suffix before being overwritten.

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
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> <FREQUENCY> <RETENTION>
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
  ├── gits.conf                     # Retention config (written by setup)
  ├── snapshots/                   # Local snapshots (retention configurable)
  │   ├── 2026-03-22_1430/
  │   │   ├── manifest.json
  │   │   ├── agents.tar.gz
  │   │   ├── credentials.tar.gz
  │   │   ├── root-files.tar.gz
  │   │   └── ...
  │   └── 2026-03-22_1130/
  │       └── ...
  ├── scripts/
  │   ├── gits-setup.sh            # Validates PAT, configures auth + cron
  │   ├── gits-backup.sh           # Creates snapshots, commits, pushes
  │   └── gits-restore.sh          # Restores all, by component, or by item
  ├── .gitignore
  └── README.md
```

- **Frequency**: Configurable during setup (1h, 3h, 6h, 12h, 24h)
- **Local retention**: Configurable during setup (1d, 3d, 7d, 14d, 30d — default 7d)
- **Remote retention**: All snapshots preserved in GitHub git history indefinitely
- **Push retries**: Up to 3 attempts with rebase on conflict
- **Logs**: `/tmp/gits-backup.log`, `/tmp/gits-restore.log`, `/tmp/gits-setup.log`

## Troubleshooting

**Backup fails to push**: The PAT may be expired. Update it:
```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <NEW_PAT> <FREQUENCY> <RETENTION>
```

**Change backup frequency or retention**:
```bash
~/.openclaw/backups/GITS/scripts/gits-setup.sh <PAT> 6h 14d
```
This replaces the existing cron job and retention setting.

**Gateway won't start after restore**:
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Restore a specific agent**:
```bash
./scripts/gits-restore.sh --contents agents
./scripts/gits-restore.sh --component agents --item kaira
```

**Restore to a specific date**: Use `--list` and `--from`:
```bash
./scripts/gits-restore.sh --list
./scripts/gits-restore.sh --from 2026-03-22_1430
```
