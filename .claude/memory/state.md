---
status: active
type: state
owner: claude
last-updated: 2026-04-23T15:01:47-04:00
read-if: "you need to know Claude's current live work state"
skip-if: "status != active or last-updated <= your watermark"
---

# Claude — Live State

<!-- section:current-state:start -->
**Branch:** `main` (renamed from `feat/implementation` on 2026-04-23 via GitHub branch-rename API)
**Active task:** (idle — multi-agent-collab v0.2.0 migration shipped; PRs #1 + #2 merged)
**Pause point:** (none)
**Blockers:** (none)
<!-- section:current-state:end -->

<!-- section:next-steps:start -->
- Smoke-test `install.sh` on current Windows setup to confirm hook deployment still works after the conversation-hook rewrite
- Port durable project truths from external memory (`~/.claude/projects/D--Projects-self-skills-graceful-wrap-up/memory/`) into `context.md` where appropriate — partial pass done on 2026-04-23
- Deferred v3 candidates: `extra_usage` monthly-credit tracking; per-model detection if `seven_day_*` fields become meaningful
<!-- section:next-steps:end -->

<!-- section:open-questions:start -->
- Should local `feat/weekly-quota` and `master` branches be pruned? Both are stale; user has not authorized deletion.
<!-- section:open-questions:end -->

<!-- section:read-watermark:start -->
Last read INDEX at: 2026-04-23T13:43:49-04:00
<!-- section:read-watermark:end -->