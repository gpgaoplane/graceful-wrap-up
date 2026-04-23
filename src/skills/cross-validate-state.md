---
name: cross-validate-state
description: Cross-validate current repo truth against code, git state, memory files, and active plans before implementation or handoff.
---

# Cross-Validate State

Use this when you need to review the current project state carefully before implementation, handoff, or another agent review.

## Goal

Establish current truth from the repo itself, not from stale assumptions.

## Read Order

Read these first:

1. `AI_AGENTS.md`
2. `docs/agents/claude.md`
3. `docs/agents/codex.md`
4. `.codex/CODEX.md` if present
5. `.codex/memory/session_state.md` if present
6. `.codex/memory/project_context.md` if present
7. `docs/STATUS.md`

Then inspect:

1. `git status --short`
2. `git log --oneline -10`
3. active design docs under `docs/plans/` with the newest relevant date
4. actual source files that are the source of truth for the feature under review

## Review Rules

- Prefer code and recent git state over older docs when they conflict.
- Treat generated runtime artifacts like `AI_HANDOFF.md` and `RESUME_PROMPT.md` as historical/runtime output, not primary source docs.
- Distinguish clearly between:
  - implemented behavior
  - active design work
  - historical plans
- If a doc is stale, say so explicitly.

## Required Output Shape

Present findings first.

1. Findings
   - bugs
   - stale assumptions
   - design mismatches
   - missing updates
2. Open questions or assumptions
3. Short summary of current true state
4. Clear recommendation on whether implementation should proceed

If there are no findings, state that explicitly and call out residual risks or validation gaps.

## Focus Areas

When reviewing this repo, pay special attention to:

- current branch vs stable implementation branch
- hook behavior that is implemented today vs only proposed in plans
- threshold model mismatches across docs
- install/uninstall coverage for new commands, skills, or hooks
- Codex memory/state files staying aligned with active docs
