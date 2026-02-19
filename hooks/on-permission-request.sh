#!/usr/bin/env bash
set -euo pipefail

# Claude Code PermissionRequest Hook
# Sends an SMS when Claude needs permission, waits for your reply.

CONFIG_FILE="${CLAUDE_SMS_CONFIG:-$HOME/.config/claude-sms/config}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found at $CONFIG_FILE. Run install.sh first." >&2
  exit 2
fi

source "$CONFIG_FILE"

# Read hook input from stdin
INPUT=$(cat)

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
      ;;
    Edit)
      local file=$(echo "$input" | jq -r '.file_path // "unknown file"')
      local old=$(echo "$input" | jq -r '.old_string // "" | tostring' | head -c 80)
      detail="${file}: ${old}..."
      ;;
    Write)
      detail=$(echo "$input" | jq -r '.file_path // "unknown file"')
      ;;
    Read)
      detail=$(echo "$input" | jq -r '.file_path // "unknown file"')
      ;;
    Task)
      detail=$(echo "$input" | jq -r '.description // .prompt // "" | tostring' | head -c 120)
      ;;
    *)
      detail=$(echo "$input" | jq -r 'tostring' | head -c 120)
      ;;
  esac

  # Truncate detail to keep SMS reasonable
  if [ ${#detail} -gt 300 ]; then
    detail="${detail:0:297}..."
  fi

  echo "Claude wants to use: ${tool}"
  if [ -n "$detail" ]; then
    echo ""
    echo "${detail}"
  fi
  echo ""
  echo "Reply Y to allow, N to deny."
}

MESSAGE=$(format_message "$TOOL_NAME" "$TOOL_INPUT")

# Get the most recent inbound message SID so we can detect new replies
LAST_MSG_SID=$(curl -sf \
  "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json?To=${TWILIO_PHONE_NUMBER}&From=${YOUR_PHONE_NUMBER}&PageSize=1" \
  -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
  | jq -r '.messages[0].sid // "none"' 2>/dev/null || echo "none")

# Send the SMS
SEND_RESPONSE=$(curl -sf -X POST \
  "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json" \
  -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
  --data-urlencode "To=${YOUR_PHONE_NUMBER}" \
  --data-urlencode "From=${TWILIO_PHONE_NUMBER}" \
  --data-urlencode "Body=${MESSAGE}" 2>/dev/null)

if [ $? -ne 0 ]; then
  echo "Failed to send SMS. Check Twilio config." >&2
  exit 2
fi

# Poll for a reply
TIMEOUT="${SMS_TIMEOUT:-120}"
POLL_INTERVAL="${SMS_POLL_INTERVAL:-3}"
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  RESPONSE=$(curl -sf \
    "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json?To=${TWILIO_PHONE_NUMBER}&From=${YOUR_PHONE_NUMBER}&PageSize=1" \
    -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" 2>/dev/null || echo '{"messages":[]}')

  NEW_SID=$(echo "$RESPONSE" | jq -r '.messages[0].sid // "none"')

  if [ "$NEW_SID" != "$LAST_MSG_SID" ] && [ "$NEW_SID" != "none" ]; then
    REPLY=$(echo "$RESPONSE" | jq -r '.messages[0].body // ""' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    case "$REPLY" in
      1|y|yes|allow|ok)
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        exit 0
        ;;
      *)
        echo "Denied via SMS (reply: ${REPLY})" >&2
        exit 2
        ;;
    esac
  fi
done

# Timed out — deny by default
echo "No SMS reply received within ${TIMEOUT}s. Denying." >&2
exit 2
