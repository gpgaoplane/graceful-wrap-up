#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/src/hooks/handoff-lib.sh"
[[ -f "$LIB" ]] && source "$LIB" || { echo "SKIP: library not found at $LIB"; exit 0; }

# find_python
PY=$(find_python)
[[ -n "$PY" ]] && ok "find_python returns path: $PY" || fail "find_python returned empty"
[[ -n "$PY" ]] && "$PY" -c "print('ok')" 2>/dev/null | grep -q ok && ok "find_python is executable" || fail "find_python path not runnable"

# tier_from_pct
[[ "$(tier_from_pct 80)"  == "" ]]       && ok "80% = no tier"  || fail "80% should return empty, got '$(tier_from_pct 80)'"
[[ "$(tier_from_pct 86)"  == "WARN" ]]   && ok "86% = WARN"     || fail "86% should be WARN, got '$(tier_from_pct 86)'"
[[ "$(tier_from_pct 90)"  == "PREPARE" ]] && ok "90% = PREPARE" || fail "90% should be PREPARE, got '$(tier_from_pct 90)'"
[[ "$(tier_from_pct 91)"  == "PREPARE" ]] && ok "91% = PREPARE" || fail "91% should be PREPARE"
[[ "$(tier_from_pct 95)"  == "STOP" ]]   && ok "95% = STOP"     || fail "95% should be STOP, got '$(tier_from_pct 95)'"
[[ "$(tier_from_pct 98)"  == "STOP" ]]   && ok "98% = STOP"     || fail "98% should be STOP, got '$(tier_from_pct 98)'"
[[ "$(tier_from_pct 100)" == "STOP" ]]   && ok "100% = STOP"    || fail "100% should be STOP"

# write_signal_file / read_signal_tier / read_signal_field roundtrip
TMP_SIG=$(mktemp)
HANDOFF_SIGNAL_FILE="$TMP_SIG" write_signal_file "PREPARE" "92" "oauth"
TIER=$(HANDOFF_SIGNAL_FILE="$TMP_SIG" read_signal_tier)
[[ "$TIER" == "PREPARE" ]] && ok "signal tier roundtrip" || fail "signal tier: got '$TIER'"
PCT=$(HANDOFF_SIGNAL_FILE="$TMP_SIG" read_signal_field "quota")
[[ "$PCT" == "92" ]] && ok "signal quota roundtrip" || fail "signal quota: got '$PCT'"
SRC=$(HANDOFF_SIGNAL_FILE="$TMP_SIG" read_signal_field "source")
[[ "$SRC" == "oauth" ]] && ok "signal source roundtrip" || fail "signal source: got '$SRC'"
rm -f "$TMP_SIG"

# read_signal_tier on missing file returns empty
HANDOFF_SIGNAL_FILE="/tmp/does-not-exist-$$" \
    result=$(read_signal_tier 2>/dev/null); [[ -z "$result" ]] && ok "missing signal file returns empty" || fail "missing signal: got '$result'"

# escape_json
R1=$(escape_json 'hello "world"')
[[ "$R1" == 'hello \"world\"' ]] && ok "escape_json double quotes" || fail "escape_json quotes: got '$R1'"
R2=$(escape_json $'line1\nline2')
[[ "$R2" == 'line1\nline2' ]] && ok "escape_json newline" || fail "escape_json newline: got '$R2'"
R3=$(escape_json $'back\bspace')
[[ "$R3" == 'back\bspace' ]] && ok "escape_json backspace" || fail "escape_json backspace: got '$R3'"
R4=$(escape_json $'form\ffeed')
[[ "$R4" == 'form\ffeed' ]] && ok "escape_json formfeed" || fail "escape_json formfeed: got '$R4'"

# should_check_this_call
should_check_this_call 5  && fail "call 5 should not check"  || ok "call 5 skipped"
should_check_this_call 9  && fail "call 9 should not check"  || ok "call 9 skipped"
should_check_this_call 10 && ok   "call 10 checked"          || fail "call 10 should check"
should_check_this_call 20 && ok   "call 20 checked"          || fail "call 20 should check"
should_check_this_call 11 && fail "call 11 should not check" || ok "call 11 skipped"

# get_and_increment_call_count — counter increments per session
TMP_CTR=$(mktemp)
C1=$(HANDOFF_COUNTER_FILE="$TMP_CTR" SESSION_ID="sess1" get_and_increment_call_count)
C2=$(HANDOFF_COUNTER_FILE="$TMP_CTR" SESSION_ID="sess1" get_and_increment_call_count)
C3=$(HANDOFF_COUNTER_FILE="$TMP_CTR" SESSION_ID="sess1" get_and_increment_call_count)
[[ "$C1" == "1" && "$C2" == "2" && "$C3" == "3" ]] && ok "counter increments 1→2→3" || fail "counter: $C1,$C2,$C3"
# New session resets counter
C4=$(HANDOFF_COUNTER_FILE="$TMP_CTR" SESSION_ID="sess2" get_and_increment_call_count)
[[ "$C4" == "1" ]] && ok "new session resets counter" || fail "new session counter: got $C4"
rm -f "$TMP_CTR"

# tier_from_weekly_pct
[[ "$(tier_from_weekly_pct 94)"  == "" ]]     && ok "weekly 94% = no tier" || fail "weekly 94% should be empty, got '$(tier_from_weekly_pct 94)'"
[[ "$(tier_from_weekly_pct 95)"  == "WARN" ]] && ok "weekly 95% = WARN"    || fail "weekly 95% should be WARN, got '$(tier_from_weekly_pct 95)'"
[[ "$(tier_from_weekly_pct 98)"  == "WARN" ]] && ok "weekly 98% = WARN"    || fail "weekly 98% should be WARN, got '$(tier_from_weekly_pct 98)'"
[[ "$(tier_from_weekly_pct 99)"  == "WARN" ]] && ok "weekly 99% = WARN"    || fail "weekly 99% should be WARN, got '$(tier_from_weekly_pct 99)'"
[[ "$(tier_from_weekly_pct 100)" == "WARN" ]] && ok "weekly 100% = WARN"   || fail "weekly 100% should be WARN, got '$(tier_from_weekly_pct 100)'"

# tier_severity
[[ "$(tier_severity "")"        == "0" ]] && ok "severity ''=0"      || fail "severity '': got $(tier_severity '')"
[[ "$(tier_severity "WARN")"    == "1" ]] && ok "severity WARN=1"    || fail "severity WARN: got $(tier_severity WARN)"
[[ "$(tier_severity "PREPARE")" == "2" ]] && ok "severity PREPARE=2" || fail "severity PREPARE: got $(tier_severity PREPARE)"
[[ "$(tier_severity "STOP")"    == "3" ]] && ok "severity STOP=3"    || fail "severity STOP: got $(tier_severity STOP)"

# turn_state_file / telemetry_file helpers
TMP_STATE=$(mktemp)
rm -f "$TMP_STATE"
TURN_PATH=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" turn_state_file)
[[ "$TURN_PATH" == "$TMP_STATE" ]] && ok "turn_state_file returns configured path" || fail "turn_state_file: got '$TURN_PATH'"

TMP_TELEMETRY=$(mktemp)
rm -f "$TMP_TELEMETRY"
TELEMETRY_PATH=$(HANDOFF_TELEMETRY_FILE="$TMP_TELEMETRY" telemetry_file)
[[ "$TELEMETRY_PATH" == "$TMP_TELEMETRY" ]] && ok "telemetry_file returns configured path" || fail "telemetry_file: got '$TELEMETRY_PATH'"

# atomic_write_text_file helper
TMP_ATOMIC=$(mktemp)
rm -f "$TMP_ATOMIC"
atomic_write_text_file "$TMP_ATOMIC" $'line1\nline2\n'
ATOMIC_CONTENT=$(cat "$TMP_ATOMIC")
[[ "$ATOMIC_CONTENT" == $'line1\nline2' ]] && ok "atomic_write_text_file writes exact content" || fail "atomic_write_text_file content mismatch"
TMP_ATOMIC_DIR=$(dirname "$TMP_ATOMIC")
TMP_ATOMIC_BASE=$(basename "$TMP_ATOMIC")
TMP_LEFTOVERS=$(find "$TMP_ATOMIC_DIR" -maxdepth 1 -type f -name ".tmp.$TMP_ATOMIC_BASE.*" | wc -l | tr -d ' ')
[[ "$TMP_LEFTOVERS" == "0" ]] && ok "atomic_write_text_file leaves no temp files" || fail "atomic_write_text_file temp files left behind"
rm -f "$TMP_ATOMIC"

# turn-state roundtrip + mark closed
HANDOFF_TURN_STATE_FILE="$TMP_STATE" mark_turn_open "sess1" "continue" "100" "190" "93" "large" "10-20%" "STOP"
TS_SESSION=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field session_id)
TS_OPEN=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field turn_open)
TS_PERMISSION=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field turn_permission)
TS_RISK=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field predicted_risk_band)
[[ "$TS_SESSION" == "sess1" && "$TS_OPEN" == "true" && "$TS_PERMISSION" == "continue" && "$TS_RISK" == "large" ]] \
    && ok "turn-state roundtrip" || fail "turn-state roundtrip mismatch"

HANDOFF_TURN_STATE_FILE="$TMP_STATE" mark_turn_closed
TS_OPEN_CLOSED=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field turn_open)
TS_PERMISSION_CLOSED=$(HANDOFF_TURN_STATE_FILE="$TMP_STATE" read_turn_state_field turn_permission)
[[ "$TS_OPEN_CLOSED" == "false" && "$TS_PERMISSION_CLOSED" == "none" ]] \
    && ok "mark_turn_closed updates state" || fail "mark_turn_closed mismatch"

# session mismatch invalidation
HANDOFF_TURN_STATE_FILE="$TMP_STATE" mark_turn_open "sess-old" "continue" "100" "190" "93" "large" "10-20%" "STOP"
HANDOFF_TURN_STATE_FILE="$TMP_STATE" discard_turn_state_if_session_mismatch "sess-new"
[[ ! -f "$TMP_STATE" ]] && ok "session mismatch discards turn-state" || fail "session mismatch did not discard turn-state"

# TTL expiration
HANDOFF_TURN_STATE_FILE="$TMP_STATE" mark_turn_open "sess1" "continue" "100" "150" "93" "large" "10-20%" "STOP"
HANDOFF_TURN_STATE_FILE="$TMP_STATE" turn_state_is_expired 149 && fail "turn-state should not expire before TTL" || ok "turn-state not expired before TTL"
HANDOFF_TURN_STATE_FILE="$TMP_STATE" turn_state_is_expired 150 && ok "turn-state expires at TTL boundary" || fail "turn-state should expire at TTL boundary"
HANDOFF_TURN_STATE_FILE="$TMP_STATE" discard_turn_state_if_expired 151
[[ ! -f "$TMP_STATE" ]] && ok "expired turn-state is discarded" || fail "expired turn-state not discarded"
rm -f "$TMP_STATE"

# telemetry persistence + truncation
HANDOFF_TELEMETRY_FILE="$TMP_TELEMETRY" append_telemetry_line '{"delta":1}'
HANDOFF_TELEMETRY_FILE="$TMP_TELEMETRY" append_telemetry_line '{"delta":2}'
TELEMETRY_CONTENT=$(cat "$TMP_TELEMETRY")
[[ "$TELEMETRY_CONTENT" == $'{"delta":1}\n{"delta":2}' ]] && ok "telemetry persists appended lines" || fail "telemetry persistence mismatch"

for i in $(seq 1 25); do
    HANDOFF_TELEMETRY_FILE="$TMP_TELEMETRY" append_telemetry_line "entry-$i"
done
TELEMETRY_LINES=$(wc -l < "$TMP_TELEMETRY" | tr -d ' ')
FIRST_TELEMETRY=$(head -n 1 "$TMP_TELEMETRY")
LAST_TELEMETRY=$(tail -n 1 "$TMP_TELEMETRY")
[[ "$TELEMETRY_LINES" == "20" ]] && ok "telemetry truncates to 20 lines" || fail "telemetry lines: got '$TELEMETRY_LINES'"
[[ "$FIRST_TELEMETRY" == "entry-6" ]] && ok "telemetry keeps newest window start" || fail "telemetry first line: got '$FIRST_TELEMETRY'"
[[ "$LAST_TELEMETRY" == "entry-25" ]] && ok "telemetry keeps newest window end" || fail "telemetry last line: got '$LAST_TELEMETRY'"
rm -f "$TMP_TELEMETRY"


# approval parser helpers
FORMAT_ERR=$(approval_format_error "FINISH_THIS")
[[ "$FORMAT_ERR" == "Use 'FINISH_THIS: <restate your request>'." ]] && ok "approval_format_error for FINISH_THIS" || fail "approval_format_error FINISH_THIS mismatch"

PARSE_FINISH=$(parse_approval_prompt "FINISH_THIS: rebuild the auth module")
FINISH_ACTION=$(printf '%s\n' "$PARSE_FINISH" | grep '^action=' | cut -d= -f2)
FINISH_PROMPT=$(printf '%s\n' "$PARSE_FINISH" | grep '^forwarded_prompt=' | cut -d= -f2-)
[[ "$FINISH_ACTION" == "finish_this" && "$FINISH_PROMPT" == "rebuild the auth module" ]] && ok "parse FINISH_THIS" || fail "parse FINISH_THIS mismatch"

PARSE_APPROVE=$(parse_approval_prompt "APPROVE_ONCE: review the current branch state")
APPROVE_ACTION=$(printf '%s\n' "$PARSE_APPROVE" | grep '^action=' | cut -d= -f2)
APPROVE_PROMPT=$(printf '%s\n' "$PARSE_APPROVE" | grep '^forwarded_prompt=' | cut -d= -f2-)
[[ "$APPROVE_ACTION" == "approve_once" && "$APPROVE_PROMPT" == "review the current branch state" ]] && ok "parse APPROVE_ONCE" || fail "parse APPROVE_ONCE mismatch"

PARSE_STOP=$(parse_approval_prompt "STOP_NOW")
STOP_ACTION=$(printf '%s\n' "$PARSE_STOP" | grep '^action=' | cut -d= -f2)
[[ "$STOP_ACTION" == "stop_now" ]] && ok "parse STOP_NOW" || fail "parse STOP_NOW mismatch"

PARSE_HANDOFF=$(parse_approval_prompt "HANDOFF_NOW")
HANDOFF_ACTION=$(printf '%s\n' "$PARSE_HANDOFF" | grep '^action=' | cut -d= -f2)
[[ "$HANDOFF_ACTION" == "handoff_now" ]] && ok "parse HANDOFF_NOW" || fail "parse HANDOFF_NOW mismatch"

PARSE_LOWER=$(parse_approval_prompt "finish_this: rebuild the auth module")
LOWER_ACTION=$(printf '%s\n' "$PARSE_LOWER" | grep '^action=' | cut -d= -f2)
[[ "$LOWER_ACTION" == "none" ]] && ok "lowercase approval is ignored" || fail "lowercase approval mismatch"

PARSE_EMBEDDED=$(parse_approval_prompt "please FINISH_THIS: rebuild the auth module")
EMBEDDED_ACTION=$(printf '%s\n' "$PARSE_EMBEDDED" | grep '^action=' | cut -d= -f2)
[[ "$EMBEDDED_ACTION" == "none" ]] && ok "embedded keyword is ignored" || fail "embedded keyword mismatch"

PARSE_MISSING_COLON=$(parse_approval_prompt "FINISH_THIS rebuild the auth module")
MISSING_COLON_ACTION=$(printf '%s\n' "$PARSE_MISSING_COLON" | grep '^action=' | cut -d= -f2)
[[ "$MISSING_COLON_ACTION" == "format_error" ]] && ok "missing colon-space becomes format_error" || fail "missing colon-space mismatch"

PARSE_EMPTY_INTENT=$(parse_approval_prompt "APPROVE_ONCE: ")
EMPTY_INTENT_ACTION=$(printf '%s\n' "$PARSE_EMPTY_INTENT" | grep '^action=' | cut -d= -f2)
[[ "$EMPTY_INTENT_ACTION" == "format_error" ]] && ok "empty approval intent becomes format_error" || fail "empty approval intent mismatch"

PARSE_PLAN_IT=$(parse_approval_prompt "PLAN_IT: refactor the auth module")
PLAN_IT_ACTION=$(printf '%s\n' "$PARSE_PLAN_IT" | grep '^action=' | cut -d= -f2)
PLAN_IT_PROMPT=$(printf '%s\n' "$PARSE_PLAN_IT" | grep '^forwarded_prompt=' | cut -d= -f2-)
[[ "$PLAN_IT_ACTION" == "plan_it" && "$PLAN_IT_PROMPT" == "refactor the auth module" ]] && ok "parse PLAN_IT" || fail "parse PLAN_IT mismatch"

PARSE_PLAN_IT_FMT=$(parse_approval_prompt "PLAN_IT rebuild the auth module")
PLAN_IT_FMT_ACTION=$(printf '%s\n' "$PARSE_PLAN_IT_FMT" | grep '^action=' | cut -d= -f2)
[[ "$PLAN_IT_FMT_ACTION" == "format_error" ]] && ok "PLAN_IT missing colon-space becomes format_error" || fail "PLAN_IT format_error mismatch"

PARSE_PLAN_IT_EMPTY=$(parse_approval_prompt "PLAN_IT: ")
PLAN_IT_EMPTY_ACTION=$(printf '%s\n' "$PARSE_PLAN_IT_EMPTY" | grep '^action=' | cut -d= -f2)
[[ "$PLAN_IT_EMPTY_ACTION" == "format_error" ]] && ok "empty PLAN_IT intent becomes format_error" || fail "empty PLAN_IT intent mismatch"

PARSE_PLAN_IT_LOWER=$(parse_approval_prompt "plan_it: refactor the auth module")
PLAN_IT_LOWER_ACTION=$(printf '%s\n' "$PARSE_PLAN_IT_LOWER" | grep '^action=' | cut -d= -f2)
[[ "$PLAN_IT_LOWER_ACTION" == "none" ]] && ok "lowercase plan_it is ignored" || fail "lowercase plan_it mismatch"

PARSE_PLAN_IT_EMBEDDED=$(parse_approval_prompt "please PLAN_IT: refactor the auth module")
PLAN_IT_EMBEDDED_ACTION=$(printf '%s\n' "$PARSE_PLAN_IT_EMBEDDED" | grep '^action=' | cut -d= -f2)
[[ "$PLAN_IT_EMBEDDED_ACTION" == "none" ]] && ok "embedded PLAN_IT is ignored" || fail "embedded PLAN_IT mismatch"

FORMAT_ERR_PLAN_IT=$(approval_format_error "PLAN_IT")
[[ "$FORMAT_ERR_PLAN_IT" == "Use 'PLAN_IT: <restate your request>'." ]] && ok "approval_format_error for PLAN_IT" || fail "approval_format_error PLAN_IT mismatch"

# Multi-line approval prompts must be rejected as format_error
PARSE_MULTILINE_FINISH=$(parse_approval_prompt $'FINISH_THIS: line1\nline2')
MULTILINE_FINISH_ACTION=$(printf '%s\n' "$PARSE_MULTILINE_FINISH" | grep '^action=' | cut -d= -f2)
MULTILINE_FINISH_ERR=$(printf '%s\n' "$PARSE_MULTILINE_FINISH" | grep '^error=' | cut -d= -f2-)
[[ "$MULTILINE_FINISH_ACTION" == "format_error" ]] && ok "multi-line FINISH_THIS rejected" || fail "multi-line FINISH_THIS: got '$MULTILINE_FINISH_ACTION'"
[[ "$MULTILINE_FINISH_ERR" == *"single line"* ]] && ok "multi-line error message mentions single line" || fail "multi-line FINISH_THIS error: '$MULTILINE_FINISH_ERR'"

PARSE_MULTILINE_APPROVE=$(parse_approval_prompt $'APPROVE_ONCE: line1\nline2')
MULTILINE_APPROVE_ACTION=$(printf '%s\n' "$PARSE_MULTILINE_APPROVE" | grep '^action=' | cut -d= -f2)
[[ "$MULTILINE_APPROVE_ACTION" == "format_error" ]] && ok "multi-line APPROVE_ONCE rejected" || fail "multi-line APPROVE_ONCE: got '$MULTILINE_APPROVE_ACTION'"

PARSE_MULTILINE_PLAN=$(parse_approval_prompt $'PLAN_IT: line1\nline2')
MULTILINE_PLAN_ACTION=$(printf '%s\n' "$PARSE_MULTILINE_PLAN" | grep '^action=' | cut -d= -f2)
[[ "$MULTILINE_PLAN_ACTION" == "format_error" ]] && ok "multi-line PLAN_IT rejected" || fail "multi-line PLAN_IT: got '$MULTILINE_PLAN_ACTION'"

PARSE_TAB_FINISH=$(parse_approval_prompt $'FINISH_THIS: foo\tbar')
TAB_FINISH_ACTION=$(printf '%s\n' "$PARSE_TAB_FINISH" | grep '^action=' | cut -d= -f2)
[[ "$TAB_FINISH_ACTION" == "format_error" ]] && ok "tab in FINISH_THIS rejected" || fail "tab FINISH_THIS: got '$TAB_FINISH_ACTION'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
