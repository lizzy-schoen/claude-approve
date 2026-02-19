# claude-sms-approve

Get texted when Claude Code needs your permission — reply to approve or deny from your phone.

Uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) + [Twilio](https://www.twilio.com/) to turn permission prompts into SMS conversations.

## How it works

```
Claude wants to run: npm test
  → You get a text: "Claude wants to use: Bash — npm test — Reply Y to allow, N to deny."
  → You reply "Y"
  → Claude continues
```

When Claude finishes a task and is waiting for your next prompt, you get a heads-up text too.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- A [Twilio account](https://www.twilio.com/try-twilio) with a phone number (~$1/month + fractions of a cent per SMS)
- `jq` and `curl` installed (`brew install jq` on macOS)

## Setup

```bash
git clone https://github.com/YOUR_USERNAME/claude-sms-approve.git
cd claude-sms-approve
./install.sh
```

The installer will ask for your Twilio credentials and phone numbers, then configure the Claude Code hooks automatically.

### Twilio setup (2 minutes)

1. Sign up at [twilio.com/try-twilio](https://www.twilio.com/try-twilio)
2. Get a phone number from the console (or use the one they give you on the trial)
3. Find your **Account SID** and **Auth Token** on the [console dashboard](https://console.twilio.com/)
4. That's it — the install script handles the rest

> **Trial accounts**: Twilio trial accounts work fine, but you'll need to [verify your phone number](https://console.twilio.com/us1/develop/phone-numbers/manage/verified) first.

## Usage

Just use Claude Code normally. Whenever it needs permission to run a tool, you'll get a text instead of (or in addition to) the terminal prompt.

**Reply options:**
- `Y`, `1`, `yes`, `ok`, `allow` — approve
- Anything else (or no reply) — deny

**Timeout**: If you don't reply within 2 minutes (configurable), the request is denied automatically.

## Configuration

Config lives at `~/.config/claude-sms/config`. You can edit it directly:

```bash
# Twilio credentials
TWILIO_ACCOUNT_SID="ACxxxxxxxx"
TWILIO_AUTH_TOKEN="xxxxxxxx"
TWILIO_PHONE_NUMBER="+15551234567"
YOUR_PHONE_NUMBER="+15559876543"

# Timing
SMS_TIMEOUT=120        # seconds to wait for reply
SMS_POLL_INTERVAL=3    # seconds between checks for reply
```

## What triggers a text?

| Event | What happens |
|-------|-------------|
| Claude needs permission to use a tool | Two-way SMS — reply to approve/deny |
| Claude is idle, waiting for input | One-way text — just a heads up |

## Uninstall

```bash
./uninstall.sh
```

Removes the hooks from Claude Code settings. Optionally deletes your Twilio config.

## How it works (technical)

This uses two Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks):

1. **`PermissionRequest` hook** (`hooks/on-permission-request.sh`): Fires when Claude needs tool permission. Sends you an SMS via Twilio's REST API, then polls for your inbound reply. Returns a JSON decision (allow/deny) that Claude Code respects.

2. **`Notification` hook** (`hooks/on-notify.sh`): Fires when Claude is idle. Sends a one-way SMS as a heads-up. Runs async so it doesn't block anything.

The permission hook is blocking by design — Claude Code is already waiting for a decision, so the script just holds that spot while it waits for your text. Default timeout is 600s on the Claude Code side, and the SMS timeout (default 120s) kicks in well before that.

## License

MIT
