#!/usr/bin/env bash
# uninstall.sh — removes graceful-wrap-up from ~/.claude/
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# Find working Python
_find_py() {
    for _p in python python3 py; do
        local _c; _c=$(command -v "$_p" 2>/dev/null) || continue
        "$_c" -c "import sys; sys.exit(0)" 2>/dev/null && echo "$_c" && return 0
    done
    echo "Error: Python not found" >&2; return 1
}
PY=$(_find_py)

echo "Uninstalling graceful-wrap-up..."

# 1. Remove hook scripts
for hook in handoff-lib.sh user-prompt-submit-handoff pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    rm -f "$HOOKS_DIR/$hook" && echo "  removed: hooks/$hook"
done

# 2. Remove skills
for skill in graceful-wrap-up.md cross-validate-state.md; do
    rm -f "$CLAUDE_DIR/skills/$skill" && echo "  removed: skills/$skill"
done

# 3. Restore command backups if they exist
for command in wrap-up.md cross-validate.md; do
    if [[ -f "$CLAUDE_DIR/commands/$command.bak" ]]; then
        mv "$CLAUDE_DIR/commands/$command.bak" "$CLAUDE_DIR/commands/$command"
        echo "  restored: commands/$command from backup"
    else
        rm -f "$CLAUDE_DIR/commands/$command" && echo "  removed: commands/$command"
    fi
done

# 4. Remove config and state files
rm -f "$CLAUDE_DIR/.handoff-config" "$CLAUDE_DIR/.handoff-signal" "$CLAUDE_DIR/.handoff-counter"
echo "  removed: state files"

# 5. Remove hook entries from settings.json
SETTINGS_PATH="$SETTINGS" "$PY" << PYEOF
import json, os

settings_path = os.environ['SETTINGS_PATH']
if not os.path.exists(settings_path):
    print('  settings.json not found — nothing to remove')
    raise SystemExit(0)

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
handoff_commands = {
    'bash ~/.claude/hooks/user-prompt-submit-handoff',
    'bash ~/.claude/hooks/pre-tool-use-handoff',
    'bash ~/.claude/hooks/pre-compact-handoff',
    'bash ~/.claude/hooks/stop-handoff',
    'bash ~/.claude/hooks/stop-failure-handoff',
}

removed = 0
for event in list(hooks.keys()):
    orig = hooks[event]
    filtered = [
        e for e in orig
        if not any(h.get('command') in handoff_commands for h in e.get('hooks', []))
    ]
    if len(filtered) < len(orig):
        removed += len(orig) - len(filtered)
    if filtered:
        hooks[event] = filtered
    else:
        del hooks[event]

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
print(f'  removed {removed} hook entries from settings.json')
PYEOF

echo ""
echo "Uninstall complete. Restart Claude Code for changes to take effect."
