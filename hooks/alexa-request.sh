#!/usr/bin/env bash
set -euo pipefail

# Claude Code PermissionRequest Hook — Alexa channel
# Called by on-permission-request.sh when mode is "alexa".
# Posts the request to API Gateway, then polls for a decision.
# Reads hook input JSON from stdin.

CONFIG_FILE="${CLAUDE_APPROVE_CONFIG:-$HOME/.config/claude-approve/config}"
source "$CONFIG_FILE"

if [ -z "${ALEXA_API_URL:-}" ] || [ -z "${ALEXA_API_KEY:-}" ]; then
  echo "[claude-approve] ALEXA_API_URL and ALEXA_API_KEY must be set in config." >&2
  exit 2
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')

# Extract a plain-text detail for the request
case "$TOOL_NAME" in
  Bash)
    TOOL_DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // "" | tostring' | head -c 500)
    ;;
  Edit|Write|Read)
    TOOL_DETAIL=$(echo "$INPUT" | jq -r '.tool_input.file_path // "unknown file"')
    ;;
  Task)
    TOOL_DETAIL=$(echo "$INPUT" | jq -r '.tool_input.description // .tool_input.prompt // "" | tostring' | head -c 500)
    ;;
  *)
    TOOL_DETAIL=$(echo "$INPUT" | jq -r '.tool_input // {} | tostring' | head -c 500)
    ;;
esac

# Submit the request
RESPONSE=$(curl -sf -X POST "${ALEXA_API_URL}/request" \
  -H "x-api-key: ${ALEXA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg tool "$TOOL_NAME" --arg detail "$TOOL_DETAIL" \
    '{"toolName": $tool, "toolDetail": $detail}')" 2>/dev/null || echo "")

REQUEST_ID=$(echo "$RESPONSE" | jq -r '.requestId // empty' 2>/dev/null || echo "")

if [ -z "$REQUEST_ID" ]; then
  echo "[claude-approve] Failed to submit request to Alexa API." >&2
  exit 2
fi

echo "[claude-approve] Request submitted (${REQUEST_ID})" >&2
echo "[claude-approve] Waiting for Alexa approval..." >&2

# Poll for a decision
TIMEOUT="${REPLY_TIMEOUT:-120}"
POLL_INTERVAL="${REPLY_POLL_INTERVAL:-3}"
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  STATUS_RESPONSE=$(curl -sf "${ALEXA_API_URL}/request?requestId=${REQUEST_ID}" \
    -H "x-api-key: ${ALEXA_API_KEY}" 2>/dev/null || echo '{"status":"error"}')

  STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status // "error"' 2>/dev/null || echo "error")

  case "$STATUS" in
    approved)
      echo "[claude-approve] Allowed via Alexa" >&2
      echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
      exit 0
      ;;
    denied)
      echo "[claude-approve] Denied via Alexa" >&2
      exit 2
      ;;
    pending)
      ;;
    *)
      echo "[claude-approve] Unexpected status: $STATUS" >&2
      exit 2
      ;;
  esac
done

echo "[claude-approve] No Alexa reply within ${TIMEOUT}s. Denying." >&2
exit 2
