---
description: End-of-session ritual — summarize work, update STATUS.md, write handoff artifacts
---

Run the end-of-session wrap-up ritual. Invoke the `graceful-wrap-up` skill first, then complete ALL steps below.

## Step 0: Invoke graceful-wrap-up skill
Use the `graceful-wrap-up` skill to write `AI_HANDOFF.md` and `RESUME_PROMPT.md` for this session.
These are the primary handoff artifacts — write them comprehensively.
Treat this as a voluntary PREPARE-tier handoff (user-requested, not quota-triggered).

## Step 1: Summarize This Session
List what was accomplished as bullet points. Be specific — file names, features, fixes.

## Step 2: Capture Learnings
Review the session for:
- Patterns worth remembering → write to project native memory
- Corrections the user made → write to project native memory
- Any pattern seen 2+ times → promote to `.claude/rules/` (ask user first)
- Any universal preference → promote to global `~/.claude/memory/MEMORY.md`

## Step 3: Update STATUS.md
Read the current `docs/STATUS.md`. Update it with:
- Move completed items from "In Progress" to "Done"
- Add new items discovered during this session to "Up Next"
- Update "Current Phase" if a phase milestone was reached
- Update the "Last Updated" timestamp
- Write a one-line handoff note at the bottom under "Handoff Note"

## Step 4: Suggest Commit
If there are uncommitted changes, suggest a commit with a clear message.
Do NOT commit automatically — only suggest.

## Step 5: Print Summary
Print a brief session summary showing:
- What was done
- Where AI_HANDOFF.md and RESUME_PROMPT.md were written
- What the next session should focus on
