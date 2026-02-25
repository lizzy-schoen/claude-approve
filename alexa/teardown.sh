#!/usr/bin/env bash
set -euo pipefail

# claude-approve Alexa teardown
# Deletes the AWS CloudFormation stack and optionally cleans up config.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$HOME/.config/claude-approve/config"

echo "=== claude-approve Alexa teardown ==="
echo ""
echo "This will delete the CloudFormation stack 'claude-approve-alexa' and all"
echo "associated resources (DynamoDB table, API Gateway, Lambda functions)."
echo ""

read -rp "Are you sure? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "Deleting CloudFormation stack..."
cd "$SCRIPT_DIR"
sam delete --stack-name claude-approve-alexa --no-prompts 2>/dev/null || \
  aws cloudformation delete-stack --stack-name claude-approve-alexa 2>/dev/null || \
  echo "Warning: Could not delete stack. You may need to delete it manually in the AWS console."

echo "Stack deletion initiated (may take a minute to complete)."

# Clean up config
echo ""
read -rp "Remove Alexa settings from config? [Y/n] " clean_config
if [[ ! "$clean_config" =~ ^[Nn] ]]; then
  if [ -f "$CONFIG_FILE" ]; then
    grep -v '^ALEXA_API_URL=' "$CONFIG_FILE" \
      | grep -v '^ALEXA_API_KEY=' \
      | grep -v '^APPROVAL_CHANNEL=' \
      | grep -v '^# Alexa approval settings' \
      > "${CONFIG_FILE}.tmp" 2>/dev/null || true
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "Alexa settings removed from $CONFIG_FILE"
  fi
fi

echo ""
echo "Done. Don't forget to delete the Alexa skill in the Developer Console:"
echo "  https://developer.amazon.com/alexa/console/ask"
