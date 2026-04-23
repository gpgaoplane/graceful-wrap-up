# multi-agent-collab Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate `graceful-wrap-up` onto the published `@gpgaoplane/multi-agent-collab@0.2.0` framework so this repo becomes the first real-world consumer of the skill it produced, without losing any current `AI_AGENTS.md` content or breaking the Phase 1 conversation-hooks work already on branch.

**Architecture:** Three phases on separate branches. **Phase A** commits the ~30 uncommitted Phase 1 conversation-hooks files in concern-grouped atomic commits on the current branch `codex/phase1-conversation-hooks` (no collab framework involvement). **Phase B** runs on a new branch `migrate/collab-v0.2.0` cut off the Phase 1 tip: delete + re-template `AI_AGENTS.md`, run `npx @gpgaoplane/multi-agent-collab init`, re-inject current content into marker sections, archive legacy `docs/agents/antigravity.md`. **Phase C** aligns `.claude/CLAUDE.md` and `.codex/CODEX.md` adapter pointers with the new `.collab/` surface. Every phase ends with `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh` green before commit.

**Tech Stack:** bash (Git Bash on Windows), npm/npx (Node ≥18), `@gpgaoplane/multi-agent-collab@0.2.0`, git.

---

## Prerequisites

Before Task A1:

- Current directory: `D:\Projects\self-skills\graceful-wrap-up`
- `git branch --show-current` → `codex/phase1-conversation-hooks`
- `node --version` → ≥18
- `npm view @gpgaoplane/multi-agent-collab version` → `0.2.0` (published, confirmed in session)
- Existing tests pass on the current dirty tree: `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh` → both exit 0
- Backup safety: `git stash list` empty (no surprises hiding), `git reflog | head -5` reviewed

## Conventions

- **TDD is NOT required** in Phase A (committing existing work) or Phase B (config/doc migration). It IS required if any code changes land inside this plan — none are planned.
- **Staging:** name files explicitly; never `git add -A` or `git add .`.
- **Commit messages:** imperative mood, explain why.
- **Line endings:** git will warn `LF will be replaced by CRLF`. These warnings are harmless on Windows; do not "fix" them by disabling `core.autocrlf`.
- **After every commit in any phase:** run the test pair `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh`. Any FAIL aborts the plan — stop and diagnose.
- **Rollback points:** tag `phase1-presnapshot` before Phase A, tag `pre-collab-migration` before Phase B. Both are annotated.

---

# Phase A — Phase 1 cleanup (current branch)

## Task A0: Pre-flight snapshot

**Files:** none (git operations only).

**Step 1: Verify starting state.**

```bash
git status --short | head -40
git branch --show-current
```

Expected: on `codex/phase1-conversation-hooks`, ~18 modified + ~12 untracked files.

**Step 2: Run tests to prove the dirty tree is green before we start touching it.**

```bash
bash tests/test-handoff-lib.sh
bash tests/test-pre-tool-use.sh
```

Expected: both scripts exit 0 with PASS reports. If either fails, STOP — fix before proceeding. A broken baseline makes commit regression detection impossible.

**Step 3: Create a rollback tag at the current committed HEAD.**

```bash
git tag -a phase1-presnapshot -m "pre-cleanup snapshot before Phase A commits"
```

No push yet — this is a local safety anchor.

**Step 4: Confirm the tag exists.**

```bash
git tag -l phase1-presnapshot
```

Expected: `phase1-presnapshot`.

**No commit for Task A0.**

---

## Task A1: Rename untracked Codex memory files to canonical names

**Why first:** The files are untracked, so renaming now puts them in git history with canonical names from day one. If we commit them under the legacy names first and rename in Phase B, we pay a rename-diff for no reason. Semantic mapping is 1:1 (verified against `templates/memory/` in the framework).

**Files:**
- Rename: `.codex/memory/project_context.md` → `.codex/memory/context.md`
- Rename: `.codex/memory/session_state.md` → `.codex/memory/state.md`
- Rename: `.codex/memory/decision_log.md` → `.codex/memory/decisions.md`
- Rename: `.codex/memory/failure_patterns.md` → `.codex/memory/pitfalls.md`

**Step 1: Verify the four source files exist and the four destination names do not.**

```bash
ls .codex/memory/
```

Expected: exactly four files — `decision_log.md`, `failure_patterns.md`, `project_context.md`, `session_state.md`. No `context.md` / `state.md` / `decisions.md` / `pitfalls.md`.

**Step 2: Rename (plain `mv`, since files are untracked).**

```bash
mv .codex/memory/project_context.md   .codex/memory/context.md
mv .codex/memory/session_state.md     .codex/memory/state.md
mv .codex/memory/decision_log.md      .codex/memory/decisions.md
mv .codex/memory/failure_patterns.md  .codex/memory/pitfalls.md
```

**Step 3: Verify.**

```bash
ls .codex/memory/
```

Expected: `context.md`, `decisions.md`, `pitfalls.md`, `state.md`.

**Step 4: Re-run tests (sanity — nothing that should have changed did).**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**No commit yet** — these files get committed together with the Codex adapter additions in Task A6.

---

## Task A2: Commit the conversation-hooks code changes

**Files:**
- Modify: `src/hooks/handoff-lib.sh`
- Modify: `src/hooks/pre-tool-use-handoff`
- Modify: `src/hooks/pre-compact-handoff`
- Modify: `src/hooks/stop-handoff`
- Create: `src/hooks/user-prompt-submit-handoff`

**Step 1: Stage only these five files.**

```bash
git add src/hooks/handoff-lib.sh \
        src/hooks/pre-tool-use-handoff \
        src/hooks/pre-compact-handoff \
        src/hooks/stop-handoff \
        src/hooks/user-prompt-submit-handoff
```

**Step 2: Verify staging.**

```bash
git diff --cached --stat
```

Expected: exactly those five files, no extras.

**Step 3: Run tests against the staged tree (they run against working tree, but working tree still includes uncommitted test changes — so this confirms hooks + current tests are coherent).**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**Step 4: Commit.**

```bash
git commit -m "feat: implement phase 1 conversation-hook model across all hooks

Rework handoff-lib.sh with conversation-aware tier detection and add
user-prompt-submit hook for approval-keyword parsing and two-step STOP
flow. PreToolUse, PreCompact, and Stop hooks refactored to emit
HANDOFF_SIGNAL context injection from the new library."
```

**Step 5: Re-run tests post-commit.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A3: Commit the updated + new tests

**Files:**
- Modify: `tests/test-handoff-lib.sh`
- Modify: `tests/test-pre-tool-use.sh`
- Create: `tests/test-pre-compact.sh`
- Create: `tests/test-stop-handoff.sh`
- Create: `tests/test-user-prompt-submit.sh`

**Step 1: Stage the five test files.**

```bash
git add tests/test-handoff-lib.sh \
        tests/test-pre-tool-use.sh \
        tests/test-pre-compact.sh \
        tests/test-stop-handoff.sh \
        tests/test-user-prompt-submit.sh
```

**Step 2: Run each newly-added test file to confirm it's not broken.**

```bash
bash tests/test-pre-compact.sh
bash tests/test-stop-handoff.sh
bash tests/test-user-prompt-submit.sh
```

Expected: each exits 0 with a PASS report.

**Step 3: Commit.**

```bash
git commit -m "test: expand suite to cover phase 1 conversation hooks

Adds pre-compact, stop, and user-prompt-submit test files; expands
handoff-lib and pre-tool-use suites for new tier-severity and
approval-keyword paths."
```

**Step 4: Run the canonical test pair.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A4: Commit the cross-validate skill and command

**Files:**
- Create: `src/skills/cross-validate-state.md`
- Create: `src/commands/cross-validate.md`

**Step 1: Stage.**

```bash
git add src/skills/cross-validate-state.md src/commands/cross-validate.md
```

**Step 2: Commit.**

```bash
git commit -m "feat: add cross-validate skill and slash command

Reusable review/cross-validation protocol that lets one agent audit
another agent's work against the current repo truth before handoff."
```

**Step 3: Run the canonical test pair.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A5: Commit the graceful-wrap-up skill + install/uninstall + README updates

**Files:**
- Modify: `src/skills/graceful-wrap-up.md`
- Modify: `install.sh`
- Modify: `uninstall.sh`
- Modify: `README.md`

**Step 1: Stage.**

```bash
git add src/skills/graceful-wrap-up.md install.sh uninstall.sh README.md
```

**Step 2: Commit.**

```bash
git commit -m "feat: update skill + install/uninstall for conversation-hook model

graceful-wrap-up.md protocol now reads HANDOFF_SIGNAL from context
injection. install.sh wires the new user-prompt-submit hook and
preserves the (matcher, command) dedup pair for StopFailure entries.
README reflects the warn-only conversation-hook architecture."
```

**Step 3: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A6: Commit Codex adapter — CODEX.md, memory, session checklist, BOOTSTRAP deletion

**Files:**
- Create: `.codex/CODEX.md`
- Create: `.codex/memory/context.md` (renamed in Task A1)
- Create: `.codex/memory/state.md` (renamed in Task A1)
- Create: `.codex/memory/decisions.md` (renamed in Task A1)
- Create: `.codex/memory/pitfalls.md` (renamed in Task A1)
- Modify: `.codex/SESSION_CHECKLIST.md`
- Delete: `.codex/BOOTSTRAP.md`

**Step 1: Stage. Use `git rm` for the deleted file.**

```bash
git rm .codex/BOOTSTRAP.md
git add .codex/CODEX.md \
        .codex/memory/context.md \
        .codex/memory/state.md \
        .codex/memory/decisions.md \
        .codex/memory/pitfalls.md \
        .codex/SESSION_CHECKLIST.md
```

**Step 2: Verify staging matches exactly.**

```bash
git diff --cached --stat
```

Expected: seven entries total — one delete (BOOTSTRAP.md), one modify (SESSION_CHECKLIST.md), five adds (CODEX.md + four memory files).

**Step 3: Commit.**

```bash
git commit -m "feat: onboard Codex adapter with memory at canonical paths

Replaces ephemeral BOOTSTRAP.md with durable .codex/CODEX.md
operating guide and four memory files (context, state, decisions,
pitfalls) matching the multi-agent-collab v0.2.0 memory schema.
SESSION_CHECKLIST.md updated to reflect the new start/end ritual."
```

**Step 4: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A7: Commit docs — STATUS, agent logs, new plans, Claude takeover note, AI_AGENTS tweaks, tmp/

**Files:**
- Modify: `AI_AGENTS.md`
- Modify: `docs/STATUS.md`
- Modify: `docs/agents/claude.md`
- Modify: `docs/agents/codex.md`
- Create: `docs/CLAUDE_TAKEOVER_2026-04-22.md`
- Create: `docs/plans/2026-04-21-phase1-conversation-hooks-design.md`
- Create: `docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md`

**Note on `AI_AGENTS.md`:** this commit lands the Phase-1-era content. Phase B will delete-and-re-template it; that's intentional — Phase A puts the file in a coherent state so Phase B's diff against framework templates is meaningful.

**Note on `tmp/` and `.claude/settings.local.json`:** NOT staged here. See Task A8.

**Step 1: Stage.**

```bash
git add AI_AGENTS.md \
        docs/STATUS.md \
        docs/agents/claude.md \
        docs/agents/codex.md \
        docs/CLAUDE_TAKEOVER_2026-04-22.md \
        docs/plans/2026-04-21-phase1-conversation-hooks-design.md \
        docs/plans/2026-04-21-phase1-conversation-hooks-implementation.md
```

**Step 2: Commit.**

```bash
git commit -m "docs: record phase 1 conversation-hook design, status, and agent logs

Adds the two phase 1 plan documents and the Claude takeover note from
2026-04-22. Updates STATUS.md, AI_AGENTS.md, and the Claude + Codex
agent logs with phase 1 outcomes."
```

**Step 3: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A8: Handle remaining uncommitted artifacts — decision point

**Remaining uncommitted paths after Task A7:**
- `AI_HANDOFF.md` (~571 line diff)
- `RESUME_PROMPT.md` (2 line diff)
- `.claude/settings.local.json` (untracked)
- `tmp/` (untracked, likely ephemeral scratch)

**Step 1: Inspect each.**

```bash
git diff AI_HANDOFF.md | head -30
git diff RESUME_PROMPT.md
cat .claude/settings.local.json
ls tmp/ 2>&1 | head
```

**Step 2: Decide per-path.**

- **`AI_HANDOFF.md` and `RESUME_PROMPT.md`** are auto-written by the Stop hook at quota-STOP. They're effectively transient session logs. **Recommendation:** commit as `chore: refresh handoff artifacts from recent sessions` ONLY if they contain durable reference content; otherwise `git checkout -- AI_HANDOFF.md RESUME_PROMPT.md` to restore tracked baseline. Ask the user if uncertain.
- **`.claude/settings.local.json`** is Claude Code's per-user permission state. Should NOT be committed. Add to `.gitignore` if not already covered. Confirm with:

  ```bash
  grep -E '^\.claude/settings\.local\.json$|^\.claude/$' .gitignore
  ```

  If the grep returns nothing, add `/.claude/settings.local.json` to `.gitignore` and commit that as `chore: gitignore Claude Code local settings`.
- **`tmp/`** — if it contains scratch files from this session or prior, add `/tmp/` to `.gitignore`. Commit as `chore: gitignore tmp scratch dir`.

**Step 3: Execute the chosen resolution** (one or more small commits as needed).

**Step 4: Final status check.**

```bash
git status --short
```

Expected: clean working tree (no modified or untracked paths). If not, loop back to Step 1 for anything remaining.

**Step 5: Run tests one last time in Phase A.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task A9: Push Phase 1 work to origin

**Step 1: Verify branch + commits.**

```bash
git log --oneline origin/codex/phase1-conversation-hooks..HEAD
```

Expected: 6–8 new commits (A2 through A8) ahead of remote.

**Step 2: Push.**

```bash
git push origin codex/phase1-conversation-hooks
```

Expected: `To github.com:gpgaoplane/graceful-wrap-up.git` with non-fast-forward NOT reported (we only added commits, no force-push scenario).

**Step 3: Push the pre-snapshot tag for external rollback if ever needed.**

```bash
git push origin phase1-presnapshot
```

Expected: `[new tag] phase1-presnapshot -> phase1-presnapshot`.

**Phase A complete. Working tree clean. All Phase 1 work preserved on remote.**

---

# Phase B — Migration onto multi-agent-collab v0.2.0

## Task B1: Create migration branch and rollback tag

**Step 1: Cut the migration branch from the current Phase 1 tip.**

```bash
git checkout -b migrate/collab-v0.2.0
```

**Step 2: Tag the pre-migration state.**

```bash
git tag -a pre-collab-migration -m "snapshot immediately before npx multi-agent-collab init"
```

**Step 3: Verify tests are still green on the new branch.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**No commit for Task B1 — the tag and branch are the artifacts.**

---

## Task B2: Back up AI_AGENTS.md and delete the repo copy

**Files:**
- Backup: `AI_AGENTS.md` → `/tmp/AI_AGENTS.md.bak` (outside the repo)
- Delete (from working tree only, not from git): `AI_AGENTS.md`

**Step 1: Create an out-of-repo backup.**

```bash
cp AI_AGENTS.md /tmp/AI_AGENTS.md.bak
wc -l /tmp/AI_AGENTS.md.bak AI_AGENTS.md
```

Expected: identical line counts.

**Step 2: Remove the working-tree copy. Do NOT `git rm` — we want bootstrap to create it fresh, then stage the replacement in Task B6.**

```bash
rm AI_AGENTS.md
```

**Step 3: Verify git sees the deletion but we haven't staged it.**

```bash
git status --short AI_AGENTS.md
```

Expected: ` D AI_AGENTS.md` (unstaged deletion).

**No commit yet.**

---

## Task B3: Run the bootstrap

**Step 1: Confirm npm package version (sanity).**

```bash
npm view @gpgaoplane/multi-agent-collab version
```

Expected: `0.2.0`.

**Step 2: Run the bootstrap.**

```bash
npx @gpgaoplane/multi-agent-collab@0.2.0 init
```

Expected output (order may vary slightly):
- `Mode: fresh` (because `.collab/VERSION` does not yet exist)
- `Setting up shared files`
- `Bootstrapping agent: Claude` / `Codex` / `Gemini`
- `Done. Repo at collab version 0.2.0.`

**Step 3: Verify the expected files were produced.**

```bash
ls .collab/
cat .collab/VERSION
test -f AI_AGENTS.md && echo "AI_AGENTS.md: created"
test -f AGENTS.md && echo "AGENTS.md: created"
test -f GEMINI.md && echo "GEMINI.md: created"
ls .gemini/memory/ 2>&1
ls .claude/memory/ 2>&1
ls docs/agents/
```

Expected:
- `.collab/` contains `ACTIVE.md`, `INDEX.md`, `PROTOCOL.md`, `ROUTING.md`, `VERSION`, `agents.d/`, `archive/`
- `cat .collab/VERSION` → `0.2.0`
- `AI_AGENTS.md`, `AGENTS.md`, `GEMINI.md` all exist
- `.gemini/memory/` contains `state.md`, `context.md`, `decisions.md`, `pitfalls.md`
- `.claude/memory/` contains `state.md`, `context.md`, `decisions.md`, `pitfalls.md`
- `docs/agents/` contains `claude.md` (preserved), `codex.md` (preserved), `antigravity.md` (preserved — will archive in Task B5), `gemini.md` (new)

**Step 4: Verify bootstrap did NOT overwrite existing adapters or Codex memory (skip-if-exists behavior).**

```bash
head -10 .claude/CLAUDE.md
head -10 .codex/CODEX.md
head -10 .codex/memory/context.md
```

Expected: unchanged from their pre-bootstrap state. `.claude/CLAUDE.md` opens with the current graceful-wrap-up rules, not the framework's generic adapter template.

**Step 5: Run tests. The hooks are source-independent of the collab surface, so they must still pass.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**No commit yet — content re-injection happens in Task B4.**

---

## Task B4: Re-inject project content into the new AI_AGENTS.md

**Goal:** replace the framework-generic content inside marker sections with the project-specific content from `/tmp/AI_AGENTS.md.bak`, and append truly project-unique sections **outside** all marker blocks so `re-init` never touches them.

**Mapping (from Q2 in the session):**

| Content from `/tmp/AI_AGENTS.md.bak` | Destination in new `AI_AGENTS.md` |
|---|---|
| "What This Project Is" paragraph (backup lines 9–17) | Replace `{{PROJECT_SUMMARY}}` inside `<!-- collab:project-summary -->` |
| "Current adapters" (backup lines 58–70) | Replace generic table inside `<!-- collab:current-adapters -->` with Claude + Codex + Gemini rows matching this repo's actual paths |
| "Onboarding checklist" (backup lines 71–79) | Merge project-specific steps into `<!-- collab:onboarding -->` — preserve the `git log --oneline -10` step if absent from template |
| "Behavioral Rules" (backup lines 94–130) | Merge into `<!-- collab:behavioral-rules -->` — MUST preserve the project-unique **Testing** subsection (`test-handoff-lib.sh` + `test-pre-tool-use.sh` commands) |
| "Current Implementation State" + active design work (backup lines 21–54) | **Append outside all markers** as `## Current Implementation State` |
| "Architecture Overview" ASCII diagram (backup lines 133–164) | **Append outside all markers** as `## Architecture Overview` |
| "Key Technical Gotchas" (backup lines 168–184) | **Append outside all markers** as `## Key Technical Gotchas` |
| "File Map" (backup lines 188–208) | **Append outside all markers** as `## File Map` |
| "Setting Up Your Agent Config" table (backup lines 212–231) | Drop — covered by the new `<!-- collab:current-adapters -->` + per-agent adapter files |
| "Agent Log Template" block (backup lines 235–260) | Drop — covered by `<!-- collab:agent-log-template -->` pointer to `templates/work-log-seed.md` in the framework |

**Step 1: Open both files side-by-side mentally.** Read in full:

```bash
cat /tmp/AI_AGENTS.md.bak
cat AI_AGENTS.md
```

**Step 2: Edit `AI_AGENTS.md` in place**, following the mapping. For each marker block (`<!-- collab:XXX:start --> ... <!-- collab:XXX:end -->`), replace the content between markers without touching the marker lines themselves. For the four "outside markers" sections, append them **after** the last marker's end line, with a leading `---` horizontal rule separator.

Use the `Edit` tool, not shell redirection. Each marker section is one Edit call; each appended free section is one Edit call.

**Step 3: Render-check — verify the marker invariants.**

```bash
grep -c '<!-- collab:.*:start -->' AI_AGENTS.md
grep -c '<!-- collab:.*:end -->' AI_AGENTS.md
```

Expected: each returns `6` (six marker pairs — project-summary, current-adapters, onboarding, behavioral-rules, routing-pointer, agent-log-template). If counts differ, a marker was accidentally deleted — restore from template.

**Step 4: Zero-loss check against backup.**

For each semantic block in the mapping table, grep the new file for a distinctive phrase from the backup. Example commands:

```bash
grep -q "quota-aware graceful handoff system" AI_AGENTS.md && echo "project-summary: OK" || echo "MISSING: project summary paragraph"
grep -q "test-handoff-lib.sh" AI_AGENTS.md && echo "testing-rule: OK" || echo "MISSING: testing rule"
grep -q "find_python" AI_AGENTS.md && echo "gotchas: OK" || echo "MISSING: find_python gotcha"
grep -q "seven_day_omelette" AI_AGENTS.md && echo "gotchas-2: OK" || echo "MISSING: seven_day_omelette note"
grep -q "stdout vs stderr for PreToolUse" AI_AGENTS.md && echo "gotchas-3: OK" || echo "MISSING: stdout/stderr gotcha"
grep -q "handoff-lib.sh            shared utilities" AI_AGENTS.md && echo "file-map: OK" || echo "MISSING: file map"
grep -q "UserPromptSubmit fires on every user prompt" AI_AGENTS.md && echo "architecture: OK" || echo "MISSING: architecture diagram"
```

Expected: every line prints `OK`. Any `MISSING` → go back to Step 2, locate that content, re-inject.

**Step 5: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**No commit yet — commits happen in Task B6 after Task B5's archive.**

---

## Task B5: Archive docs/agents/antigravity.md

**Why plain `mv` and not `npx ... archive`:** the current `docs/agents/antigravity.md` has no YAML frontmatter, so `collab-archive.sh`'s `fm_has_frontmatter` check skips the status flip, and the INDEX upsert uses `type=unknown/owner=unknown` — not a cleaner outcome than a plain move. The file is historical, not active; it doesn't need to be in INDEX at all.

**Files:**
- Move: `docs/agents/antigravity.md` → `.collab/archive/docs/agents/antigravity.md`

**Step 1: Confirm destination dir exists (bootstrap created `.collab/archive/`).**

```bash
test -d .collab/archive && echo "archive dir: present" || echo "MISSING"
```

Expected: `archive dir: present`.

**Step 2: Create the nested path and move.**

```bash
mkdir -p .collab/archive/docs/agents
mv docs/agents/antigravity.md .collab/archive/docs/agents/antigravity.md
```

**Step 3: Verify.**

```bash
ls docs/agents/
ls .collab/archive/docs/agents/
```

Expected: `docs/agents/` contains `claude.md`, `codex.md`, `gemini.md` — **no** `antigravity.md`. Archive path contains `antigravity.md`.

**Step 4: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

---

## Task B6: Stage, verify zero-loss one more time, commit the migration

**Files:** everything produced by Tasks B2–B5.

**Step 1: Full status review.**

```bash
git status --short | sort
```

Expected additions / deletions:
- ` M AI_AGENTS.md` — content re-injected
- `?? AGENTS.md` — new
- `?? GEMINI.md` — new
- `?? .collab/` — new directory tree (VERSION, ACTIVE.md, INDEX.md, ROUTING.md, PROTOCOL.md, agents.d/, archive/)
- `?? .gemini/` — new
- `?? .claude/memory/` — new (state, context, decisions, pitfalls)
- `R  docs/agents/antigravity.md -> .collab/archive/docs/agents/antigravity.md` — rename (may show as ` D` + `??` depending on git's rename-detect threshold)
- `?? docs/agents/gemini.md` — new work-log seed

**Step 2: Final zero-loss diff against backup.**

```bash
diff <(grep -v '^<!-- collab:' /tmp/AI_AGENTS.md.bak | sort -u) <(grep -v '^<!-- collab:' AI_AGENTS.md | sort -u) | head -50
```

This is a noisy diff because the new file has template scaffolding the old didn't. What matters: no line from `/tmp/AI_AGENTS.md.bak` that contains project-specific content (repo URL, tier names, hook file paths, gotcha names, ASCII diagram, file map entries) should appear as `<` (only in backup). If any do, they were lost — go back to Task B4 Step 2.

**Step 3: Remove the backup now that we've validated.**

```bash
rm /tmp/AI_AGENTS.md.bak
```

**Step 4: Stage everything.**

```bash
git add AI_AGENTS.md AGENTS.md GEMINI.md \
        .collab/ \
        .gemini/ \
        .claude/memory/ \
        docs/agents/gemini.md
git add -u docs/agents/antigravity.md  # stage the delete
git add .collab/archive/docs/agents/antigravity.md  # stage the new location
```

Note: `git add -u` is scoped to the specific path and is safe; we're not using `git add -A`.

**Step 5: Confirm staging.**

```bash
git diff --cached --stat | tail -20
git status --short
```

Expected: all intended paths staged; `git status --short` shows nothing unstaged.

**Step 6: Run tests one more time on the staged tree.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**Step 7: Commit.**

```bash
git commit -m "feat: migrate repo onto multi-agent-collab v0.2.0

Bootstrap the shared contract (.collab/), AGENTS.md front door, and
Gemini adapter (GEMINI.md, .gemini/memory/, docs/agents/gemini.md)
via npx @gpgaoplane/multi-agent-collab@0.2.0 init.

Rebuild AI_AGENTS.md on top of the framework's marker-bearing template
so future re-inits can refresh generic content while preserving
project-specific sections (implementation state, architecture diagram,
gotchas, file map) appended outside all markers.

Archive legacy docs/agents/antigravity.md — Antigravity shares the
GEMINI.md adapter surface with Gemini CLI per the framework's
descriptor."
```

**Step 8: Post-commit verification.**

```bash
git log --oneline -3
cat .collab/VERSION
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: new commit at HEAD, `.collab/VERSION` = `0.2.0`, tests green.

---

# Phase C — Adapter integration polish

## Task C1: Align `.claude/CLAUDE.md` first-read block with the new surface

**Current state:** `.claude/CLAUDE.md` already reads `AI_AGENTS.md`. We want to add pointers to the new shared files without displacing project-specific rules.

**Files:**
- Modify: `.claude/CLAUDE.md`

**Step 1: Read current content.**

```bash
cat .claude/CLAUDE.md
```

**Step 2: Add a new "Shared context" subsection** immediately after the existing "First read" block. The additions should point at:
- `.collab/INDEX.md` — for delta-read
- `.collab/ROUTING.md` + `.collab/PROTOCOL.md` — for end-of-task fan-out
- `.claude/memory/state.md` — for session-local state

Use the `Edit` tool. Preserve every existing line. Only add new lines; do not rewrite existing rules.

**Step 3: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green (config-only change; no hook logic touched).

**Step 4: Stage + commit.**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: point Claude adapter at collab INDEX, ROUTING, PROTOCOL, memory"
```

---

## Task C2: Align `.codex/CODEX.md` first-read block

**Files:**
- Modify: `.codex/CODEX.md`

**Step 1: Read current content.**

```bash
cat .codex/CODEX.md
```

**Step 2: Add the same `.collab/` pointers** (INDEX / ROUTING / PROTOCOL) and point at `.codex/memory/state.md` for session state. Preserve every existing instruction.

**Step 3: Run tests.**

```bash
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected: both green.

**Step 4: Stage + commit.**

```bash
git add .codex/CODEX.md
git commit -m "docs: point Codex adapter at collab INDEX, ROUTING, PROTOCOL, memory"
```

---

## Task C3: Final verification and branch push

**Step 1: Full state audit.**

```bash
git status --short
git log --oneline origin/codex/phase1-conversation-hooks..HEAD
cat .collab/VERSION
bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh
```

Expected:
- Clean working tree
- 3 new commits beyond the Phase A tip (B6 + C1 + C2)
- `.collab/VERSION` = `0.2.0`
- Tests green

**Step 2: Run the framework's own audit command as a sanity check.**

```bash
npx @gpgaoplane/multi-agent-collab@0.2.0 check
```

Expected: audit passes (or lists only known-archived entries). Any unexpected mismatch between INDEX and filesystem → investigate before pushing.

**Step 3: Push the migration branch and the rollback tag.**

```bash
git push -u origin migrate/collab-v0.2.0
git push origin pre-collab-migration
```

**Step 4: Confirm remote.**

```bash
git ls-remote --heads origin migrate/collab-v0.2.0
git ls-remote --tags origin pre-collab-migration
```

Expected: both return non-empty SHAs.

**Migration complete.**

---

## Completion checklist

- [ ] Phase A: 6–8 atomic commits on `codex/phase1-conversation-hooks`, pushed to origin
- [ ] `phase1-presnapshot` tag exists locally and on origin
- [ ] `pre-collab-migration` tag exists locally and on origin
- [ ] `migrate/collab-v0.2.0` branch pushed to origin
- [ ] `.collab/VERSION` contains `0.2.0`
- [ ] `AGENTS.md`, `AI_AGENTS.md`, `GEMINI.md` all present at repo root
- [ ] `.claude/memory/` and `.gemini/memory/` each contain state, context, decisions, pitfalls
- [ ] `.codex/memory/` contains state, context, decisions, pitfalls (renamed in Task A1)
- [ ] `docs/agents/antigravity.md` no longer in `docs/agents/`; present at `.collab/archive/docs/agents/`
- [ ] `bash tests/test-handoff-lib.sh && bash tests/test-pre-tool-use.sh` green at the tip of `migrate/collab-v0.2.0`
- [ ] `npx @gpgaoplane/multi-agent-collab check` passes
- [ ] Zero project-specific content from pre-migration `AI_AGENTS.md` is missing (validated by Task B6 Step 2 diff)

## What's deliberately NOT in this plan

- **PR / merge of `migrate/collab-v0.2.0` to `main`** — left to user judgment after review. The branch is safe to sit indefinitely.
- **Populating `.claude/memory/*.md` or `.gemini/memory/*.md`** with real content. Those are empty seeds intended to be filled during the first post-migration work session by each agent.
- **Updating `docs/STATUS.md`** to reference the migration. Optional; can be added as a one-line note after the branch merges.
- **Deleting `phase1-presnapshot` / `pre-collab-migration` tags** after success. Keep them indefinitely — they're lightweight.
- **Antigravity-as-separate-adapter.** The framework treats Antigravity + Gemini CLI as one `GEMINI.md` adapter. Adding a distinct `antigravity` descriptor via `--join antigravity` is available if the user later decides they want separate work logs, but it's explicitly out of scope here.

## Watch-outs during execution

- **Phase A Task A8:** the `AI_HANDOFF.md` 571-line diff may contain anything — do not commit blindly. If it looks like accumulated auto-written handoff content, `git checkout -- AI_HANDOFF.md` is the correct move. If it contains intentional doc changes, commit separately.
- **Phase B Task B3:** `npx` on Windows may prompt to install the package the first time. Confirm the scope is `@gpgaoplane/` before accepting. If the user has `npm` auth configured for a different scope, verify no scope mismatch.
- **Phase B Task B4:** the template's `{{PROJECT_SUMMARY}}` placeholder is emitted verbatim (no token substitution for this file). When you paste the project-summary content, delete the `{{PROJECT_SUMMARY}}` line — don't leave both.
- **Phase B Task B5:** if `docs/agents/antigravity.md` is `git mv`'d instead of `mv`'d, git tracks it as a rename, which is fine — the Task B6 staging still catches it. The plan specifies plain `mv` only because the file is tracked by the Phase A commit and git will auto-detect the rename at stage time.
- **Phase C Tasks C1 + C2:** resist the urge to rewrite existing `.claude/CLAUDE.md` and `.codex/CODEX.md` rules. The integration is purely additive — each adapter keeps its current project-specific content; we only add pointers to the new shared files.

## Checkpoints — pause for ack

- **After Task A9** (Phase A pushed to origin). User confirms the grouping looks right before Phase B begins.
- **After Task B3** (bootstrap done, nothing committed yet). User sees what bootstrap produced before we start re-injecting content.
- **After Task B6** (migration commit). User reviews the diff before Phase C pointers get layered on.
- **Before Task C3 Step 3** (branch push). Last chance to audit before remote.
