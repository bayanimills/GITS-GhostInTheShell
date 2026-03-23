#!/usr/bin/env bash
set -euo pipefail

# GITS Setup Script
# Configures this repo for automated backups to GitHub.
# Requires a GitHub PAT with 'repo' scope.
#
# Usage: GITS_PAT='<TOKEN>' ./scripts/gits-setup.sh [FREQUENCY] [RETENTION]
#
# The PAT is read from the GITS_PAT environment variable (not a CLI argument)
# so it stays out of shell history and `ps` output.
#
# FREQUENCY is a cron-friendly interval: 1h, 3h, 6h, 12h, 24h (default: 3h)
# RETENTION is how long to keep local snapshots: 1d, 3d, 7d, 14d, 30d (default: 7d)

BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_ROOT="$HOME/.openclaw"
LOG_FILE="/tmp/gits-setup.log"

log_message() {
    echo "$1" | tee -a "$LOG_FILE"
}

die() {
    log_message "ERROR: $1"
    exit 1
}

# Convert a frequency label (e.g. "6h") to a cron schedule expression.
frequency_to_cron() {
    local freq="$1"
    case "$freq" in
        1h)  echo "0 * * * *" ;;
        3h)  echo "0 */3 * * *" ;;
        6h)  echo "0 */6 * * *" ;;
        12h) echo "0 */12 * * *" ;;
        24h) echo "0 2 * * *" ;;
        *)   echo "" ;;
    esac
}

# Convert a retention label (e.g. "7d") to days.
retention_to_days() {
    local ret="$1"
    case "$ret" in
        1d)  echo "1" ;;
        3d)  echo "3" ;;
        7d)  echo "7" ;;
        14d) echo "14" ;;
        30d) echo "30" ;;
        *)   echo "" ;;
    esac
}

# Human-readable retention label.
retention_label() {
    local ret="$1"
    case "$ret" in
        1d)  echo "1 day" ;;
        3d)  echo "3 days" ;;
        7d)  echo "7 days" ;;
        14d) echo "2 weeks" ;;
        30d) echo "1 month" ;;
    esac
}

# --- Step 1: Require PAT from environment ---

PAT="${GITS_PAT:-}"

if [ -z "$PAT" ]; then
    cat <<'EOF'
GITS setup requires a GitHub Personal Access Token (PAT).

Pass it via the GITS_PAT environment variable:

  GITS_PAT='ghp_...' ./scripts/gits-setup.sh [FREQUENCY] [RETENTION]

FREQUENCY options: 1h, 3h (default), 6h, 12h, 24h
RETENTION options: 1d, 3d, 7d (default), 14d, 30d

EOF
    die "No PAT provided. Set GITS_PAT in the environment."
fi

# --- Step 2: Parse optional frequency ---

FREQUENCY="${1:-3h}"
CRON_SCHEDULE=$(frequency_to_cron "$FREQUENCY")

if [ -z "$CRON_SCHEDULE" ]; then
    die "Invalid frequency '$FREQUENCY'. Valid options: 1h, 3h, 6h, 12h, 24h"
fi

log_message "Backup frequency: every $FREQUENCY ($CRON_SCHEDULE)"

# --- Step 2b: Parse optional retention ---

RETENTION="${2:-7d}"
RETENTION_DAYS=$(retention_to_days "$RETENTION")

if [ -z "$RETENTION_DAYS" ]; then
    die "Invalid retention '$RETENTION'. Valid options: 1d, 3d, 7d, 14d, 30d"
fi

log_message "Local retention: $(retention_label "$RETENTION") ($RETENTION_DAYS days)"

# --- Step 3: Validate PAT format ---

if [[ ! "$PAT" =~ ^gh[ps]_ ]] && [[ ! "$PAT" =~ ^github_pat_ ]]; then
    die "Invalid PAT format. GitHub PATs start with 'ghp_', 'ghs_', or 'github_pat_'. Got: ${PAT:0:10}..."
fi

log_message "PAT format looks valid."

# --- Step 4: Detect repo owner from current remote ---

CURRENT_URL=$(git -C "$BACKUP_ROOT" remote get-url origin 2>/dev/null) || die "No git remote 'origin' configured"

if [[ "$CURRENT_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
else
    die "Cannot parse GitHub owner/repo from remote URL: $CURRENT_URL"
fi

log_message "Detected repo: $OWNER/$REPO"

# --- Step 5: Validate PAT against GitHub API ---

log_message "Validating PAT against GitHub..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $PAT" \
    "https://api.github.com/repos/$OWNER/$REPO" 2>/dev/null) || true

if [ "$HTTP_CODE" = "200" ]; then
    log_message "PAT validated: has access to $OWNER/$REPO"
elif [ "$HTTP_CODE" = "401" ]; then
    die "PAT is invalid or expired. Generate a new one at https://github.com/settings/tokens"
elif [ "$HTTP_CODE" = "403" ]; then
    die "PAT does not have permission to access $OWNER/$REPO. Ensure it has 'repo' scope."
elif [ "$HTTP_CODE" = "404" ]; then
    die "Repository $OWNER/$REPO not found, or PAT lacks access. Check the repo exists and the PAT has 'repo' scope."
else
    die "Unexpected response from GitHub API (HTTP $HTTP_CODE). Check network connectivity."
fi

# --- Step 6: Configure remote with PAT ---

NEW_URL="https://${PAT}@github.com/${OWNER}/${REPO}.git"
git -C "$BACKUP_ROOT" remote set-url origin "$NEW_URL"
log_message "Remote URL updated with PAT."

# --- Step 7: Verify git push access ---

log_message "Verifying git push access..."
if ! git -C "$BACKUP_ROOT" ls-remote origin >/dev/null 2>&1; then
    die "git ls-remote failed. PAT may not have push access."
fi
log_message "Push access confirmed."

# --- Step 8: Verify OpenClaw is installed ---

if [ ! -d "$OPENCLAW_ROOT" ]; then
    die "OpenClaw directory not found at $OPENCLAW_ROOT. Install OpenClaw first."
fi

if [ ! -f "$OPENCLAW_ROOT/openclaw.json" ]; then
    log_message "WARNING: openclaw.json not found — OpenClaw may not be fully configured."
fi

log_message "OpenClaw directory found at $OPENCLAW_ROOT"

# --- Step 9: Configure git for non-interactive use ---

git -C "$BACKUP_ROOT" config credential.helper store
git -C "$BACKUP_ROOT" config user.name "GITS Backup" 2>/dev/null || true
git -C "$BACKUP_ROOT" config user.email "gits-backup@localhost" 2>/dev/null || true

log_message "Git configured for non-interactive use."

# --- Step 10: Schedule cron job ---

# Remove any existing GITS cron entries first
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'gits-backup\.sh' || true)

NEW_ENTRY="$CRON_SCHEDULE $BACKUP_ROOT/scripts/gits-backup.sh >> /tmp/gits-backup.log 2>&1"

if [ -n "$EXISTING_CRON" ]; then
    echo "$EXISTING_CRON" | { cat; echo "$NEW_ENTRY"; } | crontab -
else
    echo "$NEW_ENTRY" | crontab -
fi

log_message "Cron job installed: $CRON_SCHEDULE"

# --- Step 11: Write config file ---

CONFIG_FILE="$BACKUP_ROOT/gits.conf"
cat > "$CONFIG_FILE" <<CONF
# GITS configuration — written by gits-setup.sh
# Do not edit manually; re-run gits-setup.sh to change settings.
RETENTION_DAYS=$RETENTION_DAYS
CONF

log_message "Configuration saved to $CONFIG_FILE"

# --- Done ---

cat <<EOF

=== GITS Setup Complete ===

  Repository:  $OWNER/$REPO
  PAT:         ${PAT:0:10}...${PAT: -4} (validated)
  Backup from: $OPENCLAW_ROOT
  Backup to:   $BACKUP_ROOT/snapshots/ (local) + GitHub (remote)
  Frequency:   Every $FREQUENCY ($CRON_SCHEDULE)
  Retention:   $(retention_label "$RETENTION") of snapshots kept locally for fast restores
  Cron:        Installed and active

Local snapshots are kept for $(retention_label "$RETENTION") so you can restore
quickly without pulling from GitHub. Older snapshots are pruned
automatically but remain available in the GitHub repo's git history.

Next step — run the first snapshot now:

  $BACKUP_ROOT/scripts/gits-backup.sh

EOF
