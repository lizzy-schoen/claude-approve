#!/usr/bin/env bash
set -euo pipefail

# Claude Code Notification Hook
# Sends a one-way SMS when Claude is idle / waiting for input.

CONFIG_FILE="${CLAUDE_SMS_CONFIG:-$HOME/.config/claude-sms/config}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config not found at $CONFIG_FILE. Run install.sh first." >&2
  exit 0  # Don't block Claude for a notification failure
fi

source "$CONFIG_FILE"

# Read hook input from stdin
INPUT=$(cat)

NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MESSAGE_TEXT=$(echo "$INPUT" | jq -r '.message // "Claude Code needs your attention."')

# Only send for relevant notification types
case "$NOTIFICATION_TYPE" in
  idle_prompt)
    SMS_BODY="Claude Code is waiting for your input."
    ;;
  *)
    # Skip other notification types (permission_prompt is handled by the PermissionRequest hook)
    exit 0
    ;;
esac

# Send the SMS (fire and forget)
curl -sf -X POST \
  "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json" \
  -u "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" \
  --data-urlencode "To=${YOUR_PHONE_NUMBER}" \
  --data-urlencode "From=${TWILIO_PHONE_NUMBER}" \
  --data-urlencode "Body=${SMS_BODY}" > /dev/null 2>&1 || true

exit 0
