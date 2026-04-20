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
[[ "$(tier_from_pct 80)"  == "" ]]          && ok "80% = no tier"    || fail "80% should return empty, got '$(tier_from_pct 80)'"
[[ "$(tier_from_pct 86)"  == "WARN" ]]       && ok "86% = WARN"       || fail "86% should be WARN, got '$(tier_from_pct 86)'"
[[ "$(tier_from_pct 90)"  == "PREPARE" ]]    && ok "90% = PREPARE"    || fail "90% should be PREPARE, got '$(tier_from_pct 90)'"
[[ "$(tier_from_pct 91)"  == "PREPARE" ]]    && ok "91% = PREPARE"    || fail "91% should be PREPARE"
[[ "$(tier_from_pct 95)"  == "STOP" ]]       && ok "95% = STOP"       || fail "95% should be STOP, got '$(tier_from_pct 95)'"
[[ "$(tier_from_pct 98)"  == "EMERGENCY" ]]  && ok "98% = EMERGENCY"  || fail "98% should be EMERGENCY, got '$(tier_from_pct 98)'"
[[ "$(tier_from_pct 100)" == "EMERGENCY" ]]  && ok "100% = EMERGENCY" || fail "100% should be EMERGENCY"

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

# get_quota_heuristic
[[ "$(get_quota_heuristic 39)" == "" ]]  && ok "heuristic 39 = empty"  || fail "heuristic 39 should be empty"
[[ "$(get_quota_heuristic 40)" == "87" ]] && ok "heuristic 40 = 87"    || fail "heuristic 40: got $(get_quota_heuristic 40)"
[[ "$(get_quota_heuristic 60)" == "92" ]] && ok "heuristic 60 = 92"    || fail "heuristic 60: got $(get_quota_heuristic 60)"
[[ "$(get_quota_heuristic 80)" == "96" ]] && ok "heuristic 80 = 96"    || fail "heuristic 80: got $(get_quota_heuristic 80)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
