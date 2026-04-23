---
status: active
type: decisions
owner: claude
last-updated: 2026-04-23T15:01:47-04:00
read-if: "you need Claude's major design decisions"
skip-if: "status != active or last-updated <= your watermark"
---

# Claude — Decision Log

Append new decisions below. Format:

```
## D-<n> — <title> — <ISO-8601>
**Context:**
**Alternatives:**
**Choice:**
**Rationale:**
**Tradeoffs:**
```

<!-- section:entries:start -->

## D-1 — Warn-only hook tier model — 2026-04-23
**Context:** PreToolUse hook needs to signal quota state to the agent without wedging legitimate work.
**Alternatives:** (a) Hard-block at STOP (exit 2 blocks the tool call). (b) Warn-only (always exit 0, inject context).
**Choice:** Warn-only. `UserPromptSubmit` is the only hook that returns `exit 2`, and only on STOP first-hit, and only to show the user a 4-option prompt — a subsequent re-submit always passes through.
**Rationale:** Hard-blocks stranded the agent mid-task with no way forward. Warn-only lets the agent choose: keep working, hand off, plan-only, or approve-once. User has the ultimate say via approval keywords.
**Tradeoffs:** Agent may miss the threshold if it ignores the context injection. Mitigated by multiple re-fires across call sites and by the Stop hook writing artifacts at STOP regardless.

## D-2 — OAuth-only quota detection — 2026-04-23
**Context:** v1 used a detection cascade: OAuth → JSONL → heuristic.
**Alternatives:** (a) Keep the cascade as fallback safety net. (b) OAuth-only.
**Choice:** OAuth-only. JSONL fallback removed entirely.
**Rationale:** JSONL's hardcoded per-plan token limits were wrong by up to ~70× for `max5`, producing false EMERGENCY readings. Claude Code itself works against the same OAuth endpoint, so if the user has a working Claude Code session, OAuth resolves. Heuristic was a 40/60/80 tool-count fabrication with no ground truth.
**Tradeoffs:** If OAuth is transiently down, we fail-open (no signal). Considered acceptable — warn-only design means fail-open degrades gracefully.

## D-3 — Adopt @gpgaoplane/multi-agent-collab@0.2.0 — 2026-04-23
**Context:** This repo had ad-hoc multi-agent collaboration files (`AI_AGENTS.md`, `.codex/`, `docs/agents/*`). A reusable skill was authored in parallel during a prior session and published to npm.
**Alternatives:** (a) Keep ad-hoc state. (b) Adopt the published skill.
**Choice:** Adopt. This repo is now the first real-world consumer of the skill it produced.
**Rationale:** Dogfooding validates the skill; shared contract (`.collab/INDEX`, `ROUTING`, `PROTOCOL`) formalizes fan-out routing and end-of-task receipts across Claude/Codex/Gemini; framework's marker-guided merge preserves project-specific content on future re-inits.
**Tradeoffs:** Migration cost ~2 hours of careful work (one subagent for AI_AGENTS re-injection, late-catch repair for one dropped bullet). Accepted for the collaboration-discipline gains.

## D-4 — Merge commits, not squash, for migration PRs — 2026-04-23
**Context:** Phase A built 7 atomic well-messaged commits; Phase B/C added 3 more on a branch that branched off Phase A.
**Alternatives:** (a) Squash each PR to one commit. (b) Merge commits preserving atomic structure. (c) Rebase merge.
**Choice:** Merge commits for both PRs.
**Rationale:** Atomic-commit blame anchors are valuable for forensic work. Squash would collapse them into one opaque commit. Also: a squash merge on PR #1 would have forced a rebase of `migrate/collab-v0.2.0` before PR #2 could cleanly show only its 3 commits.
**Tradeoffs:** Main's log gets 10 commits + 2 merge commits instead of 2 squashed commits. Noisier for a scroll-skim but richer for blame.

## D-5 — Rename default branch from feat/implementation to main — 2026-04-23
**Context:** Remote default was `feat/implementation`. Non-standard; adds friction for any future contributor.
**Alternatives:** (a) Keep as-is. (b) Rename via GitHub branch-rename API.
**Choice:** Rename. Used `POST /repos/{owner}/{repo}/branches/{old}/rename` which preserves PR bases, redirects old URLs, and updates webhooks.
**Rationale:** Cosmetic correctness + compatibility with downstream tools that assume `main`/`master`. Low risk because the API does the rewrite atomically.
**Tradeoffs:** None observed. Local clones fetch + prune cleanly.

<!-- section:entries:end -->