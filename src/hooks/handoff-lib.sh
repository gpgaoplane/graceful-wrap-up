#!/usr/bin/env bash
# handoff-lib.sh — shared utilities for graceful-handoff hooks
# Source this at the top of each hook script with:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-lib.sh"

# Overridable via env for testing
HANDOFF_SIGNAL_FILE="${HANDOFF_SIGNAL_FILE:-$HOME/.claude/.handoff-signal}"
HANDOFF_COUNTER_FILE="${HANDOFF_COUNTER_FILE:-$HOME/.claude/.handoff-counter}"
HANDOFF_CONFIG_FILE="${HANDOFF_CONFIG_FILE:-$HOME/.claude/.handoff-config}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

# --------------------------------------------------------------------------
# find_python — returns path to first working Python interpreter
# Tries python, python3, py (Windows launcher) in order.
# Windows compatibility: python3 on Git Bash resolves to a broken MS Store
# alias; python or py are reliable.
# --------------------------------------------------------------------------
find_python() {
    for _py in python python3 py; do
        local _cmd
        _cmd=$(command -v "$_py" 2>/dev/null) || continue
        "$_cmd" -c "import sys; sys.exit(0)" 2>/dev/null && echo "$_cmd" && return 0
    done
    return 1
}

# --------------------------------------------------------------------------
# tier_from_pct <percentage>
# Returns WARN/PREPARE/STOP/EMERGENCY or "" if below threshold.
# --------------------------------------------------------------------------
tier_from_pct() {
    local pct="${1:-0}"
    if   (( pct >= 98 )); then echo "EMERGENCY"
    elif (( pct >= 95 )); then echo "STOP"
    elif (( pct >= 90 )); then echo "PREPARE"
    elif (( pct >= 85 )); then echo "WARN"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# tier_from_weekly_pct <percentage>
# Weekly window uses two levels only: WARN at 95%, EMERGENCY at 99%.
# No PREPARE/STOP — weekly exhaustion has no heuristic fallback and is
# non-recoverable within the session, so the escalation is direct.
# --------------------------------------------------------------------------
tier_from_weekly_pct() {
    local pct="${1:-0}"
    if   (( pct >= 99 )); then echo "EMERGENCY"
    elif (( pct >= 95 )); then echo "WARN"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# tier_severity <tier>
# Returns numeric weight for comparing which tier is more severe.
# --------------------------------------------------------------------------
tier_severity() {
    case "${1:-}" in
        EMERGENCY) echo 4 ;;
        STOP)      echo 3 ;;
        PREPARE)   echo 2 ;;
        WARN)      echo 1 ;;
        *)         echo 0 ;;
    esac
}

# --------------------------------------------------------------------------
# get_weekly_quota_oauth
# Reads seven_day.utilization from the OAuth usage endpoint.
# Sets WEEKLY_RESETS_AT global to the ISO reset timestamp.
# Returns integer 0-100 or "" if unavailable.
# --------------------------------------------------------------------------
get_weekly_quota_oauth() {
    WEEKLY_RESETS_AT=""
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    local token; token=$(_get_credentials_field "claudeAiOauth.accessToken") || return 0
    [[ -z "$token" ]] && return 0

    local resp
    resp=$(curl -sf --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 0
    [[ -z "$resp" ]] && return 0

    local py; py=$(find_python) || return 0
    "$py" - <<PYEOF 2>/dev/null
import json, sys
try:
    d = json.loads('''${resp}''')
    sd = d.get('seven_day', {})
    if not isinstance(sd, dict):
        print('')
        sys.exit(0)
    util = sd.get('utilization')
    resets = sd.get('resets_at', '')
    if util is not None:
        v = float(util)
        pct = int(v * 100) if v <= 1.0 else int(v)
        print(f'{pct}|{resets}')
    else:
        print('')
except Exception:
    print('')
PYEOF
}

# --------------------------------------------------------------------------
# write_signal_file <tier> <pct> <source>
# --------------------------------------------------------------------------
write_signal_file() {
    local tier="$1" pct="$2" source="$3"
    printf 'tier=%s\nquota=%s\nsource=%s\ntimestamp=%s\nsession=%s\n' \
        "$tier" "$pct" "$source" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${SESSION_ID:-unknown}" > "$HANDOFF_SIGNAL_FILE"
}

# --------------------------------------------------------------------------
# read_signal_tier — prints tier from .handoff-signal, or "" if missing
# --------------------------------------------------------------------------
read_signal_tier() {
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep '^tier=' "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

# --------------------------------------------------------------------------
# read_signal_field <field>
# --------------------------------------------------------------------------
read_signal_field() {
    [[ -f "$HANDOFF_SIGNAL_FILE" ]] || return 0
    grep "^${1}=" "$HANDOFF_SIGNAL_FILE" | cut -d= -f2
}

# --------------------------------------------------------------------------
# should_check_this_call <call_number>
# Returns 0 (true) if call_number is a multiple of 10.
# --------------------------------------------------------------------------
should_check_this_call() {
    local n="${1:-1}"
    (( n % 10 == 0 ))
}

# --------------------------------------------------------------------------
# get_and_increment_call_count
# Reads counter for SESSION_ID, increments, writes back. Prints new count.
# --------------------------------------------------------------------------
get_and_increment_call_count() {
    local sid="${SESSION_ID:-unknown}" count=0
    if [[ -f "$HANDOFF_COUNTER_FILE" ]]; then
        local stored
        stored=$(cat "$HANDOFF_COUNTER_FILE" 2>/dev/null || echo "")
        local stored_sid="${stored%%:*}" stored_count="${stored##*:}"
        if [[ "$stored_sid" == "$sid" && "$stored_count" =~ ^[0-9]+$ ]]; then
            count="$stored_count"
        fi
    fi
    count=$(( count + 1 ))
    printf '%s:%d' "$sid" "$count" > "$HANDOFF_COUNTER_FILE"
    echo "$count"
}

# --------------------------------------------------------------------------
# _get_credentials_field <dot.path>
# Reads a dot-notation field from CREDENTIALS_FILE using Python.
# e.g. _get_credentials_field "claudeAiOauth.accessToken"
# --------------------------------------------------------------------------
_get_credentials_field() {
    local field="$1"
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    local py; py=$(find_python) || return 0
    "$py" - "$CREDENTIALS_FILE" "$field" << 'PYEOF' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    keys = sys.argv[2].split('.')
    val = data
    for k in keys:
        val = val[k]
    print(str(val).strip())
except Exception:
    print('')
PYEOF
}

# --------------------------------------------------------------------------
# _get_plan_limit
# Auto-detects plan limit from credentials subscriptionType.
# Returns token count (integer). Falls back to max5 (88000) if unknown.
# --------------------------------------------------------------------------
_get_plan_limit() {
    local sub_type
    sub_type=$(_get_credentials_field "claudeAiOauth.subscriptionType" 2>/dev/null || echo "")
    case "${sub_type,,}" in
        pro)          echo 19000  ;;
        max5|max_5)   echo 88000  ;;
        max20|max_20) echo 220000 ;;
        *)
            # Fallback: check .handoff-config
            local cfg_plan
            cfg_plan=$(grep '^plan=' "$HANDOFF_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || echo "")
            case "$cfg_plan" in
                pro)   echo 19000  ;;
                max20) echo 220000 ;;
                *)     echo 88000  ;;  # default: max5
            esac
            ;;
    esac
}

# --------------------------------------------------------------------------
# get_quota_oauth
# Queries the Claude OAuth usage endpoint. Returns integer 0-100 or "".
# NOTE: Uses undocumented endpoint (anthropic-beta: oauth-2025-04-20).
# --------------------------------------------------------------------------
get_quota_oauth() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    local token; token=$(_get_credentials_field "claudeAiOauth.accessToken") || return 0
    [[ -z "$token" ]] && return 0

    local resp
    resp=$(curl -sf --max-time 5 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 0
    [[ -z "$resp" ]] && return 0

    local py; py=$(find_python) || return 0
    "$py" - <<PYEOF 2>/dev/null
import json, sys
try:
    d = json.loads('''${resp}''')
    fh = d.get('five_hour', {})
    if isinstance(fh, dict):
        used  = float(fh.get('used', 0))
        limit = float(fh.get('limit', 0))
        if limit > 0:
            print(int(used * 100 / limit))
            sys.exit(0)
        util = fh.get('utilization')
        if util is not None:
            v = float(util)
            print(int(v * 100) if v <= 1.0 else int(v))
            sys.exit(0)
    elif isinstance(fh, (int, float)):
        v = float(fh)
        print(int(v * 100) if v <= 1.0 else int(v))
        sys.exit(0)
    print('')
except Exception:
    print('')
PYEOF
}

# --------------------------------------------------------------------------
# get_quota_jsonl
# Sums tokens in ~/.claude/projects/**/*.jsonl for the last 5 hours.
# Returns integer 0-100 or "".
# --------------------------------------------------------------------------
get_quota_jsonl() {
    local limit; limit=$(_get_plan_limit)
    local py; py=$(find_python) || return 0
    local projects_override="${HANDOFF_PROJECTS_DIR:-}"

    "$py" - "$limit" "$projects_override" <<'PYEOF' 2>/dev/null
import json, os, glob, sys
from datetime import datetime, timezone, timedelta

limit = int(sys.argv[1])
projects_override = sys.argv[2] if len(sys.argv) > 2 else ''
cutoff = datetime.now(timezone.utc) - timedelta(hours=5)
total = 0

projects_dir = projects_override if projects_override else os.path.join(os.path.expanduser('~'), '.claude', 'projects')
pattern = os.path.join(projects_dir, '**', '*.jsonl')

for path in glob.glob(pattern, recursive=True):
    try:
        with open(path, encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                ts_str = entry.get('timestamp', '')
                if not ts_str:
                    continue
                try:
                    ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                    if ts < cutoff:
                        continue
                except Exception:
                    continue
                usage = entry.get('message', {}).get('usage') or entry.get('usage') or {}
                total += sum(int(usage.get(k, 0)) for k in (
                    'input_tokens', 'output_tokens',
                    'cache_creation_input_tokens', 'cache_read_input_tokens'))
    except Exception:
        continue

if total > 0 and limit > 0:
    print(min(int(total * 100 / limit), 100))
else:
    print('')
PYEOF
}

# --------------------------------------------------------------------------
# get_quota_heuristic <call_count>
# Returns approximate % from tool call count. Always available, least precise.
# --------------------------------------------------------------------------
get_quota_heuristic() {
    local count="${1:-0}"
    if   (( count >= 80 )); then echo "96"
    elif (( count >= 60 )); then echo "92"
    elif (( count >= 40 )); then echo "87"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# get_quota <call_count>
# Full cascade: OAuth → JSONL → heuristic.
# Sets QUOTA_SOURCE to "oauth", "jsonl", "heuristic", or "none".
# Returns integer 0-100 or "" if all methods unavailable.
# --------------------------------------------------------------------------
get_quota() {
    local count="${1:-0}" pct
    QUOTA_SOURCE="none"

    pct=$(get_quota_oauth 2>/dev/null)
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="oauth"; echo "$pct"; return 0
    fi

    pct=$(get_quota_jsonl 2>/dev/null)
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="jsonl"; echo "$pct"; return 0
    fi

    pct=$(get_quota_heuristic "$count")
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        QUOTA_SOURCE="heuristic"; echo "$pct"; return 0
    fi

    echo ""
}

# --------------------------------------------------------------------------
# escape_json <string>
# Escapes a string for safe embedding as a JSON value.
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
# Outputs hookSpecificOutput JSON for additionalContext injection.
# --------------------------------------------------------------------------
emit_context_injection() {
    local msg; msg=$(escape_json "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
        "${HOOK_EVENT_NAME:-PreToolUse}" "$msg"
}
