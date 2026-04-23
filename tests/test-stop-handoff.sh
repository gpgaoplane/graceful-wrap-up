#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/stop-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found at $HOOK"; exit 0; }

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

setup_env() {
    export HANDOFF_SIGNAL_FILE="$TMP/signal"
    export HANDOFF_COUNTER_FILE="$TMP/counter"
    export HANDOFF_TURN_STATE_FILE="$TMP/turn-state"
    export HANDOFF_TELEMETRY_FILE="$TMP/telemetry"
    export HANDOFF_CONFIG_FILE="$TMP/config"
    export CREDENTIALS_FILE="$TMP/nocreds_missing"
    export HANDOFF_PROJECTS_DIR="$TMP/empty_projects"
    mkdir -p "$TMP/empty_projects"
}

setup_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null 2>&1
    git -C "$repo" config user.name "Codex Test" >/dev/null 2>&1
    git -C "$repo" config user.email "codex@example.com" >/dev/null 2>&1
    printf 'seed\n' > "$repo/base.txt"
    git -C "$repo" add base.txt >/dev/null 2>&1
    git -C "$repo" commit -m "seed" >/dev/null 2>&1
}

fake_stop() {
    printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"%s"}' "$1" "$2"
}

write_turn_state() {
    cat > "$HANDOFF_TURN_STATE_FILE" <<EOF
session_id=$1
turn_open=$2
turn_permission=$3
granted_at=100
expires_at=9999999999
pre_turn_quota_pct=$4
predicted_risk_band=$5
predicted_cost_range=$6
source_tier=$7
pre_turn_quota_source=$8
predicted_confidence=$9
predicted_reason_codes=${10}
EOF
}

line_field() {
    local line="$1" field="$2"
    printf '%s\n' "$line" | tr ';' '\n' | grep "^${field}=" | cut -d= -f2-
}

assert_signal() {
    local label="$1" want_tier="$2" want_source="$3"
    local got_tier got_source
    got_tier=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" 2>/dev/null | cut -d= -f2)
    got_source=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" 2>/dev/null | cut -d= -f2)
    [[ "$got_tier" == "$want_tier" && "$got_source" == "$want_source" ]] \
        && ok "$label" \
        || fail "$label: got tier='$got_tier' source='$got_source'"
}

run_stop() {
    local session_id="$1" repo="$2" quota_pct="$3" weekly_pct="${4:-0}"
    OUT=$(fake_stop "$session_id" "$repo" | HANDOFF_TEST_QUOTA_PCT="$quota_pct" HANDOFF_TEST_WEEKLY_QUOTA_PCT="$weekly_pct" bash "$HOOK" 2>/dev/null)
    EXIT=$?
    [[ $EXIT -eq 0 ]] && ok "stop hook exits 0 ($session_id/$quota_pct)" || fail "stop hook exit ($session_id/$quota_pct): $EXIT"
}

setup_env
REPO="$TMP/repo"
setup_repo "$REPO"

# sub-90 cleanup clears transient quota signal and closes turn state
printf 'tier=PREPARE\nquota=92\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
write_turn_state "s1" "true" "continue" "88" "medium" "5-10%" "PREPARE" "oauth" "medium" "planning_requested"
run_stop "s1" "$REPO" "84"
[[ ! -f "$HANDOFF_SIGNAL_FILE" ]] && ok "sub-90 cleanup clears transient signal" || fail "sub-90 cleanup should clear signal"
TURN_OPEN=$(grep '^turn_open=' "$HANDOFF_TURN_STATE_FILE" | cut -d= -f2)
TURN_PERMISSION=$(grep '^turn_permission=' "$HANDOFF_TURN_STATE_FILE" | cut -d= -f2)
[[ "$TURN_OPEN" == "false" && "$TURN_PERMISSION" == "none" ]] \
    && ok "sub-90 cleanup closes current turn" || fail "sub-90 cleanup turn-state mismatch"

TELEMETRY_LAST=$(tail -n 1 "$HANDOFF_TELEMETRY_FILE")
DELTA=$(line_field "$TELEMETRY_LAST" "actual_delta_pct")
MODE=$(line_field "$TELEMETRY_LAST" "mode")
REASONS=$(line_field "$TELEMETRY_LAST" "reason_codes")
[[ "$DELTA" == "0" ]] && ok "sub-90 telemetry floors delta at zero" || fail "sub-90 delta mismatch: $DELTA"
[[ "$MODE" == "conversation" ]] && ok "sub-90 telemetry records conversation mode" || fail "sub-90 mode mismatch: $MODE"
[[ "$REASONS" == "planning_requested" ]] && ok "sub-90 telemetry keeps predicted reason codes" || fail "sub-90 reasons mismatch: $REASONS"
[[ ! -f "$REPO/AI_HANDOFF.md" ]] && ok "ordinary stop maintenance writes no AI_HANDOFF artifact" || fail "ordinary stop maintenance should not write AI_HANDOFF.md"

# PREPARE overshoot (90-94): writes signal, no handoff artifacts
write_turn_state "s1" "true" "none" "87" "large" "10-20%" "WARN" "oauth" "high" "repo_wide_scope"
run_stop "s1" "$REPO" "92"
assert_signal "PREPARE overshoot writes PREPARE signal" "PREPARE" "test"
TELEMETRY_LAST=$(tail -n 1 "$HANDOFF_TELEMETRY_FILE")
DELTA=$(line_field "$TELEMETRY_LAST" "actual_delta_pct")
RESULT_TIER=$(line_field "$TELEMETRY_LAST" "result_tier")
[[ "$DELTA" == "5" ]] && ok "PREPARE overshoot records actual delta" || fail "PREPARE overshoot delta mismatch: $DELTA"
[[ "$RESULT_TIER" == "PREPARE" ]] && ok "PREPARE overshoot telemetry stores resulting tier" || fail "PREPARE overshoot result tier mismatch: $RESULT_TIER"
[[ ! -f "$REPO/AI_HANDOFF.md" ]] && ok "PREPARE overshoot writes no handoff artifacts" || fail "PREPARE overshoot should not write AI_HANDOFF.md"

# STOP overshoot at 95-97: writes signal AND handoff artifacts (new behavior — STOP triggers artifacts)
write_turn_state "s1" "true" "none" "91" "large" "10-20%" "PREPARE" "oauth" "high" "repo_wide_scope"
run_stop "s1" "$REPO" "96"
assert_signal "STOP (95-97) overshoot writes STOP signal" "STOP" "test"
TELEMETRY_LAST=$(tail -n 1 "$HANDOFF_TELEMETRY_FILE")
RESULT_TIER=$(line_field "$TELEMETRY_LAST" "result_tier")
[[ "$RESULT_TIER" == "STOP" ]] && ok "STOP (95-97) telemetry stores STOP tier" || fail "STOP (95-97) result tier mismatch: $RESULT_TIER"
[[ -f "$REPO/AI_HANDOFF.md" ]] && ok "STOP (95-97) writes AI_HANDOFF.md" || fail "STOP (95-97) should write AI_HANDOFF.md"
[[ -f "$REPO/RESUME_PROMPT.md" ]] && ok "STOP (95-97) writes RESUME_PROMPT.md" || fail "STOP (95-97) should write RESUME_PROMPT.md"

# STOP overshoot at 98+: appends git snapshot to existing AI_HANDOFF.md
printf 'work in progress\n' >> "$REPO/base.txt"
write_turn_state "s1" "true" "finish-this" "94" "huge" "20%+" "STOP" "oauth" "high" "repo_wide_scope,full_review_requested"
run_stop "s1" "$REPO" "98"
assert_signal "STOP (98+) overshoot writes STOP signal" "STOP" "test"
grep -q "Git Snapshot (stop-handoff hook" "$REPO/AI_HANDOFF.md" \
    && ok "STOP (98+) appends git snapshot to AI_HANDOFF.md" \
    || fail "STOP (98+) missing git snapshot"

# compaction-source signal survives sub-90 cleanup when no fresh quota supersedes it
printf 'tier=PREPARE\nquota=90+\nsource=compaction\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
write_turn_state "s1" "true" "none" "70" "small" "2-5%" "PREPARE" "oauth" "low" ""
run_stop "s1" "$REPO" "82"
assert_signal "compaction PREPARE survives sub-90 cleanup" "PREPARE" "compaction"

# stale session turn-state is discarded before evaluation
printf 'tier=STOP\nquota=96\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
write_turn_state "old-session" "true" "continue" "92" "large" "10-20%" "STOP" "oauth" "high" "repo_wide_scope"
run_stop "s1" "$REPO" "84"
[[ ! -f "$HANDOFF_TURN_STATE_FILE" ]] && ok "stale session turn-state discarded" || fail "stale session turn-state should be discarded"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
