#!/usr/bin/env bash
set -euo pipefail

# GITS Setup Script
# Configures this repo for automated backups to GitHub.
# Requires a GitHub PAT with 'repo' scope.
#
# Usage: ./scripts/gits-setup.sh <GITHUB_PAT>

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

# --- Step 1: Require PAT argument ---

PAT="${1:-}"

if [ -z "$PAT" ]; then
    cat <<'EOF'
GITS setup requires a GitHub Personal Access Token (PAT).

1. Go to: https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Select the "repo" scope (full control of private repositories)
4. Copy the token

Then run:
  ./scripts/gits-setup.sh <YOUR_PAT>

EOF
    die "No PAT provided. Cannot proceed without GitHub authentication."
fi

# --- Step 2: Validate PAT format ---

if [[ ! "$PAT" =~ ^gh[ps]_ ]] && [[ ! "$PAT" =~ ^github_pat_ ]]; then
    die "Invalid PAT format. GitHub PATs start with 'ghp_', 'ghs_', or 'github_pat_'. Got: ${PAT:0:10}..."
fi

log_message "PAT format looks valid."

# --- Step 3: Detect repo owner from current remote ---

CURRENT_URL=$(git -C "$BACKUP_ROOT" remote get-url origin 2>/dev/null) || die "No git remote 'origin' configured"

# Extract owner/repo from various URL formats
if [[ "$CURRENT_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
else
    die "Cannot parse GitHub owner/repo from remote URL: $CURRENT_URL"
fi

log_message "Detected repo: $OWNER/$REPO"

# --- Step 4: Validate PAT against GitHub API ---

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

# --- Step 5: Configure remote with PAT ---

NEW_URL="https://${PAT}@github.com/${OWNER}/${REPO}.git"
git -C "$BACKUP_ROOT" remote set-url origin "$NEW_URL"
log_message "Remote URL updated with PAT."

# --- Step 6: Verify git push access ---

log_message "Verifying git push access..."
if ! git -C "$BACKUP_ROOT" ls-remote origin >/dev/null 2>&1; then
    die "git ls-remote failed. PAT may not have push access."
fi
log_message "Push access confirmed."

# --- Step 7: Verify OpenClaw is installed ---

if [ ! -d "$OPENCLAW_ROOT" ]; then
    die "OpenClaw directory not found at $OPENCLAW_ROOT. Install OpenClaw first."
fi

if [ ! -f "$OPENCLAW_ROOT/openclaw.json" ]; then
    log_message "WARNING: openclaw.json not found — OpenClaw may not be fully configured."
fi

log_message "OpenClaw directory found at $OPENCLAW_ROOT"

# --- Step 8: Configure git for non-interactive use ---

git -C "$BACKUP_ROOT" config credential.helper store
git -C "$BACKUP_ROOT" config user.name "GITS Backup" 2>/dev/null || true
git -C "$BACKUP_ROOT" config user.email "gits-backup@localhost" 2>/dev/null || true

log_message "Git configured for non-interactive use."

# --- Done ---

cat <<EOF

=== GITS Setup Complete ===

  Repository:  $OWNER/$REPO
  PAT:         ${PAT:0:10}...${PAT: -4} (validated)
  Backup from: $OPENCLAW_ROOT
  Backup to:   $BACKUP_ROOT/snapshots/

Next steps:

  1. Run the first snapshot:
     $BACKUP_ROOT/scripts/agentbox-backup.sh

  2. Schedule snapshots every 3 hours:
     (crontab -l 2>/dev/null; echo "0 */3 * * * $BACKUP_ROOT/scripts/agentbox-backup.sh >> /tmp/agentbox-backup.log 2>&1") | crontab -

EOF
