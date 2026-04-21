---
name: graceful-wrap-up
description: Quota-aware graceful session handoff. Use when entering handoff mode, when quota signals are detected, or to manually wrap up a session and write continuation artifacts.
---

# Graceful Wrap-Up — Agent Behavior Protocol

You are entering handoff mode. Your goal: preserve all session context for a zero-knowledge AI agent that will resume this work.

## Signal Sources — Watch For These

Watch for ANY of these at all times:
- `HANDOFF_SIGNAL:` prefix in injected context (from PreToolUse or PreCompact hook)
- System messages containing usage percentage ≥ 85%
- Manual invocation via `/wrap-up` command

Read `~/.claude/.handoff-signal` if it exists — it contains `tier`, `quota`, `source`.

## Tier Behavior

### WARN (85–90%) — Pre-Task Estimation

Before starting any task that meets the estimation threshold below, estimate cost first.

**Estimation threshold:** Task requires 5+ tool calls, OR touches 3+ files, OR runs unknown-duration command, OR spawns a sub-agent.

**Estimation process:**
1. Count expected operations for the task
2. Calculate burn rate: read token totals from `~/.claude/projects/**/*.jsonl` for this session, divide by tool calls made
3. Project: `burn_rate × expected_operations`
4. Compare to remaining quota tokens

**Risk thresholds:**
- Projected cost > 100% of remaining → CRITICAL warning
- Projected cost 80–100% of remaining → HIGH warning
- Projected cost 60–80% of remaining → MEDIUM warning
- Projected cost < 60% of remaining → proceed silently

**Warning format when risk ≥ MEDIUM:**
```
Quota: {X}% used (~{N} tokens remaining, {plan} plan)

About to start: {task — 1 line}
Estimated cost: ~{N} tokens (~{Y}% of remaining)
  — {Z} expected operations at ~{rate} tokens/op (±30% estimate)

Risk: {HIGH|CRITICAL}

  1. proceed           — start, hard stop still fires at 95%
  2. break-into-phases — I'll identify a safe first phase
  3. skip              — don't start this now
```

If user answers `break-into-phases`: identify natural task breakpoints, propose a first phase within safe budget, record deferred items in `AI_HANDOFF.md` under "Deferred Scope".

Small tasks below the estimation threshold: proceed without prompt.

---

### PREPARE (90–95%) — Permission Request

Stop what you are doing. Generate a brief status. Ask for permission.

**Status brief (5 lines max):**
```
Quota: {X}% of 5-hour window
Currently: {one line — what was in progress}
Done: {N items verified complete}
In flight: {N items started but unverified}
Remaining: {what would still need doing}
```

**Permission prompt:**
```
Recommend entering handoff mode to preserve progress cleanly.

  1. yes            — stop now, write full handoff files
  2. finish-this    — complete only the current atomic unit, then stop
  3. no             — continue (95% hard stop still applies, no second ask)
```

After `finish-this`: complete strictly the current operation (one file edit OR one command — not a new task). Then proceed to STOP behavior below.

After `no`: continue, but do not start new large tasks. If quota crosses 95% at next poll, block fires automatically — do not ask again. State: "Quota has crossed the hard stop threshold. Entering handoff mode now."

---

### STOP (95–98%) — Write Artifacts Immediately

No permission request. Your tool call was blocked. Acknowledge the block briefly and write both artifacts now.

**Output to user:**
```
Entering handoff mode. Quota at {X}%. Writing AI_HANDOFF.md and RESUME_PROMPT.md.
```

Then write both files per the templates below. Do not start any other work.

---

### EMERGENCY (98%+) — RESUME_PROMPT.md First

Same as STOP but write `RESUME_PROMPT.md` FIRST, then `AI_HANDOFF.md`.
Reason: if generation is cut off mid-artifact, at minimum the next agent has a resume prompt.

---

## Artifact Templates

### AI_HANDOFF.md

Write this file to the project root (or current working directory if no project root).
Be comprehensive — this is the primary reference for a zero-context agent.

```markdown
# AI Handoff — {ISO timestamp}

## Handoff Metadata
- **Tier:** {WARN|PREPARE|STOP|EMERGENCY}
- **Quota at handoff:** {X}% ({source: oauth|jsonl|heuristic})
- **Source:** agent-written
- **Project:** {project name}
- **Branch:** {git branch}
- **Session duration:** {approx time}

## Project Background
{2–4 sentences. What this project is, what the session was working on,
and why. Complete enough for a zero-context agent to understand without
reading any prior conversation.}

## Completed Work (verified)
- {item} — verified by: {test run / review / user confirmation}

## In Progress (unverified — do not trust without re-checking)
- {item}
  - File: {exact path}
  - Status: {INTERRUPTED|PARTIAL|NEEDS_TEST|NEEDS_REVIEW}
  - Last known state: {what was happening when stopped}

## Blocked Items
- {item} — blocked by: {specific reason}

## Assumptions Made This Session
- {assumption} — basis: {why assumed, what evidence}

## Known Risks / Gotchas
- {anything a fresh agent could easily get wrong}

## Files Touched This Session
- `{path}` — {one-line description of change}

## Deferred Scope (if break-into-phases was used)
- {items explicitly deferred to next session}

## Immediate Next Step
{One specific, actionable instruction. Name the exact file, exact function,
exact command. Do not say "continue working on X" — say exactly what to do.
Example: "Open src/auth.ts line 87 and complete the validateToken() function
which was interrupted; the signature is in place, body is empty."}

## Suggested Approach for Next Session
{2–5 sentences of strategic guidance: what to verify first, what order to
tackle things, what to avoid, what the user cares about most.}
```

---

### RESUME_PROMPT.md

Write this file to the project root. This is pasted verbatim to start the next session — it must require no editing.

```markdown
# Resume Prompt — {project name} — {date}

You are resuming an interrupted work session on **{project name}**.
The previous session was stopped at {X}% quota usage ({tier}).

## First Actions (mandatory — do not skip)
1. Read `AI_HANDOFF.md` in full
2. Run `git status` and `git diff HEAD` — verify working tree matches the handoff record
3. Re-verify any items marked NEEDS_TEST or NEEDS_REVIEW before treating as complete
4. Confirm the "Immediate Next Step" in AI_HANDOFF.md is still valid given current file state

## Context
{3–5 sentences. What this project does, what the session was working on, and what
the goal of this session was. Self-contained — no prior conversation needed.}

## Last Verified Working State
{What was confirmed working before handoff. What tests passed. What the user approved.}

## Do This First
**{Exact first action — specific file, specific function or line, specific command.}**

## Do NOT Do
- Do not re-do work listed as "Completed (verified)" in AI_HANDOFF.md
- Do not trust items marked INTERRUPTED or PARTIAL without re-reading the file
- {project-specific pitfall if any}

## Key Files
- `{path}`: {one-line description}

## Environment
- Branch: {branch}
- Working directory: {cwd}
- {any required env vars, build commands, or setup steps}
```

---

## Post-Artifact Checklist

After writing both files:
1. State clearly to the user: "Handoff complete. AI_HANDOFF.md and RESUME_PROMPT.md written to {path}."
2. Mention the tier and quota level
3. Suggest the user copy RESUME_PROMPT.md content to start the next session
4. Do not start any new work
