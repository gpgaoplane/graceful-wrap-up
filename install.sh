#!/usr/bin/env bash
# install.sh — deploys graceful-wrap-up to ~/.claude/
# Safe to re-run: idempotent. Does not overwrite existing wrap-up.md without backup.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/.handoff-config"

# Find working Python (python3 on Windows Git Bash may be an MS Store alias)
_find_py() {
    for _p in python python3 py; do
        local _c; _c=$(command -v "$_p" 2>/dev/null) || continue
        "$_c" -c "import sys; sys.exit(0)" 2>/dev/null && echo "$_c" && return 0
    done
    echo "Error: Python not found — required for settings.json merging" >&2; return 1
}
PY=$(_find_py)

echo "Installing graceful-wrap-up..."

# 1. Create target dirs
mkdir -p "$HOOKS_DIR" "$SKILLS_DIR" "$COMMANDS_DIR"

# Ensure settings.json exists before merge logic runs
if [[ ! -f "$SETTINGS" ]]; then
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{\n  "hooks": {}\n}\n' > "$SETTINGS"
    echo "  created: settings.json"
fi

# 2. Deploy hook scripts
for hook in handoff-lib.sh user-prompt-submit-handoff pre-tool-use-handoff pre-compact-handoff stop-handoff stop-failure-handoff; do
    cp "$REPO_DIR/src/hooks/$hook" "$HOOKS_DIR/$hook"
    chmod +x "$HOOKS_DIR/$hook"
    echo "  installed: hooks/$hook"
done

# 3. Deploy skills
for skill in graceful-wrap-up.md cross-validate-state.md; do
    cp "$REPO_DIR/src/skills/$skill" "$SKILLS_DIR/$skill"
    echo "  installed: skills/$skill"
done

# 4. Deploy commands (backup existing commands first)
for command in wrap-up.md cross-validate.md; do
    if [[ -f "$COMMANDS_DIR/$command" ]]; then
        cp "$COMMANDS_DIR/$command" "$COMMANDS_DIR/$command.bak"
        echo "  backed up: commands/$command -> $command.bak"
    fi
    cp "$REPO_DIR/src/commands/$command" "$COMMANDS_DIR/$command"
    echo "  installed: commands/$command"
done

# 5. Write .handoff-config if not present
if [[ ! -f "$CONFIG" ]]; then
    echo "plan=max5" > "$CONFIG"
    echo "  created: .handoff-config (plan=max5 — edit to match your subscription)"
fi

# 6. Merge hook entries into settings.json
SETTINGS_PATH="$SETTINGS" "$PY" << PYEOF
import json, sys, os

settings_path = os.environ['SETTINGS_PATH']
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})

def add_hook(event, matcher, command, timeout):
    entries = hooks.setdefault(event, [])
    for e in entries:
        if e.get('matcher') == matcher:
            for h in e.get('hooks', []):
                if h.get('command') == command:
                    return False  # already present (same matcher + command)
    entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]})
    return True

added = []
if add_hook('UserPromptSubmit', '', 'bash ~/.claude/hooks/user-prompt-submit-handoff', 10000): added.append('UserPromptSubmit')
if add_hook('PreToolUse',       '', 'bash ~/.claude/hooks/pre-tool-use-handoff',        8000):  added.append('PreToolUse')
if add_hook('PreCompact',       '', 'bash ~/.claude/hooks/pre-compact-handoff',         5000):  added.append('PreCompact')
if add_hook('Stop',             '', 'bash ~/.claude/hooks/stop-handoff',               15000):  added.append('Stop')
if add_hook('StopFailure', 'rate_limit',    'bash ~/.claude/hooks/stop-failure-handoff', 15000): added.append('StopFailure/rate_limit')
if add_hook('StopFailure', 'billing_error', 'bash ~/.claude/hooks/stop-failure-handoff', 15000): added.append('StopFailure/billing_error')

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

if added:
    print('  merged hooks:', ', '.join(added))
else:
    print('  hooks already present — no changes to settings.json')
PYEOF

echo ""
echo "Installation complete."
echo ""
echo "Next steps:"
echo "  1. Edit ~/.claude/.handoff-config and set plan= to match your subscription (pro/max5/max20)"
echo "  2. Restart Claude Code for hook changes to take effect"
echo "  3. In a session, test with: /graceful-wrap-up or /cross-validate"
