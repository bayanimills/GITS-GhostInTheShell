# AgentBoxGITS – Full System Snapshot Backup (AI‑First Documentation)

## 🎯 Purpose – For AI Agents
This repository enables **complete disaster recovery** of an OpenClaw agent system. As an AI agent, you will use this repository to restore the system when:
- The host machine fails or is replaced
- OpenClaw configuration is corrupted or accidentally deleted
- You need to migrate agents to a new environment
- A fresh installation requires rapid agent bootstrap

## 📁 Repository Structure (AI‑Parsable)
```
AgentBoxGITS/
├── README.md                # This file – AI restoration instructions
├── config/                  # System configuration files
│   ├── openclaw.json       # Main OpenClaw configuration
│   ├── agents.list         # Agent definitions and permissions
│   └── cron/jobs.json      # Scheduled cron jobs
├── workspaces/             # Compressed agent workspace tarballs
│   ├── workspace-aria-YYYY-MM-DD.tar.gz
│   ├── workspace-shelley-YYYY-MM-DD.tar.gz
│   └── … (all other agents)
├── credentials/            # Credential backups (plaintext per user decision)
├── scripts/                # Restoration automation
│   ├── agentbox-restore.sh # Primary restoration script
│   └── agentbox-backup.sh  # Backup creation script (reference)
└── logs/                   # Backup execution logs (for debugging)
```

## 🤖 AI AGENT RESTORATION PROTOCOL

### **Phase 1: Pre‑Restoration Validation**
**Objective**: Ensure the backup repository is intact and suitable for restoration.

#### **Step 1.1 – Repository Integrity Check**
```bash
# 1. Verify repository exists and is accessible
cd /home/agent/.openclaw/backups/AgentBoxGITS 2>/dev/null || { echo "ERROR: Repository not found"; exit 1; }

# 2. Validate critical directories exist
REQUIRED_DIRS=("config" "workspaces" "scripts")
for dir in "${REQUIRED_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "ERROR: Missing required directory: $dir"
        exit 1
    fi
done

# 3. Check for at least one workspace tarball
WS_COUNT=$(ls workspaces/*.tar.gz 2>/dev/null | wc -l)
if [ "$WS_COUNT" -eq 0 ]; then
    echo "WARNING: No workspace tarballs found – partial restore only"
fi
```

#### **Step 1.2 – Determine Restoration Target**
```bash
# Identify latest backup date (for automatic selection)
LATEST_DATE=$(ls -1 workspaces/workspace-*.tar.gz 2>/dev/null | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | sort -r | head -1)

# If no date found, use today's date (fallback)
if [ -z "$LATEST_DATE" ]; then
    LATEST_DATE=$(date '+%Y-%m-%d')
    echo "INFO: No dated tarballs found, using fallback: $LATEST_DATE"
fi

echo "Selected restoration date: $LATEST_DATE"
```

### **Phase 2: Restoration Execution**
**Objective**: Run the restoration script with appropriate parameters and monitoring.

#### **Step 2.1 – Execute Primary Restoration Script**
```bash
# Navigate to repository root
cd /home/agent/.openclaw/backups/AgentBoxGITS

# Execute restoration with logging
./scripts/agentbox-restore.sh 2>&1 | tee /tmp/agentbox-restore-$(date +%Y%m%d-%H%M%S).log

# Capture exit code
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

### **Phase 3: Post‑Restoration Verification**
**Objective**: Confirm the restored system is operational and agents can function.

#### **Step 3.1 – Basic System Checks**
```bash
# 1. Verify OpenClaw directory structure
OPENCLAW_ROOT="$HOME/.openclaw"
REQUIRED_PATHS=("$OPENCLAW_ROOT" "$OPENCLAW_ROOT/config.yaml" "$OPENCLAW_ROOT/agents.list")

for path in "${REQUIRED_PATHS[@]}"; do
    if [ ! -e "$path" ]; then
        echo "WARNING: Missing restored file: $path"
    fi
done

# 2. Check agent workspaces were extracted
AGENT_COUNT=$(ls -d $OPENCLAW_ROOT/workspace-* 2>/dev/null | wc -l)
echo "Extracted $AGENT_COUNT agent workspace(s)"
```

#### **Step 3.2 – Gateway Startup Test**
```bash
# 1. Attempt to restart OpenClaw gateway
sudo systemctl restart openclaw-gateway 2>/dev/null || \
    openclaw gateway restart 2>/dev/null || \
    echo "WARNING: Could not restart gateway – may need manual intervention"

# 2. Verify gateway responds
sleep 5
if curl -s http://localhost:18789/status 2>/dev/null | grep -q '"status":"ok"'; then
    echo "SUCCESS: Gateway is responding"
    GATEWAY_OK=true
else
    echo "WARNING: Gateway may not be running – check logs"
    GATEWAY_OK=false
fi
```

#### **Step 3.3 – Agent Session Validation**
```bash
# Test agent connectivity (main agent)
openclaw sessions list --limit 1 2>/dev/null && echo "Agent session check passed" || echo "Agent session check failed"

# If gateway is up, spawn a test session
if [ "$GATEWAY_OK" = true ]; then
    TEST_SESSION=$(openclaw sessions spawn --agent main --task "echo 'Test successful'" --label "restore-test" 2>/dev/null | grep -o 'sessionKey=[^ ]*')
    if [ -n "$TEST_SESSION" ]; then
        echo "SUCCESS: Test session created: $TEST_SESSION"
    fi
fi
```

### **Phase 4: Error Handling & Recovery**
**Objective**: Handle restoration failures gracefully with clear recovery paths.

#### **Scenario A: Partial Restoration (Some Agents Missing)**
```
CONDITION: Workspace tarballs for specific agents are missing
ACTION:
  1. Log which agents are missing
  2. Continue with available agents
  3. Notify user that manual agent recreation may be needed
  4. Suggest using older backup if critical agent missing
```

#### **Scenario B: Configuration Version Mismatch**
```
CONDITION: Restored config.yaml incompatible with current OpenClaw version
ACTION:
  1. Backup current config before restoration
  2. Attempt to merge critical settings
  3. Fall back to default config with restored agent workspaces
  4. Document manual configuration steps required
```

#### **Scenario C: Credential Authentication Failures**
```
CONDITION: Restored credentials don't work (expired tokens, changed passwords)
ACTION:
  1. Identify which credentials failed (telegram, github, etc.)
  2. Guide user through re‑authentication for each service
  3. Update credentials directory with new tokens
  4. Test each service connection
```

### **Phase 5: Reporting & Documentation**
**Objective**: Create a restoration report for the user and update system memory.

#### **Step 5.1 – Generate Restoration Report**
```bash
# Create a summary report
REPORT_FILE="/tmp/agentbox-restore-report-$(date +%Y%m%d-%H%M%S).md"
cat > "$REPORT_FILE" << EOF
# AgentBoxGITS Restoration Report
- **Date**: $(date)
- **Restoration Source**: $LATEST_DATE
- **Agents Restored**: $(ls -d $OPENCLAW_ROOT/workspace-* 2>/dev/null | wc -l)
- **Gateway Status**: $(if [ "$GATEWAY_OK" = true ]; then echo "Operational"; else echo "Issues Detected"; fi)
- **Critical Issues**: $(grep -c "ERROR\|FAILED" /tmp/agentbox-restore*.log 2>/dev/null || echo 0)

## Next Steps
1. Review agent‑specific configurations
2. Test scheduled cron jobs
3. Verify external service connections (Telegram, GitHub, etc.)
4. Monitor system for 24 hours

## Files Restored
$(find $OPENCLAW_ROOT -type f -name "*.json" -o -name "*.yaml" -o -name "*.list" | head -20)
EOF

echo "Restoration report saved: $REPORT_FILE"
```

#### **Step 5.2 – Update System Memory**
```bash
# Append restoration event to daily memory file
MEMORY_FILE="$HOME/.openclaw/workspace/memory/$(date +%Y-%m-%d).md"
if [ -f "$MEMORY_FILE" ]; then
    cat >> "$MEMORY_FILE" << EOF

## AgentBoxGITS Restoration Executed ($(date +%H:%M %Z))
- **Source Backup**: $LATEST_DATE
- **Agents Restored**: $(ls -d $OPENCLAW_ROOT/workspace-* 2>/dev/null | wc -l)
- **Gateway Status**: $(if [ "$GATEWAY_OK" = true ]; then echo "✅ Operational"; else echo "⚠️ Issues"; fi)
- **Tags**: #disaster‑recovery #system‑restore #agentboxgits
EOF
fi
```

## 🔄 Maintenance Instructions for AI Agents

### **Regular Verification (Weekly)**
```bash
# 1. Check backup repository is up‑to‑date
cd /home/agent/.openclaw/backups/AgentBoxGITS
git fetch origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "WARNING: Local backup repository not synchronized with remote"
    git pull origin main
fi

# 2. Verify latest backup integrity
LATEST_TARBALL=$(ls -t workspaces/*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST_TARBALL" ]; then
    if tar -tzf "$LATEST_TARBALL" >/dev/null 2>&1; then
        echo "SUCCESS: Latest tarball integrity verified"
    else
        echo "ERROR: Latest tarball corrupted – investigate backup process"
    fi
fi
```

### **Prune Local Tarballs (Automated)**
```bash
# Keep only last 7 days of tarballs locally (git history preserves all)
find workspaces -name "*.tar.gz" -mtime +7 -delete 2>/dev/null
echo "Pruned tarballs older than 7 days"
```

## 🧠 Reasoning Framework for Restoration Decisions

### **Five Critical Questions Before Restoration**
1. **Trigger Verification**: What event necessitates restoration? (system failure, migration, corruption)
2. **Precondition Check**: Does the target system meet requirements? (disk space, OpenClaw installed, network)
3. **Evidence Requirement**: How do we know this backup is valid? (integrity check, recent timestamp)
4. **Boundary Analysis**: What will be affected? (existing configurations, running agents, cron jobs)
5. **Failure Planning**: What if restoration fails? (fallback to previous state, partial restore, manual recovery)

### **Restoration Decision Matrix**
| Condition | Recommended Action |
|-----------|-------------------|
| **Complete system failure** | Full restoration from latest backup |
| **Single agent corruption** | Restore only that agent's workspace |
| **Configuration issue only** | Restore config/ directory only |
| **Credentials expired** | Restore structure, then manual re‑auth |
| **Version mismatch** | Restore workspaces, merge config manually |

## 📊 Monitoring & Alerting

### **Post‑Restoration Monitoring Checklist**
- [ ] Gateway responds to status requests
- [ ] All defined agents can spawn sessions
- [ ] Cron jobs are scheduled (check `openclaw cron list`)
- [ ] External services connect (Telegram, GitHub, etc.)
- [ ] Memory system is writing daily logs
- [ ] Backup system resumes normal operation

### **Alert Thresholds**
- **Warning**: Restoration took > 10 minutes
- **Error**: > 50% of agents failed to restore
- **Critical**: Gateway unable to start after restoration
- **Security**: Credentials restoration attempted (requires manual verification)

---

## 🚨 Emergency Recovery Quick Reference

### **If Restoration Script Fails:**
```bash
# Manual restoration steps
1. cd /home/agent/.openclaw/backups/AgentBoxGITS
2. cp config/* ~/.openclaw/
3. for TAR in workspaces/workspace-*-$LATEST_DATE.tar.gz; do
     AGENT=$(basename "$TAR" | cut -d'-' -f2)
     tar -xzf "$TAR" -C ~/.openclaw/
   done
4. sudo systemctl restart openclaw-gateway
```

### **If Gateway Won't Start:**
```bash
# Diagnostic commands
openclaw gateway status
journalctl -u openclaw-gateway -n 50
tail -100 ~/.openclaw/logs/gateway.log
```

### **Contact for Support**
- **Primary**: User (Bayani) via Telegram
- **Secondary**: OpenClaw community (Discord)
- **Documentation**: docs.openclaw.ai
- **Backup Repository**: github.com/bayanimills/AgentBoxGITS

---

**Documentation Version**: 1.0 (AI‑First Edition)  
**Last Updated**: 2026‑02‑24  
**Designed For**: OpenClaw AI Agents performing disaster recovery  
**Maintenance**: Update this file when restoration protocols change  
**Tags**: #ai‑first‑docs #disaster‑recovery #agentboxgits #restoration‑protocol