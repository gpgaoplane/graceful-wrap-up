# Project Context

## Repo Purpose

`graceful-wrap-up` is a quota-aware graceful handoff system for Claude Code. It detects approaching usage limits, escalates through quota tiers, and writes continuation artifacts so a new session can resume with minimal lost context.

## Current Implemented Architecture

- Shared hook library:
  - `src/hooks/handoff-lib.sh`
- Active hook scripts:
  - `src/hooks/pre-tool-use-handoff`
  - `src/hooks/pre-compact-handoff`
  - `src/hooks/stop-handoff`
  - `src/hooks/stop-failure-handoff`
- Skill:
  - `src/skills/graceful-wrap-up.md`
- Install/remove:
  - `install.sh`
  - `uninstall.sh`

## Collaboration Architecture

- Shared canonical collaboration contract:
  - `AI_AGENTS.md`
- Claude adapter:
  - `.claude/CLAUDE.md`
- Codex adapter:
  - `.codex/CODEX.md`
- Cross-agent work logs:
  - `docs/agents/claude.md`
  - `docs/agents/codex.md`

## Current Phase 1 Target

The active design target is a conversation-aware quota model using:

- `UserPromptSubmit` as the pre-turn gate
- `PreToolUse` as the tool-path guard
- `Stop` as the post-turn catch-up hook
- `StopFailure` as emergency fallback

Target threshold model:

- `<85%` nominal
- `85-89%` warn
- `90-94%` optioned prepare
- `95-97%` optioned stop
- `98%+` forced emergency handoff

Approvals in `90-97%` are intended to apply to exactly one Claude response turn.

## Active Design Docs

- `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`
- `docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md`

These are the current active design artifacts for Phase 1. Older plan docs remain useful as historical references but may reflect stale threshold rules or earlier architecture assumptions.

## Reusable Review Entry Point

The repo now includes a reusable Claude-oriented cross-validation workflow:

- Command:
  - `src/commands/cross-validate.md`
- Skill:
  - `src/skills/cross-validate-state.md`

Purpose:

- re-check current repo truth against code, git state, memory files, and active plans
- identify stale docs or assumptions before implementation proceeds
- support future "please review and cross-validate current state" requests without rewriting the full prompt by hand

## Important Repo Truths

- Generated runtime artifacts such as `AI_HANDOFF.md` and `RESUME_PROMPT.md` are not stable source docs.
- Historical docs may be stale relative to actual code and recent commits.
- Active working project name is `graceful-wrap-up`.
- Historical references to `smart-quota-tracker` remain in older docs by design.
