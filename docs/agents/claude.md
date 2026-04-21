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
