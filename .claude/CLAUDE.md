# Claude — Project Rules (graceful-wrap-up)

## First read
Read `AI_AGENTS.md` at the repo root before starting any work session. It covers project state, multi-agent rules, architecture, and gotchas shared by all agents.

## Claude-specific
- Memory for this project: `~/.claude/projects/D--Projects-self-skills-graceful-wrap-up/memory/` — check `session_progress.md` and `project_context.md` for full history and known issues
- After any significant work session, append to `docs/agents/claude.md`
- Run `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh` before claiming any hook change is working
