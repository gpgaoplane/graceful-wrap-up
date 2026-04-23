---
description: Review current repo truth before implementation or handoff, using the cross-validate-state skill
---

Run a full cross-validation pass for the current repo state.

## Step 0: Invoke cross-validate-state skill

Use the `cross-validate-state` skill first and follow its read order.

## Step 1: Establish current truth

Read the active collaboration, memory, and status docs:

- `AI_AGENTS.md`
- `docs/agents/claude.md`
- `docs/agents/codex.md`
- `.codex/CODEX.md` if present
- `.codex/memory/session_state.md` if present
- `.codex/memory/project_context.md` if present
- `docs/STATUS.md`

Then inspect:

- `git status --short`
- `git log --oneline -10`
- the newest relevant plan docs under `docs/plans/`
- the actual source files that represent the feature or design under review

## Step 2: Cross-check for drift

Identify any mismatch between:

- code and docs
- current branch and documented branch status
- active design work and implemented behavior
- install/remove behavior and newly added commands or skills

## Step 3: Report findings first

Use this response order:

1. Findings
2. Open questions or assumptions
3. Current true state
4. Recommendation

If there are no findings, say so explicitly and note any remaining validation gaps.

## Step 4: If requested, patch stale active docs

If the user asked for it, update active status/memory/docs so another agent can review current truth without stale context.
