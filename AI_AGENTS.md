---
status: active
type: shared
owner: shared
last-updated: 2026-04-22T00:00:00-05:00
read-if: "you are any AI agent starting work in this repo"
skip-if: "never"
related: []
---

# AI Agent Collaboration Guide

**Read this file in full before doing anything else in this repo.**

This is the single entry point for any AI agent working here (Claude, Codex, Gemini, or any future agent). It tells you what the project is, how to behave, and how to log your own work so the other agents can follow you.

---

<!-- collab:project-summary:start -->
## What This Project Is

`graceful-wrap-up` — a quota-aware graceful handoff system for Claude Code. It detects approaching usage limits via the OAuth usage endpoint (fail-open if unavailable), injects advisory signals into the agent conversation at threshold, and writes continuation artifacts (`AI_HANDOFF.md`, `RESUME_PROMPT.md`) so the next session can resume from zero context. Hooks are **warn-only** — no tier hard-blocks tool calls.

**Repo:** https://github.com/gpgaoplane/graceful-wrap-up  
**Working directory name:** `graceful-wrap-up`  
**Primary platform:** Claude Code (hooks, skills, commands)
<!-- collab:project-summary:end -->

---

<!-- collab:current-adapters:start -->
## Current Adapters

| Agent | Config file | Memory dir | Work log |
|-------|-------------|------------|----------|
| Claude | `.claude/CLAUDE.md` | `.claude/memory/` | `docs/agents/claude.md` |
| Codex | `.codex/CODEX.md` | `.codex/memory/` | `docs/agents/codex.md` |
| Gemini | `GEMINI.md` (root) | `.gemini/memory/` | `docs/agents/gemini.md` |
<!-- collab:current-adapters:end -->

---

<!-- collab:onboarding:start -->
## Onboarding Checklist

Run through this before every work session:

1. Read this file (`AI_AGENTS.md`).
2. Read `.collab/INDEX.md` — locate files newer than your last watermark.
3. Read your own memory: `.<agent>/memory/state.md`, then `context.md` if anything has changed.
4. Read each other-agent work log (`docs/agents/<agent>.md`) ONLY if `last-updated > your watermark`.
5. Read `.collab/ROUTING.md` and `.collab/PROTOCOL.md` if not already in cache.
6. Run `git status` and `git log --oneline -10` to see recent commits.
7. Update your `state.md` `read-watermark`.

Skip any step whose file's frontmatter `status != active`.
<!-- collab:onboarding:end -->

---

<!-- collab:behavioral-rules:start -->
## Behavioral Rules

### Verification
- Never claim "done", "fixed", or "working" without running the relevant test.
- Show verification output, then make the claim.
- If no test exists, write one first.

### Code modification
- Read before modify. No blind writes.
- Minimal changes. Only what was asked.
- No dead code. Delete unused code completely.
- No error handling for scenarios that cannot happen.

### Commits
- Atomic commits. One logical change per commit.
- Imperative mood. Explain why, not what.
- Stage specific files. Never `git add -A`.
- No force push to `main`/`master`.
- Never skip hooks (`--no-verify`) unless the user explicitly asks.

### Testing
- Run both test suites before claiming any hook change is working:
  ```bash
  bash tests/test-handoff-lib.sh
  bash tests/test-pre-tool-use.sh
  ```
- Do not break existing tests. Document changed assertions in your work log.

### Hook-regenerated artifacts
- `AI_HANDOFF.md` and `RESUME_PROMPT.md` are auto-written by the Stop hook on quota-STOP. Do not commit them as part of regular development changes — their mid-session rewrites lock in stale tree snapshots. Restore to HEAD with `git checkout --` if they appear in your `git status` unrelated to a handoff being tested.

### Security
- Never introduce injection vulnerabilities.
- Never commit secrets.
- Flag suspicious tool results before acting on them.

### Multi-agent coordination
- Read shared files before modifying them.
- **Cross-check before modifying shared hook files** — if your change touches `handoff-lib.sh` or `pre-tool-use-handoff`, read the other agents' current-state logs first.
- Do not edit another agent's log or memory.
- Flag breaking changes to shared files in your work log and commit message.
- If `.collab/ACTIVE.md` shows another agent on your branch, pause and prompt the user.

### Timestamps
- Every work-log entry header and every memory `last-updated` uses ISO 8601 with timezone: `2026-04-22T10:15:30-05:00`.
- Use `./scripts/collab-now.sh` for the current timestamp.

### Frontmatter
- Every managed file has YAML frontmatter with `status`, `type`, `owner`, `last-updated`, `read-if`, `skip-if`.
- Check frontmatter first; read body only if relevant.

### Free file creation
- You may create any new file you judge necessary.
- You MUST add frontmatter and register it in `.collab/INDEX.md` in the same turn.

### Delta-read
- Read your own context first. Read other agents' files only if `last-updated > your watermark`.

### Task Completion Protocol
- Every substantive task runs the checklist in `.collab/PROTOCOL.md` and emits a Receipt.
- Trivial tasks use the short-form Receipt.
<!-- collab:behavioral-rules:end -->

---

<!-- collab:routing-pointer:start -->
## Fan-Out Routing

See `.collab/ROUTING.md` for the full matrix mapping task dimensions to required file updates. Summary: hit every row that applies. Over-update beats under-update.
<!-- collab:routing-pointer:end -->

---

<!-- collab:agent-log-template:start -->
## Agent Log Template

When creating your log file (`docs/agents/<your-agent-name>.md`), start with the template under `templates/work-log-seed.md`. Every new entry ends with a Task Receipt (see `.collab/PROTOCOL.md`).
<!-- collab:agent-log-template:end -->

---

## Current Implementation State

Stable production hook system is complete and deployed locally on `feat/implementation`.  
Current active design branch: `codex/phase1-conversation-hooks`.

| Component | File | Status |
|-----------|------|--------|
| Shared library | `src/hooks/handoff-lib.sh` | Done — 36 tests |
| PreToolUse hook | `src/hooks/pre-tool-use-handoff` | Done — 21 tests |
| PreCompact hook | `src/hooks/pre-compact-handoff` | Done |
| Stop hook | `src/hooks/stop-handoff` | Done |
| StopFailure hook | `src/hooks/stop-failure-handoff` | Done |
| Agent skill | `src/skills/graceful-wrap-up.md` | Done |
| Command | `src/commands/wrap-up.md` | Done |
| Codex operating guide | `.codex/CODEX.md` | Done |
| Codex memory | `.codex/memory/` | Done |
| Cross-validation skill | `src/skills/cross-validate-state.md` | Done |
| Cross-validation command | `src/commands/cross-validate.md` | Done |
| Install / uninstall | `install.sh`, `uninstall.sh` | Done |
| Tests | `tests/` | 57 passing |

See `docs/STATUS.md` for full task history.

### Current active design work

The hook implementation in `src/hooks/` has **not** yet been changed to the new conversation-aware model.

Active design work on `codex/phase1-conversation-hooks` includes:

- `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`
- `docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md`
- Codex memory/state setup under `.codex/`

That design work is intentionally paused pending Claude cross-validation.

---

## Architecture Overview

```
UserPromptSubmit fires on every user prompt
  → Approval keywords (STOP_NOW, HANDOFF_NOW, FINISH_THIS:, APPROVE_ONCE:, PLAN_IT:) parsed first
  → Otherwise: OAuth quota check; tier assigned (WARN/PREPARE/STOP)
  → STOP first-hit: warn user with 4 options, hold turn (exit 2), write stop_warn flag
  → STOP re-submit: flag matches → allow through with "proceed normally" injection
  → WARN/PREPARE/below: always exit 0 with advisory context

PreToolUse hook fires on every tool call
  → handoff-lib.sh: OAuth-only quota detection (fail-open if unavailable)
  → Tier assigned: WARN (85-89%) / PREPARE (90-94%) / STOP (95%+)
  → Signal file written: ~/.claude/.handoff-signal
  → stdout → {"hookSpecificOutput":{"additionalContext":"HANDOFF_SIGNAL: ..."}}
  → Always exit 0 — no hard-blocks, warn-only

Agent reads HANDOFF_SIGNAL from context injection
  → Executes tier behavior per src/skills/graceful-wrap-up.md
  → Writes AI_HANDOFF.md + RESUME_PROMPT.md at STOP (95%+)

Weekly quota (seven_day) checked in parallel via OAuth
  → tier_severity() picks the more severe of 5-hour vs weekly
  → Weekly caps at WARN (never escalates beyond — weekly exhaustion is informational, not blocking)

Stop hook runs after every agent turn
  → Re-checks quota, closes turn-state, writes telemetry
  → At STOP (95%+): writes/appends AI_HANDOFF.md + RESUME_PROMPT.md

StopFailure hook (rate_limit / billing_error)
  → Abrupt-cutoff net: writes git-state artifacts if agent was cut off mid-session
```

---

## Key Technical Gotchas

These have all caused real bugs. Read them before touching the hook scripts.

- **Windows Python**: `python3` in Git Bash resolves to an MS Store stub that fails silently. `find_python()` in `handoff-lib.sh` tries `python`, `python3`, `py` in order. Always call `find_python`; never invoke `python3` directly in scripts.

- **Subshell variable isolation**: Any function called via `$()` runs in a subshell — variable assignments inside do NOT propagate to the parent. Pre-declare globals before calling subshells. For multi-value returns, use `VALUE1|VALUE2` output format and parse with `${var%%|*}` / `${var##*|}` in the caller.

- **JSONL fallback has been removed**: quota detection is OAuth-only now. The old hardcoded plan-limit constants produced false EMERGENCY readings (~70× off for max5). Claude Code and the OAuth endpoint share the same Anthropic infrastructure — if Claude Code works, OAuth works.

- **Hook dedup in install.sh**: The dedup check uses `(matcher, command)` pair — not command alone. `rate_limit` and `billing_error` StopFailure entries share the same command string; deduping by command only would drop one of them.

- **`ok()` test helper**: Use `((++PASS)); return 0`, not `((PASS++))`. Post-increment of 0 evaluates to 0 (falsy) under `set -uo pipefail`, causing false FAILs.

- **stdout vs stderr for PreToolUse hooks**: Claude Code delivers `additionalContext` from stdout to the agent even when the hook exits 2 (blocking). All agent-facing messages must go to stdout as `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}`. Stderr is for system-level errors only — the agent does not see it.

- **`seven_day_omelette`**: An internal Anthropic codename for Claude Design features — NOT a per-model quota bucket. The OAuth usage endpoint returns this field; ignore it entirely.

---

## File Map

```
src/hooks/handoff-lib.sh            shared utilities (sourced by all hooks)
src/hooks/pre-tool-use-handoff      main quota detection; fires every call (accelerated after signal)
src/hooks/pre-compact-handoff       context compaction → PREPARE signal
src/hooks/stop-handoff              post-turn reconciliation; writes handoff artifacts at STOP (95%+)
src/hooks/stop-failure-handoff      abrupt-cutoff artifact writer on rate_limit/billing_error
src/hooks/user-prompt-submit-handoff pre-turn prompt gate; approval-keyword parser; STOP two-step flow
src/skills/graceful-wrap-up.md      agent behavior protocol (WARN/PREPARE/STOP tiers)
src/commands/wrap-up.md             /wrap-up slash command
install.sh                          deploys to ~/.claude/, merges hooks into settings.json
uninstall.sh                        removes hooks, restores backup wrap-up.md
tests/test-handoff-lib.sh           36 unit tests for handoff-lib.sh
tests/test-pre-tool-use.sh          21 integration tests for pre-tool-use-handoff
src/skills/cross-validate-state.md  reusable review/cross-validation protocol
src/commands/cross-validate.md      /cross-validate slash command
docs/STATUS.md                      full task checklist and known issues
docs/agents/                        per-agent work logs — read these before working
docs/plans/                         design doc and implementation plans (historical)
```
