# Claude Takeover — 2026-04-22

## Purpose

This file captures the corrected live and repo state after:

1. Codex disabled graceful-wrap-up once for safe takeover
2. Claude later re-enabled it for testing
3. the live install blocked prompts again
4. Codex re-inspected the repo and the real `~/.claude` install
5. Codex disabled the live hook registrations again

## Real `~/.claude` State Right Now

- Graceful-wrap-up hook entries have been removed again from the real `~/.claude/settings.json`
- Latest backup of the pre-disable active settings:
  - `C:\Users\PC\.claude\settings.json.graceful-wrap-up-disable.1776874115.bak`
- Earlier disable backup:
  - `C:\Users\PC\.claude\settings.json.graceful-wrap-up-disable.1776870541.bak`
- Unrelated user hooks still active:
  - `SessionStart` -> `bash ~/.claude/hooks/session-start`
  - `PostToolUseFailure` -> `bash ~/.claude/hooks/post-tool-failure`
  - `Notification` -> `bash ~/.claude/hooks/notify`
  - `Stop` -> `bash ~/.claude/hooks/notify`
- Graceful-wrap-up files are still installed on disk:
  - `~/.claude/hooks/handoff-lib.sh`
  - `~/.claude/hooks/user-prompt-submit-handoff`
  - `~/.claude/hooks/pre-tool-use-handoff`
  - `~/.claude/hooks/pre-compact-handoff`
  - `~/.claude/hooks/stop-handoff`
  - `~/.claude/hooks/stop-failure-handoff`
  - `~/.claude/commands/wrap-up.md`
  - `~/.claude/commands/cross-validate.md`
  - `~/.claude/skills/graceful-wrap-up.md`
  - `~/.claude/skills/cross-validate-state.md`
- `~/.claude/.handoff-config` still exists and still says `plan=max5`

## What Changed In The Repo

Claude's later repo changes are real and should be treated as the current code state:

- `src/hooks/pre-compact-handoff` now emits `systemMessage`
- `tests/test-pre-compact.sh` now asserts `systemMessage`
- `src/hooks/handoff-lib.sh` no longer contains the old JSONL or heuristic quota fallback
- `get_quota_state()` is now OAuth-only with fail-open behavior

So the earlier Codex takeover note that said `PreCompact` was still broken and the JSONL fallback was still active is now stale.

## Latest Live Block Root Cause

The latest live prompt blocking was not the old JSONL false-EMERGENCY bug anymore.

When Codex inspected the installed hooks after Claude re-enabled them for testing:

- installed five-hour quota source returned:
  - `quota_state=16|oauth`
- installed seven-day quota source returned:
  - `weekly_quota=100|2026-04-29T14:00:00.157536+00:00`

Direct execution of the installed `~/.claude/hooks/user-prompt-submit-handoff` with a normal sample prompt returned:

- `HANDOFF_SIGNAL: EMERGENCY — quota at 100%. New prompts are blocked. Send HANDOFF_NOW to create handoff artifacts now.`
- exit code `2`

That means the current code intentionally blocked prompts because:

- the hooks were re-enabled in `~/.claude/settings.json`
- weekly quota resolved to `100%`
- `user-prompt-submit-handoff` lets weekly severity override five-hour severity

## What This Means Operationally

- Graceful-wrap-up is currently installed on disk but inactive again because its hook registrations were removed from `~/.claude/settings.json`
- Claude should behave normally again after another restart because the automatic graceful-wrap-up enforcement hooks are no longer registered
- If graceful-wrap-up is re-enabled again without changing weekly policy, prompts may block again as long as weekly quota still resolves to `100%`

## Current Product / Policy Question

The main remaining question is no longer a proven code bug. It is a behavior decision:

- should seven-day quota at `99%+` hard-block prompts
- should it warn only
- or should weekly enforcement be configurable

The relevant code paths are:

- `src/hooks/user-prompt-submit-handoff`
- `src/hooks/handoff-lib.sh` (`tier_from_weekly_pct`)

## Recommended Next Steps For Claude

1. Restart Claude Code before testing normal prompt behavior.
2. Confirm prompting is normal with graceful-wrap-up inactive.
3. Review whether weekly quota should still hard-block at `99%+`.
4. If weekly hard-block is too aggressive, change that policy in code before any reinstall.
5. Only then re-enable graceful-wrap-up with `bash install.sh`.

## Suggested Investigation Order

1. `src/hooks/user-prompt-submit-handoff`
2. `src/hooks/handoff-lib.sh`
3. Decide weekly `EMERGENCY` vs `WARN` vs configurable behavior
4. Local shell retest
5. Reinstall into real `~/.claude`
6. Fresh Claude restart
7. Live validation again
