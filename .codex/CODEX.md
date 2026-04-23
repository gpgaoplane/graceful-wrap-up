# Codex Operating Guide

This is the primary Codex entrypoint for this repo.

Read files in this order before doing meaningful work:

1. `AI_AGENTS.md`
2. `.codex/CODEX.md`
3. `.codex/memory/session_state.md`
4. `.codex/memory/project_context.md`
5. `docs/agents/codex.md`
6. Other plans or logs only as needed

## Purpose

`AI_AGENTS.md` is the shared collaboration contract.

`.codex/CODEX.md` and `.codex/memory/*` are the Codex-specific operating layer. Keep them lean and current. Do not duplicate shared rules here unless they are truly Codex-specific.

## Memory Files

- `project_context.md`
  - durable project truths only
- `session_state.md`
  - current live state only
  - default update target when unsure
- `decision_log.md`
  - append-only major decisions
- `failure_patterns.md`
  - repeatable pitfalls, causes, and workarounds

## Update Rules

When something changes, route it like this:

- new task, progress, pause point, branch status, next step:
  - update `session_state.md`
- new durable project truth:
  - update `project_context.md`
- new project decision:
  - append to `decision_log.md`
- new recurring issue or workaround:
  - append to `failure_patterns.md`

If unsure, update `session_state.md`.

## Shared File Rules

- Read a file before editing it.
- Do not modify `docs/agents/claude.md` or other agent-owned logs unless explicitly asked.
- Leave generated runtime artifacts such as `AI_HANDOFF.md` and `RESUME_PROMPT.md` alone unless the user explicitly asks to edit or regenerate them.
- Sync important cross-agent-facing outcomes into `docs/agents/codex.md`, but keep detailed operating memory under `.codex/memory/`.

## Verification Reminder

Before claiming hook-related changes work, run the relevant verification commands when the environment allows it and record anything notable in `docs/agents/codex.md`.
