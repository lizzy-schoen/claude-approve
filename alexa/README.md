# Alexa voice approval for claude-approve

> **Status: Experimental.** This works but has quirks — read "Known issues" below before setting up.

Approve or deny Claude Code permission requests by voice through your Echo device. When Claude needs permission, your Echo chimes with a yellow ring. Say "check pending" to hear the request, then "approve" or "deny."

You can also switch between voice (Alexa), text (Discord), and off (terminal) modes — from the CLI or by voice.

## Prerequisites

- [claude-approve](../README.md) installed and working with Discord
- An AWS account (free tier is sufficient)
- An [Amazon developer account](https://developer.amazon.com/) (free)
- AWS CLI, SAM CLI, `jq`, and `curl` installed
- An Echo device on the same Amazon account

## Setup (~15 minutes)

### 1. Deploy AWS infrastructure

```bash
cd alexa && ./setup.sh
```

This uses AWS SAM to deploy:
- A DynamoDB table (`claude-approve`) for mode and request state
- An API Gateway with API key auth
- Two Lambda functions (API handler + Alexa skill handler)

SAM will walk you through deployment options. Defaults are fine for most settings.

### 2. Create the Alexa skill

The setup script prints step-by-step instructions. The short version:

1. Go to the [Alexa Developer Console](https://developer.amazon.com/alexa/console/ask) and create a new custom skill
2. Paste the interaction model from `skill/interactionModels/custom/en-US.json` into the JSON Editor
3. Set the endpoint to the Lambda ARN printed by the setup script
4. Under Permissions, enable "Alexa Notifications - Send"
5. Copy the Skill Messaging Client ID and Client Secret back into the setup script when prompted

### 3. Enable the skill on your device

1. Open the Alexa app on your phone
2. Go to Skills & Games > Your Skills > Dev
3. Enable the skill and grant notification permissions

### 4. Prime the notification token

Say **"Alexa, open [your invocation name]"** once. This saves a session token that enables yellow ring notifications. You'll need to do this again whenever the token expires (~1 hour).

## Usage

### Voice commands

The default invocation name is set in `skill/interactionModels/custom/en-US.json`. You can change it to whatever you want — just update the `invocationName` field and redeploy the interaction model.

| You say | What happens |
|---------|-------------|
| "Alexa, open [invocation name]" | Primes the token; reads pending request if one exists |
| "Alexa, ask [invocation name] to check pending" | Reads the pending request aloud |
| "Approve" / "Allow" / "Yes" / "Go ahead" | Approves the request |
| "Deny" / "Reject" / "No" / "Block" | Denies the request |
| "Enable voice mode" | Switches to Alexa approval |
| "Enable text mode" | Switches to Discord approval |
| "Disable" | Turns off remote approval (terminal prompts only) |
| "Status" | Reports current mode |

### One-shot commands

You can also combine the invocation and intent in one phrase:

```
"Alexa, tell [invocation name] to approve"
"Alexa, ask [invocation name] to check pending"
```

### Switching modes

Three approval modes: **voice** (Alexa), **text** (Discord), or **off** (terminal prompts).

From the CLI:
```bash
claude-approve mode voice    # Alexa approval + yellow ring notifications
claude-approve mode text     # Discord approval
claude-approve mode off      # terminal prompts only
claude-approve mode          # show current mode
```

From Alexa:
```
"Enable voice mode"
"Enable text mode"
"Disable"
```

The mode is stored in DynamoDB so both Alexa and the CLI can read/write it. Walking away from your desk? Tell Alexa to switch to voice mode. Heading out the door? Switch to text mode so approvals go to Discord on your phone.

## How it works

```
Claude needs permission
  → on-permission-request.sh checks mode in DynamoDB
  → If mode is "alexa":
      → alexa-request.sh POSTs to API Gateway
      → API handler stores request in DynamoDB
      → API handler sends yellow ring notification via Alexa Notifications API
      → alexa-request.sh polls GET /request for a decision
      → You say "approve" or "deny" to your Echo
      → Skill handler updates DynamoDB
      → alexa-request.sh sees the decision, returns it to Claude
```

### Architecture

| Component | Description |
|-----------|-------------|
| `template.yaml` | SAM template — DynamoDB, API Gateway, two Lambdas |
| `api-handler/index.mjs` | REST API: POST/GET `/request`, GET/PUT `/mode`. Sends Alexa notifications. |
| `skill-handler/index.mjs` | Alexa skill Lambda: voice intents, approve/deny, mode switching |
| `skill/skill.json` | Alexa skill manifest (name, permissions, events) |
| `skill/interactionModels/custom/en-US.json` | Voice interaction model (intents and sample utterances) |
| `../hooks/alexa-request.sh` | Local hook script that posts requests and polls for decisions |

### Notification flow

The system uses two notification mechanisms:

1. **Notifications API** (primary): Sends a device notification that triggers the yellow ring + chime. Requires a session-scoped `apiAccessToken` that's saved to DynamoDB each time you interact with the skill. This token expires after ~1 hour.

2. **Proactive Events API** (fallback): If the Notifications API token is expired, falls back to a proactive event that appears in the notification feed but does *not* trigger the yellow ring or chime.

When you approve or deny a request, the skill handler automatically dismisses the yellow ring notification.

## Known issues

- **Token expiry**: The Notifications API token (for yellow ring + chime) expires after roughly 1 hour. After that, notifications silently fall back to the notification feed only. To refresh, say "Alexa, open [invocation name]" — any interaction with the skill saves a fresh token. There's no way around this; it's an Alexa platform limitation.

- **Invocation name recognition**: Alexa can be picky about recognizing custom invocation names. If yours isn't working well, try a different name in `en-US.json`. Two-word names with common English words tend to work best. Avoid names that sound like existing skills or Alexa built-in commands.

- **No proactive speech**: Alexa cannot proactively start speaking to you — this is a platform restriction. The best we can do is the yellow ring notification + chime, which requires you to then ask what's pending.

- **Single pending request**: Only one request can be pending at a time. If Claude sends a new request before you've handled the previous one, the old one is overwritten.

- **Development mode**: Proactive events use the `/stages/development` endpoint. If you publish the skill, you'd need to switch to the production endpoint in `api-handler/index.mjs`.

## Why "Agent Orange"?

The default invocation name in this repo is "Agent Orange." It's a tongue-in-cheek nod to Claude being an AI *agent* with an orange logo — plus Alexa reliably recognizes the words. You're meant to pick your own invocation name (see below), but if you're wondering why the repo ships with that one, now you know. Name your skill whatever you want.

## Customization

### Changing the invocation name

Edit `invocationName` in `skill/interactionModels/custom/en-US.json`, then deploy the interaction model:

```bash
ask smapi set-interaction-model -s YOUR_SKILL_ID -l en-US \
  --interaction-model "$(cat skill/interactionModels/custom/en-US.json)"
```

Also update the `name` field in `skill/skill.json` and redeploy the manifest — this controls what Alexa says in "new notification from [name]":

```bash
curl -X PUT "https://api.amazonalexa.com/v1/skills/YOUR_SKILL_ID/stages/development/manifest" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d @skill/skill.json
```

### Changing spoken responses

Edit the `.speak()` strings in `skill-handler/index.mjs` and redeploy with SAM:

```bash
sam build && sam deploy --no-confirm-changeset --no-fail-on-empty-changeset
```

### Changing notification text

Edit the `toast`, `title`, and `spokenInfo` fields in `api-handler/index.mjs` and redeploy with SAM.

## Teardown

```bash
cd alexa && ./teardown.sh
```

This deletes the CloudFormation stack and optionally removes the Alexa settings from your config. You'll also need to delete the skill manually in the [Alexa Developer Console](https://developer.amazon.com/alexa/console/ask).

## Forking / self-hosting

If you clone this repo and want to set up your own Alexa skill:

1. Run `./setup.sh` — it creates fresh AWS resources under your account
2. Create a new skill in the Alexa Developer Console (you'll get your own skill ID)
3. Update the `SkillId` in `template.yaml` with your skill ID, then redeploy with SAM
4. Choose whatever invocation name you want
