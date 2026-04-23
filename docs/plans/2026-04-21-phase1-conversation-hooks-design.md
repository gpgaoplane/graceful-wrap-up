# Phase 1 Conversation Hooks Design

**Date:** 2026-04-21  
**Status:** Revised after Claude cross-validation. `UserPromptSubmit` probe completed on 2026-04-21 against Claude Code 2.1.117; implementation can proceed from Task 1.  
**Scope:** Claude Code native hooks only. No background daemon in Phase 1.

---

## 1. Goal

Extend `graceful-wrap-up` from a tool-centric quota guard into a turn-aware quota guard for Claude Code so it can:

- gate risky conversation turns before they begin
- continue guarding tool-heavy turns
- detect conversation-only overshoot after each Claude response
- preserve user choice on a per-turn basis from `90%` through `97%`
- force emergency handoff at `98%+`

This phase explicitly does **not** attempt to interrupt an already-running Claude response mid-stream, because Claude Code does not expose a native hook for that boundary.

---

## 2. Confirmed Claude Code Boundary Model

As of April 21, 2026, the relevant native Claude Code hooks are:

- `UserPromptSubmit`: before Claude processes a user prompt
- `PreToolUse`: before each tool call inside the turn
- `Stop`: after Claude finishes responding
- `StopFailure`: after a failed turn

What Phase 1 can protect:

- before a turn starts
- before each tool call
- after a turn ends

What Phase 1 cannot protect:

- hidden reasoning after a prompt is accepted
- context loading that happens mid-turn before the next hook boundary
- streaming chunks of a single Claude response

Additional confirmed constraint:

- when `UserPromptSubmit` blocks a prompt, that prompt is erased from Claude's context
- the block reason is shown to the user, not routed into Claude as normal conversation context

This means Phase 1 is a boundary-based protection model, not a stream-interruption model, and blocked prompt UX must be designed as a **user re-submission flow**, not as a “Claude sees the blocked request” flow.

---

## 3. Completed Pre-Implementation Gates

These items were the required blockers before implementation. They are now resolved well enough to proceed.

### 3.1 Completed Probe: `UserPromptSubmit` Contract

Probe run date:

- 2026-04-21

Probe environment:

- Claude Code `2.1.117`
- live `claude -p` sessions
- temporary hook injected via `--settings`

Observed stdin payload shape:

```json
{
  "session_id": "<uuid>",
  "transcript_path": "C:\\Users\\PC\\.claude\\projects\\...jsonl",
  "cwd": "D:\\Projects\\self-skills\\graceful-wrap-up",
  "permission_mode": "default",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "<full submitted prompt text>"
}
```

Confirmed findings:

- the full prompt text is available as `prompt`
- `UserPromptSubmit` does fire in non-interactive `claude -p` sessions
- exit `0` with no stdout allows normal processing
- exit `0` with `hookSpecificOutput.additionalContext` works in practice:
  - Claude's reply changed from `NO_CONTEXT` to `ALLOW_CONTEXT_OK` during the probe
- exit `2` blocks the turn before model generation:
  - blocked probe runs produced zero model usage in the final result object
- in `--output-format=stream-json --include-hook-events`, blocked hook stdout appears inside the `hook_response` event, while the final `result` remains empty
- in plain `claude -p` text mode, blocked hook stdout was not surfaced as terminal output during the probe
- a minimal structured block payload such as `{"decision":"block","reason":"..."}` was not given any special visible treatment in `-p` mode; it appeared as raw hook stdout in the hook event stream

Design consequence:

- implementation can safely parse `prompt` directly from stdin JSON
- implementation can rely on allowed-path `additionalContext`
- implementation must **not** depend on non-interactive `claude -p` terminal echo for blocked-prompt UX
- interactive user-facing block messaging remains based on the official documented semantics that the block reason is shown to the user

Why the probe still mattered even with the docs:

- it confirmed the exact local payload keys
- it confirmed allowed-path context injection empirically
- it showed that print-mode blocked-output behavior is not a safe proxy for interactive UX

### 3.2 Approval Round-Trip UX Is Locked

Because a blocked prompt is discarded, the user must re-submit both:

- their approval
- their original intent

An approval message by itself is not sufficient.

This is now encoded directly into the design in Section 7.

### 3.3 Signal Lifecycle Is Defined Before `Stop` Rewrite

The current `stop-handoff` deletes signal/counter state on clean exit. Phase 1 requires inter-turn state retention.

The lifecycle policy is now defined in Section 8:

- what persists within a session
- what clears at turn end
- what clears on a new session
- what survives as fallback after an emergency

---

## 4. Threshold Policy

Phase 1 replaces the earlier `95%` hard-stop model with:

| Range | Tier | Behavior |
|------|------|----------|
| `< 85%` | `NOMINAL` | No user friction |
| `85-89%` | `WARN` | Warn only for expensive prompts/tasks |
| `90-94%` | `PREPARE` | Optioned mode, one-turn approval available |
| `95-97%` | `STOP` | Still optioned mode, stricter one-turn approval |
| `98%+` | `EMERGENCY` | Forced handoff, no options except the emergency escape hatch |

Key policy rule:

- any approval in `90-97%` applies to exactly **one Claude response turn**
- after that turn, quota is re-evaluated again

For this project, `STOP` is no longer a forced stop tier by itself. It is a high-risk optioned tier. `EMERGENCY` becomes the only forced cutoff.

---

## 5. Turn Model

One Claude turn is defined as:

1. user submits one prompt
2. Claude processes the prompt
3. Claude may perform zero or more tool calls
4. Claude emits one final response
5. `Stop` fires

The system must not treat one response as multiple independent conversation turns. Multiple tool calls may happen inside the same turn, but the approval model remains one-prompt / one-response.

---

## 6. Event Responsibilities

### 6.1 `UserPromptSubmit`

Primary role: pre-turn quota and risk gate.

Responsibilities:

- fetch current quota before Claude starts the turn
- classify the submitted prompt using the prompt risk estimator
- store pre-turn quota and prediction metadata for `Stop`
- allow, warn, or block before a large turn starts
- recognize approval re-submission syntax
- create one-turn approval state when the user explicitly re-submits with approval + intent

Behavior by tier:

- `NOMINAL`
  - allow
  - no extra context
- `WARN`
  - allow most prompts
  - add warning context for `large` and `huge` prompts
- `PREPARE`
  - allow `tiny` and `small`
  - allow `medium` with strong warning
  - block `large` and `huge` into approval re-submission flow
- `STOP`
  - allow `tiny` with strong warning
  - block `small`, `medium`, `large`, and `huge` into approval re-submission flow
- `EMERGENCY`
  - block all new prompts except the explicit emergency escape hatch

### 6.2 `PreToolUse`

Primary role: protect tool-heavy turns and honor one-turn approvals.

Responsibilities:

- re-check quota before tools
- preserve the existing tool-path guard
- honor an active one-turn approval for the current open turn
- block immediately if `EMERGENCY` is reached mid-turn

Behavior:

- if current state is `EMERGENCY`, block the tool call immediately
- if a valid one-turn approval exists for the currently open turn, allow tools within that turn
- if approval is missing, expired, or for a closed turn, apply normal tier logic
- if `.handoff-turn-state.session_id` does not match the current session, discard the turn-state entirely before evaluation
- `EMERGENCY` always overrides approval

### 6.3 `Stop`

Primary role: post-turn catch-up, telemetry recording, and state transition.

This is not a small upgrade. It is a **partial rewrite** of the current `stop-handoff` behavior.

Responsibilities:

- re-check quota after every Claude response
- detect conversation-only jumps that occurred with no tool call
- read pre-turn state written by `UserPromptSubmit`
- calculate actual post-turn delta
- record telemetry
- close the current approved turn if one was open
- manage signal lifecycle for the next turn
- immediately enter emergency handoff state if the turn finished at `98%+`
- discard stale turn-state entirely if `.handoff-turn-state.session_id` does not match the current session
- append git snapshot information only when entering real handoff-writing behavior, not on every clean turn

Behavior:

- `< 90%`
  - clear active turn approval
  - clear transient `PREPARE` / `STOP` signal state
- `90-97%`
  - clear active turn approval
  - persist `PREPARE` or `STOP` state for the next prompt within the current session
- `98%+`
  - clear active turn approval
  - set `EMERGENCY`
  - write/update emergency handoff artifacts immediately

`Stop` will not use a “continue talking” pattern in Phase 1. It should remain local and low-cost.

Git snapshot rule:

- no git snapshot append for ordinary `PREPARE` / `STOP` post-turn state maintenance
- append git snapshot only during:
  - `98%+` emergency artifact writing
  - explicit handoff-writing paths

Rationale:

- if `Stop` runs after every turn, PREPARE-level snapshot appends would create noisy handoff artifacts

### 6.4 `PreCompact`

Primary role: compaction-pressure signal.

Responsibilities:

- write `PREPARE` when context compaction indicates pressure
- coordinate with `Stop` and quota-based signals using “most severe wins”

Coordination rule:

- `PreCompact` may raise the session into `PREPARE`
- `PreCompact` may raise but must not lower the current tier
- `Stop` must not blindly erase a same-turn `PREPARE` if compaction remains the most severe known signal
- if signal source is `compaction`, `Stop` must skip normal `<90%` clear behavior unless a fresh quota-based signal supersedes it
- quota-based `STOP` or `EMERGENCY` may supersede compaction-driven `PREPARE`

### 6.5 `StopFailure`

Primary role: fallback emergency artifact generation when the turn already failed.

No major architectural change in Phase 1. It remains the last-resort safety net.

---

## 7. Approval Re-Submission UX

This section is new and mandatory. It resolves the blocked-prompt round-trip problem.

### 7.1 Core Rule

When `UserPromptSubmit` blocks a prompt, the user must re-submit approval **and** intent together in the next message.

The system must not accept bare approvals like:

- `continue`
- `yes`
- `finish-this`

Those contain no original intent and are therefore unusable.

### 7.2 Required Syntax

Blocked prompt messages must instruct the user to re-submit in one of these formats:

- `STOP_NOW`
- `FINISH_THIS: <restate your request>`
- `APPROVE_ONCE: <restate your request>`

At `EMERGENCY`, the system must additionally allow:

- `HANDOFF_NOW`

### 7.2.1 Parser Rules

The approval parser must be deterministic and intentionally strict.

Rules:

- keywords are uppercase-only:
  - `STOP_NOW`
  - `FINISH_THIS:`
  - `APPROVE_ONCE:`
  - `HANDOFF_NOW`
- keyword must appear at the start of the message
- for `FINISH_THIS:` and `APPROVE_ONCE:`, intent extraction rule is:
  - everything after the first literal `: ` (colon + single space) becomes the prompt passed forward
- if the keyword is present but `: ` is missing where required, block with a user-facing format error and do not proceed
- quoted or embedded occurrences later in the message do not count as approval syntax

Examples:

- valid:
  - `FINISH_THIS: rebuild the auth module`
  - `APPROVE_ONCE: review the current branch state`
- invalid:
  - `finish_this: rebuild the auth module`
  - `please FINISH_THIS: rebuild the auth module`
  - `FINISH_THIS rebuild the auth module`

Rationale:

- uppercase-only keeps the parser simple
- start-of-message matching avoids false positives in quoted text or explanations
- `: ` gives a stable split point for extracting the real prompt text

### 7.3 Meaning

- `STOP_NOW`
  - do not run the blocked request
  - enter handoff mode now
- `FINISH_THIS: <request>`
  - allow one Claude turn
  - inject wrap-up guidance to complete only the smallest coherent unit
- `APPROVE_ONCE: <request>`
  - allow one Claude turn
  - inject more permissive “one more turn” guidance
- `HANDOFF_NOW`
  - emergency escape hatch
  - allow handoff behavior even while general prompts are blocked

### 7.4 Rationale

This is an explicit design change made in response to Claude’s review.

Reason:

- blocked prompts do not remain in Claude’s context
- therefore approval without intent cannot reproduce the user’s original request

---

## 8. Signal Lifecycle Policy

### 8.1 Fresh Quota Is Authoritative

Fresh quota checks are the primary truth whenever available.

Persisted signal files are fallback/advisory state, not a substitute for a fresh check.

### 8.2 Within a Session

Within the same session:

- `PREPARE` and `STOP` may persist between turns
- `EMERGENCY` persists until handoff is completed or a fresh check explicitly lowers the state

### 8.3 Across Sessions

Across sessions:

- stale `PREPARE` and `STOP` should not continue blocking by default
- `EMERGENCY` may remain as fallback state until the next fresh quota check occurs

### 8.4 Design Choice and Rationale

Claude suggested “EMERGENCY persists across sessions; PREPARE/STOP clear at session end.” I agree with the spirit, but the design here is slightly more precise:

- fresh quota always wins
- cross-session file persistence is only a fallback when a fresh check has not yet happened

Reason:

- we do not want old files to outrank live quota data
- we do want emergency state to survive long enough to prevent a silent unsafe restart if no fresh check has run yet

---

## 9. State Model

Current repo state files:

- `.handoff-signal`
- `.handoff-counter`

Phase 1 also needs:

- `.handoff-turn-state`
- `.handoff-telemetry`

### 9.1 `.handoff-turn-state`

Required fields:

- `session_id=<id>`
- `turn_open=true|false`
- `turn_permission=none|finish-this|continue`
- `granted_at=<timestamp>`
- `expires_at=<timestamp>`
- `pre_turn_quota_pct=<pct>`
- `predicted_risk_band=<tiny|small|medium|large|huge>`
- `predicted_cost_range=<range>`
- `source_tier=<WARN|PREPARE|STOP|EMERGENCY>`

### 9.2 Turn Identity

The design now uses a hybrid model:

- explicit `turn_open=true|false`
- TTL safety via `expires_at`

This differs slightly from Claude’s “timestamp + TTL only” simplification.

Rationale:

- `turn_open` gives clearer semantics for `PreToolUse` and `Stop`
- TTL still protects against crashes or missing `Stop`

Recommended default:

- approval TTL: 90 seconds, configurable

If approval is older than TTL, treat it as expired.

If `.handoff-turn-state.session_id` does not match the current session:

- discard the turn-state entirely
- do not attempt to honor `turn_open=true` from the old session

Rationale:

- TTL handles the common case
- explicit session mismatch handling prevents inheriting a dead session's open turn within the TTL window

### 9.3 `.handoff-telemetry`

Store a rolling maximum of the last 20 turns:

- recent turn deltas
- recent conversation-only turn deltas
- recent tool-heavy turn deltas
- last predicted risk bands
- last observed actual deltas

Telemetry must truncate on write.

### 9.4 Write Safety

Because matching hooks can run in parallel, all writes to:

- `.handoff-signal`
- `.handoff-counter`
- `.handoff-turn-state`
- `.handoff-telemetry`

must be atomic via temp-file + rename.

---

## 10. Prompt Risk Estimator

### 10.1 Purpose

The prompt risk estimator predicts whether a newly submitted prompt is likely to consume a dangerous amount of the remaining quota.

This is a **risk classifier**, not an exact token predictor.

It is designed to catch prompts that are likely to trigger:

- broad repository understanding
- long explanatory responses
- architecture/status reviews
- extensive hidden context loading
- multi-step tool-heavy follow-on work

### 10.2 Estimator Inputs

At `UserPromptSubmit`, compute:

- `prompt_chars`
- `prompt_est_tokens`
- `quota_pct_current`
- `quota_tier_current`
- `recent_avg_turn_delta_pct`
- `recent_avg_conversation_turn_delta_pct`
- `recent_avg_tool_turn_delta_pct`
- `recent_large_turn_rate`
- `reason_codes[]`

### 10.3 Reason Codes

Possible reason codes include:

- `long_prompt`
- `large_paste`
- `repo_wide_scope`
- `multi_file_scope`
- `detailed_explanation_requested`
- `broad_debugging_request`
- `full_review_requested`
- `planning_requested`
- `rewrite_requested`
- `historically_expensive_pattern`
- `high_quota_low_margin`

### 10.4 Static Risk Signals

Prompt length:

- `< 500 chars` = 0
- `500-1500` = 1
- `1500-4000` = 2
- `> 4000` = 3

Scope and breadth:

- “whole repo”, “entire project”, “everything”, “all files”, “full review” = +3
- “explain in detail”, “comprehensive”, “deep dive”, “full plan” = +2
- broad debugging with no narrow file/path focus = +2
- clearly focused one-file ask = 0

Expected output size:

- short answer / tiny clarification = 0
- moderate explanation or one-file change = +1
- broad walkthrough or design explanation = +2
- full audit / architecture review / large rewrite = +3

Expected context loading:

- no workspace context = 0
- one file / a few files = +1
- subsystem / many files = +2
- full repo understanding = +3

### 10.5 Dynamic Risk Signals

Adapt to current session behavior:

- if recent conversation-only turns average `> 5%` quota delta, +1
- if recent large turns average `> 10%`, +2
- if the last similar prompt caused a large jump, +2
- if current quota is `90-94%`, +1
- if current quota is `95-97%`, +2

### 10.6 Cold Start Behavior

When telemetry is empty or insufficient:

- use static signals only
- emit `confidence=low`

Dynamic signals should not be invented in cold-start state.

### 10.7 Risk Bands

Map total score to:

- `0-2` -> `tiny`
- `3-4` -> `small`
- `5-7` -> `medium`
- `8-10` -> `large`
- `11+` -> `huge`

Also emit:

- `confidence=high` for strong signal matches
- `confidence=medium` for mixed evidence
- `confidence=low` for weak/noisy signals or cold start

### 10.8 Estimated Cost Ranges

These are policy ranges, not exact token counts:

- `tiny` -> `< 2%`
- `small` -> `2-5%`
- `medium` -> `5-10%`
- `large` -> `10-20%`
- `huge` -> `20%+`

### 10.9 Prompt-Time Behavior by Range

| Quota Range | `tiny` | `small` | `medium` | `large` | `huge` |
|------------|--------|---------|----------|---------|--------|
| `<85%` | allow | allow | allow | allow | allow |
| `85-89%` | allow | allow | allow | warn | warn |
| `90-94%` | allow | allow | warn | block-and-require-resubmission | block-and-require-resubmission |
| `95-97%` | warn | block-and-require-resubmission | block-and-require-resubmission | block-and-require-resubmission | block-and-require-resubmission |
| `98%+` | block | block | block | block | block |

Legend:

- `allow`: no blocking
- `warn`: allow with injected context
- `block-and-require-resubmission`: user must send approval + intent together
- `block`: forced emergency handoff except escape hatch

### 10.10 Failure Policy

If quota fetch fails during `UserPromptSubmit`:

- use the normal fallback cascade first
- if all quota sources fail, fail open
- mark confidence low

Rationale:

- we should not brick normal prompt flow solely because quota lookup failed
- this is safer than fail-closed at the hook boundary when the state is uncertain

---

## 11. Guidance Injection

`finish-this-turn` and `continue-one-turn` must produce different Claude-facing guidance.

### 11.1 `FINISH_THIS`

Allowed prompt should inject context like:

- quota is high
- complete only the smallest coherent unit
- wrap up current work and avoid starting follow-on scope

### 11.2 `APPROVE_ONCE`

Allowed prompt should inject context like:

- one additional turn is approved
- keep response scoped to the restated request
- do not broaden into adjacent work

These are intentionally different, even though both consume one-turn approval state.

---

## 12. Artifact and Messaging Changes

The existing user-facing messaging is stale relative to the new policy.

Phase 1 docs and messaging must be updated to reflect:

- `90-97%` is optioned, not forced stop
- `98%+` is the only forced emergency
- approval requires re-submission with intent
- prompt risk estimation is now first-class behavior
- conversation-only overshoot is caught at `Stop`
- `HANDOFF_NOW` is the emergency escape hatch

Files that must be aligned:

- `README.md`
- `docs/STATUS.md`
- `src/skills/graceful-wrap-up.md`
- install/remove messaging where thresholds are described

### 12.1 Install Timeout Adjustment

The current `Stop` hook timeout in `install.sh` is 10 seconds. That is likely too tight for the revised Phase 1 `Stop` workload, which may include:

- quota check
- telemetry write
- turn-state lifecycle updates
- emergency artifact writing

Design requirement:

- raise the installed `Stop` timeout to 15 seconds when Task 6 updates install wiring

Rationale:

- this is not a performance target
- it is headroom to avoid false hook failures during the heavier post-turn flow

---

## 13. Known Limits

Phase 1 still cannot:

- interrupt a turn after Claude has already started processing it
- stop hidden reasoning mid-flight
- see exact token usage while the turn is still underway
- predict exact token consumption from a prompt

Phase 1 can:

- reduce the number of dangerous prompts that start at all
- reduce large late-turn surprises by warning earlier
- catch conversation-only overshoot at the next native boundary
- calibrate future decisions using observed post-turn deltas

---

## 14. Required Test Additions

Beyond the original design, Phase 1 must explicitly test:

- live-probed `UserPromptSubmit` allow vs block behavior
- `UserPromptSubmit` input payload shape, including the full prompt text field
- `UserPromptSubmit` `additionalContext` behavior on the allowed path
- stale `.handoff-turn-state` from a different session being discarded
- approval keyword with no pending blocked state
- malformed approval syntax with missing `: `
- expired approval state
- pre-turn quota written by `UserPromptSubmit` and consumed by `Stop`
- telemetry truncation at rolling max size
- `EMERGENCY` overriding an approved turn in `PreToolUse`
- `HANDOFF_NOW` working during emergency lockout
- `PreCompact` coordination with `Stop`
- compaction-source signals surviving ordinary `<90%` clear logic until superseded
- git snapshot append happening only on real handoff-writing paths
- all quota-source failures in `UserPromptSubmit` resulting in fail-open behavior

---

## 15. Phase 1 Summary

Phase 1 remains a native-hook-only redesign built around:

- `UserPromptSubmit` as the pre-turn gate
- `PreToolUse` as the tool-path guard
- `Stop` as the post-turn catch-up hook
- `PreCompact` as a coordinated pressure signal
- `StopFailure` as emergency fallback
- a conservative prompt risk estimator
- explicit approval re-submission syntax
- per-turn state with explicit turn-open semantics plus TTL safety
- forced emergency only at `98%+`

The required `UserPromptSubmit` probe and the approval/signal lifecycle gates in Section 3 are now complete, so implementation can begin from Task 1.

---

## 16. Post-Review Notes

This revision incorporates Claude’s second review with the following outcomes:

- accepted:
  - parser rules must be explicit
  - probe must confirm input payload shape
  - probe must confirm `additionalContext` on allowed `UserPromptSubmit`
  - implementation plan is now stale and must be revised before coding
  - `Stop` timeout should be increased
  - `PreCompact` must be allowed to raise but not lower severity
  - stale turn-state from another session must be discarded
  - compaction-source signals need source-aware clearing in `Stop`
  - git snapshots should be written only during real handoff paths

- refined rather than accepted verbatim:
  - `UserPromptSubmit` input/output behavior was not treated as fully unknown because the official hooks reference already documents the `prompt` input example and allowed-path `additionalContext`; however, a local probe remains mandatory before implementation

This section exists so future reviewers can distinguish:

- what was taken directly from Claude’s critique
- what was adjusted using the official hooks reference plus project-specific judgment
