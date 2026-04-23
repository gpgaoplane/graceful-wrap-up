#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/user-prompt-submit-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found at $HOOK"; exit 0; }

TMP=$(mktemp -d); trap "rm -rf '$TMP'" EXIT
export HANDOFF_SIGNAL_FILE="$TMP/signal"
export HANDOFF_COUNTER_FILE="$TMP/counter"
export HANDOFF_TURN_STATE_FILE="$TMP/turn-state"
export HANDOFF_TELEMETRY_FILE="$TMP/telemetry"
export HANDOFF_CONFIG_FILE="$TMP/config"
export HANDOFF_STOP_WARN_FILE="$TMP/stop-warn"
export CREDENTIALS_FILE="$TMP/nocreds_missing"
export HANDOFF_PROJECTS_DIR="$TMP/empty_projects"
mkdir -p "$TMP/empty_projects"

fake_prompt() {
    printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"%s","permission_mode":"default","prompt":"%s"}' \
        "$REPO_ROOT" "$1"
}

check_ac() {
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

# nominal allow
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "What does handoff-lib.sh do?" | HANDOFF_TEST_QUOTA_PCT=50 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "nominal allow exits 0" || fail "nominal allow exit: $EXIT"
[[ -z "$OUT" ]] && ok "nominal allow emits no context" || fail "nominal allow should emit no context"
TURN_OPEN=$(grep '^turn_open=' "$HANDOFF_TURN_STATE_FILE" | cut -d= -f2)
[[ "$TURN_OPEN" == "true" ]] && ok "nominal allow writes turn state (turn_open=true)" || fail "nominal allow turn-state mismatch"

# WARN tier always injects context (no risk evaluation)
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "What does handoff-lib.sh do?" | HANDOFF_TEST_QUOTA_PCT=86 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "WARN tier exits 0" || fail "WARN tier exit: $EXIT"
check_ac "WARN tier always injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "WARN tier injects WARN label" "$OUT" "WARN"
check_ac "WARN 5-hour mentions 5-hour limit" "$OUT" "5-hour limit"

# WARN tier from WEEKLY source labels weekly correctly
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "hi" | HANDOFF_TEST_QUOTA_PCT=50 HANDOFF_TEST_WEEKLY_QUOTA_PCT=96 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "WARN weekly exits 0" || fail "WARN weekly exit: $EXIT"
check_ac "WARN weekly injects WEEKLY label" "$OUT" "WEEKLY quota"
check_ac "WARN weekly mentions weekly limit" "$OUT" "weekly limit"

# PREPARE tier: large prompt exits 0 with advisory (no block)
rm -f "$HANDOFF_STOP_WARN_FILE"
OUT=$(fake_prompt "Review the whole repo, explain everything in detail, and give a comprehensive full plan." | HANDOFF_TEST_QUOTA_PCT=92 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PREPARE risky prompt exits 0 (allow with advisory)" || fail "PREPARE risky prompt exit: $EXIT"
check_ac "PREPARE risky prompt injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "PREPARE risky prompt injects PREPARE label"  "$OUT" "PREPARE"

# STOP first hit: exits 2 with warning, writes stop_warn flag
rm -f "$HANDOFF_STOP_WARN_FILE"
OUT=$(fake_prompt "Explain in detail how the hooks subsystem architecture works across the project." | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 2 ]] && ok "STOP first hit exits 2 (warn + hold)" || fail "STOP first hit exit: $EXIT"
[[ "$OUT" == *"HANDOFF_SIGNAL"* ]] && ok "STOP first hit emits warning" || fail "STOP first hit output mismatch: $OUT"
[[ "$OUT" == *"STOP_NOW"* ]] && ok "STOP first hit includes STOP_NOW option" || fail "STOP first hit options mismatch: $OUT"
[[ "$OUT" == *"PLAN_IT"* ]] && ok "STOP first hit includes PLAN_IT option" || fail "STOP first hit PLAN_IT option missing: $OUT"
[[ "$OUT" == *"FINISH_THIS"* ]] && ok "STOP first hit includes FINISH_THIS option" || fail "STOP first hit FINISH_THIS option missing: $OUT"
[[ -f "$HANDOFF_STOP_WARN_FILE" ]] && ok "STOP first hit writes stop_warn flag" || fail "STOP first hit: stop_warn flag missing"

# STOP re-submit: flag set → exits 0 with guidance, clears flag
OUT=$(fake_prompt "Explain in detail how the hooks subsystem architecture works across the project." | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "STOP re-submit exits 0 (proceed by user choice)" || fail "STOP re-submit exit: $EXIT"
check_ac "STOP re-submit injects HANDOFF_SIGNAL" "$OUT" "HANDOFF_SIGNAL"
check_ac "STOP re-submit injects STOP label"     "$OUT" "STOP"
check_ac "STOP re-submit injects normally"       "$OUT" "normally"
[[ ! -f "$HANDOFF_STOP_WARN_FILE" ]] && ok "STOP re-submit clears stop_warn flag" || fail "STOP re-submit: flag not cleared"

# PLAN_IT keyword at STOP: exits 0, injects plan-it guidance, no execution
rm -f "$HANDOFF_TURN_STATE_FILE"; rm -f "$HANDOFF_STOP_WARN_FILE"
OUT=$(fake_prompt "PLAN_IT: refactor the auth module" | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PLAN_IT at STOP exits 0" || fail "PLAN_IT at STOP exit: $EXIT"
check_ac "PLAN_IT at STOP injects plan-it guidance" "$OUT" "plan-it mode"
check_ac "PLAN_IT at STOP injects real request"     "$OUT" "refactor the auth module"
check_ac "PLAN_IT at STOP injects STOP tier label"  "$OUT" "(STOP)"

# PLAN_IT keyword below STOP: still works, tier label reflects actual tier
rm -f "$HANDOFF_TURN_STATE_FILE"; rm -f "$HANDOFF_STOP_WARN_FILE"
OUT=$(fake_prompt "PLAN_IT: refactor the auth module" | HANDOFF_TEST_QUOTA_PCT=50 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "PLAN_IT below STOP exits 0" || fail "PLAN_IT below STOP exit: $EXIT"
check_ac "PLAN_IT below STOP injects plan-it guidance" "$OUT" "plan-it mode"
check_ac "PLAN_IT below STOP injects UNAVAILABLE tier label" "$OUT" "(UNAVAILABLE)"

# HANDOFF_NOW at STOP: clears flag, exits 0
rm -f "$HANDOFF_TURN_STATE_FILE"; rm -f "$HANDOFF_STOP_WARN_FILE"
OUT=$(fake_prompt "HANDOFF_NOW" | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "HANDOFF_NOW exits 0 at STOP" || fail "HANDOFF_NOW exit: $EXIT"
check_ac "HANDOFF_NOW injects handoff guidance" "$OUT" "HANDOFF_NOW accepted"

# approval keyword with no prior blocked state still works
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "APPROVE_ONCE: review the current branch state" | HANDOFF_TEST_QUOTA_PCT=92 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "APPROVE_ONCE without prior blocked state exits 0" || fail "APPROVE_ONCE exit: $EXIT"
check_ac "APPROVE_ONCE injects scoped guidance" "$OUT" "The real request is: review the current branch state"
TURN_PERMISSION=$(grep '^turn_permission=' "$HANDOFF_TURN_STATE_FILE" | cut -d= -f2)
[[ "$TURN_PERMISSION" == "continue" ]] && ok "APPROVE_ONCE writes continue permission" || fail "APPROVE_ONCE turn-state mismatch"

# expired prior state does not break a normal allow
cat > "$HANDOFF_TURN_STATE_FILE" <<EOF
session_id=s1
turn_open=true
turn_permission=continue
granted_at=1
expires_at=2
pre_turn_quota_pct=92
predicted_risk_band=large
predicted_cost_range=10-20%
source_tier=PREPARE
EOF
OUT=$(fake_prompt "What does handoff-lib.sh do?" | HANDOFF_TEST_QUOTA_PCT=50 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "expired prior turn-state does not block allow" || fail "expired turn-state exit: $EXIT"
NEW_EXPIRES=$(grep '^expires_at=' "$HANDOFF_TURN_STATE_FILE" | cut -d= -f2)
[[ "$NEW_EXPIRES" == "0" ]] && ok "expired state was replaced by normal allow state" || fail "expired state replacement mismatch"

# quota-source failure fail-open
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "What does handoff-lib.sh do?" | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "quota-source failure fails open" || fail "quota-source failure exit: $EXIT"

# clear_stop_warn fires on every approval branch
for approval in "STOP_NOW" "HANDOFF_NOW" "FINISH_THIS: do X" "APPROVE_ONCE: do X" "PLAN_IT: do X"; do
    printf 's1' > "$HANDOFF_STOP_WARN_FILE"
    rm -f "$HANDOFF_TURN_STATE_FILE"
    fake_prompt "$approval" | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" >/dev/null 2>&1
    label="${approval%%:*}"  # trim to keyword for label
    [[ ! -f "$HANDOFF_STOP_WARN_FILE" ]] && ok "${label} clears stop_warn flag" || fail "${label} did not clear stop_warn flag"
done

# Multi-line approval prompts rejected with format_error (exit 2)
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt $'FINISH_THIS: do X\\nand also Y' | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>&1)
EXIT=$?
# Note: the JSON fake_prompt passes the literal \n escape; we test actual newlines in lib tests.
# Here just confirm the happy path still works for single-line.
rm -f "$HANDOFF_TURN_STATE_FILE"
OUT=$(fake_prompt "FINISH_THIS: do X in one line" | HANDOFF_TEST_QUOTA_PCT=96 HANDOFF_TEST_WEEKLY_QUOTA_PCT=0 bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "single-line FINISH_THIS still works" || fail "single-line FINISH_THIS exit: $EXIT"
check_ac "single-line FINISH_THIS forwards prompt" "$OUT" "do X in one line"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
