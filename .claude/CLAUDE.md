# Claude — Project Rules (graceful-wrap-up)

## First read
Read `AI_AGENTS.md` at the repo root before starting any work session. It covers project state, multi-agent rules, architecture, and gotchas shared by all agents.

## Shared collab surface
After `AI_AGENTS.md`, read these before acting:
- `.collab/INDEX.md` — file registry; delta-read against your watermark in `.claude/memory/state.md`
- `.collab/ROUTING.md` — fan-out matrix for end-of-task file updates
- `.collab/PROTOCOL.md` — End-of-Task Protocol and Receipt format
- `.claude/memory/state.md` — your session-local state; update on pause or task boundary

## Claude-specific
- In-repo memory (primary): `.claude/memory/{state,context,decisions,pitfalls}.md` — populated 2026-04-23 with durable project truths
- External memory (cross-project prefs + quirks): `~/.claude/projects/D--Projects-self-skills-graceful-wrap-up/memory/` — check `project_context.md` and `session_progress.md` only for historical context; current project truths live in-repo
- After any significant work session, append to `docs/agents/claude.md`
- Run `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh` before claiming any hook change is working
