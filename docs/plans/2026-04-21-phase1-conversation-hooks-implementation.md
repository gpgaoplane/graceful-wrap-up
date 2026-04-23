# Phase 1 Conversation Hooks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add conversation-aware quota protection to `graceful-wrap-up` using `UserPromptSubmit`, a rewritten end-of-turn `Stop` flow, prompt risk estimation, strict approval re-submission syntax, and one-turn approval state.

**Architecture:** This work extends the current hook pipeline rather than replacing it. `UserPromptSubmit` becomes the pre-turn gate, `PreToolUse` remains the tool-path guard, `Stop` becomes a partial rewrite for post-turn catch-up and state management, and shared helper logic in `handoff-lib.sh` owns tiering, state updates, lifecycle rules, and prompt-risk estimation.

**Tech Stack:** Bash hook scripts, Python helper snippets already used by the hooks, Claude Code native hooks, shell-based tests.

**Execution Note:** Task 0 was completed on 2026-04-21. The observed contract is recorded in `docs/plans/2026-04-21-phase1-conversation-hooks-design.md` Section 3.1. The next implementation step is Task 1.

---

### Task 0: Probe `UserPromptSubmit` Before Writing Feature Code

**Files:**
- Create temporarily or locally: a probe hook script outside the final feature set
- Read: `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`

**Steps:**

1. Install a temporary `UserPromptSubmit` probe hook in the local Claude environment.
2. Verify the exact stdin payload shape for `UserPromptSubmit`, especially the full prompt text field.
3. Verify blocked behavior:
   - plain text block output
   - structured block output if supported
4. Verify allowed behavior:
   - plain allow
   - allow with `hookSpecificOutput.additionalContext`
5. Record the observed contract in the work log and, if needed, patch the design doc before coding begins.

**Verification:**

- Use a live Claude Code CLI session.
- Expected: exact input and output behavior is known well enough to implement Task 4 safely.

---

### Task 1: Add Shared State and Lifecycle Helpers

**Files:**
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-handoff-lib.sh`

**Steps:**

1. Add path helpers for:
   - `.handoff-turn-state`
   - `.handoff-telemetry`
2. Add atomic write helpers for all state files.
3. Add read/write helpers for turn-state fields.
4. Add helpers to:
   - discard stale turn-state when `session_id` mismatches
   - expire turn-state by TTL
   - mark turn open/closed
5. Add telemetry helpers with rolling truncation at 20 turns max.
6. Extend tests to cover:
   - turn-state roundtrip
   - session mismatch invalidation
   - TTL expiration
   - telemetry persistence
   - telemetry truncation
   - atomic write behavior at the helper level

**Verification:**

- Run: `bash tests/test-handoff-lib.sh`
- Expected: all helper tests pass

---

### Task 2: Add Prompt Risk Estimator Helpers

**Files:**
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-handoff-lib.sh`

**Steps:**

1. Add a prompt token approximation helper.
2. Add prompt feature extraction helpers for:
   - long prompt
   - repo-wide scope
   - detailed explanation request
   - planning/review/rewrite patterns
3. Add scoring logic that maps prompt features + telemetry into:
   - `risk_band`
   - `confidence`
   - `reason_codes`
4. Add helpers to map score to estimated cost range.
5. Add cold-start behavior:
   - static signals only
   - `confidence=low` when telemetry is insufficient
6. Add tests for representative prompt classes:
   - focused small prompt
   - repo-wide review prompt
   - detailed architecture prompt
   - long pasted debugging prompt
   - cold-start behavior

**Verification:**

- Run: `bash tests/test-handoff-lib.sh`
- Expected: deterministic risk band assertions pass

---

### Task 3: Define and Test Approval Parser Helpers

**Files:**
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-handoff-lib.sh`

**Steps:**

1. Add strict approval parser helpers for:
   - `STOP_NOW`
   - `FINISH_THIS: <intent>`
   - `APPROVE_ONCE: <intent>`
   - `HANDOFF_NOW`
2. Enforce parser rules:
   - uppercase-only
   - start-of-message only
   - `: ` required for intent-bearing approvals
3. Add intent extraction helper:
   - everything after the first `: ` becomes the forwarded prompt
4. Add format-error helper for malformed approval syntax.
5. Add tests for:
   - valid `FINISH_THIS`
   - valid `APPROVE_ONCE`
   - valid `STOP_NOW`
   - valid `HANDOFF_NOW`
   - lowercase rejection
   - keyword not at message start
   - missing `: `
   - embedded quoted keyword ignored

**Verification:**

- Run: `bash tests/test-handoff-lib.sh`
- Expected: parser behavior matches the finalized design rules

---

### Task 4: Create `UserPromptSubmit` Hook Script

**Files:**
- Create: `src/hooks/user-prompt-submit-handoff`
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-user-prompt-submit.sh`

**Steps:**

1. Create the new hook script and load `handoff-lib.sh`.
2. Parse `UserPromptSubmit` hook input JSON from stdin using the probed field names.
3. Fetch current quota and derive tier.
4. Run the prompt risk estimator on the submitted prompt.
5. Handle approval re-submission syntax:
   - `STOP_NOW`
   - `FINISH_THIS: <intent>`
   - `APPROVE_ONCE: <intent>`
   - `HANDOFF_NOW`
6. When allowing a turn, write pre-turn metadata needed by `Stop`:
   - `session_id`
   - `turn_open=true`
   - `pre_turn_quota_pct`
   - prediction fields
7. Implement tier/risk routing:
   - allow
   - allow with warning context
   - block and require approval re-submission
   - block into emergency handoff
8. Implement failure policy:
   - use fallback quota cascade first
   - if all quota sources fail, fail open with low confidence
9. Add tests for:
   - nominal allow
   - warn-tier risky prompt with allowed-path context injection
   - prepare-tier block requiring re-submission
   - stop-tier block requiring re-submission
   - emergency hard block
   - `HANDOFF_NOW`
   - no prior blocked state when approval keyword is used
   - expired approval state
   - full quota-source failure fail-open

**Verification:**

- Run: `bash tests/test-user-prompt-submit.sh`
- Expected: all prompt gating and approval-routing cases pass

---

### Task 5: Update `PreToolUse` for Turn-Aware Enforcement

**Files:**
- Modify: `src/hooks/pre-tool-use-handoff`
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-pre-tool-use.sh`

**Steps:**

1. Keep existing polling behavior as the baseline.
2. Teach `PreToolUse` to:
   - honor active one-turn approvals
   - discard turn-state on session mismatch
   - treat expired approvals as invalid
3. Preserve existing emergency block behavior.
4. Make `EMERGENCY` override approval explicitly.
5. Keep existing accelerated polling once any signal is active.
6. Align tier messaging with the new policy:
   - `90-97%` optioned
   - `98%+` forced emergency
7. Add tests for:
   - active one-turn approval
   - stale session turn-state discarded
   - expired approval
   - emergency block still wins

**Verification:**

- Run: `bash tests/test-pre-tool-use.sh`
- Expected: existing behavior remains stable and new turn-state cases pass

---

### Task 6: Rewrite `Stop` for Post-Turn Catch-Up

**Files:**
- Modify: `src/hooks/stop-handoff`
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-stop-handoff.sh`

**Steps:**

1. Rework `stop-handoff` so it always evaluates quota at end-of-turn.
2. Read pre-turn metadata written by `UserPromptSubmit`.
3. Calculate actual post-turn delta.
4. Record telemetry and truncate it to the rolling max.
5. Discard turn-state if session mismatch is detected.
6. Close the current approved turn if one was open.
7. Apply signal lifecycle rules:
   - clear transient `PREPARE` / `STOP` under normal `<90%` conditions
   - but skip the normal `<90%` clear when the active signal source is `compaction` unless a fresh quota signal supersedes it
   - persist `PREPARE` / `STOP` within the current session as designed
   - set `EMERGENCY` at `98%+`
8. Restrict git snapshot append behavior:
   - no snapshot append for ordinary post-turn maintenance
   - append only during explicit handoff-writing or `98%+` emergency artifact writing
9. Add dedicated tests for:
   - sub-90 cleanup
   - conversation-only overshoot to `90-97%`
   - conversation-only overshoot to `98%+`
   - telemetry update
   - compaction-source skip-clear behavior
   - stale session turn-state discarded
   - git snapshot only on real handoff path

**Verification:**

- Run: `bash tests/test-stop-handoff.sh`
- Expected: post-turn state transitions and handoff-only snapshot behavior are correct

---

### Task 7: Review and Update `PreCompact` Coordination

**Files:**
- Modify: `src/hooks/pre-compact-handoff`
- Modify: `src/hooks/handoff-lib.sh`
- Test: `tests/test-stop-handoff.sh` or dedicated compaction tests if needed

**Steps:**

1. Confirm `PreCompact` writes `source=compaction` consistently.
2. Ensure `PreCompact` may raise but not lower the active tier.
3. Confirm compatibility with the rewritten `Stop` lifecycle rules.
4. Add or extend tests covering:
   - `WARN` quota + compaction raises to `PREPARE`
   - `STOP` / `EMERGENCY` still supersede compaction `PREPARE`

**Verification:**

- Run the relevant stop/compaction tests
- Expected: source-aware coordination behaves per design

---

### Task 8: Wire `UserPromptSubmit` and Timeout Changes Into Install and Uninstall

**Files:**
- Modify: `install.sh`
- Modify: `uninstall.sh`

**Steps:**

1. Copy the new `user-prompt-submit-handoff` script during install.
2. Add `UserPromptSubmit` hook registration without clobbering existing user/project hooks.
3. Raise the installed `Stop` timeout from 10 seconds to 15 seconds.
4. Remove the new hook cleanly during uninstall.
5. Keep existing deduplication and merge behavior intact.

**Verification:**

- Review the generated settings merge logic carefully.
- If safe to test locally, validate that the new hook entry is added and removable without disturbing unrelated hooks.

---

### Task 9: Update Skill and Active Documentation

**Files:**
- Modify: `src/skills/graceful-wrap-up.md`
- Modify: `README.md`
- Modify: `docs/STATUS.md`
- Modify: any active docs that still describe the old 95% hard-stop flow

**Steps:**

1. Replace stale `95%` hard-stop messaging with the new `98%` emergency policy.
2. Document the new event model:
   - `UserPromptSubmit`
   - `PreToolUse`
   - `PreCompact`
   - `Stop`
   - `StopFailure`
3. Document the approval re-submission syntax:
   - `STOP_NOW`
   - `FINISH_THIS: <intent>`
   - `APPROVE_ONCE: <intent>`
   - `HANDOFF_NOW`
4. Document that estimates are ranges, not exact token counts.
5. Document the one-turn approval rule.

**Verification:**

- Manual review for consistency across all active docs.

---

### Task 10: Review, Run the Test Suite, and Summarize Risks

**Files:**
- Review only: all files changed above

**Steps:**

1. Run the shell test suite:
   - `bash tests/test-handoff-lib.sh`
   - `bash tests/test-pre-tool-use.sh`
   - `bash tests/test-user-prompt-submit.sh`
   - `bash tests/test-stop-handoff.sh`
2. Fix any failures.
3. Review the final diff for stale threshold language and stale approval-flow assumptions.
4. Summarize residual limits:
   - no mid-turn interruption
   - estimation is heuristic
   - hidden reasoning cost remains unobservable until the next hook boundary

**Verification:**

- All runnable tests pass in the available environment, or any environment blockers are documented clearly.

---

Plan complete and saved to:

- `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`
- `docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md`

Two execution options:

1. Subagent-Driven (this session) - implement task-by-task here
2. Parallel Session (separate) - use the plan in a fresh execution-oriented session
