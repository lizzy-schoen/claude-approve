#!/usr/bin/env bash
set -euo pipefail

# Claude Code PermissionRequest Hook
# Routes permission requests to Discord or Alexa based on configured mode.

# Check if claude-approve is enabled (disabled = fall through to terminal prompts)
STATE_FILE="$HOME/.config/claude-approve/enabled"
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "false" ]; then
  exit 0
fi

CONFIG_FILE="${CLAUDE_APPROVE_CONFIG:-$HOME/.config/claude-approve/config}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found at $CONFIG_FILE. Run install.sh first." >&2
  exit 2
fi

source "$CONFIG_FILE"

# Read hook input from stdin (must happen before any dispatch)
INPUT=$(cat)

# Resolve approval channel — check DynamoDB if Alexa is configured, else use local config
APPROVAL_CHANNEL="${APPROVAL_CHANNEL:-discord}"
if [ -n "${ALEXA_API_URL:-}" ] && [ -n "${ALEXA_API_KEY:-}" ]; then
  MODE_RESPONSE=$(curl -sf "${ALEXA_API_URL}/mode" -H "x-api-key: ${ALEXA_API_KEY}" 2>/dev/null || echo "")
  if [ -n "$MODE_RESPONSE" ]; then
    REMOTE_MODE=$(echo "$MODE_RESPONSE" | jq -r '.mode // empty' 2>/dev/null || echo "")
    [ -n "$REMOTE_MODE" ] && APPROVAL_CHANNEL="$REMOTE_MODE"
  fi
fi

if [ "$APPROVAL_CHANNEL" = "off" ]; then
  exit 0  # fall through to terminal prompts
fi

if [ "$APPROVAL_CHANNEL" = "alexa" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  # Show in terminal, then hand off to alexa-request.sh
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
  TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {}')
  format_terminal_message() {
    local tool="$1"
    local input="$2"
    local detail=""
    case "$tool" in
      Bash) detail=$(echo "$input" | jq -r '.command // "" | tostring') ;;
      Edit|Write|Read) detail=$(echo "$input" | jq -r '.file_path // "unknown file"') ;;
      Task) detail=$(echo "$input" | jq -r '.description // .prompt // "" | tostring' | head -c 120) ;;
      *) detail=$(echo "$input" | jq -r 'tostring' | head -c 120) ;;
    esac
    echo "[claude-approve] Claude wants to use: ${tool}"
    [ -n "$detail" ] && echo "  ${detail}"
    echo "  Waiting for Alexa approval..."
  }
  format_terminal_message "$TOOL_NAME" "$TOOL_INPUT" >&2
  echo "$INPUT" | "$SCRIPT_DIR/alexa-request.sh"
  exit $?
fi

# --- Discord channel (default) ---

# Signal to the Discord bot that a permission request is active
LOCK_FILE="/tmp/claude-approve.lock"
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP

DISCORD_API="https://discord.com/api/v10"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {}')

# Format a human-readable message based on the tool
format_message() {
  local tool="$1"
  local input="$2"
  local detail=""

  case "$tool" in
    Bash)
      detail=$(echo "$input" | jq -r '.command // "" | tostring')
      # Wrap in code block for Discord
      if [ -n "$detail" ]; then
        detail="\`\`\`
${detail}
\`\`\`"
      fi
      ;;
    Edit)
      local file=$(echo "$input" | jq -r '.file_path // "unknown file"')
      local old=$(echo "$input" | jq -r '.old_string // "" | tostring' | head -c 200)
      detail="\`${file}\`
\`\`\`
${old}
\`\`\`"
      ;;
    Write)
      detail="\`$(echo "$input" | jq -r '.file_path // "unknown file"')\`"
      ;;
    Read)
      detail="\`$(echo "$input" | jq -r '.file_path // "unknown file"')\`"
      ;;
    Task)
      detail=$(echo "$input" | jq -r '.description // .prompt // "" | tostring' | head -c 200)
      ;;
    *)
      detail=$(echo "$input" | jq -r 'tostring' | head -c 200)
      ;;
  esac

  # Truncate detail for Discord message limit
  if [ ${#detail} -gt 1500 ]; then
    detail="${detail:0:1497}..."
  fi

  local msg="**Claude wants to use: ${tool}**"
  if [ -n "$detail" ]; then
    msg="${msg}
${detail}"
  fi
  msg="${msg}

Reply **Y** to allow, **N** to deny."

  echo "$msg"
}

MESSAGE=$(format_message "$TOOL_NAME" "$TOOL_INPUT")

# Also show in terminal (plain text, no Discord markdown)
format_terminal_message() {
  local tool="$1"
  local input="$2"
  local detail=""

  case "$tool" in
    Bash)
      detail=$(echo "$input" | jq -r '.command // "" | tostring')
      ;;
    Edit|Write|Read)
      detail=$(echo "$input" | jq -r '.file_path // "unknown file"')
      ;;
    Task)
      detail=$(echo "$input" | jq -r '.description // .prompt // "" | tostring' | head -c 120)
      ;;
    *)
      detail=$(echo "$input" | jq -r 'tostring' | head -c 120)
      ;;
  esac

  echo "[claude-approve] Claude wants to use: ${tool}"
  if [ -n "$detail" ]; then
    echo "  ${detail}"
  fi
  echo "  Waiting for Discord reply..."
}

format_terminal_message "$TOOL_NAME" "$TOOL_INPUT" >&2

# Open a DM channel with the user (idempotent — always returns the same channel)
DM_CHANNEL=$(curl -sf -X POST "${DISCORD_API}/users/@me/channels" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"recipient_id\": \"${DISCORD_USER_ID}\"}" \
  | jq -r '.id // empty')

if [ -z "$DM_CHANNEL" ]; then
  echo "Failed to open Discord DM channel. Check bot token and user ID." >&2
  exit 2
fi

# Get the latest message ID so we can detect new replies
LAST_MSG_ID=$(curl -sf "${DISCORD_API}/channels/${DM_CHANNEL}/messages?limit=1" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  | jq -r '.[0].id // "0"' 2>/dev/null || echo "0")

# Send the DM
PAYLOAD=$(jq -n --arg content "$MESSAGE" '{"content": $content}')
SEND_RESPONSE=$(curl -sf -X POST "${DISCORD_API}/channels/${DM_CHANNEL}/messages" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

if [ $? -ne 0 ]; then
  echo "Failed to send Discord DM." >&2
  exit 2
fi

BOT_MSG_ID=$(echo "$SEND_RESPONSE" | jq -r '.id // "0"')

# Poll for a reply
TIMEOUT="${REPLY_TIMEOUT:-120}"
POLL_INTERVAL="${REPLY_POLL_INTERVAL:-3}"
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Get messages after our bot message
  MESSAGES=$(curl -sf "${DISCORD_API}/channels/${DM_CHANNEL}/messages?after=${BOT_MSG_ID}&limit=5" \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" 2>/dev/null || echo '[]')

  # Find the first message from the user (not the bot)
  REPLY=$(echo "$MESSAGES" | jq -r --arg uid "$DISCORD_USER_ID" '
    [.[] | select(.author.id == $uid)] | first | .content // empty
  ' 2>/dev/null || echo "")

  if [ -n "$REPLY" ]; then
    REPLY_CLEAN=$(echo "$REPLY" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    case "$REPLY_CLEAN" in
      1|y|yes|allow|ok)
        # React with checkmark to confirm
        curl -sf -X PUT "${DISCORD_API}/channels/${DM_CHANNEL}/messages/${BOT_MSG_ID}/reactions/%E2%9C%85/@me" \
          -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" > /dev/null 2>&1 || true
        echo "[claude-approve] Allowed via Discord" >&2
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        exit 0
        ;;
      *)
        # React with X to confirm denial
        curl -sf -X PUT "${DISCORD_API}/channels/${DM_CHANNEL}/messages/${BOT_MSG_ID}/reactions/%E2%9D%8C/@me" \
          -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" > /dev/null 2>&1 || true
        echo "[claude-approve] Denied via Discord" >&2
        exit 2
        ;;
    esac
  fi
done

# Timed out — deny by default, react with clock
curl -sf -X PUT "${DISCORD_API}/channels/${DM_CHANNEL}/messages/${BOT_MSG_ID}/reactions/%E2%8F%B0/@me" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" > /dev/null 2>&1 || true
echo "[claude-approve] No Discord reply received within ${TIMEOUT}s. Denying." >&2
exit 2
