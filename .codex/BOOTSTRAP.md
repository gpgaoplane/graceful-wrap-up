# Codex Bootstrap

Read these files in this order before doing any meaningful work in this repo:

1. `AI_AGENTS.md`
2. `docs/agents/claude.md`
3. `docs/agents/codex.md`
4. `docs/STATUS.md` when you need current implementation status

## Purpose

This directory is the Codex-specific adapter layer for the repo. It exists to keep Codex bootstrap and workflow notes isolated from the shared project documentation.

The shared source of truth is still `AI_AGENTS.md`.
Do not duplicate or override shared project rules here unless a rule is genuinely Codex-specific.

## Codex-Specific Expectations

- Treat `AI_AGENTS.md` as canonical for shared collaboration rules, architecture notes, and cross-agent coordination.
- After any significant work session, append to `docs/agents/codex.md`.
- Read a file before editing it.
- Do not modify `docs/agents/claude.md` or any future agent log owned by another agent.
- Leave generated runtime artifacts such as `AI_HANDOFF.md` and `RESUME_PROMPT.md` alone unless the user explicitly asks to regenerate or edit them.
- Before claiming hook-related changes work, run the relevant verification commands and record anything notable in `docs/agents/codex.md`.

## Verification Commands

Use these when changing hook logic or shared behavior:

```bash
bash tests/test-handoff-lib.sh
bash tests/test-pre-tool-use.sh
```

If the environment blocks `bash`, note that explicitly in your final report and in the Codex work log when relevant.
