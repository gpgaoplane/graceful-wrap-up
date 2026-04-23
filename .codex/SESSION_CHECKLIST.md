# Codex Session Checklist

## Start

1. Read `AI_AGENTS.md`
2. Read `.codex/CODEX.md`
3. Read `.codex/memory/session_state.md`
4. Read `.codex/memory/project_context.md`
5. Read `docs/agents/codex.md` if cross-agent history matters
6. Check `git status --short`
7. Check recent commits with `git log --oneline -10`

## End

1. Re-run verification relevant to your change
2. Update `.codex/memory/session_state.md`
3. Update `project_context.md`, `decision_log.md`, or `failure_patterns.md` only if warranted
4. Update `docs/agents/codex.md`
5. Summarize what changed, what was verified, and any remaining risks

## Shared-File Reminder

If editing any of these, read the latest shared guidance first:

- `src/hooks/handoff-lib.sh`
- `src/hooks/pre-tool-use-handoff`
- `install.sh`
- `uninstall.sh`
- `AI_AGENTS.md`
