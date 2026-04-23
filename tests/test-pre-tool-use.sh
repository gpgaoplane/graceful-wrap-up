#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/pre-tool-use-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found at $HOOK"; exit 0; }

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
SIG="$TMP/signal"; CTR="$TMP/counter"; TURN="$TMP/turn-state"
CFG="$TMP/config"; CREDS="$TMP/nocreds_missing"
export HANDOFF_SIGNAL_FILE="$SIG"
export HANDOFF_COUNTER_FILE="$CTR"
export HANDOFF_TURN_STATE_FILE="$TURN"
export HANDOFF_CONFIG_FILE="$CFG"
export CREDENTIALS_FILE="$CREDS"
export HANDOFF_PROJECTS_DIR="$TMP/empty_projects"
mkdir -p "$TMP/empty_projects"

fake() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "${1:-Bash}"; }

check_ac() {
    # check_ac <label> <json> <required_substring>
    local label="$1" json="$2" needle="$3"
    /c/Python313/python -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    ac = str(d.get('hookSpecificOutput', {}).get('additionalContext', ''))
    assert sys.argv[2] in ac, f'missing {sys.argv[2]!r} in: {ac}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$json" "$needle" 2>/dev/null | grep -q ok \
        && ok "$label" \
        || fail "$label: bad JSON: $json"
}

# --- Calls 1-9: must exit 0, no signal file ---
for i in $(seq 1 9); do
    fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
    [[ $? -eq 0 ]] || fail "call $i should exit 0, got $?"
done
ok "calls 1-9 all exit 0"
[[ ! -f "$SIG" ]] && ok "no signal file written before call 10" || fail "signal file should not exist before call 10"

# --- Call 10: OAuth unavailable (no test override) → no tier → exit 0, no signal ---
fake "Bash" | SESSION_ID="s1" bash "$HOOK" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "call 10 OAuth unavailable exits 0" || fail "call 10: exit $?"
[[ ! -f "$SIG" ]] && ok "call 10 OAuth unavailable writes no signal" || fail "call 10: unexpected signal"

# --- WARN tier: OAuth returns 87% → exit 0, context injected ---
printf 's1:9' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=87 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]]       && ok "WARN tier exits 0"         || fail "WARN tier: exit $EXIT"
[[ -f "$SIG" ]]          && ok "WARN tier writes signal"   || fail "WARN tier: signal missing"
TIER=$(grep '^tier=' "$SIG" 2>/dev/null | cut -d= -f2)
[[ "$TIER" == "WARN" ]]  && ok "WARN tier signal = WARN"   || fail "WARN tier signal: got '$TIER'"
check_ac "WARN tier injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "WARN tier injects WARN label"     "$OUT" "WARN"

# --- Accelerated polling: WARN signal in file → non-10th call still runs quota check ---
printf 's1:10' > "$CTR"  # next call will be 11 (not a multiple of 10)
# SIG still has tier=WARN from above
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=87 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "accelerated polling: call 11 with WARN signal exits 0" || fail "accelerated polling: exit $EXIT"
[[ -n "$OUT" ]]   && ok "accelerated polling: call 11 still emits output (not skipped)" || fail "accelerated polling: expected output but got none"

# --- PREPARE tier: OAuth returns 92% → exit 0, context injected ---
printf 's1:9' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=92 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PREPARE tier exits 0" || fail "PREPARE tier: exit $EXIT"
check_ac "PREPARE tier injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "PREPARE tier injects PREPARE label"  "$OUT" "PREPARE"

# --- STOP tier: OAuth returns 96% → exit 0, advisory context injected ---
printf 's1:9' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=96 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "STOP tier exits 0 (advisory, no hard-block)" || fail "STOP tier: exit $EXIT (expected 0)"
check_ac "STOP tier injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "STOP tier injects STOP label"     "$OUT" "STOP"

# --- STOP tier at 99%: exits 0, advisory injected ---
printf 's1:9' > "$CTR"; rm -f "$SIG"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=99 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "STOP tier at 99% exits 0 (advisory, no hard-block)" || fail "STOP 99%: exit $EXIT (expected 0)"
check_ac "STOP 99% injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "STOP 99% injects STOP label"     "$OUT" "STOP"

# --- STOP signal in file: accelerated polling re-warns, exits 0 ---
printf 'tier=STOP\nquota=96\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=96 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "existing STOP signal re-warns (exit 0)" || fail "STOP re-warn: exit $EXIT"
check_ac "STOP re-warn injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"

# --- STOP signal + active approval → skip non-check call (no output) ---
cat > "$TURN" <<EOF
session_id=s1
turn_open=true
turn_permission=continue
granted_at=100
expires_at=9999999999
pre_turn_quota_pct=92
predicted_risk_band=large
predicted_cost_range=10-20%
source_tier=STOP
EOF
printf 'tier=STOP\nquota=96\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
OUT=$(fake "Bash" | SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "active approval at STOP skips non-check call" || fail "active approval STOP exit: $EXIT"
[[ -z "$OUT" ]] && ok "active approval at STOP emits nothing on non-check call" || fail "active approval STOP output mismatch: $OUT"

# --- stale session turn-state is discarded; STOP still exits 0 (warn-only) ---
cat > "$TURN" <<EOF
session_id=old-session
turn_open=true
turn_permission=continue
granted_at=100
expires_at=9999999999
pre_turn_quota_pct=92
predicted_risk_band=large
predicted_cost_range=10-20%
source_tier=STOP
EOF
printf 'tier=STOP\nquota=96\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=96 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "stale session: STOP exits 0 (warn-only)" || fail "stale session STOP exit: $EXIT"
[[ ! -f "$TURN" ]] && ok "stale session turn-state is discarded" || fail "stale session state not discarded"

# --- expired turn-state is discarded; STOP still exits 0 ---
cat > "$TURN" <<EOF
session_id=s1
turn_open=true
turn_permission=continue
granted_at=1
expires_at=2
pre_turn_quota_pct=92
predicted_risk_band=large
predicted_cost_range=10-20%
source_tier=STOP
EOF
printf 'tier=STOP\nquota=96\nsource=oauth\n' > "$SIG"
printf 's1:1' > "$CTR"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=96 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "expired turn-state: STOP exits 0 (warn-only)" || fail "expired approval STOP exit: $EXIT"
[[ ! -f "$TURN" ]] && ok "expired turn-state is discarded" || fail "expired turn-state not discarded"

# --- STOP with active approval on a check call: exits 0 with advisory ---
cat > "$TURN" <<EOF
session_id=s1
turn_open=true
turn_permission=continue
granted_at=100
expires_at=9999999999
pre_turn_quota_pct=96
source_tier=STOP
EOF
printf 'tier=STOP\nquota=99\nsource=oauth\n' > "$SIG"
printf 's1:9' > "$CTR"
OUT=$(fake "Bash" | HANDOFF_TEST_QUOTA_PCT=99 SESSION_ID="s1" bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "STOP with active approval exits 0 (warn-only)" || fail "STOP approval exit: $EXIT"
check_ac "STOP with approval injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
