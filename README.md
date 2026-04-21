# graceful-wrap-up

A quota-aware graceful handoff system for Claude Code.

Detects approaching usage limits, asks permission before entering handoff mode, hard-stops at 95%+, and writes comprehensive continuation artifacts so a zero-context AI agent can resume your session seamlessly.

## What It Does

| Quota | Behavior |
|-------|----------|
| 85–90% | Estimates cost before starting large tasks, warns if risky |
| 90–95% | Shows status brief, asks permission (yes / finish-this / no) |
| 95–98% | Hard stops, writes `AI_HANDOFF.md` + `RESUME_PROMPT.md` |
| 98%+ | Emergency stop — writes `RESUME_PROMPT.md` first |
| Session cutoff | Hook writes emergency artifacts from git state |

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

**Detection cascade (hooks):** OAuth endpoint → JSONL burn rate → tool-call heuristics. Falls back gracefully if credentials are unavailable.

**Signal injection:** PreToolUse hook injects a terse one-line signal into the conversation when quota crosses 90%. The agent reads it and acts.

**Hard stop:** At 95%+, PreToolUse hook blocks the tool call (exit 2). Agent is forced to write handoff files.

**Emergency net:** StopFailure hook fires on abrupt cutoffs and writes git-state-only artifacts.

## Portability

The skill file (`src/skills/graceful-wrap-up.md`) is platform-agnostic. Codex and Antigravity adapters (hook equivalents for those platforms) are planned for a future release.

## Collaboration

This repo now includes a shared AI collaboration guide in `AI_AGENTS.md`.

- Claude uses `.claude/CLAUDE.md`
- Codex uses `.codex/BOOTSTRAP.md`
- Agent work logs live in `docs/agents/`

If you are using an AI agent to work in this repo, start with `AI_AGENTS.md`.

## Requirements

- Claude Code CLI
- Bash, Python3, curl (standard on macOS/Linux; use Git Bash on Windows)
- `claude login` credentials (for OAuth quota detection — falls back to JSONL/heuristics without it)
