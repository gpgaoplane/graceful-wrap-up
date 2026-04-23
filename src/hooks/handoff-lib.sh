#!/usr/bin/env bash
# handoff-lib.sh — shared utilities for graceful-handoff hooks
# Source this at the top of each hook script with:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-lib.sh"

# Overridable via env for testing
HANDOFF_SIGNAL_FILE="${HANDOFF_SIGNAL_FILE:-$HOME/.claude/.handoff-signal}"
HANDOFF_COUNTER_FILE="${HANDOFF_COUNTER_FILE:-$HOME/.claude/.handoff-counter}"
HANDOFF_TURN_STATE_FILE="${HANDOFF_TURN_STATE_FILE:-$HOME/.claude/.handoff-turn-state}"
HANDOFF_TELEMETRY_FILE="${HANDOFF_TELEMETRY_FILE:-$HOME/.claude/.handoff-telemetry}"
HANDOFF_CONFIG_FILE="${HANDOFF_CONFIG_FILE:-$HOME/.claude/.handoff-config}"
HANDOFF_STOP_WARN_FILE="${HANDOFF_STOP_WARN_FILE:-$HOME/.claude/.handoff-stop-warn}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

# --------------------------------------------------------------------------
# turn_state_file / telemetry_file
# Path helpers for Phase 1 conversation state.
# --------------------------------------------------------------------------
turn_state_file() {
    printf '%s' "$HANDOFF_TURN_STATE_FILE"
}

telemetry_file() {
    printf '%s' "$HANDOFF_TELEMETRY_FILE"
}

# --------------------------------------------------------------------------
# atomic_write_text_file <path> <content>
# Writes file contents via temp-file + rename.
# --------------------------------------------------------------------------
atomic_write_text_file() {
    local path="$1" content="${2-}"
    local dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.tmp.$(basename "$path").XXXXXX")" || return 1
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$path"
}

# --------------------------------------------------------------------------
# read_kv_field_from_file <path> <field>
# Reads a simple key=value field from a state file.
# --------------------------------------------------------------------------
read_kv_field_from_file() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    grep "^${field}=" "$path" | cut -d= -f2-
}

# --------------------------------------------------------------------------
# write_turn_state_fields <key=value>...
# Rewrites the turn-state file atomically.
# --------------------------------------------------------------------------
write_turn_state_fields() {
    local content=""
    local entry
    for entry in "$@"; do
        content+="${entry}"$'\n'
    done
    atomic_write_text_file "$(turn_state_file)" "$content"
}

# --------------------------------------------------------------------------
# read_turn_state_field <field>
# --------------------------------------------------------------------------
read_turn_state_field() {
    read_kv_field_from_file "$(turn_state_file)" "$1"
}

# --------------------------------------------------------------------------
# clear_turn_state
# --------------------------------------------------------------------------
clear_turn_state() {
    rm -f "$(turn_state_file)"
}

# --------------------------------------------------------------------------
# mark_turn_open <session_id> <permission> <granted_at> <expires_at>
#                <pre_turn_quota_pct> <predicted_risk_band>
#                <predicted_cost_range> <source_tier>
#                [pre_turn_quota_source] [predicted_confidence]
#                [predicted_reason_codes]
#
# NOTE: predicted_risk_band and predicted_cost_range are RESERVED fields.
# Callers currently pass empty strings for both; risk evaluation was removed
# when the tier model was simplified to WARN/PREPARE/STOP. The positions are
# retained so telemetry schema stays stable and a future risk subsystem can
# repopulate them without touching every call site.
# --------------------------------------------------------------------------
mark_turn_open() {
    write_turn_state_fields \
        "session_id=${1:-unknown}" \
        "turn_open=true" \
        "turn_permission=${2:-none}" \
        "granted_at=${3:-0}" \
        "expires_at=${4:-0}" \
        "pre_turn_quota_pct=${5:-}" \
        "predicted_risk_band=${6:-}" \
        "predicted_cost_range=${7:-}" \
        "source_tier=${8:-}" \
        "pre_turn_quota_source=${9:-}" \
        "predicted_confidence=${10:-}" \
        "predicted_reason_codes=${11:-}"
}

# --------------------------------------------------------------------------
# mark_turn_closed
# Preserves existing metadata while closing the active turn.
# --------------------------------------------------------------------------
mark_turn_closed() {
    local path session_id granted_at expires_at quota risk cost tier
    local quota_source confidence reasons
    path="$(turn_state_file)"
    [[ -f "$path" ]] || return 0

    session_id="$(read_turn_state_field session_id)"
    granted_at="$(read_turn_state_field granted_at)"
    expires_at="$(read_turn_state_field expires_at)"
    quota="$(read_turn_state_field pre_turn_quota_pct)"
    risk="$(read_turn_state_field predicted_risk_band)"
    cost="$(read_turn_state_field predicted_cost_range)"
    tier="$(read_turn_state_field source_tier)"
    quota_source="$(read_turn_state_field pre_turn_quota_source)"
    confidence="$(read_turn_state_field predicted_confidence)"
    reasons="$(read_turn_state_field predicted_reason_codes)"

    write_turn_state_fields \
        "session_id=${session_id:-unknown}" \
        "turn_open=false" \
        "turn_permission=none" \
        "granted_at=${granted_at:-0}" \
        "expires_at=${expires_at:-0}" \
        "pre_turn_quota_pct=${quota:-}" \
        "predicted_risk_band=${risk:-}" \
        "predicted_cost_range=${cost:-}" \
        "source_tier=${tier:-}" \
        "pre_turn_quota_source=${quota_source:-}" \
        "predicted_confidence=${confidence:-}" \
        "predicted_reason_codes=${reasons:-}"
}

# --------------------------------------------------------------------------
# discard_turn_state_if_session_mismatch <current_session_id>
# Removes turn-state created by a different session.
# --------------------------------------------------------------------------
discard_turn_state_if_session_mismatch() {
    local current_session="$1" existing_session
    existing_session="$(read_turn_state_field session_id)"
    [[ -z "$existing_session" ]] && return 0
    [[ "$existing_session" == "$current_session" ]] && return 0
    clear_turn_state
}

# --------------------------------------------------------------------------
# turn_state_is_expired [now_epoch]
# Returns 0 when expires_at exists and is older than now.
# --------------------------------------------------------------------------
turn_state_is_expired() {
    local now_epoch="${1:-$(date -u +%s)}"
    local expires_at
    expires_at="$(read_turn_state_field expires_at)"
    [[ "$expires_at" =~ ^[0-9]+$ ]] || return 1
    (( now_epoch >= expires_at ))
}

# --------------------------------------------------------------------------
# discard_turn_state_if_expired [now_epoch]
# --------------------------------------------------------------------------
discard_turn_state_if_expired() {
    turn_state_is_expired "${1:-$(date -u +%s)}" || return 0
    clear_turn_state
}

# --------------------------------------------------------------------------
# append_telemetry_line <line> [max_entries]
# Appends a telemetry record and keeps only the most recent N entries.
# --------------------------------------------------------------------------
append_telemetry_line() {
    local line="$1" max_entries="${2:-20}"
    local path start content=""
    local -a lines=()
    path="$(telemetry_file)"

    if [[ -f "$path" ]]; then
        mapfile -t lines < "$path"
    fi

    lines+=("$line")
    if (( ${#lines[@]} > max_entries )); then
        start=$(( ${#lines[@]} - max_entries ))
        lines=("${lines[@]:$start}")
    fi

    local entry
    for entry in "${lines[@]}"; do
        content+="${entry}"$'\n'
    done

    atomic_write_text_file "$path" "$content"
}

# --------------------------------------------------------------------------
# non_negative_pct_delta <before_pct> <after_pct>
# Returns a floor-at-zero integer delta for quota movement.
# --------------------------------------------------------------------------
non_negative_pct_delta() {
    local before_pct="$1" after_pct="$2"
    if [[ "$before_pct" =~ ^[0-9]+$ && "$after_pct" =~ ^[0-9]+$ ]]; then
        if (( after_pct >= before_pct )); then
            echo $(( after_pct - before_pct ))
        else
            echo 0
        fi
    else
        echo 0
    fi
}

# --------------------------------------------------------------------------
# build_telemetry_line <timestamp> <session_id> <mode> <pre_pct> <post_pct>
#                      <delta_pct> <risk_band> <cost_range> <confidence>
#                      <reason_codes> <result_tier> <quota_source>
# --------------------------------------------------------------------------
build_telemetry_line() {
    local timestamp="$1" session_id="$2" mode="$3" pre_pct="$4" post_pct="$5"
    local delta_pct="$6" risk_band="$7" cost_range="$8" confidence="$9"
    local reason_codes="${10}" result_tier="${11}" quota_source="${12}"

    reason_codes="${reason_codes//;/,}"
    printf 'timestamp=%s;session_id=%s;mode=%s;pre_turn_quota_pct=%s;post_turn_quota_pct=%s;actual_delta_pct=%s;predicted_risk_band=%s;predicted_cost_range=%s;predicted_confidence=%s;reason_codes=%s;result_tier=%s;quota_source=%s' \
        "$timestamp" "$session_id" "$mode" "$pre_pct" "$post_pct" "$delta_pct" \
        "$risk_band" "$cost_range" "$confidence" "$reason_codes" "$result_tier" "$quota_source"
}


# --------------------------------------------------------------------------
# approval_format_error <keyword>
# --------------------------------------------------------------------------
approval_format_error() {
    case "${1:-}" in
        FINISH_THIS)
            printf '%s' "Use 'FINISH_THIS: <restate your request>'."
            ;;
        APPROVE_ONCE)
            printf '%s' "Use 'APPROVE_ONCE: <restate your request>'."
            ;;
        PLAN_IT)
            printf '%s' "Use 'PLAN_IT: <restate your request>'."
            ;;
        *)
            printf '%s' "Invalid approval format."
            ;;
    esac
}

# --------------------------------------------------------------------------
# parse_approval_prompt <message>
# Emits key=value lines:
#   action=none|stop_now|finish_this|approve_once|handoff_now|format_error
#   forwarded_prompt=
#   error=
# --------------------------------------------------------------------------
parse_approval_prompt() {
    local message="$1" forwarded=""
    local multiline_err="Approval prompts must be on a single line without newlines or tabs."

    case "$message" in
        STOP_NOW)
            printf 'action=stop_now\nforwarded_prompt=\nerror=\n'
            return 0
            ;;
        HANDOFF_NOW)
            printf 'action=handoff_now\nforwarded_prompt=\nerror=\n'
            return 0
            ;;
        FINISH_THIS:\ *)
            forwarded="${message#FINISH_THIS: }"
            if [[ -z "$forwarded" ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error FINISH_THIS)"
            elif [[ "$forwarded" == *[$'\n\r\t']* ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$multiline_err"
            else
                printf 'action=finish_this\nforwarded_prompt=%s\nerror=\n' "$forwarded"
            fi
            return 0
            ;;
        APPROVE_ONCE:\ *)
            forwarded="${message#APPROVE_ONCE: }"
            if [[ -z "$forwarded" ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error APPROVE_ONCE)"
            elif [[ "$forwarded" == *[$'\n\r\t']* ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$multiline_err"
            else
                printf 'action=approve_once\nforwarded_prompt=%s\nerror=\n' "$forwarded"
            fi
            return 0
            ;;
        PLAN_IT:\ *)
            forwarded="${message#PLAN_IT: }"
            if [[ -z "$forwarded" ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error PLAN_IT)"
            elif [[ "$forwarded" == *[$'\n\r\t']* ]]; then
                printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$multiline_err"
            else
                printf 'action=plan_it\nforwarded_prompt=%s\nerror=\n' "$forwarded"
            fi
            return 0
            ;;
        FINISH_THIS* )
            printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error FINISH_THIS)"
            return 0
            ;;
        APPROVE_ONCE* )
            printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error APPROVE_ONCE)"
            return 0
            ;;
        PLAN_IT* )
            printf 'action=format_error\nforwarded_prompt=\nerror=%s\n' "$(approval_format_error PLAN_IT)"
            return 0
            ;;
        *)
            printf 'action=none\nforwarded_prompt=\nerror=\n'
            return 0
            ;;
    esac
}

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
# Returns WARN/PREPARE/STOP or "" if below threshold.
# --------------------------------------------------------------------------
tier_from_pct() {
    local pct="${1:-0}"
    if   (( pct >= 95 )); then echo "STOP"
    elif (( pct >= 90 )); then echo "PREPARE"
    elif (( pct >= 85 )); then echo "WARN"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# tier_from_weekly_pct <percentage>
# Weekly window: WARN only at 95%+. Never escalates beyond WARN — weekly
# exhaustion does not hard-block; user is informed and decides what to do.
# --------------------------------------------------------------------------
tier_from_weekly_pct() {
    local pct="${1:-0}"
    if   (( pct >= 95 )); then echo "WARN"
    else echo ""
    fi
}

# --------------------------------------------------------------------------
# tier_severity <tier>
# Returns numeric weight for comparing which tier is more severe.
# --------------------------------------------------------------------------
tier_severity() {
    case "${1:-}" in
        STOP)    echo 3 ;;
        PREPARE) echo 2 ;;
        WARN)    echo 1 ;;
        *)       echo 0 ;;
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
    if [[ -n "${HANDOFF_TEST_WEEKLY_QUOTA_PCT:-}" && "${HANDOFF_TEST_WEEKLY_QUOTA_PCT}" =~ ^[0-9]+$ ]]; then
        printf '%s|%s\n' "${HANDOFF_TEST_WEEKLY_QUOTA_PCT}" "${HANDOFF_TEST_WEEKLY_RESETS_AT:-}"
        return 0
    fi

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
    "$py" - "$resp" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
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
    local content
    content=$(printf 'tier=%s\nquota=%s\nsource=%s\ntimestamp=%s\nsession=%s\n' \
        "$tier" "$pct" "$source" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${SESSION_ID:-unknown}")
    atomic_write_text_file "$HANDOFF_SIGNAL_FILE" "$content"
}

# --------------------------------------------------------------------------
# clear_signal_file
# --------------------------------------------------------------------------
clear_signal_file() {
    rm -f "$HANDOFF_SIGNAL_FILE"
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
    read_kv_field_from_file "$HANDOFF_SIGNAL_FILE" "$1"
}

# --------------------------------------------------------------------------
# should_preserve_compaction_signal <existing_tier> <existing_source> <new_tier>
# Keeps compaction PREPARE active unless a fresh quota-backed PREPARE/STOP
# result supersedes it.
# --------------------------------------------------------------------------
should_preserve_compaction_signal() {
    local existing_tier="$1" existing_source="$2" new_tier="$3"
    local existing_sev new_sev

    [[ "$existing_source" == "compaction" && "$existing_tier" == "PREPARE" ]] || return 1
    existing_sev=$(tier_severity "$existing_tier")
    new_sev=$(tier_severity "$new_tier")
    (( new_sev < existing_sev ))
}

# --------------------------------------------------------------------------
# build_git_snapshot_section <cwd> <timestamp>
# Returns a markdown section with the current git state.
# --------------------------------------------------------------------------
build_git_snapshot_section() {
    local cwd="$1" timestamp="$2"
    local branch="unknown" status="(not a git repo)"
    local diff_stat="(not a git repo)" log="(not a git repo)"

    if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        status=$(git -C "$cwd" status --porcelain 2>/dev/null || echo "(unavailable)")
        diff_stat=$(git -C "$cwd" diff --stat HEAD 2>/dev/null || echo "(no uncommitted changes)")
        log=$(git -C "$cwd" log --oneline -10 2>/dev/null || echo "(no log)")
        [[ -n "$status" ]] || status="(clean working tree)"
        [[ -n "$diff_stat" ]] || diff_stat="(no uncommitted changes)"
        [[ -n "$log" ]] || log="(no log)"
    fi

    printf '## Git Snapshot (stop-handoff hook — %s)\n**Branch:** %s\n\n### Working Tree\n```\n%s\n```\n### Diff Summary\n```\n%s\n```\n### Recent Commits\n```\n%s\n```' \
        "$timestamp" "$branch" "$status" "$diff_stat" "$log"
}

# --------------------------------------------------------------------------
# write_stop_handoff_artifacts <cwd> <tier> <quota_pct> <source> [timestamp]
# Creates baseline handoff artifacts if missing and appends a git snapshot to
# AI_HANDOFF.md when a turn ends at STOP tier (quota >= 95%).
# --------------------------------------------------------------------------
write_stop_handoff_artifacts() {
    local cwd="$1" tier="$2" quota_pct="$3" source="$4"
    local timestamp="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local project handoff_file resume_file snapshot_section
    local handoff_content existing_content resume_content

    project="$(basename "$cwd")"
    handoff_file="${cwd}/AI_HANDOFF.md"
    resume_file="${cwd}/RESUME_PROMPT.md"
    snapshot_section="$(build_git_snapshot_section "$cwd" "$timestamp")"

    if [[ -f "$handoff_file" ]]; then
        existing_content=$(cat "$handoff_file" 2>/dev/null || echo "")
        handoff_content="${existing_content}"
        [[ -n "$handoff_content" ]] && handoff_content+=$'\n\n'
        handoff_content+="${snapshot_section}"$'\n'
    else
        handoff_content=$(cat <<EOF
# AI Handoff — ${timestamp}

## Handoff Metadata
- **Tier:** ${tier}
- **Quota at hook stop:** ${quota_pct}%
- **Source:** stop-hook (${source})
- **Project:** ${project}
- **WARNING:** This baseline handoff was generated automatically after the turn ended at the STOP quota threshold. Prefer any richer human-authored notes if they exist.

## What To Do First
1. Read this file fully
2. Run \`git status\` and \`git diff HEAD\`
3. Verify the latest edits before continuing
4. Keep the next step narrow and quota-aware

${snapshot_section}
EOF
)
    fi
    atomic_write_text_file "$handoff_file" "$handoff_content"

    if [[ ! -f "$resume_file" ]]; then
        resume_content=$(cat <<EOF
# Resume Prompt — ${project} — ${timestamp}

You are resuming work after the previous session ended a turn at the STOP quota threshold (${quota_pct}%).
This prompt was generated by the Stop hook from local repo state.

## First Actions
1. Read \`AI_HANDOFF.md\`
2. Run \`git status\` and \`git diff HEAD\`
3. Verify the last coherent completed work before continuing
4. Keep the next step focused and avoid scope expansion until handoff state is stable

## Context
Project: **${project}**
Signal source: **${source}**
Tier: **${tier}**
EOF
)
        atomic_write_text_file "$resume_file" "$resume_content"
    fi
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
    atomic_write_text_file "$HANDOFF_COUNTER_FILE" "$(printf '%s:%d' "$sid" "$count")"
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
    "$py" - "$resp" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
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
# get_quota_state <call_count>
# OAuth-only quota detection. Falls open (returns "|none") when unavailable.
# Returns "pct|source", where source is oauth/test/none.
# --------------------------------------------------------------------------
get_quota_state() {
    local pct

    if [[ -n "${HANDOFF_TEST_QUOTA_PCT:-}" && "${HANDOFF_TEST_QUOTA_PCT}" =~ ^[0-9]+$ ]]; then
        printf '%s|test\n' "$HANDOFF_TEST_QUOTA_PCT"
        return 0
    fi

    pct=$(get_quota_oauth 2>/dev/null)
    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        printf '%s|oauth\n' "$pct"
        return 0
    fi

    printf '|none\n'
}

# --------------------------------------------------------------------------
# stop_warn_file / write_stop_warn / read_stop_warn_session / clear_stop_warn
# Tracks whether the user has been warned at STOP tier this session,
# enabling the two-step "warn then allow" flow in UserPromptSubmit.
# --------------------------------------------------------------------------
stop_warn_file() {
    printf '%s' "$HANDOFF_STOP_WARN_FILE"
}

write_stop_warn() {
    atomic_write_text_file "$(stop_warn_file)" "${SESSION_ID:-unknown}"
}

read_stop_warn_session() {
    [[ -f "$(stop_warn_file)" ]] || { printf ''; return 0; }
    cat "$(stop_warn_file)" 2>/dev/null
}

clear_stop_warn() {
    rm -f "$(stop_warn_file)"
}

# --------------------------------------------------------------------------
# escape_json <string>
# Escapes a string for safe embedding as a JSON value.
# --------------------------------------------------------------------------
escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --------------------------------------------------------------------------
# emit_context_injection <message>
# Outputs hookSpecificOutput JSON for additionalContext injection.
# Valid for PreToolUse and UserPromptSubmit only.
# --------------------------------------------------------------------------
emit_context_injection() {
    local msg; msg=$(escape_json "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
        "${HOOK_EVENT_NAME:-PreToolUse}" "$msg"
}

# --------------------------------------------------------------------------
# emit_system_message <message>
# Outputs systemMessage JSON for PreCompact and other hooks that do not
# support hookSpecificOutput.
# --------------------------------------------------------------------------
emit_system_message() {
    local msg; msg=$(escape_json "$1")
    printf '{"systemMessage":"%s"}' "$msg"
}
