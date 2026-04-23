#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; ((++PASS)); return 0; }
fail() { echo "FAIL: $1"; ((++FAIL)); return 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/src/hooks/pre-compact-handoff"
[[ -f "$HOOK" ]] || { echo "SKIP: hook not found at $HOOK"; exit 0; }

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

export HANDOFF_SIGNAL_FILE="$TMP/signal"
export HANDOFF_COUNTER_FILE="$TMP/counter"
export HANDOFF_TURN_STATE_FILE="$TMP/turn-state"
export HANDOFF_TELEMETRY_FILE="$TMP/telemetry"
export HANDOFF_CONFIG_FILE="$TMP/config"
export CREDENTIALS_FILE="$TMP/nocreds_missing"
export HANDOFF_PROJECTS_DIR="$TMP/empty_projects"
mkdir -p "$TMP/empty_projects"

fake() {
    printf '{"session_id":"s1","hook_event_name":"PreCompact"}'
}

check_ac() {
    local label="$1" json="$2" needle="$3"
    /c/Python313/python -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    ac = str(d.get('systemMessage', ''))
    assert sys.argv[2] in ac, f'missing {sys.argv[2]!r} in: {ac}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$json" "$needle" 2>/dev/null | grep -q ok \
        && ok "$label" \
        || fail "$label: bad JSON: $json"
}

# no signal -> write compaction PREPARE
rm -f "$HANDOFF_SIGNAL_FILE"
OUT=$(fake | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "no-signal compaction exits 0" || fail "no-signal compaction exit: $EXIT"
TIER=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
SOURCE=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
[[ "$TIER" == "PREPARE" && "$SOURCE" == "compaction" ]] \
    && ok "no-signal compaction writes PREPARE source=compaction" \
    || fail "no-signal compaction signal mismatch: tier='$TIER' source='$SOURCE'"
check_ac "no-signal compaction injects context" "$OUT" "context compaction triggered"

# WARN signal -> compaction raises to PREPARE
printf 'tier=WARN\nquota=87\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
OUT=$(fake | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "WARN->PREPARE compaction exits 0" || fail "WARN->PREPARE compaction exit: $EXIT"
TIER=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
SOURCE=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
[[ "$TIER" == "PREPARE" && "$SOURCE" == "compaction" ]] \
    && ok "WARN compaction raises to PREPARE" \
    || fail "WARN compaction signal mismatch: tier='$TIER' source='$SOURCE'"

# quota-backed PREPARE should not be overwritten by compaction
printf 'tier=PREPARE\nquota=92\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
OUT=$(fake | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "existing PREPARE exits 0" || fail "existing PREPARE exit: $EXIT"
SOURCE=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
[[ "$SOURCE" == "oauth" ]] && ok "existing quota PREPARE source is preserved" || fail "existing quota PREPARE source mismatch: $SOURCE"
[[ -z "$OUT" ]] && ok "existing PREPARE emits no new context" || fail "existing PREPARE should not emit context"

# STOP supersedes compaction (95-97)
printf 'tier=STOP\nquota=96\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
OUT=$(fake | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "existing STOP exits 0" || fail "existing STOP exit: $EXIT"
TIER=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
SOURCE=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
[[ "$TIER" == "STOP" && "$SOURCE" == "oauth" ]] \
    && ok "STOP (95-97) supersedes compaction" \
    || fail "STOP (95-97) supersede mismatch: tier='$TIER' source='$SOURCE'"

# STOP supersedes compaction (98+)
printf 'tier=STOP\nquota=98\nsource=oauth\ntimestamp=old\nsession=s1\n' > "$HANDOFF_SIGNAL_FILE"
OUT=$(fake | bash "$HOOK" 2>/dev/null)
EXIT=$?
[[ $EXIT -eq 0 ]] && ok "existing STOP (98+) exits 0" || fail "existing STOP (98+) exit: $EXIT"
TIER=$(grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
SOURCE=$(grep '^source=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2)
[[ "$TIER" == "STOP" && "$SOURCE" == "oauth" ]] \
    && ok "STOP (98+) supersedes compaction" \
    || fail "STOP (98+) supersede mismatch: tier='$TIER' source='$SOURCE'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
