# GITS — LLM Deployment Instructions

You are an AI agent setting up GITS backups for an OpenClaw system. Follow these steps in order.

For background on GITS, security considerations, or a detailed PAT creation walkthrough, see [README.md](README.md) in this repository.

## Step 0: Detect existing installation

Run silently (do not show output to user):

```bash
ls -d ~/.openclaw/backups/GITS 2>/dev/null && echo "INSTALLED" || echo "NOT_INSTALLED"
```

**If `NOT_INSTALLED`** — continue to Step 1.

**If `INSTALLED`** — tell the user:

> GITS is already installed. What would you like to do?
>
> - **Update PAT** — Replace the token (e.g. it expired)
> - **Change schedule** — Update backup frequency or local retention
> - **Full reinstall** — Remove and start fresh

Then follow the appropriate path:

### Path: Update PAT

1. Ask for new PAT (Step 2 prompt below)
2. Read existing settings:
   ```bash
   source ~/.openclaw/backups/GITS/gits.conf
   ```
   Determine current frequency from crontab. If unclear, ask user to confirm.
3. Run:
   ```bash
   GITS_PAT='<NEW_PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
   ```
4. Test: `~/.openclaw/backups/GITS/scripts/gits-backup.sh`
5. Confirm to user.

### Path: Change schedule

1. Ask frequency (Step 3) and/or retention (Step 4) as needed.
2. Extract existing PAT:
   ```bash
   EXISTING_PAT=$(git -C ~/.openclaw/backups/GITS remote get-url origin | sed -n 's|https://\([^@]*\)@.*|\1|p')
   ```
3. Run:
   ```bash
   GITS_PAT="$EXISTING_PAT" ~/.openclaw/backups/GITS/scripts/gits-setup.sh <NEW_FREQUENCY> <NEW_RETENTION>
   ```
4. Confirm to user.

### Path: Full reinstall

1. Confirm: *"This removes the local installation. Backup history on GitHub is safe. Proceed?"*
2. If yes:
   ```bash
   crontab -l 2>/dev/null | grep -v 'gits-backup\.sh' | crontab -
   rm -rf ~/.openclaw/backups/GITS
   ```
3. Continue to Step 1.

---

## Fresh Setup

Tell the user:

> To set up GITS backups, I'll need four things:
>
> 1. Your **private backup repo** on GitHub
> 2. A **GitHub Personal Access Token** (PAT)
> 3. How **often** to back up
> 4. How **long** to keep local snapshots
>
> Let's start with the first one.

Ask each question **one at a time**.

## Step 1: Get the backup repo URL

> GITS pushes snapshots to a **private** GitHub repo that you own.
> If you haven't created one yet, go to **https://github.com/new**,
> pick a name (e.g. **"gits-backup"**), and make sure **Private** is selected.
>
> What's the repo URL? (e.g. `https://github.com/yourname/gits-backup`)

Save this as `<BACKUP_REPO_URL>` for Step 5.

**The repo MUST be private.** If the user gives a public repo URL, warn them.

## Step 2: Get a GitHub PAT

If user already provided a PAT (starts with `ghp_`, `ghs_`, or `github_pat_`), skip to **Validation**.

Otherwise ask:

> GITS needs a GitHub Personal Access Token (PAT) to push backups.
> A PAT is like a special-purpose password — limited permissions,
> revocable any time.
>
> 1. Go to **https://github.com/settings/tokens**
> 2. Click **Generate new token** (fine-grained or classic)
> 3. Fine-grained: select your GITS repo, set **Contents** → **Read and write**
>    Classic: check the **`repo`** box
> 4. Name it **"GITS Backup"**, set expiration
> 5. Click **Generate token** and copy it — shown only once
>
> Paste the token here.

### Validation

1. **Format**: must match `ghp_[A-Za-z0-9]{36,}`, `ghs_[A-Za-z0-9]{36,}`, or `github_pat_[A-Za-z0-9_]{22,}`. If not, ask to retry.
2. **Never echo the token.** Do not repeat it, log it, or put it in code blocks. Say "your token" or "the PAT."
3. Do not continue until valid.

## Step 3: Backup frequency

> How often should GITS back up?
>
> - **1h** — Every hour
> - **3h** — Every 3 hours (recommended)
> - **6h** — Every 6 hours
> - **12h** — Every 12 hours
> - **24h** — Once a day

Default: `3h`.

## Step 4: Local retention

> How long to keep snapshots on this machine? Older ones are pruned
> locally but stay in GitHub's git history.
>
> - **1d** — 1 day
> - **3d** — 3 days
> - **7d** — 7 days (recommended)
> - **14d** — 2 weeks
> - **30d** — 1 month

Default: `7d`.

## Step 5: Clone and configure

Clone this repo (the one containing these instructions) to get the scripts:

```bash
mkdir -p ~/.openclaw/backups
git clone <TEMPLATE_URL> ~/.openclaw/backups/GITS
```

`<TEMPLATE_URL>` is the URL that led you to these instructions (e.g. `https://github.com/bayanimills/GITS-GhostInTheShell`).

Then point the remote at the user's backup repo:

```bash
git -C ~/.openclaw/backups/GITS remote set-url origin <BACKUP_REPO_URL>
```

`<BACKUP_REPO_URL>` is the URL from Step 1.

## Step 6: Run setup

```bash
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>
```

Substitute the actual PAT into `GITS_PAT`. Do **not** echo or log it.

If setup fails, stop and report the error. Do not continue.

## Step 7: First backup

```bash
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

Verify: look for `"Successfully pushed to remote"` in output.

Tell the user:
- Backups run automatically at chosen frequency
- Local snapshots kept for chosen retention period
- Older snapshots pruned locally, preserved in GitHub git history

---

## Restoring on a New / Blank Machine

This is the pathway when OpenClaw is freshly installed and you need to restore from a GITS backup.

### One-liner for your LLM

After OpenClaw is installed on the new machine, give your AI agent this prompt:

```
Restore my OpenClaw from GITS backup: clone https://github.com/<OWNER>/<BACKUP-REPO> using PAT, run scripts/gits-restore.sh, restart the gateway, then re-establish automated backups following https://github.com/bayanimills/GITS-GhostInTheShell/blob/main/SETUP.md
```

The agent will ask for your PAT, clone the backup repo, restore everything, and set up scheduled backups on the new machine.

### Manual restore steps

```bash
# 1. Clone the backup repo (contains your snapshots)
git clone https://<PAT>@github.com/<OWNER>/<BACKUP-REPO>.git ~/.openclaw/backups/GITS

# 2. Restore everything from the latest snapshot
~/.openclaw/backups/GITS/scripts/gits-restore.sh

# 3. Restart the gateway to pick up restored config
sudo systemctl restart openclaw-gateway

# 4. Re-establish automated backups on this machine
GITS_PAT='<PAT>' ~/.openclaw/backups/GITS/scripts/gits-setup.sh <FREQUENCY> <RETENTION>

# 5. Verify with a test backup
~/.openclaw/backups/GITS/scripts/gits-backup.sh
```

Without step 4, the new machine will NOT push backups to GitHub.

### Selective restore

```bash
gits-restore.sh --list                             # list snapshots
gits-restore.sh --contents agents                  # list items in component
gits-restore.sh --component agents                 # restore whole component
gits-restore.sh --component agents --item agentname    # restore single item
gits-restore.sh --from 2026-03-22_1430             # from specific snapshot
```
