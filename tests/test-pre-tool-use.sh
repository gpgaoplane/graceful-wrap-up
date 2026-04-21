#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/pre-tool-use-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found at $HOOK"; exit 0; }

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
SIG="$TMP/signal"; CTR="$TMP/counter"
CFG="$TMP/config"; CREDS="$TMP/nocreds_missing"
export HANDOFF_SIGNAL_FILE="$SIG"
export HANDOFF_COUNTER_FILE="$CTR"
export HANDOFF_CONFIG_FILE="$CFG"
export CREDENTIALS_FILE="$CREDS"
export HANDOFF_PROJECTS_DIR="$TMP/empty_projects"
mkdir -p "$TMP/empty_projects"

fake() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "${1:-Bash}"; }

# --- Calls 1-9: must exit 0, no signal file ---
for i in $(seq 1 9); do
    fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
    [[ $? -eq 0 ]] || fail "call $i should exit 0, got $?"
done
ok "calls 1-9 all exit 0"
[[ ! -f "$SIG" ]] && ok "no signal file written before call 10" || fail "signal file should not exist before call 10"

# --- Call 10 with counter=10 (low heuristic, 10 < 40) → no tier → exit 0, no signal ---
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "call 10 low heuristic exits 0" || fail "call 10 low: exit $?"
[[ ! -f "$SIG" ]] && ok "call 10 low heuristic writes no signal" || fail "call 10: unexpected signal"

# --- WARN tier: counter=39 → next call is 40 → heuristic 40→87% → WARN → exit 0, signal written ---
printf 's1:39' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]]       && ok "WARN tier exits 0"         || fail "WARN tier: exit $EXIT"
[[ -f "$SIG" ]]          && ok "WARN tier writes signal"   || fail "WARN tier: signal missing"
TIER=$(grep '^tier=' "$SIG" 2>/dev/null | cut -d= -f2)
[[ "$TIER" == "WARN" ]]  && ok "WARN tier signal = WARN"   || fail "WARN tier signal: got '$TIER'"
# WARN must produce no stdout output (silent injection)
[[ -z "$OUT" ]]          && ok "WARN tier silent (no stdout)" || fail "WARN tier: unexpected stdout: $OUT"

# --- PREPARE tier: counter=59 → next call 60 → heuristic 60→92% → PREPARE → exit 0, JSON context injected ---
printf 's1:59' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PREPARE tier exits 0" || fail "PREPARE tier: exit $EXIT"
# Verify JSON output contains additionalContext
/c/Python313/python -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    ac = str(d.get('hookSpecificOutput', {}).get('additionalContext', ''))
    assert 'HANDOFF_SIGNAL' in ac, f'missing HANDOFF_SIGNAL in: {ac}'
    assert 'PREPARE' in ac, f'missing PREPARE in: {ac}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$OUT" 2>/dev/null | grep -q ok \
    && ok "PREPARE tier injects additionalContext JSON" \
    || fail "PREPARE tier: bad JSON output: $OUT"

# --- STOP tier: counter=79 → next call 80 → heuristic 80→96% → STOP → exit 2 (block) ---
printf 's1:79' > "$CTR"; rm -f "$SIG"
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
EXIT=$?
[[ $EXIT -eq 2 ]] && ok "STOP tier exits 2 (blocks tool call)" || fail "STOP tier: exit $EXIT (expected 2)"

# --- EMERGENCY re-block: signal already EMERGENCY → immediate block on any call ---
printf 'tier=EMERGENCY\nquota=99\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
EXIT=$?
[[ $EXIT -eq 2 ]] && ok "existing EMERGENCY signal re-blocks immediately" || fail "EMERGENCY re-block: exit $EXIT"

# --- STOP re-block: signal already STOP → immediate block ---
printf 'tier=STOP\nquota=96\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
EXIT=$?
[[ $EXIT -eq 2 ]] && ok "existing STOP signal re-blocks immediately" || fail "STOP re-block: exit $EXIT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
