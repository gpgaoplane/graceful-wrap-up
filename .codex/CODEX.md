# Codex Operating Guide

This is the primary Codex entrypoint for this repo.

Read files in this order before doing meaningful work:

1. `AI_AGENTS.md`
2. `.collab/INDEX.md` — file registry; delta-read against your watermark
3. `.collab/ROUTING.md` and `.collab/PROTOCOL.md` — fan-out matrix + End-of-Task Receipt format
4. `.codex/CODEX.md`
5. `.codex/memory/state.md`
6. `.codex/memory/context.md`
7. `docs/agents/codex.md`
8. Other plans or logs only as needed

## Purpose

`AI_AGENTS.md` is the shared collaboration contract.

`.codex/CODEX.md` and `.codex/memory/*` are the Codex-specific operating layer. Keep them lean and current. Do not duplicate shared rules here unless they are truly Codex-specific.

## Memory Files

- `context.md`
  - durable project truths only
- `state.md`
  - current live state only
  - default update target when unsure
- `decisions.md`
  - append-only major decisions
- `pitfalls.md`
  - repeatable pitfalls, causes, and workarounds

## Update Rules

When something changes, route it like this:

- new task, progress, pause point, branch status, next step:
  - update `state.md`
- new durable project truth:
  - update `context.md`
- new project decision:
  - append to `decisions.md`
- new recurring issue or workaround:
  - append to `pitfalls.md`

If unsure, update `state.md`.

## Shared File Rules

- Read a file before editing it.
- Do not modify `docs/agents/claude.md` or other agent-owned logs unless explicitly asked.
- Leave generated runtime artifacts such as `AI_HANDOFF.md` and `RESUME_PROMPT.md` alone unless the user explicitly asks to edit or regenerate them.
- Sync important cross-agent-facing outcomes into `docs/agents/codex.md`, but keep detailed operating memory under `.codex/memory/`.

## Verification Reminder

Before claiming hook-related changes work, run the relevant verification commands when the environment allows it and record anything notable in `docs/agents/codex.md`.
