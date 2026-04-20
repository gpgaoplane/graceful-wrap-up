# Graceful Handoff Framework — Implementation Plan v2 (Package Structure)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a quota-aware graceful handoff system for Claude Code, packaged as an installable GitHub repo with install/uninstall scripts. Skill file + 4 hook scripts + README.

**Architecture:** Signal injection hybrid — hook scripts detect quota via OAuth → JSONL → heuristics, inject signals into conversation, agent executes intelligent handoff. Source lives in `src/`, deployed to `~/.claude/` via `install.sh`.

**Tech Stack:** Bash (hooks, install scripts), Markdown (skill, README), JSON (settings.json merging), Python3 (JSON parsing — available on all Claude Code hosts), curl (OAuth endpoint).

**Repo:** `https://github.com/gpgaoplane/smart-quota-tracker.git`
**Local path:** `D:/Projects/self-skills/graceful-wrap-up/`
**Reference:** `docs/plans/2026-04-20-graceful-handoff-design.md` — read before starting.

**Supersedes:** `docs/plans/2026-04-20-graceful-handoff-implementation.md` (v1 wrote directly to `~/.claude/` — this version writes to `src/` and deploys via install.sh)

---

## Path Convention (applies to ALL tasks)

| v1 path | v2 path (source) | Deployed to (by install.sh) |
|---------|-----------------|----------------------------|
| `~/.claude/hooks/handoff-lib.sh` | `src/hooks/handoff-lib.sh` | `~/.claude/hooks/handoff-lib.sh` |
| `~/.claude/hooks/pre-tool-use-handoff` | `src/hooks/pre-tool-use-handoff` | `~/.claude/hooks/pre-tool-use-handoff` |
| `~/.claude/hooks/pre-compact-handoff` | `src/hooks/pre-compact-handoff` | `~/.claude/hooks/pre-compact-handoff` |
| `~/.claude/hooks/stop-handoff` | `src/hooks/stop-handoff` | `~/.claude/hooks/stop-handoff` |
| `~/.claude/hooks/stop-failure-handoff` | `src/hooks/stop-failure-handoff` | `~/.claude/hooks/stop-failure-handoff` |
| `~/.claude/skills/graceful-wrap-up.md` | `src/skills/graceful-wrap-up.md` | `~/.claude/skills/graceful-wrap-up.md` |
| `~/.claude/commands/wrap-up.md` | `src/commands/wrap-up.md` | `~/.claude/commands/wrap-up.md` |
| `~/.claude/hooks/tests/` | `tests/` | not deployed |

Test scripts reference `src/hooks/` paths directly — no deployment needed for testing.

---

## Final Repo Structure

```
smart-quota-tracker/
├── install.sh                  ← ./install.sh to deploy everything
├── uninstall.sh                ← ./uninstall.sh to remove everything
├── README.md
├── src/
│   ├── hooks/
│   │   ├── handoff-lib.sh
│   │   ├── pre-tool-use-handoff
│   │   ├── pre-compact-handoff
│   │   ├── stop-handoff
│   │   └── stop-failure-handoff
│   ├── skills/
│   │   └── graceful-wrap-up.md
│   └── commands/
│       └── wrap-up.md
├── tests/
│   ├── test-handoff-lib.sh
│   └── test-pre-tool-use.sh
└── docs/
    └── plans/
        ├── 2026-04-20-graceful-handoff-design.md
        └── 2026-04-20-graceful-handoff-implementation-v2.md
```

---

## Task 0: Repository Setup

**Files:**
- Create: `src/hooks/` directory
- Create: `src/skills/` directory
- Create: `src/commands/` directory
- Create: `tests/` directory
- Connect local repo to GitHub remote

**Step 1: Create directory structure**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
mkdir -p src/hooks src/skills src/commands tests
```

**Step 2: Connect to GitHub remote**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git remote add origin https://github.com/gpgaoplane/smart-quota-tracker.git
git remote -v
```
Expected: origin points to `gpgaoplane/smart-quota-tracker.git`.

**Step 3: Add .gitignore**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/.gitignore << 'EOF'
# State files — generated at runtime, not source
.handoff-signal
.handoff-counter

# OS
.DS_Store
Thumbs.db
EOF
```

**Step 4: Stage and commit scaffold**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add .gitignore
git add -f src/.keep tests/.keep 2>/dev/null || touch src/hooks/.keep src/skills/.keep src/commands/.keep tests/.keep && git add src/ tests/
git commit -m "chore: add package directory structure"
```

**Step 5: Push to GitHub**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git push -u origin master
```
Expected: branch pushed, tracking set.

---

## Pre-Implementation: Discover Credentials Structure

Before writing any hook code, inspect the actual `~/.claude/.credentials.json` on this machine. The OAuth detection approach depends on the exact field path for the access token.

**Step 1: Check if the file exists**
```bash
ls -la ~/.claude/.credentials.json 2>/dev/null || echo "FILE NOT FOUND"
```

**Step 2: If it exists, inspect keys only (do not log token values)**
```bash
python3 -c "
import json
with open('$HOME/.claude/.credentials.json') as f:
    d = json.load(f)
def keys_only(obj, depth=0):
    if isinstance(obj, dict):
        for k, v in obj.items():
            print('  ' * depth + str(k) + ': ' + type(v).__name__)
            if isinstance(v, dict):
                keys_only(v, depth+1)
keys_only(d)
"
```

**Step 3: Record the token field path** — update the `get_quota_oauth()` function in `src/hooks/handoff-lib.sh` Task 1 with the actual field path (e.g., `claudeAiOauth.accessToken`).

**Step 4: Identify plan tier**
```bash
grep -r "plan\|tier\|subscription\|max" ~/.claude/*.json 2>/dev/null | grep -v ".jsonl" | head -10 || echo "no plan info found"
```
If not found, default is `max5` (88,000 tokens/5hr window). Record for `.handoff-config` in Task 9.

---

## Task 1: Create Shared Hook Library

**Files:**
- Create: `src/hooks/handoff-lib.sh`
- Create: `tests/test-handoff-lib.sh`

**Step 1: Write the failing test first**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/tests/test-handoff-lib.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/src/hooks/handoff-lib.sh"
[[ -f "$LIB" ]] && source "$LIB" || { echo "SKIP: library not found at $LIB"; exit 0; }

# tier_from_pct
[[ "$(tier_from_pct 80)" == "" ]]        && ok "80% = no tier"    || fail "80% should return empty"
[[ "$(tier_from_pct 86)" == "WARN" ]]     && ok "86% = WARN"       || fail "86% should be WARN"
[[ "$(tier_from_pct 91)" == "PREPARE" ]]  && ok "91% = PREPARE"    || fail "91% should be PREPARE"
[[ "$(tier_from_pct 95)" == "STOP" ]]     && ok "95% = STOP"       || fail "95% should be STOP"
[[ "$(tier_from_pct 98)" == "EMERGENCY" ]] && ok "98% = EMERGENCY" || fail "98% should be EMERGENCY"

# write_signal_file / read_signal_tier roundtrip
TMP_SIGNAL=$(mktemp)
HANDOFF_SIGNAL_FILE="$TMP_SIGNAL" write_signal_file "PREPARE" "92" "oauth"
TIER=$(HANDOFF_SIGNAL_FILE="$TMP_SIGNAL" read_signal_tier)
[[ "$TIER" == "PREPARE" ]] && ok "signal roundtrip" || fail "signal roundtrip: got '$TIER'"
rm -f "$TMP_SIGNAL"

# escape_json
RESULT=$(escape_json 'hello "world"')
[[ "$RESULT" == 'hello \"world\"' ]] && ok "escape_json quotes" || fail "escape_json: got '$RESULT'"

# should_check_this_call sampling
should_check_this_call 5  && fail "call 5 should not check"  || ok "call 5 skipped"
should_check_this_call 10 && ok "call 10 checked"            || fail "call 10 should check"
should_check_this_call 20 && ok "call 20 checked"            || fail "call 20 should check"
should_check_this_call 11 && fail "call 11 should not check" || ok "call 11 skipped"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/tests/test-handoff-lib.sh
```

**Step 2: Run test — confirm SKIP**
```bash
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-handoff-lib.sh
```
Expected: `SKIP: library not found at .../src/hooks/handoff-lib.sh`

**Step 3: Create `src/hooks/handoff-lib.sh`**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/src/hooks/handoff-lib.sh << 'ENDOFLIB'
#!/usr/bin/env bash
# handoff-lib.sh — shared utilities for graceful-handoff hooks
# Source this file at the top of each hook script.

HANDOFF_SIGNAL_FILE="${HANDOFF_SIGNAL_FILE:-$HOME/.claude/.handoff-signal}"
HANDOFF_COUNTER_FILE="${HANDOFF_COUNTER_FILE:-$HOME/.claude/.handoff-counter}"
HANDOFF_CONFIG_FILE="${HANDOFF_CONFIG_FILE:-$HOME/.claude/.handoff-config}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

declare -A PLAN_LIMITS=([pro]=19000 [max5]=88000 [max20]=220000)

tier_from_pct() {
    local pct="${1:-0}"
    if   (( pct >= 98 )); then echo "EMERGENCY"
    elif (( pct >= 95 )); then echo "STOP"
    elif (( pct >= 90 )); then echo "PREPARE"
    elif (( pct >= 85 )); then echo "WARN"
    else echo ""
    fi
}

write_signal_file() {
    local tier="$1" pct="$2" source="$3"
    printf 'tier=%s\nquota=%s\nsource=%s\ntimestamp=%s\nsession=%s\n' \
        "$tier" "$pct" "$source" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${SESSION_ID:-unknown}" > "$HANDOFF_SIGNAL_FILE"
}

read_signal_tier() {
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

read_signal_field() {
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep "^${1}=" "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

should_check_this_call() {
    local call_num="${1:-1}"
    (( call_num % 10 == 0 ))
}

get_and_increment_call_count() {
    local sid="${SESSION_ID:-unknown}" count=0
    if [[ -f "$HANDOFF_COUNTER_FILE" ]]; then
        local stored
        stored=$(cat "$HANDOFF_COUNTER_FILE" 2>/dev/null || echo "")
        [[ "${stored%%:*}" == "$sid" && "${stored##*:}" =~ ^[0-9]+$ ]] && count="${stored##*:}"
    fi
    count=$(( count + 1 ))
    printf '%s:%d' "$sid" "$count" > "$HANDOFF_COUNTER_FILE"
    echo "$count"
}

get_quota_oauth() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    local token
    token=$(python3 -c "
import json
try:
    d = json.load(open('${CREDENTIALS_FILE}'))
    # UPDATE THIS FIELD PATH after running pre-implementation credential discovery
    t = (d.get('claudeAiOauth') or {}).get('accessToken') or d.get('access_token') or ''
    print(t.strip())
except: print('')
" 2>/dev/null || echo "")
    [[ -z "$token" ]] && return 0

    local resp
    resp=$(curl -sf --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || echo "")
    [[ -z "$resp" ]] && return 0

    python3 -c "
import json, sys
try:
    fh = json.loads(sys.stdin.read()).get('five_hour', {})
    if isinstance(fh, dict):
        used, limit = float(fh.get('used',0)), float(fh.get('limit',0))
        print(int(used*100/limit) if limit>0 else '')
    elif isinstance(fh, (int,float)):
        v = float(fh)
        print(int(v*100) if v<=1.0 else int(v))
    else: print('')
except: print('')
" <<< "$resp" 2>/dev/null || echo ""
}

get_quota_jsonl() {
    local plan
    plan=$(grep '^plan=' "$HANDOFF_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || echo "max5")
    local limit="${PLAN_LIMITS[$plan]:-88000}"
    python3 -c "
import json, os, glob, time
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(hours=5)
total = 0
for path in glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True):
    try:
        for line in open(path, errors='ignore'):
            try:
                e = json.loads(line.strip())
                ts = e.get('timestamp','')
                if not ts: continue
                t = datetime.fromisoformat(ts.replace('Z','+00:00'))
                if t < cutoff: continue
                u = e.get('message',{}).get('usage',{}) or e.get('usage',{})
                total += sum(int(u.get(k,0)) for k in
                    ['input_tokens','output_tokens',
                     'cache_creation_input_tokens','cache_read_input_tokens'])
            except: continue
    except: continue
print(min(int(total*100/${limit}),100) if total>0 else '')
" 2>/dev/null || echo ""
}

get_quota_heuristic() {
    local count="${1:-0}"
    if   (( count >= 80 )); then echo "96"
    elif (( count >= 60 )); then echo "92"
    elif (( count >= 40 )); then echo "87"
    else echo ""
    fi
}

get_quota() {
    local count="${1:-0}" pct
    QUOTA_SOURCE="none"
    pct=$(get_quota_oauth)
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then QUOTA_SOURCE="oauth";     echo "$pct"; return; fi
    pct=$(get_quota_jsonl)
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then QUOTA_SOURCE="jsonl";     echo "$pct"; return; fi
    pct=$(get_quota_heuristic "$count")
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then QUOTA_SOURCE="heuristic"; echo "$pct"; return; fi
    echo ""
}

escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

emit_context_injection() {
    local msg; msg=$(escape_json "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
        "${HOOK_EVENT_NAME:-PreToolUse}" "$msg"
}
ENDOFLIB
chmod +x D:/Projects/self-skills/graceful-wrap-up/src/hooks/handoff-lib.sh
```

**Step 4: Run tests — confirm pass**
```bash
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-handoff-lib.sh
```
Expected: `Results: 9 passed, 0 failed`

**Step 5: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/hooks/handoff-lib.sh tests/test-handoff-lib.sh
git commit -m "feat: add handoff-lib.sh shared utilities with tests"
git push
```

---

## Task 2: Create `pre-tool-use-handoff` Hook

**Files:**
- Create: `src/hooks/pre-tool-use-handoff`
- Create: `tests/test-pre-tool-use.sh`

**Step 1: Write the failing test**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/tests/test-pre-tool-use.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/pre-tool-use-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found"; exit 0; }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
SIG="$TMP/signal"; CTR="$TMP/counter"; CFG="$TMP/config"; CREDS="$TMP/nocreds"
export HANDOFF_SIGNAL_FILE="$SIG" HANDOFF_COUNTER_FILE="$CTR"
export HANDOFF_CONFIG_FILE="$CFG" CREDENTIALS_FILE="$CREDS"

fake() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"; }

# Calls 1-9: exit 0, no signal
for i in $(seq 1 9); do
    fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
    [[ $? -eq 0 ]] || fail "call $i exit should be 0"
done
ok "calls 1-9 exit 0"
[[ ! -f "$SIG" ]] && ok "no signal before call 10" || fail "early signal file"

# Call 10 with low count (10 < 40) — heuristic returns empty — no signal
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "call 10 low heuristic exits 0" || fail "call 10 low: exit $?"

# Simulate WARN (count=40): expect exit 0, signal written
printf 's1:39' > "$CTR"; rm -f "$SIG"
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "WARN tier exits 0" || fail "WARN exit was $?"
[[ -f "$SIG" ]] && ok "WARN writes signal" || fail "WARN: signal missing"
[[ "$(grep '^tier=' "$SIG" | cut -d= -f2)" == "WARN" ]] && ok "WARN tier correct" || fail "WARN tier wrong"

# Simulate PREPARE (count=60): expect exit 0, JSON output with additionalContext
printf 's1:59' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
[[ $? -eq 0 ]] && ok "PREPARE exits 0" || fail "PREPARE exit $?"
echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'additionalContext' in str(d)" 2>/dev/null \
    && ok "PREPARE outputs additionalContext" || fail "PREPARE: no additionalContext in: $OUT"

# Simulate STOP (count=80): expect exit 2
printf 's1:79' > "$CTR"; rm -f "$SIG"
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "STOP exits 2 (block)" || fail "STOP exit was $?"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/tests/test-pre-tool-use.sh
```

**Step 2: Run — confirm SKIP**
```bash
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-pre-tool-use.sh
```

**Step 3: Create `src/hooks/pre-tool-use-handoff`**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/src/hooks/pre-tool-use-handoff << 'EOF'
#!/usr/bin/env bash
# PreToolUse hook: quota detection, signal injection, tool blocking.
# Sourced lib path is resolved relative to this script's installed location.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

INPUT=$(cat)
SESSION_ID=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('session_id','unknown'))" <<< "$INPUT" 2>/dev/null || echo "unknown")
HOOK_EVENT_NAME="PreToolUse"
export SESSION_ID HOOK_EVENT_NAME

COUNT=$(get_and_increment_call_count)
should_check_this_call "$COUNT" || exit 0

# Re-block immediately if already at STOP/EMERGENCY without re-polling
EXISTING=$(read_signal_tier)
if [[ "$EXISTING" == "STOP" || "$EXISTING" == "EMERGENCY" ]]; then
    PCT=$(read_signal_field "quota")
    printf 'HANDOFF_SIGNAL: quota=%s%% tier=%s — tool blocked. Write handoff files now.' "$PCT" "$EXISTING"
    exit 2
fi

QUOTA_SOURCE="none"
QUOTA_PCT=$(get_quota "$COUNT")
[[ -z "$QUOTA_PCT" ]] && exit 0

TIER=$(tier_from_pct "$QUOTA_PCT")
[[ -z "$TIER" ]] && exit 0

write_signal_file "$TIER" "$QUOTA_PCT" "$QUOTA_SOURCE"

case "$TIER" in
    WARN)
        exit 0 ;;
    PREPARE)
        emit_context_injection "HANDOFF_SIGNAL: quota=${QUOTA_PCT}% source=${QUOTA_SOURCE} tier=PREPARE"
        exit 0 ;;
    STOP)
        printf 'HANDOFF_SIGNAL: quota=%s%% tier=STOP — tool blocked. Write AI_HANDOFF.md and RESUME_PROMPT.md now.' "$QUOTA_PCT"
        exit 2 ;;
    EMERGENCY)
        printf 'HANDOFF_SIGNAL: quota=%s%% tier=EMERGENCY — CRITICAL. Write RESUME_PROMPT.md FIRST, then AI_HANDOFF.md.' "$QUOTA_PCT"
        exit 2 ;;
esac
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/src/hooks/pre-tool-use-handoff
```

**Step 4: Run tests — confirm pass**
```bash
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-pre-tool-use.sh
```
Expected: `Results: 9 passed, 0 failed`

**Step 5: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/hooks/pre-tool-use-handoff tests/test-pre-tool-use.sh
git commit -m "feat: add pre-tool-use-handoff hook with detection cascade"
git push
```

---

## Task 3: Create `pre-compact-handoff` Hook

**Files:**
- Create: `src/hooks/pre-compact-handoff`

**Step 1: Create**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/src/hooks/pre-compact-handoff << 'EOF'
#!/usr/bin/env bash
# PreCompact hook: context compaction = implicit PREPARE signal.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

INPUT=$(cat)
SESSION_ID=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('session_id','unknown'))" <<< "$INPUT" 2>/dev/null || echo "unknown")
HOOK_EVENT_NAME="PreCompact"
export SESSION_ID HOOK_EVENT_NAME

EXISTING=$(read_signal_tier)
[[ "$EXISTING" == "STOP" || "$EXISTING" == "EMERGENCY" ]] && exit 0

write_signal_file "PREPARE" "90+" "compaction"
emit_context_injection "HANDOFF_SIGNAL: context compaction triggered — tier=PREPARE. Consider wrapping up current work."
exit 0
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/src/hooks/pre-compact-handoff
```

**Step 2: Smoke test**
```bash
echo '{"session_id":"t","hook_event_name":"PreCompact"}' | \
  HANDOFF_SIGNAL_FILE=/tmp/t-compact \
  SCRIPT_DIR=D:/Projects/self-skills/graceful-wrap-up/src/hooks \
  bash D:/Projects/self-skills/graceful-wrap-up/src/hooks/pre-compact-handoff
echo "Exit: $?"; cat /tmp/t-compact 2>/dev/null; rm -f /tmp/t-compact
```
Expected: JSON with additionalContext, exit 0, signal file with `tier=PREPARE`.

**Step 3: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/hooks/pre-compact-handoff
git commit -m "feat: add pre-compact-handoff hook"
git push
```

---

## Task 4: Create `stop-handoff` Hook

**Files:**
- Create: `src/hooks/stop-handoff`

**Step 1: Create**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-handoff << 'EOF'
#!/usr/bin/env bash
# Stop hook: appends git snapshot to AI_HANDOFF.md if signal exists.
# Does nothing on clean sessions with no signal — zero cost.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

INPUT=$(cat)
TIER=$(read_signal_tier)
[[ -z "$TIER" ]] && exit 0

CWD=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('cwd','.'))" <<< "$INPUT" 2>/dev/null || echo ".")
cd "$CWD" 2>/dev/null || true
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HANDOFF_FILE="${CWD}/AI_HANDOFF.md"

GIT_SECTION=""
if git rev-parse --git-dir &>/dev/null 2>&1; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    STATUS=$(git status --porcelain 2>/dev/null || echo "(unavailable)")
    DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "(no uncommitted changes)")
    LOG=$(git log --oneline -10 2>/dev/null || echo "(no log)")
    GIT_SECTION="
## Git Snapshot (stop-handoff hook — ${TIMESTAMP})
**Branch:** ${BRANCH}

### Working Tree
\`\`\`
${STATUS}
\`\`\`
### Diff Summary
\`\`\`
${DIFF_STAT}
\`\`\`
### Recent Commits
\`\`\`
${LOG}
\`\`\`"
fi

if [[ -f "$HANDOFF_FILE" ]]; then
    printf '%s\n' "$GIT_SECTION" >> "$HANDOFF_FILE"
else
    printf '# AI Handoff — %s\n\n## Source\nstop-hook-only (agent did not write artifacts)\n\n## Tier\n%s\n%s\n' \
        "$TIMESTAMP" "$TIER" "$GIT_SECTION" > "$HANDOFF_FILE"
fi

rm -f "$HANDOFF_SIGNAL_FILE" "$HANDOFF_COUNTER_FILE"
exit 0
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-handoff
```

**Step 2: Smoke test**
```bash
TMP=$(mktemp -d); echo -e "tier=PREPARE\nquota=91" > "$TMP/sig"
echo "{\"session_id\":\"t\",\"cwd\":\"$TMP\"}" | \
  HANDOFF_SIGNAL_FILE="$TMP/sig" \
  bash D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-handoff
echo "Exit: $?"; head -10 "$TMP/AI_HANDOFF.md" 2>/dev/null; rm -rf "$TMP"
```

**Step 3: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/hooks/stop-handoff
git commit -m "feat: add stop-handoff hook for git snapshot on clean exit"
git push
```

---

## Task 5: Create `stop-failure-handoff` Hook

**Files:**
- Create: `src/hooks/stop-failure-handoff`

**Step 1: Create**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-failure-handoff << 'EOF'
#!/usr/bin/env bash
# StopFailure hook: fires on rate_limit or billing_error.
# Agent is gone. Writes emergency artifacts from git state only.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

INPUT=$(cat)
CWD=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('cwd','.'))" <<< "$INPUT" 2>/dev/null || pwd)
cd "$CWD" 2>/dev/null || true
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT=$(basename "$CWD")
TIER=$(read_signal_tier || echo "DEAD")
QUOTA=$(read_signal_field "quota" 2>/dev/null || echo "unknown")

BRANCH="unknown"; STATUS="(not a git repo)"; DIFF_STAT="(not a git repo)"
DIFF_FULL="(not a git repo)"; LOG="(not a git repo)"
if git rev-parse --git-dir &>/dev/null 2>&1; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    STATUS=$(git status --porcelain 2>/dev/null || echo "(unavailable)")
    DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "(no changes)")
    DIFF_FULL=$(git diff HEAD 2>/dev/null | head -300 || echo "(no diff)")
    LOG=$(git log --oneline -15 2>/dev/null || echo "(no log)")
fi

# Write AI_HANDOFF.md
cat > "${CWD}/AI_HANDOFF.md.tmp" << HEOF
# AI Handoff — ${TIMESTAMP}

## Handoff Metadata
- **Tier:** DEAD (session cutoff — no agent context)
- **Quota at cutoff:** ${QUOTA}%
- **Source:** emergency-hook-only (rate_limit or billing_error)
- **Project:** ${PROJECT} | **Branch:** ${BRANCH}
- **WARNING:** Written by hook after abrupt cutoff. No conversation context. Treat all in-progress work as UNVERIFIED.

## What To Do First
1. Read this file fully
2. Run \`git status\` and \`git diff HEAD\` — verify against git state below
3. Inspect modified files for truncation or incomplete state
4. Check git log to reconstruct what was in progress

## Git State at Cutoff

### Working Tree
\`\`\`
${STATUS}
\`\`\`
### Diff Summary
\`\`\`
${DIFF_STAT}
\`\`\`
### Full Diff (first 300 lines)
\`\`\`diff
${DIFF_FULL}
\`\`\`
### Recent Commits
\`\`\`
${LOG}
\`\`\`

## Recovery Guidance
- Modified files were being worked on at cutoff — inspect for truncation
- Untracked files may be newly created and incomplete
- Do not commit anything without verifying correctness first
HEOF
mv "${CWD}/AI_HANDOFF.md.tmp" "${CWD}/AI_HANDOFF.md"

# Write RESUME_PROMPT.md
cat > "${CWD}/RESUME_PROMPT.md.tmp" << REOF
# Resume Prompt — ${PROJECT} — ${TIMESTAMP}

You are resuming an **abruptly interrupted** session on **${PROJECT}**.
The session was cut off at quota exhaustion (${QUOTA}% usage).
This file was written automatically with NO agent context — only git state.

## First Actions (mandatory)
1. Read \`AI_HANDOFF.md\` in full
2. Run \`git status\` and \`git diff HEAD\`
3. Inspect modified files for incomplete/truncated state
4. Identify last coherent completed work from \`git log\`

## Context
Project: **${PROJECT}** | Branch: **${BRANCH}**
Session was cut off abruptly. Reconstruct intent from git history and file state.

## Do This First
Read the git diff. Find the most recently modified file. Determine if it is complete.
If not — completing or reverting it is your first task.

## Do NOT Do
- Do not assume any in-progress work is correct or complete
- Do not commit without verifying compilation/tests
- Do not re-do already-committed work
REOF
mv "${CWD}/RESUME_PROMPT.md.tmp" "${CWD}/RESUME_PROMPT.md"

exit 0
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-failure-handoff
```

**Step 2: Smoke test**
```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q && git commit --allow-empty -m "init" -q
echo "{\"session_id\":\"t\",\"cwd\":\"$TMP\"}" | \
  bash D:/Projects/self-skills/graceful-wrap-up/src/hooks/stop-failure-handoff
echo "Exit: $?"; head -15 "$TMP/AI_HANDOFF.md"; head -10 "$TMP/RESUME_PROMPT.md"
rm -rf "$TMP"
```
Expected: both files written, exit 0.

**Step 3: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/hooks/stop-failure-handoff
git commit -m "feat: add stop-failure-handoff emergency artifact writer"
git push
```

---

## Task 6: Create Skill and Command Files

**Files:**
- Create: `src/skills/graceful-wrap-up.md`
- Create: `src/commands/wrap-up.md`

**Step 1: Create the skill** — copy content exactly from v1 plan Task 7 (`~/.claude/skills/graceful-wrap-up.md`). The content is unchanged; only the destination path changes.
```bash
# The full skill content is defined in v1 plan Task 7.
# Write it to: D:/Projects/self-skills/graceful-wrap-up/src/skills/graceful-wrap-up.md
# (copy the heredoc from v1 plan verbatim)
```

**Step 2: Create the enhanced command** — copy content from v1 plan Task 8.
```bash
# Write to: D:/Projects/self-skills/graceful-wrap-up/src/commands/wrap-up.md
```

**Step 3: Verify line counts**
```bash
wc -l D:/Projects/self-skills/graceful-wrap-up/src/skills/graceful-wrap-up.md
wc -l D:/Projects/self-skills/graceful-wrap-up/src/commands/wrap-up.md
```
Skill should be ~150 lines; command ~30 lines.

**Step 4: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add src/skills/graceful-wrap-up.md src/commands/wrap-up.md
git commit -m "feat: add graceful-wrap-up skill and enhanced wrap-up command"
git push
```

---

## Task 7: Create `install.sh`

**Files:**
- Create: `install.sh`
- Create: `uninstall.sh`

**Step 1: Create `install.sh`**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/install.sh << 'EOF'
#!/usr/bin/env bash
# install.sh — deploys smart-quota-tracker to ~/.claude/
# Safe to re-run: idempotent. Does not overwrite existing wrap-up.md without backup.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/.handoff-config"

echo "Installing smart-quota-tracker..."

# 1. Create target dirs
mkdir -p "$HOOKS_DIR" "$SKILLS_DIR" "$COMMANDS_DIR"

# 2. Deploy hook scripts
for hook in handoff-lib.sh pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    cp "$REPO_DIR/src/hooks/$hook" "$HOOKS_DIR/$hook"
    chmod +x "$HOOKS_DIR/$hook"
    echo "  installed: hooks/$hook"
done

# 3. Deploy skill
cp "$REPO_DIR/src/skills/graceful-wrap-up.md" "$SKILLS_DIR/graceful-wrap-up.md"
echo "  installed: skills/graceful-wrap-up.md"

# 4. Deploy command (backup existing wrap-up.md)
if [[ -f "$COMMANDS_DIR/wrap-up.md" ]]; then
    cp "$COMMANDS_DIR/wrap-up.md" "$COMMANDS_DIR/wrap-up.md.bak"
    echo "  backed up: commands/wrap-up.md -> wrap-up.md.bak"
fi
cp "$REPO_DIR/src/commands/wrap-up.md" "$COMMANDS_DIR/wrap-up.md"
echo "  installed: commands/wrap-up.md"

# 5. Write .handoff-config if not present
if [[ ! -f "$CONFIG" ]]; then
    echo "plan=max5" > "$CONFIG"
    echo "  created: .handoff-config (plan=max5 — edit to match your subscription)"
fi

# 6. Merge hook entries into settings.json
python3 << PYEOF
import json, sys, os

settings_path = os.path.expanduser('~/.claude/settings.json')
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})

def add_hook(event, matcher, command, timeout):
    entries = hooks.setdefault(event, [])
    for e in entries:
        for h in e.get('hooks', []):
            if h.get('command') == command:
                return False  # already present
    entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]})
    return True

added = []
if add_hook('PreToolUse',  '', 'bash ~/.claude/hooks/pre-tool-use-handoff',  8000):  added.append('PreToolUse')
if add_hook('PreCompact',  '', 'bash ~/.claude/hooks/pre-compact-handoff',   5000):  added.append('PreCompact')
if add_hook('Stop',        '', 'bash ~/.claude/hooks/stop-handoff',          10000): added.append('Stop')
if add_hook('StopFailure', 'rate_limit',    'bash ~/.claude/hooks/stop-failure-handoff', 15000): added.append('StopFailure/rate_limit')
if add_hook('StopFailure', 'billing_error', 'bash ~/.claude/hooks/stop-failure-handoff', 15000): added.append('StopFailure/billing_error')

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

if added:
    print('  merged hooks:', ', '.join(added))
else:
    print('  hooks already present — no changes to settings.json')
PYEOF

echo ""
echo "Installation complete."
echo ""
echo "Next steps:"
echo "  1. Edit ~/.claude/.handoff-config and set plan= to match your subscription (pro/max5/max20)"
echo "  2. Restart Claude Code for hook changes to take effect"
echo "  3. In a session, test with: /graceful-wrap-up"
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/install.sh
```

**Step 2: Create `uninstall.sh`**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/uninstall.sh << 'EOF'
#!/usr/bin/env bash
# uninstall.sh — removes smart-quota-tracker from ~/.claude/
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Uninstalling smart-quota-tracker..."

# 1. Remove hook scripts
for hook in handoff-lib.sh pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    rm -f "$HOOKS_DIR/$hook" && echo "  removed: hooks/$hook"
done

# 2. Remove skill
rm -f "$CLAUDE_DIR/skills/graceful-wrap-up.md" && echo "  removed: skills/graceful-wrap-up.md"

# 3. Restore wrap-up.md backup if it exists
if [[ -f "$CLAUDE_DIR/commands/wrap-up.md.bak" ]]; then
    mv "$CLAUDE_DIR/commands/wrap-up.md.bak" "$CLAUDE_DIR/commands/wrap-up.md"
    echo "  restored: commands/wrap-up.md from backup"
else
    rm -f "$CLAUDE_DIR/commands/wrap-up.md" && echo "  removed: commands/wrap-up.md"
fi

# 4. Remove config and state files
rm -f "$CLAUDE_DIR/.handoff-config" "$CLAUDE_DIR/.handoff-signal" "$CLAUDE_DIR/.handoff-counter"
echo "  removed: state files"

# 5. Remove hook entries from settings.json
python3 << PYEOF
import json, os

settings_path = os.path.expanduser('~/.claude/settings.json')
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
handoff_commands = {
    'bash ~/.claude/hooks/pre-tool-use-handoff',
    'bash ~/.claude/hooks/pre-compact-handoff',
    'bash ~/.claude/hooks/stop-handoff',
    'bash ~/.claude/hooks/stop-failure-handoff',
}

removed = 0
for event in list(hooks.keys()):
    orig = hooks[event]
    filtered = [
        e for e in orig
        if not any(h.get('command') in handoff_commands for h in e.get('hooks', []))
    ]
    if len(filtered) < len(orig):
        removed += len(orig) - len(filtered)
    if filtered:
        hooks[event] = filtered
    else:
        del hooks[event]

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
print(f'  removed {removed} hook entries from settings.json')
PYEOF

echo ""
echo "Uninstall complete. Restart Claude Code for changes to take effect."
EOF
chmod +x D:/Projects/self-skills/graceful-wrap-up/uninstall.sh
```

**Step 3: Test install script (dry-run verification)**
```bash
# Verify Python3 merge logic is correct
cd D:/Projects/self-skills/graceful-wrap-up
python3 -c "
import json
# Simulate merge — uses actual settings.json
with open('$HOME/.claude/settings.json') as f:
    s = json.load(f)
print('Existing hooks:', list(s.get('hooks', {}).keys()))
print('Settings valid JSON: OK')
"
```

**Step 4: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add install.sh uninstall.sh
git commit -m "feat: add install/uninstall scripts for package deployment"
git push
```

---

## Task 8: Create `README.md`

**Files:**
- Create: `README.md`

**Step 1: Create README**
```bash
cat > D:/Projects/self-skills/graceful-wrap-up/README.md << 'EOF'
# smart-quota-tracker

A quota-aware graceful handoff system for Claude Code.

Detects approaching usage limits, asks permission before entering handoff mode, hard-stops at 95%+, and writes comprehensive continuation artifacts so a zero-context AI agent can resume your session seamlessly.

## What It Does

| Quota | Behavior |
|-------|----------|
| 85–90% | Estimates cost before starting large tasks, warns if risky |
| 90–95% | Shows status brief, asks permission (yes / finish-this / no) |
| 95–98% | Hard stops, writes `AI_HANDOFF.md` + `RESUME_PROMPT.md` |
| 98%+ | Emergency stop — writes `RESUME_PROMPT.md` first |
| Session cutoff | Hook writes emergency artifacts from git state |

## Install

```bash
git clone https://github.com/gpgaoplane/smart-quota-tracker.git
cd smart-quota-tracker
./install.sh
```

Then edit `~/.claude/.handoff-config` and set your plan:
```
plan=max5   # or: pro, max20
```

Restart Claude Code for hooks to take effect.

## Uninstall

```bash
./uninstall.sh
```

Restores your previous `wrap-up.md` and removes all hook entries from `settings.json`.

## Skill Only (no hooks)

If you only want the agent behavior without automatic detection:
```bash
cp src/skills/graceful-wrap-up.md ~/.claude/skills/
```
Activate manually with `/graceful-wrap-up` or the agent detects quota warnings from system messages.

## How It Works

**Detection cascade (hooks):** OAuth endpoint → JSONL burn rate → tool-call heuristics. Falls back gracefully if credentials are unavailable.

**Signal injection:** PreToolUse hook injects a terse one-line signal into the conversation when quota crosses 90%. The agent reads it and acts.

**Hard stop:** At 95%+, PreToolUse hook blocks the tool call (exit 2). Agent is forced to write handoff files.

**Emergency net:** StopFailure hook fires on abrupt cutoffs and writes git-state-only artifacts.

## Portability

The skill file (`src/skills/graceful-wrap-up.md`) is platform-agnostic. Codex and Antigravity adapters (hook equivalents for those platforms) are planned for a future release.

## Requirements

- Claude Code CLI
- Bash, Python3, curl (standard on macOS/Linux)
- `claude login` credentials (for OAuth quota detection — falls back to JSONL/heuristics without it)
EOF
```

**Step 2: Commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add README.md
git commit -m "docs: add README with install/uninstall instructions"
git push
```

---

## Task 9: Run Install and Integration Testing

**Step 1: Run the install script**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
./install.sh
```
Expected: all files deployed, hook entries merged, no errors.

**Step 2: Verify deployment**
```bash
python3 << 'EOF'
import json, os
h = os.path.expanduser
print("Hook scripts:")
for f in ['handoff-lib.sh','pre-tool-use-handoff','pre-compact-handoff','stop-handoff','stop-failure-handoff']:
    path = h(f'~/.claude/hooks/{f}')
    status = "OK" if os.path.isfile(path) and os.access(path, os.X_OK) else "MISSING/not-executable"
    print(f"  {status}: {f}")
print("\nSkill:", "OK" if os.path.isfile(h('~/.claude/skills/graceful-wrap-up.md')) else "MISSING")
print("Command:", "OK" if os.path.isfile(h('~/.claude/commands/wrap-up.md')) else "MISSING")
print("Config:", "OK" if os.path.isfile(h('~/.claude/.handoff-config')) else "MISSING")
with open(h('~/.claude/settings.json')) as f:
    s = json.load(f)
hooks = s.get('hooks', {})
for key in ['PreToolUse','PreCompact','Stop','StopFailure']:
    n = len(hooks.get(key, []))
    print(f"  settings.json {key}: {n} entries")
EOF
```

**Step 3: Run unit tests against deployed files**
```bash
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-handoff-lib.sh
bash D:/Projects/self-skills/graceful-wrap-up/tests/test-pre-tool-use.sh
```
Expected: all pass.

**Step 4: Syntax check all hook scripts**
```bash
for f in handoff-lib.sh pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    bash -n ~/.claude/hooks/$f && echo "OK: $f" || echo "SYNTAX ERROR: $f"
done
```

**Step 5: Test stop-failure hook with a git repo**
```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q
echo "work in progress" > wip.txt && git add . && git commit -m "init" -q
echo "unfinished" >> wip.txt
echo "{\"session_id\":\"t\",\"cwd\":\"$TMP\"}" | bash ~/.claude/hooks/stop-failure-handoff
echo "Exit: $?"; head -20 "$TMP/AI_HANDOFF.md"; head -12 "$TMP/RESUME_PROMPT.md"
rm -rf "$TMP"
```

**Step 6: Test uninstall/reinstall cycle**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
./uninstall.sh
# Verify hooks removed
python3 -c "import json; s=json.load(open('$HOME/.claude/settings.json')); print('PreToolUse' not in s.get('hooks',{}) and 'OK: hooks removed' or 'FAIL: hooks still present')"
# Reinstall
./install.sh
echo "Reinstall exit: $?"
```

**Step 7: Final validation checklist**
```bash
echo "=== smart-quota-tracker validation ==="
for f in handoff-lib.sh pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    [[ -x "$HOME/.claude/hooks/$f" ]] && echo "OK: $f" || echo "MISSING: $f"
done
[[ -f "$HOME/.claude/skills/graceful-wrap-up.md" ]] && echo "OK: skill" || echo "MISSING: skill"
python3 -c "
import json,os
s=json.load(open(os.path.expanduser('~/.claude/settings.json')))
h=s.get('hooks',{})
for k in ['PreToolUse','PreCompact','Stop','StopFailure']:
    print(f'  {k}: {len(h.get(k,[]))} entries')
"
```

**Step 8: Final commit**
```bash
cd D:/Projects/self-skills/graceful-wrap-up
git add .
git status
git commit -m "chore: finalize package — all tests passing" --allow-empty
git push
```
