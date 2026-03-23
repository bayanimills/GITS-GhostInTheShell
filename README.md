# GITS (Ghost In The Shell) – OpenClaw Recovery System

Automated off-site backup of your entire `~/.openclaw` directory to GitHub. GITS snapshots your OpenClaw installation on a schedule, pushes to this repo, and lets you restore everything — or just the specific agent or file you need — on any machine.

## Features

- **Automated scheduled backups** — runs via cron at your chosen interval (every 1h, 3h, 6h, 12h, or 24h)
- **Per-component snapshots** — each top-level directory in `~/.openclaw` (agents, credentials, workspaces, etc.) gets its own tarball, plus a `root-files.tar.gz` for loose config files. A `manifest.json` records what was captured and component sizes
- **Granular restore** — restore everything, a single component (`--component agents`), or a single item within a component (`--component agents --item kaira`)
- **Local retention** — recent snapshots are kept on disk (configurable: 1–30 days) for fast restores without pulling from GitHub. Older snapshots are pruned automatically but remain in the repo's git history indefinitely
- **Pre-restore safety** — existing files are backed up with a `.pre-restore` or `.backup-TIMESTAMP` suffix before being overwritten, with automatic rollback on extraction failure
- **Push resilience** — up to 3 push attempts with rebase-on-conflict if the remote has diverged
- **PAT-based auth** — uses a GitHub Personal Access Token (classic or fine-grained) passed via environment variable, never on the command line
- **Idempotent setup** — re-running setup detects an existing installation and offers to update just the PAT, change the schedule, or do a full reinstall

## Quick Start

GITS is designed to be set up by an LLM agent (Claude, etc.) — just give it this repo's URL and say "set up GITS backups." The agent follows the [Setup Instructions](#setup-instructions) below.

To set it up manually:

```bash
# 1. Clone this repo
git clone https://github.com/<OWNER>/GITS-GhostInTheShell.git ~/.openclaw/backups/GITS

# 2. Run setup (creates cron job, configures git auth)
GITS_PAT='ghp_...' ~/.openclaw/backups/GITS/scripts/gits-setup.sh 3h 7d

# 3. Run first backup
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

To restore on a new machine:

```bash
git clone https://<PAT>@github.com/<OWNER>/GITS-GhostInTheShell.git GITS
cd GITS && ./scripts/gits-restore.sh
```

## How It Works

### Backup cycle (`gits-backup.sh`)

1. **Prerequisites** — verifies `~/.openclaw` exists and `tar`/`git` are available
2. **Auth check** — confirms the git remote has a PAT embedded and can reach GitHub (via `git ls-remote`)
3. **Snapshot** — iterates every top-level directory in `~/.openclaw` (skipping `backups/`, `venv/`, `node_modules/`, `.git/`), creates a `.tar.gz` per directory. Loose root files (e.g. `openclaw.json`) are bundled into `root-files.tar.gz`. Writes `manifest.json` with timestamps, component names, and byte sizes
4. **Prune** — deletes local snapshot directories and legacy tarballs older than `RETENTION_DAYS` (read from `gits.conf`, default 7) using `find -mtime`
5. **Commit & push** — switches to `main` branch, stages everything with `git add --force`, commits with a timestamped message, and pushes. On push failure, retries up to 3 times with `git pull --rebase` between attempts

### Setup (`gits-setup.sh`)

1. Reads PAT from `GITS_PAT` environment variable (not a CLI argument — stays out of shell history and `ps`)
2. Validates PAT format (must start with `ghp_`, `ghs_`, or `github_pat_`)
3. Validates PAT against the GitHub API — checks HTTP response code: 200 (ok), 401 (invalid/expired), 403 (insufficient scope), 404 (repo not found)
4. Rewrites the git remote URL to embed the PAT for non-interactive pushes
5. Verifies push access with `git ls-remote`
6. Confirms `~/.openclaw` exists
7. Configures git: sets `credential.helper store`, committer name (`GITS Backup`), and email (`gits-backup@localhost`)
8. Installs a cron job at the chosen frequency (replaces any existing GITS cron entry)
9. Writes `RETENTION_DAYS` to `gits.conf`

### Restore (`gits-restore.sh`)

| Command | Effect |
|---|---|
| `gits-restore.sh` | Restore all components from the latest snapshot |
| `--component agents` | Restore just the `agents/` directory |
| `--component agents --item kaira` | Restore just the `kaira` agent |
| `--from 2026-03-22_1430` | Use a specific snapshot instead of latest |
| `--list` | List available snapshots with sizes |
| `--show TAG` | Print a snapshot's `manifest.json` |
| `--contents agents` | List items inside a component tarball |

**Safety features:**
- Before a full restore, the existing `~/.openclaw` is renamed to `~/.openclaw.backup-YYYYMMDD-HHMMSS`
- Before a component restore, the existing component dir is renamed with `.pre-restore`
- Before an item restore, the existing item is copied/moved to `.pre-restore`
- On extraction failure, the backup is rolled back automatically
- After restore, validates the result: checks for `openclaw.json`, counts workspaces and agent definitions
- Warns if running as root (not recommended)
- Supports legacy monolithic tarballs (`openclaw-*.tar.gz`) for backwards compatibility

### Directory structure

```
~/.openclaw/backups/GITS/          # This repo
  ├── gits.conf                     # Retention config (written by setup)
  ├── snapshots/                   # Local snapshots (pruned by retention)
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

### What gets backed up

Everything in `~/.openclaw/`, split into per-component tarballs:

- Each top-level directory (e.g. `agents/`, `credentials/`, workspace dirs) → its own `.tar.gz`
- Loose root files (e.g. `openclaw.json`, `jobs.json`) → `root-files.tar.gz`
- A `manifest.json` listing all components with sizes

Excluded from snapshots (to keep tarballs small):
- `backups/` (avoids recursive backup)
- `venv`, `node_modules`, `.git`
- `*.log`, `*.tmp`

### Configuration

- **Frequency**: 1h, 3h (default), 6h, 12h, 24h — stored as a cron schedule
- **Local retention**: 1d, 3d, 7d (default), 14d, 30d — stored in `gits.conf` as `RETENTION_DAYS`
- **Remote retention**: All snapshots preserved in GitHub git history indefinitely
- **Push retries**: Up to 3 attempts with `git pull --rebase` on conflict
- **Logs**: `/tmp/gits-setup.log`, `/tmp/gits-backup.log`, `/tmp/gits-restore.log`

---

## Setup Instructions (for LLM agents)

You are reading this because a user asked you to set up GITS backups and gave you this repo's URL. **Before doing anything else**, check whether GITS is already installed.

### Step 0: Detect existing installation

Run this check silently (do not show the command output to the user):

```bash
ls -d ~/.openclaw/backups/GITS 2>/dev/null && echo "INSTALLED" || echo "NOT_INSTALLED"
```

**If `NOT_INSTALLED`** — this is a fresh setup. Continue to **Step 1** below.

**If `INSTALLED`** — GITS is already on this machine. Do **not** re-clone or start from scratch. Instead, tell the user:

> GITS is already installed on this machine. What would you like to do?
>
> - **Update PAT** — Replace the token (e.g. it expired)
> - **Change schedule** — Update backup frequency or local retention
> - **Full reinstall** — Remove the existing installation and start fresh

Then follow the appropriate path:

#### Path: Update PAT

1. Ask for the new PAT (follow the **Step 1** prompt and validation below)
2. Run `gits-setup.sh` with the new PAT and the **existing** settings:
   ```bash
   # Read current settings from gits.conf
   source ~/.openclaw/backups/GITS/gits.conf
   ```
   Then look up the current cron frequency from the crontab. If you can't determine existing values, ask the user to confirm them.
   ```bash
   GITS_PAT='<NEW_PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
   ```
3. Run a test backup to verify: `~/.openclaw/backups/GITS/scripts/gits-backup.sh`
4. Tell the user the PAT has been updated and backups are working.

#### Path: Change schedule

1. Ask whichever question applies — frequency (Step 2 prompt) and/or retention (Step 3 prompt)
2. Re-run `gits-setup.sh` with the existing PAT (already embedded in the git remote) and the new settings. To reuse the current PAT without asking for it again:
   ```bash
   # Extract the PAT already stored in the remote URL
   EXISTING_PAT=$(git -C ~/.openclaw/backups/GITS remote get-url origin | sed -n 's|https://\([^@]*\)@.*|\1|p')
   ```
   Then:
   ```bash
   GITS_PAT="$EXISTING_PAT" ~/.openclaw/backups/GITS/scripts/gits-setup.sh <NEW_FREQUENCY> <NEW_RETENTION>
   ```
3. Tell the user the schedule has been updated.

#### Path: Full reinstall

1. Confirm with the user: *"This will remove the existing GITS installation and set it up again from scratch. Your backup history on GitHub is safe — only the local copy is removed. Proceed?"*
2. If confirmed:
   ```bash
   # Remove existing cron entry
   crontab -l 2>/dev/null | grep -v 'gits-backup\.sh' | crontab -
   # Remove local installation
   rm -rf ~/.openclaw/backups/GITS
   ```
3. Continue with **Step 1** below (fresh setup).

---

### Fresh Setup (Steps 1–6)

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

A GitHub Personal Access Token (PAT) with `repo` (classic) or **Contents: Read and write** (fine-grained) permission is required for GITS to push backups.

If the user already provided a PAT along with this URL (it starts with `ghp_`, `ghs_`, or `github_pat_`), skip straight to **validation** below, then to Step 2.

Otherwise, **stop and ask the user now**:

> GITS needs a GitHub Personal Access Token (PAT) to push backups to
> this repo. A PAT is a scoped, revocable credential — safer than a
> password because you control exactly what it can access.
>
> **Create one here → https://github.com/settings/tokens**
>
> You have two options:
>
> | | Fine-grained (recommended) | Classic |
> |---|---|---|
> | **Click** | *"Generate new token" → "Fine-grained token"* | *"Generate new token (classic)"* |
> | **Scope** | Set **Repository access** to *"Only select repositories"* and pick this repo, then under **Permissions → Repository permissions**, set **Contents** to *"Read and write"* | Check the **`repo`** box (no other scopes needed) |
> | **Advantage** | Locked to just this one repo | Simpler, fewer clicks |
>
> For both: name it **"GITS Backup"**, set expiration to **90 days**
> (or your preference), then click **Generate token** and copy it
> immediately — GitHub only shows it once.
>
> Paste the token here when you're ready.

#### Validation

When the user provides a token:

1. **Format check** — verify it matches one of: `ghp_[A-Za-z0-9]{36,}`, `ghs_[A-Za-z0-9]{36,}`, or `github_pat_[A-Za-z0-9_]{22,}`. If not, tell the user the value doesn't look like a GitHub token and ask them to try again.
2. **Never echo the token.** Do not repeat the token back in your response, do not include it in code blocks, and do not log it. Refer to it only as "your token" or "the PAT."
3. **Do not continue until validation passes.**

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

Pass the PAT through an environment variable so it does not appear in shell history or `ps` output:

```bash
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
```

For example: `GITS_PAT='...' ~/.openclaw/backups/GITS/scripts/gits-setup.sh 6h 7d`

**Important:** When constructing this command, substitute the user's actual token into the `GITS_PAT` value. Do **not** echo or log the token anywhere else.

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
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
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

## Troubleshooting

**Backup fails to push**: The PAT may be expired. Update it:
```bash
GITS_PAT='<NEW_PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
```

**Change backup frequency or retention**:
```bash
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh 6h 14d
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
