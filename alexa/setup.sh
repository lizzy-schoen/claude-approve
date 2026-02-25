#!/usr/bin/env bash
set -euo pipefail

# claude-approve Alexa setup
# Deploys AWS infrastructure (DynamoDB, API Gateway, Lambda) and guides
# you through creating the Alexa skill in the Developer Console.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.config/claude-approve"
CONFIG_FILE="$CONFIG_DIR/config"

echo "=== claude-approve Alexa setup ==="
echo ""

# Check prerequisites
for cmd in aws sam jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed." >&2
    case "$cmd" in
      aws) echo "  Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2 ;;
      sam) echo "  Install: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html" >&2 ;;
      jq)  echo "  brew install jq  (macOS)  /  apt install jq  (Linux)" >&2 ;;
      curl) echo "  brew install curl  (macOS)  /  apt install curl  (Linux)" >&2 ;;
    esac
    exit 1
  fi
done

# Check AWS credentials
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
  echo "Error: AWS credentials not configured. Run 'aws configure' first." >&2
  exit 1
fi
echo "AWS credentials verified."
echo ""

# Install skill handler dependencies
echo "Installing Alexa skill handler dependencies..."
(cd "$SCRIPT_DIR/skill-handler" && npm install --production 2>&1) || {
  echo "Error: npm install failed in skill-handler/." >&2
  exit 1
}
echo ""

# Build and deploy with SAM
echo "Building and deploying AWS resources..."
echo "SAM will walk you through the deployment options."
echo ""

cd "$SCRIPT_DIR"
sam build
sam deploy --guided --stack-name claude-approve-alexa

echo ""
echo "Retrieving deployment outputs..."

# Get CloudFormation outputs
STACK_OUTPUT=$(aws cloudformation describe-stacks \
  --stack-name claude-approve-alexa \
  --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo "[]")

API_URL=$(echo "$STACK_OUTPUT" | jq -r '.[] | select(.OutputKey=="ApiUrl") | .OutputValue' || echo "")
SKILL_LAMBDA_ARN=$(echo "$STACK_OUTPUT" | jq -r '.[] | select(.OutputKey=="SkillFunctionArn") | .OutputValue' || echo "")

if [ -z "$API_URL" ] || [ -z "$SKILL_LAMBDA_ARN" ]; then
  echo "Error: Could not retrieve stack outputs. Check CloudFormation console." >&2
  exit 1
fi

# Get the API key value
echo "Retrieving API key..."
API_KEY_ID=$(aws apigateway get-api-keys \
  --query 'items[?contains(name, `claude-approve`)].id | [0]' \
  --output text 2>/dev/null || echo "")

if [ -z "$API_KEY_ID" ] || [ "$API_KEY_ID" = "None" ]; then
  echo "Warning: Could not find API key automatically." >&2
  echo "You can find it in the AWS API Gateway console under API Keys." >&2
  read -rp "API Key value (paste manually): " API_KEY_VALUE
else
  API_KEY_VALUE=$(aws apigateway get-api-key \
    --api-key "$API_KEY_ID" \
    --include-value \
    --query 'value' --output text 2>/dev/null || echo "")

  if [ -z "$API_KEY_VALUE" ] || [ "$API_KEY_VALUE" = "None" ]; then
    echo "Warning: Could not retrieve API key value." >&2
    read -rp "API Key value (paste from AWS console): " API_KEY_VALUE
  fi
fi

echo ""
echo "=== AWS resources deployed ==="
echo "  API URL:          $API_URL"
echo "  Skill Lambda ARN: $SKILL_LAMBDA_ARN"
echo ""

# Initialize mode in DynamoDB
echo "Initializing mode to 'discord'..."
curl -sf -X PUT "${API_URL}/mode" \
  -H "x-api-key: ${API_KEY_VALUE}" \
  -H "Content-Type: application/json" \
  -d '{"mode": "discord"}' > /dev/null 2>&1 && echo "Done." || echo "Warning: Could not set initial mode."
echo ""

# Alexa skill setup instructions
echo "=== Now set up the Alexa skill (~5 min) ==="
echo ""
echo "  1. Go to https://developer.amazon.com/alexa/console/ask"
echo "  2. Click 'Create Skill'"
echo "  3. Name: 'Claude Approve', Language: English (US)"
echo "  4. Choose 'Custom' model, 'Provision your own' hosting"
echo "  5. Choose 'Start from Scratch' template"
echo ""
echo "  --- Interaction Model ---"
echo "  6. In the skill editor, go to 'JSON Editor' under Interaction Model"
echo "  7. Paste the contents of:"
echo "     $SCRIPT_DIR/skill/interactionModels/custom/en-US.json"
echo "  8. Click 'Save' then 'Build Model'"
echo ""
echo "  --- Endpoint ---"
echo "  9. Go to 'Endpoint' in the sidebar"
echo " 10. Choose 'AWS Lambda ARN'"
echo " 11. Paste this ARN in the Default Region field:"
echo "     $SKILL_LAMBDA_ARN"
echo " 12. Click 'Save'"
echo ""
echo "  --- Proactive Events (for yellow ring notifications) ---"
echo " 13. Go to 'Permissions' in the sidebar"
echo " 14. Enable 'Alexa Notifications - Send'"
echo " 15. Scroll down to 'Alexa Skill Messaging' and copy the Client ID and Client Secret"
echo ""
echo "  --- Alexa App ---"
echo " 16. On your phone, open the Alexa app"
echo " 17. Go to Skills & Games > Your Skills > Dev"
echo " 18. Find 'Claude Approve', enable it"
echo " 19. Grant notification permissions when prompted"
echo ""

read -rp "Alexa Skill ID (shown at top of skill page): " SKILL_ID

if [ -n "$SKILL_ID" ]; then
  echo ""
  echo "Adding Alexa trigger permission to Lambda..."
  FUNCTION_NAME=$(echo "$SKILL_LAMBDA_ARN" | awk -F: '{print $NF}')
  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "alexa-skill-$(date +%s)" \
    --action lambda:InvokeFunction \
    --principal alexa-appkit.amazon.com \
    --event-source-token "$SKILL_ID" 2>/dev/null && echo "Done." || echo "Warning: Could not add permission (may already exist)."
fi

echo ""
read -rp "Alexa Client ID (from Permissions > Skill Messaging): " ALEXA_CLIENT_ID
read -rp "Alexa Client Secret: " ALEXA_CLIENT_SECRET

if [ -n "$ALEXA_CLIENT_ID" ] && [ -n "$ALEXA_CLIENT_SECRET" ]; then
  echo ""
  echo "Updating Lambda with proactive event credentials..."
  FUNCTION_NAME=$(echo "$(echo "$STACK_OUTPUT" | jq -r '.[] | select(.OutputKey=="SkillFunctionArn") | .OutputValue')" | awk -F: '{print $NF}')

  # Update the API handler Lambda (it's the one that sends proactive events)
  API_FUNCTION_NAME="claude-approve-alexa-ApiFunction"
  # Get the actual function name from CloudFormation
  API_FUNC=$(aws cloudformation describe-stack-resources \
    --stack-name claude-approve-alexa \
    --logical-resource-id ApiFunction \
    --query 'StackResources[0].PhysicalResourceId' --output text 2>/dev/null || echo "")

  if [ -n "$API_FUNC" ]; then
    aws lambda update-function-configuration \
      --function-name "$API_FUNC" \
      --environment "Variables={TABLE_NAME=claude-approve,ALEXA_CLIENT_ID=${ALEXA_CLIENT_ID},ALEXA_CLIENT_SECRET=${ALEXA_CLIENT_SECRET}}" \
      > /dev/null 2>&1 && echo "Done." || echo "Warning: Could not update Lambda config."
  else
    echo "Warning: Could not find API Lambda. Set ALEXA_CLIENT_ID and ALEXA_CLIENT_SECRET manually in Lambda console." >&2
  fi
fi

# Update config file
echo ""
echo "Updating config..."
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
  # Remove old Alexa entries
  grep -v '^ALEXA_API_URL=' "$CONFIG_FILE" \
    | grep -v '^ALEXA_API_KEY=' \
    | grep -v '^APPROVAL_CHANNEL=' \
    > "${CONFIG_FILE}.tmp" 2>/dev/null || true
  mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

cat >> "$CONFIG_FILE" <<EOF

# Alexa approval settings (added by alexa/setup.sh)
APPROVAL_CHANNEL="discord"
ALEXA_API_URL="${API_URL}"
ALEXA_API_KEY="${API_KEY_VALUE}"
EOF

chmod 600 "$CONFIG_FILE"

# Make scripts executable
chmod +x "$PROJECT_DIR/hooks/alexa-request.sh"

echo ""
echo "=== Alexa setup complete! ==="
echo ""
echo "Config updated: $CONFIG_FILE"
echo "  ALEXA_API_URL=${API_URL}"
echo "  APPROVAL_CHANNEL=discord (default — switch with voice or CLI)"
echo ""
echo "Switch modes:"
echo "  claude-approve mode voice    # Alexa approval + yellow ring notifications"
echo "  claude-approve mode text     # Discord approval (default)"
echo "  claude-approve mode off      # Terminal prompts only"
echo ""
echo "Or from Alexa:"
echo '  "Alexa, tell Claude Approve to enable voice mode"'
echo '  "Alexa, tell Claude Approve to enable text mode"'
echo ""
echo "Test it:"
echo "  claude-approve mode voice"
echo '  echo '"'"'{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'"'"' | '"$PROJECT_DIR"'/hooks/on-permission-request.sh'
echo '  Then say: "Alexa, ask Claude Approve to check pending"'
echo ""
echo "To tear down AWS resources: $SCRIPT_DIR/teardown.sh"
