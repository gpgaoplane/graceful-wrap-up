---
name: graceful-wrap-up
description: Quota-aware graceful session handoff. Use when quota pressure is active, when handoff artifacts need to be written, or when you need to preserve state before a session ends.
---

# Graceful Wrap-Up — Agent Behavior Protocol

You are in quota-aware handoff mode. Your priority is to preserve enough project state for a fresh agent to resume safely, especially when the session is near a 5-hour limit.

## Event Model

Watch for quota pressure from any of these hooks:

- `UserPromptSubmit` — pre-turn prompt gate
- `PreToolUse` — tool guard inside the current turn
- `PreCompact` — context-pressure signal
- `Stop` — post-turn reconciliation and fallback artifact writing
- `StopFailure` — abrupt cutoff fallback

Also treat manual `/wrap-up` as an explicit request to write handoff artifacts now.

## Core Rules

- Treat all cost estimates as **ranges**, not exact token counts.
- Prefer the smallest coherent next step once quota pressure is active.
- Do not broaden scope after a one-turn approval.
- At `STOP` (95%+), writing or finishing handoff artifacts becomes the top priority.

## Tier Behavior

The hooks are **warn-only**. No tier hard-blocks tool calls or silently drops prompts. The user decides what to do at each tier.

### WARN (`85-89%`)

- Continue, but keep scope tight.
- If a task looks broad or expensive, describe the likely cost as a range and suggest a narrower slice.

### PREPARE (`90-94%`)

- Before executing: break the request into numbered steps, identify which steps fit in remaining quota, present the breakdown to the user, and wait for confirmation.
- Avoid adjacent work and new large tasks.

### STOP (`95%+`)

Consolidates what used to be STOP + EMERGENCY. First time a user submits a non-approval prompt at STOP, the hook holds the turn and shows four options:

- re-submit the same message to proceed normally
- `PLAN_IT: <request>` — get a step breakdown without executing
- `FINISH_THIS: <request>` — complete one last minimal task, then hand off
- `STOP_NOW` — write handoff artifacts and stop

On re-submit, respond normally to the user's request; prepare handoff artifacts when done. The `stop_warn` flag is session-scoped — once the user chooses to proceed at STOP in a session, subsequent STOP hits do not re-warn.

## Approval Keywords

The user may send one of these forms (exact match, uppercase, must start the message):

- `STOP_NOW` — stop the current request and write handoff artifacts now
- `HANDOFF_NOW` — write handoff artifacts immediately, then stop
- `FINISH_THIS: <restate the request>` — complete only the smallest coherent unit for that restated request, then hand off
- `APPROVE_ONCE: <restate the request>` — answer or act on that one restated request only, with no scope expansion
- `PLAN_IT: <restate the request>` — break the request into numbered steps without executing, wait for the user to confirm which steps to proceed with

Parser rules:

- uppercase only
- must start the message (no leading text)
- `FINISH_THIS:`, `APPROVE_ONCE:`, `PLAN_IT:` require the literal `: ` (colon + space) separator
- approval prompts must be on a **single line** — no embedded newlines or tabs (the hook returns a format error otherwise)

## One-Turn Approval Rule

`FINISH_THIS` and `APPROVE_ONCE` grant a one-turn approval. They are temporary and scoped:

- valid only for the current open turn (TTL ~90 seconds)
- valid only for the user's restated intent
- never reusable for later turns
- `PLAN_IT` does NOT grant execution permission — it only allows planning output

## When To Write Artifacts

Write `AI_HANDOFF.md` and `RESUME_PROMPT.md` when:

- the user invokes `/wrap-up`
- the user sends `STOP_NOW` or `HANDOFF_NOW`
- you are at STOP quota pressure (95%+) and need to preserve state before the session ends

## Artifact Expectations

### `AI_HANDOFF.md`

Make it the main continuity record. Include:

- current quota tier and source
- branch and working-tree state
- completed work that was actually verified
- in-progress work that still needs checking
- blockers, risks, and assumptions
- the exact immediate next step

### `RESUME_PROMPT.md`

Make it paste-ready for the next session. Include:

- a short project reminder
- mandatory first actions
- last verified state
- one exact next action
- things the next agent should avoid redoing

## Minimal Templates

Use these if you need a fast, reliable structure.

### `AI_HANDOFF.md`

```markdown
# AI Handoff — {ISO timestamp}

## Handoff Metadata
- **Tier:** {WARN|PREPARE|STOP}
- **Quota at handoff:** {range or pct}
- **Source:** {agent-written|stop-hook|stop-failure}
- **Project:** {project name}
- **Branch:** {git branch}

## Completed Work (verified)
- {item}

## In Progress (needs re-check)
- {item}

## Blockers / Risks
- {item}

## Files Touched
- `{path}` — {what changed}

## Immediate Next Step
{one specific action}

## Suggested Approach
{short strategy for the next session}
```

### `RESUME_PROMPT.md`

```markdown
# Resume Prompt — {project name} — {date}

You are resuming an interrupted or quota-limited session on **{project name}**.

## First Actions
1. Read `AI_HANDOFF.md`
2. Run `git status` and `git diff HEAD`
3. Re-check anything marked unverified before trusting it
4. Execute the immediate next step if it still matches the working tree

## Context
{short self-contained project/session reminder}

## Last Verified State
{what was definitely working}

## Do This First
**{exact next action}**

## Do NOT Do
- Do not re-do verified work
- Do not trust interrupted work without re-checking it
```

## Final Behavior

Once handoff artifacts are written:

- tell the user handoff is complete
- mention the active tier / quota pressure briefly
- stop taking on new work unless the user explicitly redirects the session
