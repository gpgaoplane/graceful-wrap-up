# graceful-wrap-up

A quota-aware graceful handoff system for Claude Code.

This branch implements the Phase 1 conversation-aware hook model: prompt gating at `UserPromptSubmit`, tool guarding at `PreToolUse`, compaction signaling at `PreCompact`, post-turn reconciliation at `Stop`, and abrupt-cutoff recovery at `StopFailure`.

## What It Does

| Quota | Behavior |
|-------|----------|
| 85–89% | `WARN`: allow prompts, inject advisory context ("approaching the limit") |
| 90–94% | `PREPARE`: allow prompts, inject step-breakdown instruction before executing |
| 95%+ | `STOP`: first hit warns the user with four options and holds the turn; re-submit proceeds normally |
| Abrupt cutoff | `StopFailure` writes recovery artifacts from git state |

Hooks are **warn-only** — no tier hard-blocks tool calls or silently drops prompts. The user always has the final say.

## Approval Syntax

At STOP, the user can choose one of these (exact match, uppercase, single line, must start the message):

- `STOP_NOW` — stop and write handoff artifacts now
- `HANDOFF_NOW` — write handoff artifacts immediately, then stop
- `FINISH_THIS: <restate the request>` — complete one last minimal task, then hand off
- `APPROVE_ONCE: <restate the request>` — answer or act on that one restated request only, no scope expansion
- `PLAN_IT: <restate the request>` — break the request into numbered steps without executing, then wait for confirmation

`FINISH_THIS` / `APPROVE_ONCE` grant a one-turn execution approval (~90s TTL). `PLAN_IT` grants planning-only output (no execution). Multi-line approval prompts are rejected with a format error.

## Install

```bash
git clone https://github.com/gpgaoplane/graceful-wrap-up.git
cd graceful-wrap-up
./install.sh
```

Then edit `~/.claude/.handoff-config` and set your plan:
```
plan=max5   # or: pro, max20
```

Restart Claude Code for hooks to take effect.

## Uninstall

```bash
./uninstall.sh
```

Restores your previous `wrap-up.md` and removes all hook entries from `settings.json`.

## Skill Only (no hooks)

If you only want the agent behavior without automatic detection:
```bash
cp src/skills/graceful-wrap-up.md ~/.claude/skills/
```
Activate manually with `/graceful-wrap-up` or the agent detects quota warnings from system messages.

## How It Works

**Detection:** OAuth usage endpoint only. Falls open (no tier) if credentials or connectivity are unavailable — the system never fails closed.

**Prompt gating:** `UserPromptSubmit` checks quota and either allows through with an advisory injection (WARN/PREPARE) or — at STOP on the first hit — surfaces the four-option warning and holds the turn.

**Runtime guardrails:** `PreToolUse` injects advisory context on every 10th tool call (accelerated to every call once any signal is active); `PreCompact` raises the session to `PREPARE` without downgrading a stronger quota-backed tier.

**Post-turn catch-up:** `Stop` re-checks quota after every response, closes one-turn approvals, records rolling telemetry, preserves compaction-driven `PREPARE` correctly, and writes recovery handoff artifacts at STOP (95%+).

**Abrupt-cutoff net:** `StopFailure` writes git-state-only artifacts when the session is cut off by rate_limit or billing_error.

## Portability

The skill file (`src/skills/graceful-wrap-up.md`) is platform-agnostic. A Codex adapter and Codex memory layer now exist in this repo. Antigravity integration remains deferred for a future phase.

## Collaboration

This repo now includes a shared AI collaboration guide in `AI_AGENTS.md`.

- Claude uses `.claude/CLAUDE.md`
- Codex uses `.codex/CODEX.md`
- Agent work logs live in `docs/agents/`
- A reusable review command is available at `/cross-validate`

If you are using an AI agent to work in this repo, start with `AI_AGENTS.md`.

## Requirements

- Claude Code CLI
- Bash, Python3, curl (standard on macOS/Linux; use Git Bash on Windows)
- `claude login` credentials (for OAuth quota detection — fails open with no advisories if unavailable)
