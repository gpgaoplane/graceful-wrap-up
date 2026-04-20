# Graceful Handoff Framework — Design Document

**Date:** 2026-04-20
**Status:** Approved — ready for implementation planning
**Scope:** Claude Code (v1). Codex and Antigravity adapters deferred to future phases.

---

## 1. Goal

Prevent abrupt quota-exhaustion cutoffs in Claude Code sessions by detecting approaching limits early, asking for user approval when appropriate, stopping work gracefully at hard thresholds, and producing comprehensive handoff artifacts that allow a zero-context AI agent to resume the session seamlessly.

---

## 2. Form Factor

**A skill file + four hook scripts + one settings.json edit.**

Not a plugin. The skill (`graceful-wrap-up.md`) is the portable core — plain markdown instructions that can be reused across platforms. The hook scripts are the Claude Code-specific detection layer that wraps the skill. When porting to Codex or Antigravity, the skill content is reused verbatim and only the hook scripts are replaced.

---

## 3. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  DETECTION LAYER (hook scripts — Claude Code specific)          │
│                                                                 │
│  PreToolUse hook (every 10th call)                              │
│    └─ polls quota via cascade: OAuth → JSONL → soft signals     │
│    └─ below threshold: zero injection, zero cost                │
│    └─ WARN (85-90%): writes .handoff-signal, no injection       │
│    └─ PREPARE (90-95%): injects 1-line signal into conversation │
│    └─ STOP (95%+): returns exit 2 → blocks tool call            │
│    └─ EMERGENCY (98%+): returns exit 2 → blocks tool call       │
│                                                                 │
│  PreCompact hook                                                │
│    └─ fires when context about to be compacted (implicit signal)│
│    └─ writes .handoff-signal tier=PREPARE if not already set    │
│    └─ injects 1-line signal into conversation                   │
│                                                                 │
│  Stop hook (clean exit)                                         │
│    └─ if .handoff-signal exists: appends git snapshot section   │
│       to AI_HANDOFF.md                                          │
│    └─ if no signal: does nothing (zero cost)                    │
│                                                                 │
│  StopFailure hook (rate_limit | billing_error)                  │
│    └─ always fires on abrupt cutoff                             │
│    └─ writes emergency AI_HANDOFF.md from git state only        │
│    └─ writes minimal RESUME_PROMPT.md                           │
└─────────────────────────────────────────────────────────────────┘
                          │ injects signal
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  BEHAVIOR LAYER (graceful-wrap-up skill — portable)             │
│                                                                 │
│  Agent reads signal → executes tier-appropriate behavior        │
│  Agent watches for system-reminder usage messages (belt+suspenders)│
│  Agent writes AI_HANDOFF.md + RESUME_PROMPT.md with full context│
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Detection Cascade

Runs inside the PreToolUse hook script on every 10th tool call.

```
Step 1 — OAuth endpoint (hard signal, exact %)
  Prerequisite: ~/.claude/.credentials.json exists (claude login auth)
  Request: GET https://api.anthropic.com/api/oauth/usage
           Authorization: Bearer <token>
           anthropic-beta: oauth-2025-04-20
  Response fields: five_hour, seven_day, seven_day_sonnet, seven_day_opus
  Use: five_hour utilization % as primary signal
  On failure or missing credentials: fall through to Step 2

Step 2 — JSONL token burn rate (inferred signal)
  Read: ~/.claude/projects/**/*.jsonl (current 5-hour window entries)
  Sum: input_tokens + output_tokens + cache_read_tokens + cache_write_tokens
  Compare against plan limit (Pro: ~19k, Max5: ~88k, Max20: ~220k)
  Derive: burn % = tokens_used / plan_limit
  If plan unknown: fall through to Step 3

Step 3 — Soft signals (heuristic fallback)
  Read: ~/.claude/.handoff-counter (tool call count for this session)
  Thresholds: count >= 40 → WARN, >= 60 → PREPARE, >= 80 → STOP
  Session age: > 30 min + dense context → escalate one tier
  Always available, least precise
```

**Dynamic threshold adjustment (applies to all detection methods):**
- Large or risky operation pending: subtract 5% from each tier boundary
- Task actively in progress: subtract 5% from each tier boundary
- Both conditions: subtract 10% (most conservative)

---

## 5. Tier System

### Tier 0: NOMINAL (< 85%)
No action. Zero hook output. Zero agent overhead.

---

### Tier 1: WARN (85–90%)

**Mechanism:** Hook writes `.handoff-signal` file. No conversation injection. No user prompt on its own.

**Agent behavior — pre-task estimation:**

Before initiating any task that meets the estimation threshold (5+ expected tool calls, OR 3+ files to touch, OR unknown-duration command, OR sub-agent spawn), the agent MUST:

1. Derive remaining quota from the `.handoff-signal` file or known detection data
2. Estimate task scope: count expected operations
3. Calculate burn rate: `tokens_used_this_session / tool_calls_this_session` (from JSONL)
4. Project cost: `burn_rate × expected_operations`
5. Compare: `projected_cost / remaining_quota_tokens`

**Risk routing:**

| Projected cost vs remaining | Risk | Action |
|-----------------------------|------|--------|
| > 100% of remaining | Critical | Always warn |
| 80–100% of remaining | High | Warn with strong advisory |
| 60–80% of remaining | Medium | Warn with lighter advisory |
| < 60% of remaining | Low | Proceed silently, no prompt |

**Warning format (Medium or above):**
```
Quota: {X}% used (~{N} tokens remaining, {plan} plan)

About to start: {task description — 1 line}
Estimated cost: ~{N} tokens (~{Y}% of remaining)
  — {Z} expected operations at ~{rate} tokens/op current burn rate
  — estimate may be off by ±30%

Risk: {HIGH|CRITICAL} — task may not complete within remaining quota.

  1. proceed           — start anyway, hard stop fires at 95% if not done
  2. break-into-phases — I'll identify a safe first phase that fits now
  3. skip              — don't start this now
```

If user answers `break-into-phases`: agent identifies natural breakpoints, proposes a first phase within the estimated safe budget, and saves the remainder for the next session (records deferred scope in handoff state).

**Small tasks at WARN tier proceed without any prompt.** This tier is never a blanket block.

---

### Tier 2: PREPARE (90–95%)

**Mechanism:** Hook injects one-line signal into conversation:
```
HANDOFF_SIGNAL: quota={X}% source={oauth|jsonl|heuristic} tier=PREPARE
```
Also writes `.handoff-signal` file with tier=PREPARE.

**Agent behavior — permission request:**

Agent stops what it is doing, generates a brief inline status, and asks for user approval.

**Status brief format:**
```
Quota: {X}% of 5-hour window
Currently: {one line — what task was in progress}
Done: {N items verified complete}
In flight: {N items started but unverified — list them}
Remaining: {what would still need doing this session}
```

**Permission prompt:**
```
Recommend entering handoff mode to preserve progress cleanly.

  1. yes            — stop now, write full handoff files
  2. finish-this    — complete only the current atomic unit, then stop
  3. no             — continue as-is (95% hard stop still applies)
```

**After user response:**
- `yes`: agent enters handoff mode immediately, writes both artifacts
- `finish-this`: agent completes strictly the current atomic unit (one file edit or one command — not a new task), then writes artifacts
- `no`: agent continues, avoids starting new large tasks, 95% hard stop unchanged and non-negotiable

**If user answers `no` and quota later crosses 95%:** the tool block fires automatically with no second permission request. The agent states: "Quota has crossed the hard stop threshold. Entering handoff mode now." — no apology, no re-asking.

---

### Tier 3: STOP (95–98%)

**Mechanism:** Hook returns exit code 2, blocking the tool call Claude Code was about to run. Block message injected:
```
HANDOFF_SIGNAL: quota={X}% tier=STOP — tool call blocked. Write handoff files now.
```

**Agent behavior:** No permission request. Agent acknowledges the block and immediately:
1. Writes `AI_HANDOFF.md` in full (comprehensive — see Section 7)
2. Writes `RESUME_PROMPT.md` in full (see Section 7)
3. Outputs a brief summary to the user confirming artifacts are written
4. Stops

No new work is initiated under any circumstances at this tier.

---

### Tier 4: EMERGENCY (98–100%)

**Mechanism:** Hook returns exit code 2 (same as STOP). Block message:
```
HANDOFF_SIGNAL: quota={X}% tier=EMERGENCY — write RESUME_PROMPT.md first, then AI_HANDOFF.md
```

**Agent behavior:** Same as STOP but with explicit priority ordering:
1. Write `RESUME_PROMPT.md` FIRST (smallest, highest value to next agent)
2. Then write `AI_HANDOFF.md`

Rationale: if the session gets cut off mid-artifact (which is possible at 98%+), at minimum the next agent has a resume prompt.

---

### Tier 5: DEAD (StopFailure — rate_limit | billing_error)

**Mechanism:** StopFailure hook fires after the session has been cut off. Agent is gone. Hook script runs without conversation context.

**Hook script behavior:**
1. Write `AI_HANDOFF.md` from: `git status --porcelain`, `git diff HEAD`, `git log --oneline -10`, existing task state files, timestamp
2. Write minimal `RESUME_PROMPT.md` with project name, last known git state, instruction to read AI_HANDOFF.md
3. Mark both files clearly: `## Source: EMERGENCY (session cutoff — no agent context)`

Quality is lower than agent-written artifacts but gives the next agent a working foundation.

---

## 6. Token Cost Optimization

Optimization applies ONLY to ongoing monitoring and inter-turn signals. Artifact files are intentionally comprehensive (see Section 7).

| Component | Optimization |
|-----------|-------------|
| PreToolUse hook | Fires every 10th call (not every call) |
| Hook injection below threshold | Zero — nothing injected |
| Hook injection above WARN | One terse line only |
| `.handoff-signal` file | Tiny machine-readable key=value, ~5 lines |
| `.handoff-counter` file | Single integer |
| Skill file | Terse imperatives, no prose explanations. Target < 130 lines |
| Stop hook on clean sessions | Does nothing if no `.handoff-signal` exists |
| Agent status brief (PREPARE tier) | 5 lines maximum |

---

## 7. Artifact Specifications

Both artifacts are written by the agent (with full conversation context) at STOP/EMERGENCY tier, or by the hook script at DEAD tier (git state only).

### 7.1 `AI_HANDOFF.md`

Comprehensive. Self-contained for a zero-context agent. No length limit.

```markdown
# AI Handoff — {ISO timestamp}

## Handoff Metadata
- **Tier:** {PREPARE|STOP|EMERGENCY|DEAD}
- **Quota at handoff:** {X}% ({source: oauth|jsonl|heuristic})
- **Source:** {agent-written|emergency-hook-only}
- **Project:** {project name}
- **Branch:** {git branch}
- **Session duration:** {approx}

## Project Background
{2–4 sentences: what this project is, what we were trying to accomplish this session,
and why. Enough for a zero-context agent to understand the work without reading prior
conversation.}

## Completed Work (verified)
- {item} — verified by: {test run / review / user confirmation / none}
- {item}

## In Progress (unverified — do not trust without re-checking)
- {item}
  - File: {path}
  - Status: {INTERRUPTED|PARTIAL|NEEDS_TEST|NEEDS_REVIEW}
  - Last known state: {brief description of where it was left}

## Blocked Items
- {item} — blocked by: {reason}

## Assumptions Made This Session
- {assumption} — basis: {why this was assumed}

## Known Risks / Gotchas
- {anything a new agent could easily get wrong}

## Git State
{output of: git status --porcelain}

## Diff Summary
{output of: git diff --stat HEAD}

## Recent Commits
{output of: git log --oneline -10}

## Files Touched This Session
{list of modified/created/deleted files with one-line description of change}

## Deferred Scope (if break-into-phases was used)
- {items explicitly deferred to next session}

## Immediate Next Step
{One specific, actionable instruction. Name the exact file, exact task, exact command.
Do not say "continue working on X" — say "open src/foo.ts line 42 and complete the
validateToken() function which was interrupted mid-write."}

## Suggested Approach for Next Session
{2–5 sentences of strategic guidance for the next agent — what to verify first,
what order to tackle things, what to avoid.}
```

---

### 7.2 `RESUME_PROMPT.md`

Complete cold-start prompt. Pasted verbatim to begin the next session. Should require no editing.

```markdown
# Resume Prompt — {project name} — {date}

You are resuming an interrupted work session on **{project name}**.
The previous session was cut off at {X}% quota usage.

## First Actions (do these before anything else)
1. Read `AI_HANDOFF.md` in full
2. Run `git status` and `git diff HEAD` to confirm your working tree matches the handoff record
3. Verify any items marked NEEDS_TEST or NEEDS_REVIEW before treating them as complete
4. Confirm the "Immediate Next Step" in AI_HANDOFF.md is still valid given current file state

## Context
{3–5 sentences: what this project does, what the session was working on, and what
the goal of this session was. Self-contained — no prior conversation needed.}

## Last Verified Working State
{What was confirmed working before handoff. What tests passed. What the user approved.}

## Do This First
**{Exact first action — specific file, specific function, specific command.}**

## Do NOT Do
- Do not re-do work listed as "Completed (verified)" in AI_HANDOFF.md
- Do not trust items marked INTERRUPTED or PARTIAL without re-reading the file and
  verifying current state
- {any project-specific pitfalls worth flagging}

## Key Files
- `{path}`: {one-line description of what it is and why it matters}
- `{path}`: {one-line description}

## Environment
- Branch: {branch}
- Working directory: {cwd}
- {any relevant env vars or setup steps needed}
```

---

## 8. Files to Create

| File | Location | Action |
|------|----------|--------|
| `graceful-wrap-up.md` | `~/.claude/skills/` | Create (new skill) |
| `hooks/pre-tool-use-handoff` | `~/.claude/hooks/` | Create (new hook script) |
| `hooks/pre-compact-handoff` | `~/.claude/hooks/` | Create (new hook script) |
| `hooks/stop-handoff` | `~/.claude/hooks/` | Create (new hook script) |
| `hooks/stop-failure-handoff` | `~/.claude/hooks/` | Create (new hook script) |
| `~/.claude/settings.json` | `~/.claude/` | Edit — deep merge, add 4 hook entries |
| `~/.claude/commands/wrap-up.md` | `~/.claude/commands/` | Edit — enhance existing command |

**Files NOT modified:** `~/.claude/CLAUDE.md`, `~/.claude/rules/`, any project-specific files.

**settings.json strategy:** Read current content first. Add new hook entries by appending to existing arrays (PreToolUse, PreCompact arrays may not exist yet — create them). Never replace existing Stop/Notification/PostToolUseFailure entries. Existing Stop entry (calls notify) is preserved; new stop-handoff is added as a second entry in the Stop array.

---

## 9. Portability Model

```
PORTABLE CORE (graceful-wrap-up.md skill)
  — agent behavior instructions
  — tier definitions and decision logic
  — artifact templates (AI_HANDOFF.md, RESUME_PROMPT.md)
  — works on any platform that supports skill/instruction injection

CLAUDE CODE ADAPTER (this implementation)
  — 4 hook scripts
  — settings.json hook wiring
  — OAuth endpoint detection
  — JSONL burn rate detection

CODEX ADAPTER (future)
  — Replace hook scripts with Codex event handlers
  — Reuse skill content verbatim (or as AGENTS.md section)
  — Replace OAuth call with Codex quota API if available
  — Reuse artifact templates unchanged

ANTIGRAVITY ADAPTER (future)
  — Replace hook scripts with Antigravity event system
  — Reuse skill content as system prompt section
  — Reuse artifact templates unchanged
```

Artifact format (`AI_HANDOFF.md`, `RESUME_PROMPT.md`) is platform-agnostic plain markdown. Any agent on any platform can read and act on it.

---

## 10. settings.json Hook Wiring

New entries to add (deep merge into existing settings):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-tool-use-handoff",
            "timeout": 8000
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-compact-handoff",
            "timeout": 5000
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-handoff",
            "timeout": 10000
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "matcher": "rate_limit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-failure-handoff",
            "timeout": 15000
          }
        ]
      },
      {
        "matcher": "billing_error",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-failure-handoff",
            "timeout": 15000
          }
        ]
      }
    ]
  }
}
```

Existing `Stop` entry (calls notify) is preserved. New stop-handoff is a second entry in the same array — both fire on clean stop.

---

## 11. State Files

Small machine-readable files written by hooks to coordinate between hooks and agent:

| File | Location | Content | Written by | Read by |
|------|----------|---------|-----------|---------|
| `.handoff-signal` | `~/.claude/` | `tier=PREPARE\nquota=92\nsource=oauth\ntimestamp=...` | PreToolUse, PreCompact hooks | Agent (via skill), Stop hook |
| `.handoff-counter` | `~/.claude/` | `{session_id}:{tool_call_count}` | PreToolUse hook | PreToolUse hook |

Both files are cleaned up by the Stop hook after a clean exit. The StopFailure hook reads but does not clean them (preserves state for debugging).

---

## 12. Validation Checklist

Before declaring implementation complete:

- [ ] PreToolUse hook fires silently below 85% (verify: zero injection in tool output)
- [ ] PreToolUse hook injects correct tier signal above 90% (verify: injection appears in context)
- [ ] PreToolUse hook blocks tool call above 95% (verify: exit code 2 behavior)
- [ ] PreCompact hook writes .handoff-signal correctly
- [ ] Stop hook does nothing when .handoff-signal absent
- [ ] Stop hook appends git snapshot when .handoff-signal present
- [ ] StopFailure hook writes both artifacts from git state only
- [ ] WARN tier: small tasks proceed without prompt
- [ ] WARN tier: large task at low risk proceeds without prompt
- [ ] WARN tier: large task at high risk shows warning + 3 options
- [ ] PREPARE tier: status brief + permission prompt appears correctly
- [ ] PREPARE tier: `finish-this` response behavior is correct
- [ ] PREPARE tier: `no` response leaves 95% hard stop intact
- [ ] STOP tier: no permission request, immediate artifact generation
- [ ] EMERGENCY tier: RESUME_PROMPT.md written before AI_HANDOFF.md
- [ ] AI_HANDOFF.md produced by agent is comprehensive and self-contained
- [ ] RESUME_PROMPT.md can cold-start a new session without edits
- [ ] settings.json existing hooks (Stop→notify, Notification, PostToolUseFailure) unmodified
- [ ] Skill file loads and agent follows tier behavior correctly
