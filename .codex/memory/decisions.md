# Decision Log

## 2026-04-21

- Chose `.codex/` as the Codex-specific adapter layer while keeping `AI_AGENTS.md` as the shared canonical collaboration contract.
- Chose `.codex/CODEX.md` as the primary Codex entrypoint, analogous to Claude's `.claude/CLAUDE.md`.
- Chose a lean memory model rather than a large memory tree to reduce drift and stale files.
- Chose the default routing rule: when unsure where an update belongs, put it in `session_state.md`.
- Chose to pause Phase 1 implementation until Claude cross-validates the new conversation-aware design.
- Chose `98%+` as the forced emergency cutoff, with `90-97%` remaining optioned on a per-turn basis in the active Phase 1 design.
