---
status: active
type: pitfalls
owner: claude
last-updated: 2026-04-23T15:01:47-04:00
read-if: "you are touching an area Claude has flagged before"
skip-if: "status != active or last-updated <= your watermark"
---

# Claude — Pitfalls

Append new pitfalls below. Format:

```
## P-<n> — <title> — <ISO-8601>
**Symptom:**
**Root cause:**
**Workaround:**
**Regression test:**
```

<!-- section:entries:start -->

## P-1 — Windows `python3` resolves to MS Store stub — 2026-04-23
**Symptom:** Hook scripts that call `python3` hang or fail with "Python was not found" despite a working Python install.
**Root cause:** On Windows, `python3` is aliased by default to a Microsoft Store app-execution alias that opens the Store instead of running Python. Git Bash sees it as executable but it fails silently.
**Workaround:** Never call `python3` directly. Use `find_python()` in `src/hooks/handoff-lib.sh`, which tries `python`, `python3`, `py` in that order and returns the first that produces a live interpreter. All hook scripts source `handoff-lib.sh` and call `find_python`.
**Regression test:** `tests/test-handoff-lib.sh` includes `find_python returns path` and `find_python is executable` checks.

## P-2 — Subshell variable isolation — 2026-04-23
**Symptom:** A global variable set inside a shell function returns empty in the caller; OR `set -u` fires an "unbound variable" error mid-hook.
**Root cause:** Functions invoked via `$(fn)` run in a subshell. Variable assignments inside do not propagate to the parent shell.
**Workaround:** Pre-declare globals in the parent (`QUOTA_SOURCE="none"`) before calling subshelled functions. For multi-value returns use `VALUE1|VALUE2` output format and parse with `${var%%|*}` / `${var##*|}` in the caller. See `handoff-lib.sh` `get_quota_oauth` (returns `PCT|RESETS_AT`) and its caller.
**Regression test:** Covered indirectly by `test-handoff-lib.sh` tier-detection suites.

## P-3 — `ok()` post-increment misfires under `set -uo pipefail` — 2026-04-23
**Symptom:** Test reports "FAIL" on assertions that clearly passed; PASS counter lags by one.
**Root cause:** `((PASS++))` evaluates to PASS's *old* value. When PASS is 0, `((0))` returns non-zero exit status, which under `set -uo pipefail` marks the function as failed.
**Workaround:** Always use `((++PASS)); return 0` in test helpers. Pre-increment evaluates to the new value, which is always ≥1.
**Regression test:** `tests/test-handoff-lib.sh` and all sibling test files use the corrected pattern.

## P-4 — Hook dedup requires (matcher, command) pair, not command alone — 2026-04-23
**Symptom:** `install.sh` drops one of two StopFailure hook entries during merge.
**Root cause:** `StopFailure/rate_limit` and `StopFailure/billing_error` share the same command string (both invoke `stop-failure-handoff`). Deduping by command alone removes one.
**Workaround:** Dedup key is `(matcher, command)`. `install.sh` uses this compound key.
**Regression test:** None yet (install path not covered by unit tests). Manual smoke-test: run `install.sh` on a settings.json with both entries, verify both survive.

## P-5 — `stdout` vs `stderr` for PreToolUse `additionalContext` — 2026-04-23
**Symptom:** Agent never sees the HANDOFF_SIGNAL advisory despite hook firing cleanly.
**Root cause:** Claude Code delivers `hookSpecificOutput.additionalContext` to the agent only from the hook's stdout — and only when exit code is 0 or 2. stderr is logged for the user/developer but never reaches the agent's conversation.
**Workaround:** All agent-facing messages must be emitted as JSON on stdout: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}`. Reserve stderr for system-level errors the developer needs to see.
**Regression test:** `test-pre-tool-use.sh` asserts `additionalContext` lands in stdout for each tier.

## P-6 — `seven_day_omelette` is a codename, not a bucket — 2026-04-23
**Symptom:** OAuth usage response includes a `seven_day_omelette` field at 100% utilization; tempting to treat as a per-model quota bucket.
**Root cause:** Confirmed (via Anthropic-facing investigation during v1) that `seven_day_omelette` is an internal Claude Design feature codename, not per-model quota metadata. It saturates unrelated to user quota.
**Workaround:** `handoff-lib.sh` ignores the `_omelette` field. Only `five_hour.utilization` and `seven_day.utilization` are consumed.
**Regression test:** None — negative assertion (we don't consume it) doesn't have a natural test shape. Covered by code review.

## P-7 — Hook-regenerated artifacts drift on every session — 2026-04-23
**Symptom:** `AI_HANDOFF.md` and `RESUME_PROMPT.md` appear as modified in `git status` with large diffs after any session that hit STOP tier. Committing them clutters history with stale tree snapshots.
**Root cause:** `Stop` and `StopFailure` hooks auto-write these files at STOP / rate_limit / billing_error. Each run refreshes the embedded git-status snapshot and timestamp.
**Workaround:** Treat them as runtime artifacts. If they appear modified unrelated to a deliberate handoff test, restore with `git checkout -- AI_HANDOFF.md RESUME_PROMPT.md`. Rule is formalized in `AI_AGENTS.md` under `### Hook-regenerated artifacts` behavioral rules.
**Regression test:** Behavioral; no automated check. Discipline enforced in review.

## P-8 — CRLF line-ending warnings on Windows commits — 2026-04-23
**Symptom:** Every `git add` on shell scripts prints `warning: in the working copy of '...', LF will be replaced by CRLF the next time Git touches it`.
**Root cause:** `core.autocrlf=true` (Git for Windows default) rewrites LF to CRLF on checkout and back to LF on commit. Warnings are informational; files on disk may temporarily have mixed endings.
**Workaround:** Ignore the warnings — do **not** change `core.autocrlf` to work around them. Bash scripts run correctly because `.gitattributes` (or the implicit conversion) ensures LF lands in the tree. Verify by running tests after any staging operation; the suite has been stable through dozens of these warnings.
**Regression test:** Continuous — the test suite runs directly from the working tree and has caught zero CRLF-induced failures across all of Phase A/B/C.

<!-- section:entries:end -->