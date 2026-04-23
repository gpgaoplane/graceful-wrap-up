# Claude Work Log

## Onboarded: 2026-04-20

**Platform:** Claude Code (Anthropic)  
**Config file:** `.claude/CLAUDE.md`  
**First task:** Design and implement the full smart-quota-tracker system from scratch

---

## 2026-04-20 — Full system implementation (v1 + v2)

**Changed:** All files under `src/`, `tests/`, `install.sh`, `uninstall.sh`, `README.md`, `docs/STATUS.md`, `docs/plans/`

**Why:** Initial build. User requested a quota-aware graceful handoff system for Claude Code.

**Decisions:**
- Signal injection hybrid (hook → stdout additionalContext) over pure hook or pure skill approach — skill alone requires manual invocation; pure hook can't communicate intent to agent
- Detection cascade: OAuth first (most accurate), JSONL burn rate second, heuristic (tool call count) as last resort — OAuth is undocumented but available; JSONL is reliable but slower; heuristic is always available
- Tier system: WARN/PREPARE/STOP/EMERGENCY — four levels give gradual escalation rather than a binary warn/block
- `(matcher, command)` pair dedup in install.sh — rate_limit and billing_error StopFailure hooks share same command; deduping by command alone would silently drop one
- `PCT|RESETS_AT` output format for `get_weekly_quota_oauth` — subshell variable isolation means you can't set globals from `$()`; encoding both values in one string and parsing in the caller is the cleanest workaround

**Watch out:**
- `seven_day_omelette` field in OAuth response is an internal Anthropic codename — not a per-model bucket, not useful, ignore it
- `python3` on Windows Git Bash resolves to MS Store stub — always use `find_python()`, never call `python3` directly
- `ok()` test helper must use `((++PASS)); return 0` — post-increment of 0 returns exit 1 under `set -uo pipefail`
- `HANDOFF_PROJECTS_DIR` must be set to an empty temp dir in tests — otherwise `get_quota_jsonl` reads real `~/.claude/projects/` and returns 100%

**Did not touch:** No Codex or Antigravity adapter work — those are planned separately.

---

## 2026-04-21 — Weekly quota detection (feat/weekly-quota → merged)

**Changed:** `src/hooks/handoff-lib.sh`, `src/hooks/pre-tool-use-handoff`, `tests/test-handoff-lib.sh`

**Why:** Five-hour window can be near-empty while weekly is fine, or vice versa. Weekly exhaustion blocks new sessions too, so needs its own detection path.

**Decisions:**
- Weekly WARN at 95%, EMERGENCY at 99% (no PREPARE/STOP) — weekly exhaustion is non-recoverable mid-session; simpler two-level model is appropriate
- `tier_severity()` compares five-hour vs weekly and picks the more severe — weekly wins on tie-break (equal severity) because it blocks future sessions too
- Weekly check is OAuth-only — no JSONL fallback (JSONL doesn't expose weekly window); no heuristic (tool count has no meaningful weekly analogue)

**Watch out:** If OAuth credentials are unavailable, weekly detection silently returns nothing — that's by design, not a bug.

---

## 2026-04-21 — Production bug fixes (four bugs + design gap)

**Changed:** `src/hooks/pre-tool-use-handoff`, `tests/test-pre-tool-use.sh`, `docs/STATUS.md`

**Why:** Production failure: no WARN at 90%, no hard stop at 95-98%. Root-caused 4 bugs and 1 design gap after the system ran without triggering during a live session.

**Bugs fixed:**
1. Five-hour WARN tier was silent — wrote signal file but emitted nothing to agent
2. No polling acceleration after WARN — 9 unchecked calls between quota checks meant usage could jump from 85% to 98% before next check
3. STOP/EMERGENCY block reason went to stderr — agent never saw it; confirmed via live test that stdout `additionalContext` reaches agent even on exit 2
4. All messages depended on `/wrap-up` skill being loaded — skill is opt-in, not auto-loaded; messages now contain explicit step-by-step instructions any agent will act on

**Decisions:**
- Confirmed via live test: PreToolUse hook exit 2 + stdout additionalContext → agent sees the context injection. This is the correct channel for all agent-facing messages at all tiers.
- Accelerated polling: once any tier is in the signal file, check quota on every call (not every 10th)
- Re-block logic for STOP/EMERGENCY now also uses `emit_context_injection` before exit 2

**Test count:** 13 → 21 (added WARN injection check, STOP stdout check, re-block stdout checks, accelerated polling test)

**Did not touch:** `handoff-lib.sh` (no changes needed), other hooks, install scripts.

---

## 2026-04-22 — Fix PreCompact schema bug, remove JSONL/heuristic quota fallback

**Changed:** `src/hooks/handoff-lib.sh`, `src/hooks/pre-compact-handoff`, `tests/test-pre-compact.sh`, `tests/test-pre-tool-use.sh`, `tests/test-handoff-lib.sh`, `docs/STATUS.md`, `docs/agents/claude.md`

**Why:** Two blockers preventing live re-enablement of graceful-wrap-up:
1. `pre-compact-handoff` was emitting `hookSpecificOutput.additionalContext` which is not a valid field for the `PreCompact` event — causing validation failure and broken `/compact`.
2. `get_quota_jsonl` was falsely reporting 100% on a nearly fresh max5 session. Root cause: hardcoded token limit of 88,000 is ~70× too low for max5 (real limit ~6.1M tokens based on 8% OAuth = 488k tokens). This produced false EMERGENCY on every hook subprocess that missed OAuth.

**Decisions:**
- Added `emit_system_message()` to `handoff-lib.sh` — outputs `{"systemMessage":"..."}` which is the correct schema for PreCompact. Kept `emit_context_injection()` intact for PreToolUse and UserPromptSubmit which correctly use `hookSpecificOutput.additionalContext`.
- Removed `get_quota_jsonl()`, `get_quota_heuristic()`, `_get_plan_limit()`, and `get_quota()` entirely. `get_quota_state()` is now OAuth-only with fail-open (`|none`) when unavailable.
- Rationale for OAuth-only: Claude Code and the quota usage API share the same Anthropic infrastructure. If Claude Code is running and generating responses, the OAuth endpoint is reachable. A fallback that produces worse results than no fallback is not a fallback.
- Updated `test-pre-compact.sh` `check_ac()` to assert `systemMessage` instead of `hookSpecificOutput.additionalContext`.
- Updated `test-pre-tool-use.sh` WARN/PREPARE/STOP/accelerated-polling tests to use `HANDOFF_TEST_QUOTA_PCT` env override piped to the hook subprocess — previously relied on heuristic call-count thresholds (counter=39→87%, counter=59→92%, counter=79→96%) which no longer exist.
- Removed 4 dead heuristic tests from `test-handoff-lib.sh`.

**Watch out:**
- `get_quota_state` signature still accepts a `call_count` parameter positionally but ignores it — callers in `pre-tool-use-handoff`, `stop-handoff`, `user-prompt-submit-handoff` still pass it; harmless in bash but worth cleaning up later if desired.
- `HANDOFF_PROJECTS_DIR` env var reference in the old 2026-04-20 work log entry above is now stale — that isolation guard was only needed for JSONL tests, which are gone.

**Test counts:** 71 + 20 + 29 + 12 + 21 = 153 total, 0 failures.

**Did not touch:** `stop-handoff`, `stop-failure-handoff`, `user-prompt-submit-handoff`, `install.sh`, `uninstall.sh`, design docs, or Codex-owned files.

---

## 2026-04-22 — Warn-only pivot: remove all hard-blocks

**Changed:** `src/hooks/handoff-lib.sh`, `src/hooks/pre-tool-use-handoff`, `src/hooks/user-prompt-submit-handoff`, all five test files, `docs/STATUS.md`

**Why:** Architectural pivot: system should inform users and let them decide, never silently cut them off. Hard-blocks at STOP/EMERGENCY in PreToolUse and UserPromptSubmit were removed. Weekly EMERGENCY (99%+) was removed — Claude Code itself does not hard-block at weekly=100%, so our hook was more aggressive than the platform.

**Decisions:**
- `pre-tool-use-handoff`: removed all `exit 2` instances. STOP/EMERGENCY now emit advisory context to the agent and exit 0. Re-block logic removed. Agent self-regulates from injected signals.
- `user-prompt-submit-handoff` — two-step STOP/EMERGENCY flow:
  - First hit: warn user with available options (STOP_NOW, FINISH_THIS, HANDOFF_NOW for EMERGENCY; STOP_NOW, FINISH_THIS for STOP), write `stop_warn` session flag, `exit 2` (hold turn)
  - Re-submit: read flag, if session matches → allow through with scoped guidance injected to agent, clear flag, `exit 0`
  - No special syntax required to re-submit — just send the original prompt again
- `user-prompt-submit-handoff` PREPARE: removed `exit 2` for large/huge risk. Always allow through with warning injection.
- `tier_from_weekly_pct`: removed EMERGENCY branch; max weekly tier is now WARN.
- `HANDOFF_STOP_WARN_FILE` env var added to lib (default `$HOME/.claude/.handoff-stop-warn`). Isolated in tests via `$TMP/stop-warn`.
- Removed `emit_block_options()` and `emit_emergency_block()` — replaced by inline emissions in the STOP/EMERGENCY cases.
- All approval action handlers (`stop_now`, `handoff_now`, `finish_this`, `approve_once`) now call `clear_stop_warn` to clean up any pending warn flag.

**Watch out:**
- `estimate_prompt_risk` is still called and used for WARN/PREPARE informational injection but no longer gates STOP/EMERGENCY behavior.
- `HAS_ACTIVE_APPROVAL` in `pre-tool-use-handoff` is still used to skip quota checks on non-check calls when user has an active approval — this is correct behavior (the user said "keep going"), not a block bypass.
- The `stop_warn` flag is session-scoped (stores SESSION_ID). A different session will not match, so stale flags are naturally ignored without cleanup.

**Test counts:** 71 + 33 + 32 + 12 + 21 = 169 total, 0 failures.

**Did not touch:** `stop-handoff`, `stop-failure-handoff`, `pre-compact-handoff`, `install.sh`, `uninstall.sh`, design docs, or Codex-owned files.

---

## 2026-04-22 — EMERGENCY consolidation + PLAN_IT keyword

**Changed:** `src/hooks/handoff-lib.sh`, `src/hooks/user-prompt-submit-handoff`, `src/hooks/pre-tool-use-handoff`, `src/hooks/stop-handoff`, `tests/test-handoff-lib.sh`, `tests/test-pre-tool-use.sh`, `tests/test-user-prompt-submit.sh`, `docs/STATUS.md`

**Why:** User wanted to simplify the tier model further: EMERGENCY was redundant with STOP, `estimate_prompt_risk` was dead weight (WARN/PREPARE no longer gate on risk), and a new PLAN_IT keyword was needed to let users trigger step-breakdown mode at STOP without committing to execution.

**Decisions:**
- Deleted `estimate_prompt_risk` and 11 supporting functions (approximate_prompt_tokens, trim_lower, add_reason_code, all telemetry read helpers, risk band/cost helpers). Risk evaluation is gone entirely — WARN and PREPARE now always emit, unconditionally.
- EMERGENCY tier eliminated: `tier_from_pct` now returns STOP at 95%+. `tier_severity` is now 0/1/2/3 (empty/WARN/PREPARE/STOP).
- `stop-handoff` emergency artifact trigger changed from `$POST_TIER == "EMERGENCY"` to `$POST_TIER == "STOP"`.
- STOP first hit: four options surfaced (re-submit normally, PLAN_IT, FINISH_THIS, STOP_NOW).
- STOP re-submit: injects "respond normally" not "respond minimally" — user correction, they don't want scope imposed.
- `PLAN_IT: <request>` keyword added to `parse_approval_prompt` and `approval_format_error`. Handler in `user-prompt-submit-handoff` emits step-breakdown context injection including the forwarded prompt.
- PLAN_IT passes `write_allowed_turn "none" 0 0` — no actual turn permission, just a planning turn with no execution.

**Watch out:**
- Turn-state still has `predicted_risk_band` and `predicted_cost_range` fields (they come from `mark_turn_open` positional args 6–7). These are now always written as empty strings. `read_turn_state_field` still works on them; the fields are just empty. No behavior change — nothing reads them for logic anymore.
- `mark_turn_open` doc comment still lists these parameters; can be cleaned up in a future pass without behavioral impact.
- WARN now always emits context injection for every prompt at 85-89% — this is intentional and correct. No "but what if it's a tiny prompt" exception.

**Test counts:** 60 + 31 + 30 + 12 + 21 = 154 total, 0 failures.

---

## 2026-04-22 — Post-pivot refinement pass (audit-driven)

**Changed:** `src/hooks/handoff-lib.sh`, `src/hooks/user-prompt-submit-handoff`, `src/hooks/pre-tool-use-handoff`, `src/hooks/stop-handoff`, `tests/test-handoff-lib.sh`, `tests/test-user-prompt-submit.sh`, `tests/test-pre-compact.sh`, `tests/test-stop-handoff.sh`, `docs/STATUS.md`

**Why:** After the EMERGENCY→STOP consolidation, deep code review + self-audit surfaced 17 items. Fixed 9 that were real correctness/hygiene issues; documented rationale for skipping 8 low-value items. Consolidated into one pass to minimize churn.

**Decisions (fixes applied):**

1. **Multi-line approval prompt rejection** — Any `FINISH_THIS: <x>` / `APPROVE_ONCE: <x>` / `PLAN_IT: <x>` whose forwarded payload contains `\n`, `\r`, or `\t` now returns `format_error` with message "Approval prompts must be on a single line without newlines or tabs." Without this, the `key=value\n` output format of `parse_approval_prompt` truncated the forwarded prompt at first newline, silently dropping part of the user's request. Reject-with-error was chosen over escape-and-decode because approval prompts are short directives by nature.

2. **PLAN_IT tier label honesty** — Injection was hardcoded `(STOP)`. Fixed to `${TIER:-UNAVAILABLE}` so sub-STOP usage of PLAN_IT (valid — PLAN_IT is user-initiated, not tier-gated) reports the actual tier. Added test coverage at 50% quota.

3. **WARN weekly-source mislabel** — `user-prompt-submit-handoff` WARN case always said "approaching the 5-hour limit" even when `$ACTIVE_SOURCE` was `seven_day`. Added the same conditional branching that `pre-tool-use-handoff` already had. Added test.

4. **Renamed `write_emergency_handoff_artifacts` → `write_stop_handoff_artifacts`** — function now fires on any STOP-tier turn end (95%+), not just the historical EMERGENCY threshold. The old name + "emergency quota boundary/threshold" wording leaked into user-visible `AI_HANDOFF.md` and `RESUME_PROMPT.md` templates — misleading since STOP is the normal close-out path at 95%+ now. Softened template language to "STOP quota threshold" and "stop-hook" source label.

5. **`escape_json` coverage** — added `\b` and `\f` substitutions. Without them, raw form-feed/backspace in a user prompt would produce technically-invalid JSON and could trip strict parsers.

6. **Python heredoc injection hardening** — `get_quota_oauth` and `get_weekly_quota_oauth` now pass the raw HTTP response via `sys.argv[1]` with a **quoted** heredoc delimiter (`<<'PYEOF'`). Previously used `'''${resp}'''` with unquoted delimiter — bash variable expansion inside the Python source. No exploit known (API returns clean JSON), but the pattern was unsafe and matched the already-correct `_get_credentials_field` pattern.

7. **`weekly_reset_suffix` empty-guard** — in `pre-tool-use-handoff`, when `WEEKLY_RESETS_AT` is empty the old `weekly_reset_date` produced a dangling "resets ." in the injection. New helper only emits " — resets YYYY-MM-DD" suffix when the date is present.

8. **`mark_turn_open` RESERVED-args doc** — positions 6 (`predicted_risk_band`) and 7 (`predicted_cost_range`) are now always empty since risk evaluation was removed. Added explicit "RESERVED" note in doc header so future readers don't hunt for a non-existent writer.

9. **Stale EMERGENCY comments swept** — `should_preserve_compaction_signal` and `stop_warn_file` headers no longer reference EMERGENCY.

**Decisions (test coverage added — 25 new assertions):**

- `escape_json` tests for `\b` and `\f`
- `parse_approval_prompt` multi-line rejection for each of FINISH_THIS / APPROVE_ONCE / PLAN_IT + tab-containing variant
- `clear_stop_warn` fires on each of 5 approval branches (STOP_NOW, HANDOFF_NOW, FINISH_THIS, APPROVE_ONCE, PLAN_IT) via a loop
- PLAN_IT below STOP uses `(UNAVAILABLE)` label
- WARN weekly-source injection content (`WEEKLY quota`, `weekly limit`)
- WARN 5-hour injection content (`5-hour limit`)
- `test-stop-handoff.sh`: PREPARE overshoot (90-94) writes signal but NO artifacts; STOP 95-97 writes artifacts; STOP 98+ appends git snapshot to existing file

**Decisions (issues NOT fixed — deliberate):**

- **Stale `stop_warn` flag across tier transitions within a session** — user chose to proceed once; skipping subsequent warnings in the same session is consistent UX. Document the decision, no functional change.
- **Counter race condition** — pre-existing, would need file locking. Polling-cadence drift is harmless.
- **STOP_NOW trailing whitespace strict match** — Claude Code trims input; false positives from lenient matching would be worse.
- **PREPARE wording inconsistency across hooks** — functionally equivalent; unifying has marginal value.
- **`write_stop_handoff_artifacts` accumulating per-turn git snapshots** — by design for recovery resilience.
- **Forwarded-prompt semantic prompt-injection** — out of threat model (user's own session, user's own text).
- **Defensive `[[ PCT == SOURCE ]]` dead check** — harmless, removing it risks breakage if `get_quota_state` contract changes.
- **Wording "re-submit" → "send again"** — bikeshed.

**Watch out:**
- The `fake_prompt` test helper in `test-user-prompt-submit.sh` uses `%s` to interpolate prompt text into JSON, which doesn't cleanly handle real newlines. Multi-line rejection is tested at the library level (`test-handoff-lib.sh`) where the function is called directly.
- `should_preserve_compaction_signal` still references `compaction` source literal at both write (pre-compact-handoff) and read sites (stop-handoff) — correct, but the coupling would bite if either side diverges.

**Test counts:** 67 + 46 + 30 + 12 + 24 = 179 total, 0 failures. +25 over previous pass.

**Did not touch:** `install.sh`, `uninstall.sh`, `pre-compact-handoff` (content unchanged — no EMERGENCY references), `stop-failure-handoff` (no EMERGENCY in code), design docs, Codex-owned files.
