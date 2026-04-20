# Graceful Handoff Framework — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a quota-aware graceful handoff system for Claude Code that detects approaching usage limits, asks user approval in the 90–95% window, hard-stops at 95%+, and writes comprehensive continuation artifacts for a zero-context AI agent.

**Architecture:** Signal injection hybrid — hook scripts detect quota via OAuth endpoint → JSONL burn rate → soft-signal cascade, inject terse signals into conversation, agent executes intelligent handoff with full context. Four hook scripts wrap one portable skill file.

**Tech Stack:** Bash (hook scripts), Markdown (skill file + artifacts), JSON (settings.json, state files), Python3 (JSON parsing in hooks — available on all Claude Code hosts), curl (OAuth endpoint).

**Reference:** `docs/plans/2026-04-20-graceful-handoff-design.md` — read this before starting.

---

## Pre-Implementation: Discover Credentials Structure

Before writing any code, you must discover the actual structure of `~/.claude/.credentials.json` on this machine. The OAuth approach depends on it.

**Step 1: Check if the file exists**
```bash
ls -la ~/.claude/.credentials.json 2>/dev/null || echo "FILE NOT FOUND"
```

**Step 2: If it exists, inspect its structure (keys only — do not log tokens)**
```bash
python3 -c "
import json
with open('$HOME/.claude/.credentials.json') as f:
    d = json.load(f)
def keys_only(obj, depth=0):
    if isinstance(obj, dict):
        for k, v in obj.items():
            print('  ' * depth + str(k) + ': ' + (str(type(v).__name__)))
            if isinstance(v, dict):
                keys_only(v, depth+1)
    elif isinstance(obj, list) and obj:
        print('  ' * depth + '[0]: ...')
keys_only(d)
"
```

**Step 3: Record the token field path** — you will need to update `handoff-lib.sh` Task 2 with the actual field path (e.g., `claudeAiOauth.accessToken` or `access_token`).

**Step 4: Identify your Claude plan tier**
```bash
# Check for plan info in credentials or any claude config
grep -r "plan\|tier\|subscription\|max" ~/.claude/*.json 2>/dev/null | grep -v ".jsonl" | head -20 || echo "no plan info found in config"
```

Record your plan (Pro / Max5 / Max20) — needed for JSONL burn rate calculation. Default assumed: **Max5 (88,000 tokens per 5-hour window)** if not found.

---

## Task 1: Create Shared Hook Library

**Files:**
- Create: `~/.claude/hooks/handoff-lib.sh`
- Create: `~/.claude/hooks/tests/test-handoff-lib.sh`

**Step 1: Write the failing test first**

```bash
cat > ~/.claude/hooks/tests/test-handoff-lib.sh << 'EOF'
#!/usr/bin/env bash
# Tests for handoff-lib.sh — run before implementing to confirm failures

set -uo pipefail
PASS=0; FAIL=0
ok() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

LIB="$HOME/.claude/hooks/handoff-lib.sh"
[[ -f "$LIB" ]] && source "$LIB" || { echo "SKIP: library not found"; exit 0; }

# Test tier_from_pct
[[ "$(tier_from_pct 80)" == "" ]] && ok "80% = no tier" || fail "80% should return empty"
[[ "$(tier_from_pct 86)" == "WARN" ]] && ok "86% = WARN" || fail "86% should be WARN"
[[ "$(tier_from_pct 91)" == "PREPARE" ]] && ok "91% = PREPARE" || fail "91% should be PREPARE"
[[ "$(tier_from_pct 95)" == "STOP" ]] && ok "95% = STOP" || fail "95% should be STOP"
[[ "$(tier_from_pct 98)" == "EMERGENCY" ]] && ok "98% = EMERGENCY" || fail "98% should be EMERGENCY"

# Test write_signal_file / read_signal_tier
TMP_SIGNAL=$(mktemp)
HANDOFF_SIGNAL_FILE="$TMP_SIGNAL" write_signal_file "PREPARE" "92" "oauth"
TIER=$(HANDOFF_SIGNAL_FILE="$TMP_SIGNAL" read_signal_tier)
[[ "$TIER" == "PREPARE" ]] && ok "write/read signal roundtrip" || fail "signal roundtrip: got '$TIER'"
rm -f "$TMP_SIGNAL"

# Test escape_json
RESULT=$(escape_json 'hello "world" \n')
[[ "$RESULT" == 'hello \"world\" \\n' ]] && ok "escape_json basic" || fail "escape_json: got '$RESULT'"

# Test should_check_this_call (counter-based sampling)
TMP_COUNTER=$(mktemp)
# Call 5 should not check
HANDOFF_COUNTER_FILE="$TMP_COUNTER" SESSION_ID="test123" \
  should_check_this_call 5 && fail "call 5 should not check" || ok "call 5 skipped"
# Call 10 should check
HANDOFF_COUNTER_FILE="$TMP_COUNTER" SESSION_ID="test123" \
  should_check_this_call 10 && ok "call 10 checked" || fail "call 10 should check"
rm -f "$TMP_COUNTER"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
EOF
chmod +x ~/.claude/hooks/tests/test-handoff-lib.sh
```

**Step 2: Run test — confirm it skips (library not yet created)**
```bash
bash ~/.claude/hooks/tests/test-handoff-lib.sh
```
Expected output: `SKIP: library not found`

**Step 3: Create `handoff-lib.sh`**

```bash
cat > ~/.claude/hooks/handoff-lib.sh << 'ENDOFLIB'
#!/usr/bin/env bash
# Shared utilities for graceful-handoff hooks — sourced by all 4 hook scripts

# File paths (override via env for testing)
HANDOFF_SIGNAL_FILE="${HANDOFF_SIGNAL_FILE:-$HOME/.claude/.handoff-signal}"
HANDOFF_COUNTER_FILE="${HANDOFF_COUNTER_FILE:-$HOME/.claude/.handoff-counter}"
HANDOFF_CONFIG_FILE="${HANDOFF_CONFIG_FILE:-$HOME/.claude/.handoff-config}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

# Plan token limits per 5-hour window
declare -A PLAN_LIMITS=(
    ["pro"]=19000
    ["max5"]=88000
    ["max20"]=220000
)

# --------------------------------------------------------------------------
# tier_from_pct <percentage>
# Returns WARN/PREPARE/STOP/EMERGENCY or empty string if below threshold.
# --------------------------------------------------------------------------
tier_from_pct() {
    local pct="${1:-0}"
    if (( pct >= 98 )); then echo "EMERGENCY"
    elif (( pct >= 95 )); then echo "STOP"
    elif (( pct >= 90 )); then echo "PREPARE"
    elif (( pct >= 85 )); then echo "WARN"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# write_signal_file <tier> <pct> <source>
# --------------------------------------------------------------------------
write_signal_file() {
    local tier="$1" pct="$2" source="$3"
    cat > "$HANDOFF_SIGNAL_FILE" << EOF
tier=${tier}
quota=${pct}
source=${source}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
session=${SESSION_ID:-unknown}
EOF
}

# --------------------------------------------------------------------------
# read_signal_tier
# Prints the tier from .handoff-signal, or empty if file missing/invalid.
# --------------------------------------------------------------------------
read_signal_tier() {
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

# --------------------------------------------------------------------------
# read_signal_field <field>
# --------------------------------------------------------------------------
read_signal_field() {
    local field="$1"
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep "^${field}=" "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

# --------------------------------------------------------------------------
# should_check_this_call <call_number>
# Returns 0 (true) if this call number should trigger a quota check.
# Checks every 10th call. Also updates the counter file.
# --------------------------------------------------------------------------
should_check_this_call() {
    local call_num="${1:-1}"
    (( call_num % 10 == 0 ))
}

# --------------------------------------------------------------------------
# get_and_increment_call_count
# Reads current count for SESSION_ID, increments, writes back. Prints new count.
# --------------------------------------------------------------------------
get_and_increment_call_count() {
    local sid="${SESSION_ID:-unknown}"
    local count=0
    if [[ -f "$HANDOFF_COUNTER_FILE" ]]; then
        local stored
        stored=$(cat "$HANDOFF_COUNTER_FILE" 2>/dev/null || echo "")
        local stored_sid="${stored%%:*}"
        local stored_count="${stored##*:}"
        if [[ "$stored_sid" == "$sid" ]] && [[ "$stored_count" =~ ^[0-9]+$ ]]; then
            count=$stored_count
        fi
    fi
    count=$(( count + 1 ))
    printf '%s:%d' "$sid" "$count" > "$HANDOFF_COUNTER_FILE"
    echo "$count"
}

# --------------------------------------------------------------------------
# get_quota_oauth
# Returns integer percentage (0-100) or empty string on failure.
# Uses ~/.claude/.credentials.json and the undocumented OAuth usage endpoint.
# NOTE: Endpoint uses anthropic-beta: oauth-2025-04-20 — may change.
# --------------------------------------------------------------------------
get_quota_oauth() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0

    # Extract access token — UPDATE FIELD PATH after running pre-implementation discovery
    local token
    token=$(python3 -c "
import json, sys
try:
    with open('${CREDENTIALS_FILE}') as f:
        d = json.load(f)
    # Try common field paths — update this after credential discovery
    token = (d.get('claudeAiOauth', {}) or {}).get('accessToken') \
         or d.get('access_token') \
         or ''
    print(token.strip())
except Exception as e:
    print('')
" 2>/dev/null || echo "")

    [[ -z "$token" ]] && return 0

    local response
    response=$(curl -sf \
        --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || echo "")

    [[ -z "$response" ]] && return 0

    # Parse five_hour utilization — returns integer 0-100
    python3 -c "
import json, sys
try:
    d = json.loads('''${response}''')
    fh = d.get('five_hour', {})
    if isinstance(fh, dict):
        used = float(fh.get('used', 0))
        limit = float(fh.get('limit', 0))
        if limit > 0:
            print(int(used * 100 / limit))
        elif 'utilization' in fh:
            print(int(float(fh['utilization']) * 100))
        else:
            print('')
    elif isinstance(fh, (int, float)):
        # Already a percentage (0.0-1.0 or 0-100)
        val = float(fh)
        print(int(val * 100) if val <= 1.0 else int(val))
    else:
        print('')
except:
    print('')
" 2>/dev/null || echo ""
}

# --------------------------------------------------------------------------
# get_quota_jsonl
# Sums tokens in ~/.claude/projects/**/*.jsonl for the last 5 hours,
# compares to configured plan limit. Returns integer 0-100 or empty.
# --------------------------------------------------------------------------
get_quota_jsonl() {
    local plan
    plan=$(grep '^plan=' "$HANDOFF_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || echo "max5")
    local limit="${PLAN_LIMITS[$plan]:-88000}"

    python3 -c "
import json, os, glob, time
from datetime import datetime, timezone, timedelta

cutoff = datetime.now(timezone.utc) - timedelta(hours=5)
total = 0
projects_dir = os.path.expanduser('~/.claude/projects')
pattern = os.path.join(projects_dir, '**', '*.jsonl')

for path in glob.glob(pattern, recursive=True):
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except:
                    continue
                ts_str = entry.get('timestamp', '')
                if not ts_str:
                    continue
                try:
                    ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                    if ts < cutoff:
                        continue
                except:
                    continue
                usage = entry.get('message', {}).get('usage', {})
                if not usage:
                    usage = entry.get('usage', {})
                total += (
                    int(usage.get('input_tokens', 0)) +
                    int(usage.get('output_tokens', 0)) +
                    int(usage.get('cache_creation_input_tokens', 0)) +
                    int(usage.get('cache_read_input_tokens', 0))
                )
    except:
        continue

limit = ${limit}
if total > 0 and limit > 0:
    pct = int(total * 100 / limit)
    print(min(pct, 100))
else:
    print('')
" 2>/dev/null || echo ""
}

# --------------------------------------------------------------------------
# get_quota_heuristic <call_count>
# Returns approximate percentage based on tool call count. Always succeeds.
# --------------------------------------------------------------------------
get_quota_heuristic() {
    local count="${1:-0}"
    if (( count >= 80 )); then echo "96"
    elif (( count >= 60 )); then echo "92"
    elif (( count >= 40 )); then echo "87"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# get_quota <call_count>
# Full cascade: OAuth → JSONL → heuristic. Returns integer or empty.
# Also sets QUOTA_SOURCE env var to "oauth", "jsonl", or "heuristic".
# --------------------------------------------------------------------------
get_quota() {
    local count="${1:-0}"
    local pct

    pct=$(get_quota_oauth)
    if [[ -n "$pct" ]] && [[ "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="oauth"
        echo "$pct"
        return 0
    fi

    pct=$(get_quota_jsonl)
    if [[ -n "$pct" ]] && [[ "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="jsonl"
        echo "$pct"
        return 0
    fi

    pct=$(get_quota_heuristic "$count")
    if [[ -n "$pct" ]] && [[ "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="heuristic"
        echo "$pct"
        return 0
    fi

    QUOTA_SOURCE="none"
    echo ""
}

# --------------------------------------------------------------------------
# escape_json <string>
# Escapes a string for safe embedding in a JSON value.
# --------------------------------------------------------------------------
escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --------------------------------------------------------------------------
# emit_context_injection <message>
# Outputs JSON for hookSpecificOutput additionalContext injection.
# --------------------------------------------------------------------------
emit_context_injection() {
    local msg
    msg=$(escape_json "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
        "${HOOK_EVENT_NAME:-PreToolUse}" "$msg"
}

# --------------------------------------------------------------------------
# emit_block <message>
# Outputs block message to stdout. Caller must exit 2.
# --------------------------------------------------------------------------
emit_block() {
    printf '%s' "$1"
}
ENDOFLIB
chmod +x ~/.claude/hooks/handoff-lib.sh
```

**Step 4: Run tests — confirm they pass**
```bash
bash ~/.claude/hooks/tests/test-handoff-lib.sh
```
Expected: `Results: 8 passed, 0 failed`

**Step 5: Commit**
```bash
cd ~/.claude
git add hooks/handoff-lib.sh hooks/tests/test-handoff-lib.sh
git commit -m "feat: add handoff-lib.sh shared utilities with tests"
```

---

## Task 2: Create `pre-tool-use-handoff` Hook

**Files:**
- Create: `~/.claude/hooks/pre-tool-use-handoff`
- Create: `~/.claude/hooks/tests/test-pre-tool-use.sh`

**Step 1: Write the failing test**

```bash
mkdir -p ~/.claude/hooks/tests
cat > ~/.claude/hooks/tests/test-pre-tool-use.sh << 'EOF'
#!/usr/bin/env bash
# Tests for pre-tool-use-handoff

set -uo pipefail
PASS=0; FAIL=0
ok() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

HOOK="$HOME/.claude/hooks/pre-tool-use-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found"; exit 0; }

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

HANDOFF_SIGNAL_FILE="$TMP_DIR/signal"
HANDOFF_COUNTER_FILE="$TMP_DIR/counter"
HANDOFF_CONFIG_FILE="$TMP_DIR/config"
CREDENTIALS_FILE="$TMP_DIR/creds_missing"
export HANDOFF_SIGNAL_FILE HANDOFF_COUNTER_FILE HANDOFF_CONFIG_FILE CREDENTIALS_FILE

fake_input() {
    printf '{"session_id":"test-session","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"
}

# Test 1: Calls 1-9 do not check quota (exit 0, no signal file)
for i in $(seq 1 9); do
    OUTPUT=$(fake_input "Bash" | SESSION_ID="test-session" bash "$HOOK" 2>/dev/null)
    EXIT=$?
    [[ $EXIT -eq 0 ]] || fail "call $i should exit 0"
done
[[ ! -f "$HANDOFF_SIGNAL_FILE" ]] && ok "no signal file before call 10" || fail "signal file should not exist yet"

# Test 2: Call 10 runs check — with no credentials and no JSONL,
#          counter=10 → heuristic returns empty (10 < 40) → no signal, exit 0
OUTPUT=$(fake_input "Bash" | SESSION_ID="test-session" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "call 10 with low count exits 0" || fail "call 10 low count: exit was $EXIT"

# Test 3: Simulate 40 calls → heuristic WARN tier → signal file written, exit 0
echo "test-session:39" > "$HANDOFF_COUNTER_FILE"
OUTPUT=$(fake_input "Bash" | SESSION_ID="test-session" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "WARN tier exits 0" || fail "WARN tier: exit was $EXIT"
[[ -f "$HANDOFF_SIGNAL_FILE" ]] && ok "WARN tier writes signal file" || fail "WARN tier: signal file missing"
TIER=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" 2>/dev/null | cut -d= -f2)
[[ "$TIER" == "WARN" ]] && ok "WARN tier signal is WARN" || fail "WARN signal: got '$TIER'"

# Test 4: Simulate 60 calls → PREPARE tier → injects context, exit 0
rm -f "$HANDOFF_SIGNAL_FILE"
echo "test-session:59" > "$HANDOFF_COUNTER_FILE"
OUTPUT=$(fake_input "Bash" | SESSION_ID="test-session" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PREPARE tier exits 0" || fail "PREPARE tier: exit was $EXIT"
echo "$OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if 'additionalContext' in str(d) else 'fail')" 2>/dev/null | grep -q ok \
    && ok "PREPARE tier outputs additionalContext JSON" \
    || fail "PREPARE tier: no additionalContext in output"

# Test 5: Simulate 80 calls → STOP tier → exit 2 (block)
rm -f "$HANDOFF_SIGNAL_FILE"
echo "test-session:79" > "$HANDOFF_COUNTER_FILE"
OUTPUT=$(fake_input "Bash" | SESSION_ID="test-session" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 2 ]] && ok "STOP tier exits 2 (block)" || fail "STOP tier: exit was $EXIT (expected 2)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
EOF
chmod +x ~/.claude/hooks/tests/test-pre-tool-use.sh
```

**Step 2: Run test — confirm it skips**
```bash
bash ~/.claude/hooks/tests/test-pre-tool-use.sh
```
Expected: `SKIP: hook not found`

**Step 3: Create `pre-tool-use-handoff`**

```bash
cat > ~/.claude/hooks/pre-tool-use-handoff << 'EOF'
#!/usr/bin/env bash
# PreToolUse hook — quota detection, signal injection, and tool blocking
# Fires before every tool call. Checks quota every 10th call only.

set -uo pipefail
source "$HOME/.claude/hooks/handoff-lib.sh"

# Read hook input
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id','unknown'))" 2>/dev/null || echo "unknown")
HOOK_EVENT_NAME="PreToolUse"
export SESSION_ID HOOK_EVENT_NAME

# Increment and check sampling threshold
COUNT=$(get_and_increment_call_count)
should_check_this_call "$COUNT" || exit 0

# Check if signal is already at STOP or EMERGENCY — re-block without re-polling
EXISTING_TIER=$(read_signal_tier)
if [[ "$EXISTING_TIER" == "STOP" || "$EXISTING_TIER" == "EMERGENCY" ]]; then
    EXISTING_PCT=$(read_signal_field "quota")
    emit_block "HANDOFF_SIGNAL: quota=${EXISTING_PCT}% tier=${EXISTING_TIER} — tool call blocked. Write handoff files now."
    exit 2
fi

# Run detection cascade
QUOTA_SOURCE="none"
QUOTA_PCT=$(get_quota "$COUNT")

# No signal below 85%
[[ -z "$QUOTA_PCT" ]] && exit 0
TIER=$(tier_from_pct "$QUOTA_PCT")
[[ -z "$TIER" ]] && exit 0

# Write signal file (always, for all tiers)
write_signal_file "$TIER" "$QUOTA_PCT" "$QUOTA_SOURCE"

# Tier-specific output
case "$TIER" in
    WARN)
        # Silent — agent reads .handoff-signal when starting large tasks
        exit 0
        ;;
    PREPARE)
        emit_context_injection "HANDOFF_SIGNAL: quota=${QUOTA_PCT}% source=${QUOTA_SOURCE} tier=PREPARE"
        exit 0
        ;;
    STOP)
        emit_block "HANDOFF_SIGNAL: quota=${QUOTA_PCT}% tier=STOP — tool call blocked. Stop work and write AI_HANDOFF.md and RESUME_PROMPT.md now."
        exit 2
        ;;
    EMERGENCY)
        emit_block "HANDOFF_SIGNAL: quota=${QUOTA_PCT}% tier=EMERGENCY — CRITICAL. Write RESUME_PROMPT.md FIRST, then AI_HANDOFF.md. No new work."
        exit 2
        ;;
esac
EOF
chmod +x ~/.claude/hooks/pre-tool-use-handoff
```

**Step 4: Run tests — confirm they pass**
```bash
bash ~/.claude/hooks/tests/test-pre-tool-use.sh
```
Expected: `Results: 9 passed, 0 failed`

**Step 5: Commit**
```bash
cd ~/.claude
git add hooks/pre-tool-use-handoff hooks/tests/test-pre-tool-use.sh
git commit -m "feat: add pre-tool-use-handoff hook with detection cascade"
```

---

## Task 3: Create `pre-compact-handoff` Hook

**Files:**
- Create: `~/.claude/hooks/pre-compact-handoff`

**Step 1: Create the hook**

```bash
cat > ~/.claude/hooks/pre-compact-handoff << 'EOF'
#!/usr/bin/env bash
# PreCompact hook — context compaction is an implicit high-quota signal.
# Writes PREPARE signal if no higher tier already set. Injects into context.

set -uo pipefail
source "$HOME/.claude/hooks/handoff-lib.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id','unknown'))" 2>/dev/null || echo "unknown")
HOOK_EVENT_NAME="PreCompact"
export SESSION_ID HOOK_EVENT_NAME

# Don't downgrade an existing STOP or EMERGENCY signal
EXISTING_TIER=$(read_signal_tier)
if [[ "$EXISTING_TIER" == "STOP" || "$EXISTING_TIER" == "EMERGENCY" ]]; then
    exit 0
fi

# Compaction = implicit PREPARE signal
write_signal_file "PREPARE" "90+" "compaction"
emit_context_injection "HANDOFF_SIGNAL: context compaction triggered — tier=PREPARE (implicit). Consider wrapping up current work."
exit 0
EOF
chmod +x ~/.claude/hooks/pre-compact-handoff
```

**Step 2: Smoke test**
```bash
echo '{"session_id":"test","hook_event_name":"PreCompact"}' | \
  HANDOFF_SIGNAL_FILE=/tmp/test-compact-signal \
  bash ~/.claude/hooks/pre-compact-handoff
echo "Exit: $?"
cat /tmp/test-compact-signal 2>/dev/null && rm -f /tmp/test-compact-signal
```
Expected: JSON output with `additionalContext`, exit 0, signal file written with `tier=PREPARE`.

**Step 3: Commit**
```bash
cd ~/.claude
git add hooks/pre-compact-handoff
git commit -m "feat: add pre-compact-handoff hook"
```

---

## Task 4: Create `stop-handoff` Hook

**Files:**
- Create: `~/.claude/hooks/stop-handoff`

This hook appends a git state snapshot to `AI_HANDOFF.md` if a handoff signal exists. On clean sessions with no signal, it does nothing.

**Step 1: Create the hook**

```bash
cat > ~/.claude/hooks/stop-handoff << 'EOF'
#!/usr/bin/env bash
# Stop hook — on clean exit, appends git snapshot to AI_HANDOFF.md if signal exists.
# Does NOTHING on clean sessions (no signal file) — zero cost.

set -uo pipefail
source "$HOME/.claude/hooks/handoff-lib.sh"

INPUT=$(cat)

TIER=$(read_signal_tier)
[[ -z "$TIER" ]] && exit 0   # No signal — clean session, nothing to do

CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd','.'))" 2>/dev/null || echo ".")
cd "$CWD" 2>/dev/null || true

HANDOFF_FILE="${CWD}/AI_HANDOFF.md"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build git snapshot section
GIT_SECTION=""
if git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_STATUS=$(git status --porcelain 2>/dev/null || echo "(git status unavailable)")
    GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "(no diff)")
    GIT_LOG=$(git log --oneline -10 2>/dev/null || echo "(no log)")
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    GIT_SECTION=$(cat << GITSECTION

## Git Snapshot (appended by stop-handoff hook — ${TIMESTAMP})
**Branch:** ${GIT_BRANCH}

### Working Tree Status
\`\`\`
${GIT_STATUS:-nothing to report}
\`\`\`

### Diff Summary
\`\`\`
${GIT_DIFF_STAT:-no uncommitted changes}
\`\`\`

### Recent Commits
\`\`\`
${GIT_LOG}
\`\`\`
GITSECTION
)
fi

# Append to AI_HANDOFF.md if it exists, otherwise create a minimal one
if [[ -f "$HANDOFF_FILE" ]]; then
    printf '%s\n' "$GIT_SECTION" >> "$HANDOFF_FILE"
else
    # Handoff file missing — agent didn't write it (STOP triggered but agent didn't respond)
    # Create a minimal one from available context
    cat > "$HANDOFF_FILE" << MINIMALEOF
# AI Handoff — ${TIMESTAMP}

## Handoff Metadata
- **Tier:** ${TIER}
- **Source:** stop-hook-only (agent did not write handoff artifacts)
- **Project:** $(basename "$CWD")
- **Warning:** The agent did not complete handoff artifact generation. Git state below is the primary recovery data.
${GIT_SECTION}

## Immediate Next Step
Read git diff carefully and determine what was in progress. Check any files modified in the last session.
MINIMALEOF
fi

# Clean up state files
rm -f "$HANDOFF_SIGNAL_FILE" "$HANDOFF_COUNTER_FILE"
exit 0
EOF
chmod +x ~/.claude/hooks/stop-handoff
```

**Step 2: Smoke test (with signal present)**
```bash
# Set up
echo -e "tier=PREPARE\nquota=91\nsource=oauth" > /tmp/test-stop-signal
mkdir -p /tmp/test-handoff-proj

echo '{"session_id":"test","cwd":"/tmp/test-handoff-proj","hook_event_name":"Stop"}' | \
  HANDOFF_SIGNAL_FILE=/tmp/test-stop-signal \
  bash ~/.claude/hooks/stop-handoff

echo "Exit: $?"
cat /tmp/test-handoff-proj/AI_HANDOFF.md 2>/dev/null | head -20
rm -rf /tmp/test-handoff-proj /tmp/test-stop-signal
```
Expected: Exit 0, `AI_HANDOFF.md` created with git snapshot section.

**Step 3: Smoke test (no signal — should be silent)**
```bash
echo '{"session_id":"test","cwd":"/tmp","hook_event_name":"Stop"}' | \
  HANDOFF_SIGNAL_FILE=/tmp/nonexistent-signal \
  bash ~/.claude/hooks/stop-handoff
echo "Exit: $? (expected 0, no output)"
```

**Step 4: Commit**
```bash
cd ~/.claude
git add hooks/stop-handoff
git commit -m "feat: add stop-handoff hook for git snapshot on clean exit"
```

---

## Task 5: Create `stop-failure-handoff` Hook

**Files:**
- Create: `~/.claude/hooks/stop-failure-handoff`

This fires when the session is cut off by `rate_limit` or `billing_error`. The agent is gone. This hook writes emergency artifacts from git state only.

**Step 1: Create the hook**

```bash
cat > ~/.claude/hooks/stop-failure-handoff << 'EOF'
#!/usr/bin/env bash
# StopFailure hook — fires on rate_limit or billing_error.
# Agent is already dead. Writes emergency artifacts from git state only.
# Artifacts are marked clearly as EMERGENCY / no-agent-context.

set -uo pipefail
source "$HOME/.claude/hooks/handoff-lib.sh"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd','.'))" 2>/dev/null || pwd)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT=$(basename "$CWD")

cd "$CWD" 2>/dev/null || true

HANDOFF_FILE="${CWD}/AI_HANDOFF.md"
RESUME_FILE="${CWD}/RESUME_PROMPT.md"
EXISTING_TIER=$(read_signal_tier)
QUOTA_PCT=$(read_signal_field "quota" || echo "unknown")

# --- Git state collection ---
GIT_BRANCH="unknown"
GIT_STATUS="(not a git repo)"
GIT_DIFF_STAT="(not a git repo)"
GIT_DIFF_FULL="(not a git repo)"
GIT_LOG="(not a git repo)"

if git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    GIT_STATUS=$(git status --porcelain 2>/dev/null || echo "(unavailable)")
    GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "(no uncommitted changes)")
    GIT_DIFF_FULL=$(git diff HEAD 2>/dev/null | head -300 || echo "(no diff)")
    GIT_LOG=$(git log --oneline -15 2>/dev/null || echo "(no log)")
fi

# --- Write AI_HANDOFF.md ---
cat > "${HANDOFF_FILE}.tmp" << HANDOFFEOF
# AI Handoff — ${TIMESTAMP}

## Handoff Metadata
- **Tier:** DEAD (session cutoff — no agent context available)
- **Quota at cutoff:** ${QUOTA_PCT}%
- **Source:** emergency-hook-only (rate_limit or billing_error)
- **Project:** ${PROJECT}
- **Branch:** ${GIT_BRANCH}
- **WARNING:** This file was written by a hook after the session was abruptly cut off.
  The agent did not write this. There is NO conversation context — only git state.
  Treat all in-progress work as UNVERIFIED.

## What To Do First
1. Read this file in full
2. Run \`git status\` and \`git diff HEAD\` to see exact working tree state
3. Cross-reference git diff against recent commits to understand what was in progress
4. Check for any \`AI_HANDOFF.md\` or \`RESUME_PROMPT.md\` that the agent may have partially written

## Git State at Cutoff

### Working Tree Status
\`\`\`
${GIT_STATUS}
\`\`\`

### Diff Summary (files changed vs HEAD)
\`\`\`
${GIT_DIFF_STAT}
\`\`\`

### Full Diff (first 300 lines)
\`\`\`diff
${GIT_DIFF_FULL}
\`\`\`

### Recent Commits
\`\`\`
${GIT_LOG}
\`\`\`

## Recovery Guidance
- Any file shown as **modified** in git status was being worked on at cutoff
- Any file shown as **untracked** was likely newly created and may be incomplete
- Check modified files for obvious truncation (incomplete functions, unclosed blocks)
- Do not assume any in-progress work is correct — verify before using

## Immediate Next Step
Assess the git diff, identify the last coherent change, and determine the minimal
action needed to restore the project to a clean working state before resuming the
original task.
HANDOFFEOF

mv "${HANDOFF_FILE}.tmp" "$HANDOFF_FILE"

# --- Write RESUME_PROMPT.md ---
cat > "${RESUME_FILE}.tmp" << RESUMEEOF
# Resume Prompt — ${PROJECT} — ${TIMESTAMP}

You are resuming an **abruptly interrupted** work session on **${PROJECT}**.
The previous session was cut off at quota exhaustion (${QUOTA_PCT}% usage).
This resume prompt was written automatically with NO agent context — only git state.

## First Actions (mandatory — do not skip)
1. Read \`AI_HANDOFF.md\` in full
2. Run \`git status\` and \`git diff HEAD\` — verify this matches what AI_HANDOFF.md describes
3. Inspect any modified files for truncation or incomplete state
4. Identify the last coherent completed unit of work from git log

## Context
Project: **${PROJECT}** | Branch: **${GIT_BRANCH}**
The session was cut off abruptly. The full task context is NOT available.
You must reconstruct intent from git history and file state.

## Do This First
Read the git diff carefully. Find the most recently modified file.
Determine if it is in a complete, compilable/runnable state.
If not — completing or reverting it is your first task.

## Do NOT Do
- Do not assume any work-in-progress is complete or correct
- Do not commit anything without verifying it compiles/runs/passes tests
- Do not re-do work that git log shows as already committed

## Key Reference Files
- \`AI_HANDOFF.md\`: git state snapshot from the moment of cutoff
- \`git log --oneline -15\`: recent commit history showing progress before cutoff
RESUMEEOF

mv "${RESUME_FILE}.tmp" "$RESUME_FILE"

exit 0
EOF
chmod +x ~/.claude/hooks/stop-failure-handoff
```

**Step 2: Smoke test**
```bash
mkdir -p /tmp/test-stopfail && cd /tmp/test-stopfail && git init -q && git commit --allow-empty -m "init"
echo '{"session_id":"test","cwd":"/tmp/test-stopfail","hook_event_name":"StopFailure","error":"rate_limit"}' | \
  bash ~/.claude/hooks/stop-failure-handoff
echo "Exit: $?"
echo "--- AI_HANDOFF.md ---"
cat /tmp/test-stopfail/AI_HANDOFF.md | head -30
echo "--- RESUME_PROMPT.md ---"
cat /tmp/test-stopfail/RESUME_PROMPT.md | head -20
rm -rf /tmp/test-stopfail
```
Expected: Both files written, exit 0.

**Step 3: Commit**
```bash
cd ~/.claude
git add hooks/stop-failure-handoff
git commit -m "feat: add stop-failure-handoff emergency artifact writer"
```

---

## Task 6: Wire Hooks in `settings.json`

**Files:**
- Modify: `~/.claude/settings.json`

Use the `update-config` skill for this task. Before editing, confirm the current file state:

**Step 1: Verify current settings**
```bash
cat ~/.claude/settings.json
```
Confirm the existing `Stop` entry (calls `notify`) is visible. It must be preserved.

**Step 2: Add the four new hook entries**

The new settings.json must deep-merge the following into the existing structure. The existing `Stop` → `notify` entry must remain. Add new entries alongside it:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-tool-use-handoff",
            "timeout": 8000
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-compact-handoff",
            "timeout": 5000
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/notify",
            "timeout": 5000
          }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-handoff",
            "timeout": 10000
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "matcher": "rate_limit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-failure-handoff",
            "timeout": 15000
          }
        ]
      },
      {
        "matcher": "billing_error",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-failure-handoff",
            "timeout": 15000
          }
        ]
      }
    ]
  }
}
```

**Step 3: Verify the merge preserved all existing entries**
```bash
python3 -c "
import json
with open('$HOME/.claude/settings.json') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
print('SessionStart:', 'present' if 'SessionStart' in hooks else 'MISSING')
print('PostToolUseFailure:', 'present' if 'PostToolUseFailure' in hooks else 'MISSING')
print('Notification:', 'present' if 'Notification' in hooks else 'MISSING')
print('Stop entries:', len(hooks.get('Stop', [])))
print('PreToolUse entries:', len(hooks.get('PreToolUse', [])))
print('PreCompact entries:', len(hooks.get('PreCompact', [])))
print('StopFailure entries:', len(hooks.get('StopFailure', [])))
"
```
Expected:
```
SessionStart: present
PostToolUseFailure: present
Notification: present
Stop entries: 2
PreToolUse entries: 1
PreCompact entries: 1
StopFailure entries: 2
```

**Step 4: Commit**
```bash
cd ~/.claude
git add settings.json
git commit -m "feat: wire graceful-handoff hooks into settings.json"
```

---

## Task 7: Create `graceful-wrap-up.md` Skill File

**Files:**
- Create: `~/.claude/skills/graceful-wrap-up.md`

**Step 1: Create the skill**

```bash
cat > ~/.claude/skills/graceful-wrap-up.md << 'ENDOFSKILL'
---
name: graceful-wrap-up
description: Quota-aware graceful session handoff. Use when entering handoff mode, when quota signals are detected, or to manually wrap up a session and write continuation artifacts.
---

# Graceful Wrap-Up — Agent Behavior Protocol

You are entering handoff mode. Your goal: preserve all session context for a zero-knowledge AI agent that will resume this work.

## Signal Sources — Watch For These

Watch for ANY of these at all times:
- `HANDOFF_SIGNAL:` prefix in injected context (from PreToolUse or PreCompact hook)
- System messages containing usage percentage ≥ 85%
- Manual invocation via `/wrap-up` command

Read `~/.claude/.handoff-signal` if it exists — it contains `tier`, `quota`, `source`.

## Tier Behavior

### WARN (85–90%) — Pre-Task Estimation

Before starting any task that meets the estimation threshold below, estimate cost first.

**Estimation threshold:** Task requires 5+ tool calls, OR touches 3+ files, OR runs unknown-duration command, OR spawns a sub-agent.

**Estimation process:**
1. Count expected operations for the task
2. Calculate burn rate: read token totals from `~/.claude/projects/**/*.jsonl` for this session, divide by tool calls made
3. Project: `burn_rate × expected_operations`
4. Compare to remaining quota tokens

**Risk thresholds:**
- Projected cost > 100% of remaining → CRITICAL warning
- Projected cost 80–100% of remaining → HIGH warning
- Projected cost 60–80% of remaining → MEDIUM warning
- Projected cost < 60% of remaining → proceed silently

**Warning format when risk ≥ MEDIUM:**
```
Quota: {X}% used (~{N} tokens remaining, {plan} plan)

About to start: {task — 1 line}
Estimated cost: ~{N} tokens (~{Y}% of remaining)
  — {Z} expected operations at ~{rate} tokens/op (±30% estimate)

Risk: {HIGH|CRITICAL}

  1. proceed           — start, hard stop still fires at 95%
  2. break-into-phases — I'll identify a safe first phase
  3. skip              — don't start this now
```

If user answers `break-into-phases`: identify natural task breakpoints, propose a first phase within safe budget, record deferred items in `AI_HANDOFF.md` under "Deferred Scope".

Small tasks below the estimation threshold: proceed without prompt.

---

### PREPARE (90–95%) — Permission Request

Stop what you are doing. Generate a brief status. Ask for permission.

**Status brief (5 lines max):**
```
Quota: {X}% of 5-hour window
Currently: {one line — what was in progress}
Done: {N items verified complete}
In flight: {N items started but unverified}
Remaining: {what would still need doing}
```

**Permission prompt:**
```
Recommend entering handoff mode to preserve progress cleanly.

  1. yes            — stop now, write full handoff files
  2. finish-this    — complete only the current atomic unit, then stop
  3. no             — continue (95% hard stop still applies, no second ask)
```

After `finish-this`: complete strictly the current operation (one file edit OR one command — not a new task). Then proceed to STOP behavior below.

After `no`: continue, but do not start new large tasks. If quota crosses 95% at next poll, block fires automatically — do not ask again. State: "Quota has crossed the hard stop threshold. Entering handoff mode now."

---

### STOP (95–98%) — Write Artifacts Immediately

No permission request. Your tool call was blocked. Acknowledge the block briefly and write both artifacts now.

**Output to user:**
```
Entering handoff mode. Quota at {X}%. Writing AI_HANDOFF.md and RESUME_PROMPT.md.
```

Then write both files per the templates below. Do not start any other work.

---

### EMERGENCY (98%+) — RESUME_PROMPT.md First

Same as STOP but write `RESUME_PROMPT.md` FIRST, then `AI_HANDOFF.md`.
Reason: if generation is cut off mid-artifact, at minimum the next agent has a resume prompt.

---

## Artifact Templates

### AI_HANDOFF.md

Write this file to the project root (or current working directory if no project root).
Be comprehensive — this is the primary reference for a zero-context agent.

```markdown
# AI Handoff — {ISO timestamp}

## Handoff Metadata
- **Tier:** {WARN|PREPARE|STOP|EMERGENCY}
- **Quota at handoff:** {X}% ({source: oauth|jsonl|heuristic})
- **Source:** agent-written
- **Project:** {project name}
- **Branch:** {git branch}
- **Session duration:** {approx time}

## Project Background
{2–4 sentences. What this project is, what the session was working on,
and why. Complete enough for a zero-context agent to understand without
reading any prior conversation.}

## Completed Work (verified)
- {item} — verified by: {test run / review / user confirmation}

## In Progress (unverified — do not trust without re-checking)
- {item}
  - File: {exact path}
  - Status: {INTERRUPTED|PARTIAL|NEEDS_TEST|NEEDS_REVIEW}
  - Last known state: {what was happening when stopped}

## Blocked Items
- {item} — blocked by: {specific reason}

## Assumptions Made This Session
- {assumption} — basis: {why assumed, what evidence}

## Known Risks / Gotchas
- {anything a fresh agent could easily get wrong}

## Files Touched This Session
- `{path}` — {one-line description of change}

## Deferred Scope (if break-into-phases was used)
- {items explicitly deferred to next session}

## Immediate Next Step
{One specific, actionable instruction. Name the exact file, exact function,
exact command. Do not say "continue working on X" — say exactly what to do.
Example: "Open src/auth.ts line 87 and complete the validateToken() function
which was interrupted; the signature is in place, body is empty."}

## Suggested Approach for Next Session
{2–5 sentences of strategic guidance: what to verify first, what order to
tackle things, what to avoid, what the user cares about most.}
```

---

### RESUME_PROMPT.md

Write this file to the project root. This is pasted verbatim to start the next session — it must require no editing.

```markdown
# Resume Prompt — {project name} — {date}

You are resuming an interrupted work session on **{project name}**.
The previous session was stopped at {X}% quota usage ({tier}).

## First Actions (mandatory — do not skip)
1. Read `AI_HANDOFF.md` in full
2. Run `git status` and `git diff HEAD` — verify working tree matches the handoff record
3. Re-verify any items marked NEEDS_TEST or NEEDS_REVIEW before treating as complete
4. Confirm the "Immediate Next Step" in AI_HANDOFF.md is still valid given current file state

## Context
{3–5 sentences. What this project does, what the session was working on, and what
the goal of this session was. Self-contained — no prior conversation needed.}

## Last Verified Working State
{What was confirmed working before handoff. What tests passed. What the user approved.}

## Do This First
**{Exact first action — specific file, specific function or line, specific command.}**

## Do NOT Do
- Do not re-do work listed as "Completed (verified)" in AI_HANDOFF.md
- Do not trust items marked INTERRUPTED or PARTIAL without re-reading the file
- {project-specific pitfall if any}

## Key Files
- `{path}`: {one-line description}

## Environment
- Branch: {branch}
- Working directory: {cwd}
- {any required env vars, build commands, or setup steps}
```

---

## Post-Artifact Checklist

After writing both files:
1. State clearly to the user: "Handoff complete. AI_HANDOFF.md and RESUME_PROMPT.md written to {path}."
2. Mention the tier and quota level
3. Suggest the user copy RESUME_PROMPT.md content to start the next session
4. Do not start any new work
ENDOFSKILL
```

**Step 2: Verify the skill was written**
```bash
wc -l ~/.claude/skills/graceful-wrap-up.md
head -5 ~/.claude/skills/graceful-wrap-up.md
```
Expected: ~150 lines, frontmatter present.

**Step 3: Commit**
```bash
cd ~/.claude
git add skills/graceful-wrap-up.md
git commit -m "feat: add graceful-wrap-up skill — portable agent behavior layer"
```

---

## Task 8: Enhance `wrap-up.md` Command

**Files:**
- Modify: `~/.claude/commands/wrap-up.md`

**Step 1: Read current content**
```bash
cat ~/.claude/commands/wrap-up.md
```

**Step 2: Replace with enhanced version**

The enhanced command adds handoff artifact generation on top of the existing 5-step ritual, and wires in the graceful-wrap-up skill.

```bash
cat > ~/.claude/commands/wrap-up.md << 'EOF'
---
description: End-of-session ritual — summarize work, update STATUS.md, write handoff artifacts
---

Run the end-of-session wrap-up ritual. Invoke the `graceful-wrap-up` skill first, then complete ALL steps below.

## Step 0: Invoke graceful-wrap-up skill
Use the `graceful-wrap-up` skill to write `AI_HANDOFF.md` and `RESUME_PROMPT.md` for this session.
These are the primary handoff artifacts — write them comprehensively.
Treat this as a voluntary PREPARE-tier handoff (user-requested, not quota-triggered).

## Step 1: Summarize This Session
List what was accomplished as bullet points. Be specific — file names, features, fixes.

## Step 2: Capture Learnings
Review the session for:
- Patterns worth remembering → write to project native memory
- Corrections the user made → write to project native memory
- Any pattern seen 2+ times → promote to `.claude/rules/` (ask user first)
- Any universal preference → promote to global `~/.claude/memory/MEMORY.md`

## Step 3: Update STATUS.md
Read the current `docs/STATUS.md`. Update it with:
- Move completed items from "In Progress" to "Done"
- Add new items discovered during this session to "Up Next"
- Update "Current Phase" if a phase milestone was reached
- Update the "Last Updated" timestamp
- Write a one-line handoff note at the bottom under "Handoff Note"

## Step 4: Suggest Commit
If there are uncommitted changes, suggest a commit with a clear message.
Do NOT commit automatically — only suggest.

## Step 5: Print Summary
Print a brief session summary showing:
- What was done
- Where AI_HANDOFF.md and RESUME_PROMPT.md were written
- What the next session should focus on
EOF
```

**Step 3: Verify**
```bash
head -10 ~/.claude/commands/wrap-up.md
```

**Step 4: Commit**
```bash
cd ~/.claude
git add commands/wrap-up.md
git commit -m "feat: enhance wrap-up command with graceful-wrap-up skill integration"
```

---

## Task 9: Create Optional Configuration File

**Files:**
- Create: `~/.claude/.handoff-config`

This lets the user configure their plan tier for accurate JSONL burn rate calculation.

**Step 1: Create with detected or default plan**
```bash
# Set to your actual plan: pro, max5, or max20
# Change this value based on your Claude subscription
cat > ~/.claude/.handoff-config << 'EOF'
plan=max5
EOF
```

**Step 2: Verify**
```bash
cat ~/.claude/.handoff-config
```

---

## Task 10: Integration Testing

Run through all tiers manually to verify end-to-end behavior.

**Test A: Hook scripts are executable and syntax-valid**
```bash
for hook in pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    bash -n ~/.claude/hooks/$hook && echo "OK: $hook" || echo "SYNTAX ERROR: $hook"
done
bash -n ~/.claude/hooks/handoff-lib.sh && echo "OK: handoff-lib.sh" || echo "SYNTAX ERROR: handoff-lib.sh"
```
Expected: All `OK`.

**Test B: Unit tests pass**
```bash
bash ~/.claude/hooks/tests/test-handoff-lib.sh
bash ~/.claude/hooks/tests/test-pre-tool-use.sh
```
Expected: All pass.

**Test C: Pre-compact hook end-to-end**
```bash
echo '{"session_id":"integ-test","hook_event_name":"PreCompact","cwd":"/tmp"}' | \
  HANDOFF_SIGNAL_FILE=/tmp/integ-signal \
  bash ~/.claude/hooks/pre-compact-handoff
echo "Exit: $? (expected 0)"
cat /tmp/integ-signal && rm /tmp/integ-signal
```

**Test D: Stop-failure hook with a real git repo**
```bash
mkdir -p /tmp/integ-proj && cd /tmp/integ-proj
git init -q && echo "test" > test.txt && git add . && git commit -m "init" -q
echo "partial change" >> test.txt
echo '{"session_id":"integ","cwd":"/tmp/integ-proj","hook_event_name":"StopFailure"}' | \
  bash ~/.claude/hooks/stop-failure-handoff
echo "Exit: $?"
echo "--- AI_HANDOFF.md (first 20 lines) ---"
head -20 /tmp/integ-proj/AI_HANDOFF.md
echo "--- RESUME_PROMPT.md (first 15 lines) ---"
head -15 /tmp/integ-proj/RESUME_PROMPT.md
rm -rf /tmp/integ-proj
```

**Test E: Skill loads correctly**
In a Claude Code session, run:
```
/graceful-wrap-up
```
Then say: "Test — I'm simulating a PREPARE tier signal. Show me the permission prompt with a fake status."
Verify the agent outputs the correct status brief and 3-option prompt.

**Test F: Full PREPARE → yes flow**
In a Claude Code session with a real project:
1. Manually write `~/.claude/.handoff-signal` with `tier=PREPARE\nquota=91\nsource=manual`
2. Start a new prompt — the hook should inject the signal
3. Invoke the skill
4. Confirm `AI_HANDOFF.md` and `RESUME_PROMPT.md` are written to the project root
5. Verify both files are comprehensive enough to cold-start a new session

**Step: Final commit**
```bash
cd ~/.claude
git add .
git commit -m "test: add integration test verification steps"
```

---

## Validation Checklist

Before declaring complete, verify every item in `docs/plans/2026-04-20-graceful-handoff-design.md` Section 12:

```bash
# Quick verification script
echo "=== Graceful Handoff Validation ==="
echo ""
echo "Hook scripts:"
for f in handoff-lib.sh pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    [[ -x "$HOME/.claude/hooks/$f" ]] && echo "  OK: $f" || echo "  MISSING: $f"
done
echo ""
echo "Skill file:"
[[ -f "$HOME/.claude/skills/graceful-wrap-up.md" ]] && echo "  OK: graceful-wrap-up.md" || echo "  MISSING"
echo ""
echo "Settings.json hooks:"
python3 -c "
import json
with open('$HOME/.claude/settings.json') as f:
    d = json.load(f)
h = d.get('hooks', {})
for key in ['PreToolUse', 'PreCompact', 'Stop', 'StopFailure']:
    n = len(h.get(key, []))
    status = 'OK' if n > 0 else 'MISSING'
    print(f'  {status}: {key} ({n} entries)')
"
echo ""
echo "Config:"
[[ -f "$HOME/.claude/.handoff-config" ]] && echo "  OK: .handoff-config" || echo "  MISSING"
```
