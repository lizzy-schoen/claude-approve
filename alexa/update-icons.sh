#!/usr/bin/env bash
set -euo pipefail

# Update skill manifest with icons and privacy policy to enable yellow ring notifications
SKILL_ID="amzn1.ask.skill.a46e189f-0cef-43e9-83d9-0078eff85f87"

SMALL_ICON='https://aws-sam-cli-managed-default-samclisourcebucket-onigabfxkguk.s3.us-west-2.amazonaws.com/skill-icons/icon-108.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAVIFSO7T67P3MKKKB%2F20260220%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Date=20260220T044021Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=a797d165aef4e871a53f056a70199328d062f614028d2d2b937b564a9596ad48'
LARGE_ICON='https://aws-sam-cli-managed-default-samclisourcebucket-onigabfxkguk.s3.us-west-2.amazonaws.com/skill-icons/icon-512.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAVIFSO7T67P3MKKKB%2F20260220%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Date=20260220T044021Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=f3d82d756f1255936b9dc0a0825bdf46f8019bb7fdb8d61cf925532cd9ef882f'

echo "Step 1: Getting current manifest..."
ask smapi get-skill-manifest -s "$SKILL_ID" -g development > /tmp/full-manifest.json 2>&1

echo "Step 2: Adding icons and privacy policy..."
jq --arg small "$SMALL_ICON" --arg large "$LARGE_ICON" '
  .manifest.publishingInformation.locales["en-US"].smallIconUri = $small |
  .manifest.publishingInformation.locales["en-US"].largeIconUri = $large |
  .manifest.publishingInformation.locales["en-US"].examplePhrases = [
    "Alexa ask code approve to check pending",
    "approve",
    "deny"
  ] |
  .manifest.privacyAndCompliance = {
    "allowsPurchases": false,
    "usesPersonalInfo": false,
    "isChildDirected": false,
    "isExportCompliant": true,
    "containsAds": false,
    "locales": {
      "en-US": {
        "privacyPolicyUrl": "https://github.com/lizzyschoen/claude-approve"
      }
    }
  }
' /tmp/full-manifest.json > /tmp/updated-manifest.json

echo "Step 3: Updating manifest..."
MANIFEST=$(jq '.manifest' /tmp/updated-manifest.json)
ask smapi update-skill-manifest -s "$SKILL_ID" -g development --manifest "$MANIFEST" 2>&1

echo ""
echo "Done! Manifest updated with skill icons."
echo "The yellow ring should now work with proactive events."

# Also fix the OAuth credentials while we're at it
echo ""
echo "Step 4: Restoring proactive events OAuth credentials..."
LAMBDA_NAME=$(aws cloudformation describe-stack-resource --stack-name claude-approve-alexa --logical-resource-id ApiFunction --query 'StackResourceDetail.PhysicalResourceId' --output text --region us-west-2 2>/dev/null)
if [ -n "$LAMBDA_NAME" ]; then
  source "$HOME/.config/claude-approve/config"
  if [ -n "${ALEXA_CLIENT_ID:-}" ] && [ -n "${ALEXA_CLIENT_SECRET:-}" ]; then
    aws lambda update-function-configuration \
      --function-name "$LAMBDA_NAME" \
      --environment "Variables={TABLE_NAME=claude-approve,ALEXA_CLIENT_ID=${ALEXA_CLIENT_ID},ALEXA_CLIENT_SECRET=${ALEXA_CLIENT_SECRET}}" \
      --region us-west-2 --output text --query 'FunctionName' 2>&1
    echo "OAuth credentials restored on Lambda."
  else
    echo "No ALEXA_CLIENT_ID/SECRET in config — skipping credential restore."
  fi
fi
