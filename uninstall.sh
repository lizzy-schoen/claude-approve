#!/usr/bin/env bash
set -euo pipefail

# claude-approve uninstaller
# Removes hooks from Claude Code settings and optionally deletes config.

CONFIG_DIR="$HOME/.config/claude-approve"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== claude-approve uninstall ==="
echo ""

# Remove hooks from Claude Code settings
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
  HOOK_PATH="$SCRIPT_DIR/hooks"

  UPDATED=$(jq --arg path "$HOOK_PATH" '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= (if . then map(select(.command | startswith($path) | not)) else . end)
        ) | map(select(.hooks | length > 0))
      ) | if .hooks | length == 0 then del(.hooks) else . end
    else .
    end
  ' "$SETTINGS_FILE")

  echo "$UPDATED" > "$SETTINGS_FILE"
  echo "Hooks removed from $SETTINGS_FILE"
else
  echo "Could not update settings (file missing or jq not installed)."
  echo "Manually remove the claude-approve hooks from $SETTINGS_FILE"
fi

# Ask about config
echo ""
read -rp "Also delete config at $CONFIG_DIR? [y/N]: " DELETE_CONFIG
if [[ "${DELETE_CONFIG,,}" =~ ^(y|yes)$ ]]; then
  rm -rf "$CONFIG_DIR"
  echo "Config deleted."
else
  echo "Config kept at $CONFIG_DIR"
fi

echo ""
echo "Uninstall complete."
