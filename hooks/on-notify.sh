#!/usr/bin/env bash
set -euo pipefail

# Claude Code Notification Hook
# Sends a one-way Discord DM when Claude is idle / waiting for input.

CONFIG_FILE="${CLAUDE_APPROVE_CONFIG:-$HOME/.config/claude-approve/config}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found at $CONFIG_FILE. Run install.sh first." >&2
  exit 0  # Don't block Claude for a notification failure
fi

source "$CONFIG_FILE"

DISCORD_API="https://discord.com/api/v10"

# Read hook input from stdin
INPUT=$(cat)

NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')

# Only send for relevant notification types
case "$NOTIFICATION_TYPE" in
  idle_prompt)
    MESSAGE="Claude Code is waiting for your input."
    ;;
  *)
    # Skip other notification types (permission_prompt is handled by the PermissionRequest hook)
    exit 0
    ;;
esac

# Open DM channel and send message
DM_CHANNEL=$(curl -sf -X POST "${DISCORD_API}/users/@me/channels" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"recipient_id\": \"${DISCORD_USER_ID}\"}" \
  | jq -r '.id // empty' 2>/dev/null)

if [ -n "$DM_CHANNEL" ]; then
  PAYLOAD=$(jq -n --arg content "$MESSAGE" '{"content": $content}')
  curl -sf -X POST "${DISCORD_API}/channels/${DM_CHANNEL}/messages" \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" > /dev/null 2>&1 || true
fi

exit 0
