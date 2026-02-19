#!/usr/bin/env bash
set -euo pipefail

# Claude Code Notification Hook
# Sends a Discord DM when Claude is idle / waiting for input.
# Includes Claude's last message so you can see what was said.

# Check if claude-approve is enabled (disabled = no Discord notifications)
STATE_FILE="$HOME/.config/claude-approve/enabled"
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "false" ]; then
  exit 0
fi

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
    ;;
  *)
    # Skip other notification types (permission_prompt is handled by the PermissionRequest hook)
    exit 0
    ;;
esac

# Try to extract Claude's last message from the most recent session file
LAST_MSG=""
LATEST_SESSION=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)

if [ -n "$LATEST_SESSION" ] && [ -f "$LATEST_SESSION" ]; then
  # Find the last assistant message that has text content, extract and join its text blocks
  LAST_MSG=$(tail -100 "$LATEST_SESSION" 2>/dev/null | \
    jq -c 'select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0)' 2>/dev/null | \
    tail -1 | \
    jq -r 'join("\n")' 2>/dev/null)

  # Truncate for Discord (leave room for the header)
  if [ ${#LAST_MSG} -gt 1500 ]; then
    LAST_MSG="${LAST_MSG:0:1497}..."
  fi
fi

# Build the Discord message
if [ -n "$LAST_MSG" ]; then
  MESSAGE="**Claude Code is waiting for your input.**

${LAST_MSG}

_Reply here to continue the conversation._"
else
  MESSAGE="**Claude Code is waiting for your input.**

_Reply here to continue the conversation._"
fi

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
