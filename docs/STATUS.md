# graceful-wrap-up — Project Status

## Takeover Update (2026-04-22)
- The real `~/.claude` install was intentionally put into a reversible safe state for takeover:
  - graceful-wrap-up hook registrations were removed from `~/.claude/settings.json`
  - graceful-wrap-up command/skill/hook files remain installed on disk
  - transient runtime state was cleared where present
- Claude later re-enabled the hooks for testing, so Codex disabled them again.
- Latest disable backup:
  - `C:\Users\PC\.claude\settings.json.graceful-wrap-up-disable.1776874115.bak`
- The latest live block root cause during testing was:
  - five-hour quota source returned `16|oauth`
  - weekly quota source returned `100|...`
  - current `UserPromptSubmit` logic therefore blocked prompts at `EMERGENCY` by design
- Dedicated takeover doc:
  - `docs/CLAUDE_TAKEOVER_2026-04-22.md`

## Current Phase
Phase 1 conversation-aware hook implementation is mostly built on branch `codex/phase1-conversation-hooks`. The repo now includes Claude's `PreCompact` fix and the removal of the JSONL/heuristic fallback, but the live install is intentionally disabled again until weekly-quota behavior is intentionally decided.

## Done
- [x] Design doc: `docs/plans/2026-04-20-graceful-handoff-design.md`
- [x] Implementation plan v2: `docs/plans/2026-04-20-graceful-handoff-implementation-v2.md`
- [x] `src/hooks/handoff-lib.sh` — shared library with turn-state, telemetry, prompt-risk, approval parsing, lifecycle, and artifact helpers
- [x] `src/hooks/user-prompt-submit-handoff` — pre-turn quota/risk gate with approval re-submission handling
- [x] `src/hooks/pre-tool-use-handoff` — turn-aware tool enforcement with one-turn approval support
- [x] `src/hooks/pre-compact-handoff` — compaction pressure can raise to `PREPARE` without downgrading stronger quota state
- [x] `src/hooks/stop-handoff` — post-turn quota reconciliation, telemetry writes, and emergency artifact behavior
- [x] `src/hooks/stop-failure-handoff` — emergency artifact writer on rate_limit/billing_error
- [x] `src/skills/graceful-wrap-up.md` — updated agent protocol for conversation-aware hooks, approval syntax, and 98% emergency policy
- [x] `src/commands/wrap-up.md` — enhanced wrap-up command wiring in skill
- [x] `install.sh` / `uninstall.sh` — deploy/remove with `UserPromptSubmit`, 15s `Stop` timeout, and Windows-safe settings-path handling
- [x] `README.md`
- [x] `tests/test-handoff-lib.sh`
- [x] `tests/test-user-prompt-submit.sh`
- [x] `tests/test-pre-tool-use.sh`
- [x] `tests/test-pre-compact.sh`
- [x] `tests/test-stop-handoff.sh`
- [x] Weekly quota detection (`feat/weekly-quota`): `tier_from_weekly_pct`, `get_weekly_quota_oauth`, `tier_severity` — merged to `feat/implementation`
- [x] Installed and validated locally (`~/.claude/hooks/`, `~/.claude/skills/`, `settings.json`)
- [x] Re-validated against the real `~/.claude` environment on Claude Code `2.1.117`
- [x] Live probe logs captured:
  - `tmp/live-warn-probe.jsonl`
  - `tmp/live-prepare-probe.jsonl`
  - `tmp/live-emergency-probe.jsonl`
- [x] Live probe outcomes confirmed:
  - WARN allows a normal model turn
  - PREPARE short-circuits before model usage
  - EMERGENCY short-circuits before model usage
- [x] Production bug fixes: WARN now emits context injection; STOP/EMERGENCY route to stdout additionalContext (confirmed works on exit 2); accelerated polling once any signal active; all messages self-contained with explicit artifact-writing instructions
- [x] Codex adapter and lean memory system:
  - `.codex/CODEX.md`
  - `.codex/memory/project_context.md`
  - `.codex/memory/session_state.md`
  - `.codex/memory/decision_log.md`
  - `.codex/memory/failure_patterns.md`
- [x] Active Phase 1 design docs:
  - `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`
  - `docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md`
- [x] Reusable cross-validation workflow:
  - `src/commands/cross-validate.md`
  - `src/skills/cross-validate-state.md`
- [x] Installer robustness:
  - `install.sh` now creates `~/.claude/settings.json` if missing
  - `uninstall.sh` now exits cleanly if `~/.claude/settings.json` is absent
  - shell-resolved settings paths are passed into embedded Python, avoiding Windows `~` mismatches during install/uninstall

## Done (2026-04-22 — Claude session)
- [x] Fixed `src/hooks/pre-compact-handoff` — now emits `{"systemMessage":"..."}` (valid PreCompact schema) instead of `hookSpecificOutput.additionalContext` (invalid)
- [x] Added `emit_system_message()` helper to `src/hooks/handoff-lib.sh`
- [x] Fixed `tests/test-pre-compact.sh` — `check_ac()` now asserts `systemMessage` field (was asserting wrong `hookSpecificOutput` shape)
- [x] Removed JSONL and heuristic quota fallback entirely from `src/hooks/handoff-lib.sh`:
  - Deleted `get_quota_jsonl()`, `get_quota_heuristic()`, `_get_plan_limit()`, `get_quota()`
  - `get_quota_state()` is now OAuth-only; falls open (`|none`) when OAuth unavailable
  - Decision: Claude Code and the quota API share the same Anthropic infrastructure — if Claude Code works, OAuth works; JSONL was producing false EMERGENCY due to an uncorrectable token-limit constant (~70× off for max5)
- [x] Updated `tests/test-pre-tool-use.sh` — WARN/PREPARE/STOP/accelerated-polling tests now use `HANDOFF_TEST_QUOTA_PCT` env override instead of heuristic call-count triggers
- [x] Removed 4 dead heuristic tests from `tests/test-handoff-lib.sh`

## Done (2026-04-22 — warn-only pivot)
- [x] Removed all hard-blocks from `pre-tool-use-handoff` (STOP/EMERGENCY now exit 0 with advisory context)
- [x] Removed all hard-blocks from `user-prompt-submit-handoff` at PREPARE tier (allow through with warning)
- [x] Designed and implemented two-step STOP/EMERGENCY flow in `user-prompt-submit-handoff`:
  - First hit at STOP/EMERGENCY: warn user with options (STOP_NOW, FINISH_THIS, HANDOFF_NOW), hold turn (exit 2), write `stop_warn` flag
  - Re-submit: detect flag match, allow through with scoped guidance injected to agent (exit 0), clear flag
- [x] `tier_from_weekly_pct`: capped at WARN (99%+ was EMERGENCY — more aggressive than Claude Code itself; removed)
- [x] Added `HANDOFF_STOP_WARN_FILE` env var + `stop_warn_file/write_stop_warn/read_stop_warn_session/clear_stop_warn` helpers to `handoff-lib.sh`
- [x] Removed `emit_block_options()` and `emit_emergency_block()` — replaced by inline warn/hold emissions
- [x] All approval action handlers (`stop_now`, `handoff_now`, `finish_this`, `approve_once`) now call `clear_stop_warn`
- [x] Updated all tests — 169/169 passing

## Done (2026-04-22 — Post-pivot refinement pass)
- [x] Renamed `write_emergency_handoff_artifacts` → `write_stop_handoff_artifacts`; softened "emergency quota boundary/threshold" language in AI_HANDOFF.md / RESUME_PROMPT.md templates to "STOP quota threshold"
- [x] Swept remaining stale EMERGENCY references in `handoff-lib.sh` doc comments (`should_preserve_compaction_signal`, `stop_warn_file`)
- [x] PLAN_IT message now uses `${TIER:-UNAVAILABLE}` instead of hardcoded `(STOP)` — correct label at any quota level
- [x] `user-prompt-submit-handoff` WARN tier now matches `pre-tool-use-handoff`: "WEEKLY quota" wording when source is seven_day, "5-hour limit" when source is five_hour
- [x] Multi-line approval prompts (`FINISH_THIS: ...`, `APPROVE_ONCE: ...`, `PLAN_IT: ...` with embedded newlines/tabs) now rejected as `format_error` with message "Approval prompts must be on a single line..."
- [x] `pre-tool-use-handoff`: `weekly_reset_suffix` guards empty `WEEKLY_RESETS_AT` (no more dangling "resets ." trailing period)
- [x] `escape_json` now covers `\b` and `\f` control chars (previously could emit invalid JSON for raw form-feed/backspace)
- [x] `get_quota_oauth` and `get_weekly_quota_oauth` now pass raw API response via `sys.argv[1]` with quoted heredoc delimiter (no more bash variable expansion inside Python source — safer if API returns unexpected content)
- [x] `mark_turn_open` positions 6-7 (`predicted_risk_band`, `predicted_cost_range`) documented as RESERVED — prevents future readers from hunting for a non-existent writer
- [x] `test-pre-compact.sh` and `test-stop-handoff.sh` updated for STOP-only tier model (EMERGENCY removed); `test-stop-handoff.sh` now also exercises PREPARE overshoot (no artifacts) vs STOP 95-97 (writes artifacts) vs STOP 98+ (appends git snapshot)
- [x] Added test coverage: `clear_stop_warn` fires on every approval branch (5 new tests); PLAN_IT below STOP uses UNAVAILABLE label; weekly-source WARN message content; multi-line approval rejection

## Done (2026-04-22 — EMERGENCY consolidation + PLAN_IT pivot)
- [x] Deleted `estimate_prompt_risk` and all 11 supporting functions from `handoff-lib.sh` (approximate_prompt_tokens, trim_lower, add_reason_code, telemetry read helpers, risk band/cost helpers)
- [x] Consolidated EMERGENCY tier into STOP: `tier_from_pct` now returns STOP at 95%+; EMERGENCY no longer exists anywhere in codebase
- [x] `tier_severity`: STOP=3, PREPARE=2, WARN=1 (EMERGENCY=4 removed)
- [x] Weekly quota: unchanged WARN-only cap; severity comparison now works correctly with 3-tier model
- [x] WARN tier: plain advisory always emitted — no risk evaluation or conditional emit
- [x] PREPARE tier: step-breakdown instruction injected (no wrap-up instruction)
- [x] STOP first hit: four options presented (re-submit, PLAN_IT, FINISH_THIS, STOP_NOW); hold turn (exit 2); write stop_warn flag
- [x] STOP re-submit: respond **normally** (not minimally)
- [x] Added `PLAN_IT: <request>` approval keyword to `handoff-lib.sh` (parse_approval_prompt, approval_format_error) and `user-prompt-submit-handoff` handler
- [x] `stop-handoff`: STOP tier (95%+) now triggers emergency artifact writes (was EMERGENCY)
- [x] All test files updated: EMERGENCY assertions replaced with STOP; estimate_prompt_risk tests removed; PLAN_IT parse tests added; WARN "always emits" assertion added; STOP re-submit "normally" assertion added
- [x] Hooks reinstalled via `bash install.sh`

## In Progress
- Restart Claude Code for hooks to take effect
- Live probes: WARN, STOP first-hit, STOP re-submit, PLAN_IT

## Test Results (2026-04-22 — post-refinement pass)
- `test-handoff-lib.sh`: 67/67 passed
- `test-user-prompt-submit.sh`: 46/46 passed
- `test-pre-tool-use.sh`: 30/30 passed
- `test-pre-compact.sh`: 12/12 passed
- `test-stop-handoff.sh`: 24/24 passed
- **Total: 179/179**

## Retest Results (2026-04-22, post quota reset)
- Re-ran the full local shell suite after the user's quota reset:
  - `test-handoff-lib.sh`: 75/75 passed
  - `test-user-prompt-submit.sh`: 20/20 passed
  - `test-pre-tool-use.sh`: 29/29 passed
  - `test-pre-compact.sh`: 12/12 passed
  - `test-stop-handoff.sh`: 21/21 passed
- Re-ran the final install/uninstall smoke script and again confirmed install preserves unrelated hooks while adding this project's hook set, and uninstall removes only this project's entries
- Re-ran live WARN/PREPARE/EMERGENCY probes and observed the same runtime behavior as before:
  - WARN still allows a normal model turn
  - PREPARE still short-circuits before model usage
  - EMERGENCY still short-circuits before model usage
- Fresh rerun logs were captured in:
  - `tmp/live-warn-probe-rerun.jsonl`
  - `tmp/live-prepare-probe-rerun.jsonl`
  - `tmp/live-emergency-probe-rerun.jsonl`

## Live Validation Results (2026-04-22)
- Real `~/.claude/settings.json` already contained the expected five-hook registration with the current timeouts, and reinstall refreshed the installed hook files without disturbing unrelated hooks
- WARN probe (`HANDOFF_TEST_QUOTA_PCT=86`) completed a normal turn and returned `OK`
- PREPARE probe (`HANDOFF_TEST_QUOTA_PCT=92`) returned an immediate empty result with zero model usage
- EMERGENCY probe (`HANDOFF_TEST_QUOTA_PCT=98`) returned an immediate empty result with zero model usage
- This confirms the installed runtime behavior even though the current non-interactive stream output does not show `UserPromptSubmit` hook events directly

## Known Issues / Notes
- Real `~/.claude` graceful-wrap-up hook registrations are intentionally disabled again on 2026-04-22 for safe takeover
- Previous false EMERGENCY root cause (now fixed): `get_quota_jsonl` used a hardcoded token limit of 88,000 for max5, while the real limit is ~6.1M tokens. The JSONL path and heuristic have been removed; quota detection is now OAuth-only with fail-open behavior
- The latest live block was not the old JSONL fallback bug; it was the current weekly quota policy:
  - installed helper output returned `quota_state=16|oauth`
  - installed weekly helper output returned `weekly_quota=100|...`
  - `user-prompt-submit-handoff` therefore blocked prompts at `EMERGENCY` by design
- The main remaining product/policy question is whether weekly quota at `99%+` should hard-block or merely warn
- `seven_day_omelette` is an internal Anthropic codename for Claude Design features — excluded from detection
- `extra_usage` (monthly CAD credits) is at 100% on this account — out of scope for this PR
- Windows: `python3` in Git Bash resolves to MS Store alias; `find_python()` helper works around this
- Quota source is now passed explicitly as `pct|source` from the shared helper to avoid subshell loss in runtime hooks
- Git Bash remains the reliable shell test runner for this repo on Windows
- Claude Code `2.1.117` `claude -p --verbose --output-format stream-json` surfaced `SessionStart` hooks in the live probes but did not visibly emit `UserPromptSubmit` hook events
- Claude-native `rate_limit_event` warnings may appear during probes and should not be confused with hook behavior driven by `HANDOFF_TEST_QUOTA_PCT`
- Attempted automated interactive blocked-UX capture on Windows still failed at the harness level with `stdin is not a tty` (`tmp/interactive-prepare-transcript.txt`), so the remaining gap is automation of the capture rather than hook correctness

## Branch
Stable implementation branch: `feat/implementation`  
Current design/memory branch: `codex/phase1-conversation-hooks`

## Last Updated
2026-04-22 (post-fix)
