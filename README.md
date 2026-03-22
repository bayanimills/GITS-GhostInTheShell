# AgentBoxGITS – Full System Snapshot Backup (AI‑First Documentation)

## Purpose
This repository enables **complete disaster recovery** of an OpenClaw agent system. Use it when:
- The host machine fails or is replaced
- OpenClaw configuration is corrupted or accidentally deleted
- You need to migrate agents to a new environment
- A fresh installation requires rapid agent bootstrap

## Prerequisites
- **OS**: Linux (tested on Ubuntu/Debian)
- **Tools**: `bash` (4.0+), `tar`, `git`, `curl` (for gateway verification)
- **OpenClaw**: Must be installed at `$HOME/.openclaw` (the restore script will create this directory if missing)
- **Disk space**: At least 2x the size of the `workspaces/` directory

## Quick Start – Restore in 3 Steps

```bash
# 1. Clone the backup repository (skip if already present)
git clone https://github.com/bayanimills/AgentBoxGITS.git
cd AgentBoxGITS

# 2. Run the restore script (auto-detects latest backup date)
./scripts/agentbox-restore.sh

# 3. Restart the gateway
sudo systemctl restart openclaw-gateway
```

The restore script will:
- Detect the most recent backup date from workspace tarballs
- Copy configuration files to `$HOME/.openclaw/`
- Extract all workspace tarballs for that date
- Restore credentials (if a matching backup exists)
- Validate the restoration and print next steps

If any step fails, check the log at `/tmp/agentbox-restore.log`.

## Repository Structure
```
AgentBoxGITS/
├── README.md                # This file – restoration instructions
├── config/                  # System configuration files
│   ├── openclaw.json       # Main OpenClaw configuration
│   ├── agents.list         # Agent definitions and permissions
│   └── jobs.json           # Scheduled cron jobs
├── workspaces/             # Compressed agent workspace tarballs
│   ├── workspace-aria-YYYY-MM-DD.tar.gz
│   ├── workspace-shelley-YYYY-MM-DD.tar.gz
│   └── … (all other agents)
├── credentials/            # Credential backups (encrypted tarballs)
├── scripts/                # Restoration automation
│   ├── agentbox-restore.sh # Primary restoration script
│   └── agentbox-backup.sh  # Backup creation script (reference)
└── logs/                   # Backup execution logs (for debugging)
```

## Detailed Restoration Protocol

### Phase 1: Pre‑Restoration Validation

Run the restore script with `--dry-run` to validate the backup before making changes, or perform manual checks:

```bash
cd /path/to/AgentBoxGITS

# Validate critical directories exist
for dir in config workspaces scripts; do
    [ -d "$dir" ] && echo "OK: $dir" || echo "MISSING: $dir"
done

# Check available backup dates
ls workspaces/workspace-*.tar.gz | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u
```

### Phase 2: Restoration Execution

```bash
cd /path/to/AgentBoxGITS

# Execute restoration with logging
./scripts/agentbox-restore.sh 2>&1 | tee /tmp/agentbox-restore-$(date +%Y%m%d-%H%M%S).log
RESTORE_EXIT=$?
```

#### **Step 2.2 – Interpret Exit Codes**
| Exit Code | Meaning | AI Action Required |
|-----------|---------|-------------------|
| **0** | Success | Proceed to Phase 3 (Verification) |
| **1** | Prerequisite failure | Check system dependencies, retry |
| **2** | Configuration error | Validate config files, manual fix may be needed |
| **3** | Workspace extraction failure | Check disk space, tarball integrity |
| **4** | Credential restoration issue | Review credentials directory, may need manual auth |
| **>4** | Unknown error | Examine log file, consider partial restore |

### Phase 3: Post‑Restoration Verification

Run these checks as a single script block so variables persist:

```bash
#!/usr/bin/env bash
OPENCLAW_ROOT="$HOME/.openclaw"

# 1. Verify critical files were restored
for path in "$OPENCLAW_ROOT/openclaw.json" "$OPENCLAW_ROOT/agents.list"; do
    [ -f "$path" ] && echo "OK: $path" || echo "MISSING: $path"
done

# 2. Count restored workspaces
AGENT_COUNT=$(ls -d "$OPENCLAW_ROOT"/workspace-* 2>/dev/null | wc -l)
echo "Restored $AGENT_COUNT agent workspace(s)"

# 3. Restart and verify gateway
sudo systemctl restart openclaw-gateway 2>/dev/null || \
    openclaw gateway restart 2>/dev/null || \
    echo "WARNING: Could not restart gateway – may need manual intervention"

sleep 5
if curl -s http://localhost:18789/status 2>/dev/null | grep -q '"status":"ok"'; then
    echo "SUCCESS: Gateway is responding"
else
    echo "WARNING: Gateway may not be running – check: journalctl -u openclaw-gateway -n 50"
fi

# 4. Test agent session
openclaw sessions list --limit 1 2>/dev/null && echo "Agent session check passed" || echo "Agent session check failed"
```

### Phase 4: Error Handling & Recovery

| Scenario | Symptoms | Resolution |
|----------|----------|------------|
| **Some agents missing** | Workspace tarballs absent for specific agents | Restore continues with available agents. Check older backup dates or recreate the agent manually. |
| **Config version mismatch** | Gateway fails to start after restore | Back up current config, restore workspaces only, merge config settings manually. |
| **Credentials expired** | Telegram bots / API calls fail post-restore | Re-authenticate each service. Restored credential files may contain stale tokens. |
| **Disk space** | Extraction fails mid-way | Free space, then re-run the restore script (it's idempotent). |

## Maintenance

### Weekly Verification
```bash
cd /path/to/AgentBoxGITS
git pull origin main

# Verify latest tarball is not corrupted
LATEST_TARBALL=$(ls -t workspaces/*.tar.gz 2>/dev/null | head -1)
tar -tzf "$LATEST_TARBALL" >/dev/null 2>&1 && echo "OK" || echo "CORRUPTED: $LATEST_TARBALL"
```

### Pruning (automated by backup script)
The backup script (`agentbox-backup.sh`) retains 7 days of tarballs locally. Git history preserves all prior versions.

## Post‑Restoration Checklist
- [ ] Gateway responds: `curl -s http://localhost:18789/status`
- [ ] Agents can spawn sessions: `openclaw sessions list --limit 1`
- [ ] Cron jobs scheduled: `openclaw cron list`
- [ ] Telegram bots responding
- [ ] Backup cron job resumes (check `crontab -l`)

---

## Emergency Recovery (Manual)

If the restore script itself fails, do it by hand:

```bash
cd /path/to/AgentBoxGITS

# Pick the latest backup date
LATEST_DATE=$(ls workspaces/workspace-*.tar.gz | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -ru | head -1)

# Restore configs
mkdir -p ~/.openclaw/cron
cp config/openclaw.json ~/.openclaw/
cp config/agents.list ~/.openclaw/
cp config/jobs.json ~/.openclaw/cron/jobs.json

# Restore workspaces
for TAR in workspaces/workspace-*-"$LATEST_DATE".tar.gz; do
    tar -xzf "$TAR" -C ~/.openclaw/
done

# Restore credentials
tar -xzf credentials/credentials-"$LATEST_DATE".tar.gz -C ~/.openclaw/

# Restart
sudo systemctl restart openclaw-gateway
```

### Gateway Won't Start?
```bash
openclaw gateway status
journalctl -u openclaw-gateway -n 50
tail -100 ~/.openclaw/logs/gateway.log
```

## Contact
- **Primary**: Bayani via Telegram
- **OpenClaw community**: Discord
- **Docs**: docs.openclaw.ai
- **This repo**: github.com/bayanimills/AgentBoxGITS

---

**Last Updated**: 2026-03-22