---
status: active
type: context
owner: claude
last-updated: 2026-04-23T15:01:47-04:00
read-if: "you need durable project truths as understood by Claude"
skip-if: "status != active or last-updated <= your watermark"
---

# Claude — Durable Context

Append new invariants and project truths below, each with a dated ISO-8601 header.

<!-- section:entries:start -->

## 2026-04-23 — Project identity
`graceful-wrap-up` is a quota-aware graceful handoff system for Claude Code, packaged as an installable repo. It detects approaching usage limits via the Anthropic OAuth usage endpoint, injects advisory signals into the agent's conversation at threshold, and writes continuation artifacts (`AI_HANDOFF.md`, `RESUME_PROMPT.md`) so the next session can resume from zero context. All hooks are **warn-only** — no tier hard-blocks tool calls. Primary platform: Claude Code. Secondary adapters: Codex, Gemini (shared `GEMINI.md` with Antigravity). Repo URL: `https://github.com/gpgaoplane/graceful-wrap-up`.

## 2026-04-23 — Conversation-hook architecture
Phase 1 (shipped 2026-04-23) replaced silent PreToolUse-only tier detection with a conversation-aware model. `UserPromptSubmit` fires on every prompt and parses approval keywords (`STOP_NOW`, `HANDOFF_NOW`, `FINISH_THIS:`, `APPROVE_ONCE:`, `PLAN_IT:`); otherwise it checks quota and assigns a tier (WARN/PREPARE/STOP). STOP first-hit holds the turn (`exit 2`) with a 4-option prompt; STOP re-submit lets the agent through with a "proceed normally" injection. `PreToolUse` continues to emit `HANDOFF_SIGNAL` via `hookSpecificOutput.additionalContext`. `Stop` + `StopFailure` hooks write handoff artifacts at STOP or on `rate_limit`/`billing_error` cutoffs.

## 2026-04-23 — OAuth-only quota detection
Quota source is exclusively the OAuth usage endpoint at `https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`, token from `~/.claude/.credentials.json`). The old JSONL + heuristic cascades were removed — their hardcoded plan limits produced false EMERGENCY readings (~70× off for `max5`). Claude Code and the OAuth endpoint share the same backend; if Claude Code works, OAuth works. If OAuth fails, hooks **fail-open** — no blocking.

## 2026-04-23 — Multi-agent-collab v0.2.0 adoption
As of 2026-04-23 this repo follows `@gpgaoplane/multi-agent-collab@0.2.0`. Shared contract lives in `AI_AGENTS.md` + `.collab/` (INDEX, ROUTING, PROTOCOL, ACTIVE, VERSION). Every task ends with a Task Receipt per `.collab/PROTOCOL.md`. Framework-generic content lives inside `<!-- collab:*:start/end -->` marker blocks in `AI_AGENTS.md` so re-inits can refresh them; project-specific sections (Implementation State, Architecture Overview, Key Technical Gotchas, File Map) live **outside** all markers and are preserved forever.

## 2026-04-23 — Memory routing rules
Two tiers of Claude memory:
1. **External** (`~/.claude/projects/D--Projects-self-skills-graceful-wrap-up/memory/`) — personal preferences, universal Claude quirks. Cross-project relevance.
2. **In-repo** (`.claude/memory/`) — this repo's project truths. Shared via git; other agents read via `.collab/INDEX.md`.

Do not cross-contaminate. External memory entries that became accurate project truths get ported into in-repo `context.md`, not symlinked.

## 2026-04-23 — Standing rule: end-of-task doc update
After every substantive task, update: (a) `docs/STATUS.md` — task checklist + test results, (b) `docs/agents/claude.md` — dated work-log entry with Task Receipt, (c) `.claude/memory/state.md` — current-state and next-steps. This was established as a user standing rule 2026-04-21 to prevent stale docs causing multi-agent repeated work. The multi-agent-collab PROTOCOL fan-out matrix now formalizes it.

## 2026-04-23 — Test discipline
Before claiming any hook change works, run `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh`. As of 2026-04-23 the suite also contains `test-pre-compact.sh`, `test-stop-handoff.sh`, `test-user-prompt-submit.sh` — run those too when touching their respective hooks. Total: 179 assertions across 5 files.

<!-- section:entries:end -->