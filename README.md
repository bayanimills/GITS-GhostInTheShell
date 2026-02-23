# GITS (Ghost In The Shell) – OpenClaw Recovery System

Automated off-site backup of your entire OpenClaw installation to a private GitHub repo. GITS snapshots your system on a schedule, pushes to GitHub, and lets you restore everything — or just the specific agent or file you need — on any machine.

## Quick Start

Tell your OpenClaw agent:

```
Set up GITS backups following the instructions at https://github.com/bayanimills/GITS-GhostInTheShell/blob/main/SETUP.md
```

That's it. The agent reads the deployment instructions, walks you through a few questions, and handles the rest.

## What is GITS?

GITS is a disaster recovery system for [OpenClaw](https://docs.openclaw.ai). It takes a snapshot of your entire `~/.openclaw` directory at regular intervals and pushes it to a private GitHub repository. If your machine dies, you clone the repo on a new machine and restore — fully or selectively, down to a single agent.

It's designed to be installed by an AI agent. You give your agent this repo's URL, it asks you a few questions (your backup repo URL, a GitHub token, backup frequency, and how long to keep local copies), and sets everything up automatically.

## Security Notice

**Before setting up GITS, ask your AI agent: "What are the security risks of using GITS?"**

Your agent should explain what data is being backed up, where it's stored, and what the implications are for your specific setup. Key points:

- **Your backup repo must be PRIVATE.** A public repo would expose your entire OpenClaw configuration — API keys, credentials, agent data — to anyone on the internet. When creating the repo on GitHub, always select **Private**.
- GITS uses a **GitHub Personal Access Token (PAT)** to push backups — see [What is a PAT?](#what-is-a-pat) below.
- Backup snapshots contain everything in `~/.openclaw`, including sensitive files. The security of your backups depends on the security of your GitHub account.

## What is a PAT?

A **Personal Access Token (PAT)** is like a special-purpose password for your GitHub account. Instead of giving something your full GitHub password, you create a PAT that only has permission to do specific things — and you can revoke it at any time without changing your password.

Think of it like a house key that only opens one door, instead of a master key that opens everything. If you lose it, you can change just that one lock.

**Why GITS needs one:** GITS runs automatically in the background (via a scheduled task). It needs a way to push your backup snapshots to GitHub without you typing your password every time. A PAT lets it do that safely.

**How to create one:**

1. Go to **https://github.com/settings/tokens**
2. Choose either token type:

| | Fine-grained token | Classic token |
|---|---|---|
| **Create** | Click *"Generate new token"* → *"Fine-grained token"* | Click *"Generate new token (classic)"* |
| **Scope** | Set **Repository access** → *"Only select repositories"* → pick your GITS repo, then **Permissions → Contents** → *"Read and write"* | Check the **`repo`** box |
| **Trade-off** | Locked to specific repo(s), minimum permissions — but the repo must already exist before you can select it | Simpler to create — but grants access to all your repos |

3. Name it something recognizable (e.g. **"GITS Backup"**)
4. Set an expiration (90 days is a reasonable default)
5. Click **Generate token** and **copy it immediately** — GitHub only shows it once

The token will start with `ghp_`, `ghs_`, or `github_pat_`. Keep it safe — treat it like a password.

## Features

- **Automated scheduled backups** — runs via cron at your chosen interval (1h, 3h, 6h, 12h, or 24h)
- **Per-component snapshots** — each directory in `~/.openclaw` gets its own tarball, plus `root-files.tar.gz` for config files. A `manifest.json` records what was captured
- **Granular restore** — restore everything, a single component (`--component agents`), or a single item within a component (`--component agents --item agentname`)
- **Local retention** — configurable (1 day to 1 month) for fast restores without pulling from GitHub
- **Pre-restore safety** — existing files are backed up before overwriting, with automatic rollback on failure
- **Push resilience** — up to 3 push attempts with rebase-on-conflict
- **Secure auth** — PAT passed via environment variable, never on the command line
- **Idempotent setup** — re-running detects an existing installation and offers to update PAT, change schedule, or full reinstall

## Prerequisites

### 1. A private GitHub repo

Create a **private** repo on GitHub. An empty repo is fine — GITS will populate it.

**The repo MUST be private.** Your backups contain API keys, credentials, and agent data.

### 2. A PAT

See [What is a PAT?](#what-is-a-pat) above for a full explanation and step-by-step creation guide.

### 3. System requirements

GITS requires `bash` (4.0+), `tar`, `git`, and `curl` — all standard on Linux. No additional packages need to be installed.

## How It Works

GITS backs up everything in `~/.openclaw/`, split into per-component tarballs. Each top-level directory (agents, credentials, workspaces, etc.) gets its own archive. Loose config files are bundled into `root-files.tar.gz`. A `manifest.json` records what was captured and sizes.

**Excluded from snapshots** (build artifacts that can be regenerated):
- `backups/` — avoids backing up the backup tool itself
- `venv/` — Python virtual environments, recreated with `pip install`
- `node_modules/` — Node.js packages, recreated with `npm install`
- `.git/` — git metadata within OpenClaw directories
- `*.log`, `*.tmp` — temporary files

### Backup cycle

Every interval (configurable), `gits-backup.sh` runs: creates component tarballs, writes a manifest, prunes old local snapshots past the retention period, commits everything, and pushes to GitHub. On push failure, retries up to 3 times with rebase.

### Restore options

| Command | Effect |
|---|---|
| `gits-restore.sh` | Restore everything from latest snapshot |
| `--component agents` | Restore just the agents directory |
| `--component agents --item agentname` | Restore just one specific agent |
| `--from 2026-03-22_1430` | Restore from a specific snapshot |
| `--list` | List available snapshots |
| `--contents agents` | List items inside a component |

Existing files are always backed up before overwriting (`.pre-restore` suffix), with automatic rollback on failure.

### Configuration

| Setting | Options | Default |
|---|---|---|
| Backup frequency | 1h, 3h, 6h, 12h, 24h | 3h |
| Local retention | 1 day, 3 days, 7 days, 2 weeks, 1 month | 7 days |
| Remote retention | Indefinite (git history) | — |

### Directory structure

```
~/.openclaw/backups/GITS/
  ├── gits.conf               # Settings (written by setup)
  ├── snapshots/               # Local snapshots (pruned by retention)
  │   └── 2026-03-22_1430/
  │       ├── manifest.json
  │       ├── agents.tar.gz
  │       ├── credentials.tar.gz
  │       ├── root-files.tar.gz
  │       └── ...
  ├── scripts/
  │   ├── gits-setup.sh        # Validates PAT, configures auth + cron
  │   ├── gits-backup.sh       # Creates snapshots, commits, pushes
  │   └── gits-restore.sh      # Restores all, by component, or by item
  ├── SETUP.md                 # LLM deployment instructions
  ├── .gitignore
  └── README.md                # This file
```

## Manual Deployment

If you prefer to set up GITS without an AI agent:

```bash
# 1. Clone this repo to get the scripts
git clone https://github.com/bayanimills/GITS-GhostInTheShell.git ~/.openclaw/backups/GITS

# 2. Point the remote at your private backup repo
git -C ~/.openclaw/backups/GITS remote set-url origin https://github.com/<YOU>/<YOUR-BACKUP-REPO>.git

# 3. Run setup (validates PAT, configures git auth + cron)
GITS_PAT='ghp_...' ~/.openclaw/backups/GITS/scripts/gits-setup.sh 3h 7d

# 4. Run first backup
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

To restore on a new machine:

```bash
git clone https://<PAT>@github.com/<YOU>/<YOUR-BACKUP-REPO>.git GITS
cd GITS && ./scripts/gits-restore.sh
```

## Troubleshooting

**Backup fails to push**: The PAT may be expired. Re-run setup with a new one:
```bash
GITS_PAT='<NEW_PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
```

**Change backup frequency or retention**:
```bash
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh 6h 14d
```

**Gateway won't start after restore**:
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
```

**Restore a specific agent**:
```bash
./scripts/gits-restore.sh --contents agents
./scripts/gits-restore.sh --component agents --item agentname
```

**Restore to a specific date**:
```bash
./scripts/gits-restore.sh --list
./scripts/gits-restore.sh --from 2026-03-22_1430
```

**Logs**: `/tmp/gits-setup.log`, `/tmp/gits-backup.log`, `/tmp/gits-restore.log`
