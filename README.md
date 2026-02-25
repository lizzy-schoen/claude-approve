# claude-approve

Approve Claude Code permissions from Discord or Alexa — on your phone or by voice.

Uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to turn permission prompts into remote conversations. Approve via Discord DMs while on a walk, or say "Alexa, approve" while doing the dishes. Optionally send follow-up commands from Discord.

## How it works

```
Claude wants to run: npm test
  → Your bot DMs you: "Claude wants to use: Bash — npm test — Reply Y to allow, N to deny."
  → You reply "Y" in Discord
  → Bot reacts ✅ and Claude continues
```

When Claude finishes a task and is waiting for your next prompt, you get a DM with what Claude said — so you can see the results and reply from your phone.

## What's included

**Hooks** (work out of the box after install — no Node.js required):
- Permission request DMs — approve or deny Claude's tool use from Discord
- Idle notifications — see Claude's last message when it's waiting for you

**Remote command bot** (opt-in, requires Node.js):
- Send Claude commands from Discord and get responses back
- Continue conversations remotely — reply to questions, give follow-up instructions
- Start it when you want it, stop it when you don't

The hooks and the bot share the same Discord bot and config. You can use the hooks alone, or add the bot for full remote control.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- A Discord account
- `jq` and `curl` installed (`brew install jq` on macOS)
- Node.js (only needed for the remote command bot)

## Setup (~5 minutes)

### 1. Add the Discord bot to a server

[**Click here to add the bot to your server**](https://discord.com/oauth2/authorize?client_id=1473881241521487962&permissions=67584&integration_type=0&scope=bot)

Pick any server you're in — the bot just needs to share a server with you so it can DM you.

### 2. Get your Discord User ID

1. Open Discord Settings > Advanced > enable **Developer Mode**
2. Right-click your own name anywhere and click **Copy User ID**

### 3. Run the installer

```bash
git clone https://github.com/lizzy-schoen/claude-approve.git
cd claude-approve
./install.sh
```

It'll ask for your bot token, user ID, and timeout preferences, then wire everything up. If Node.js is installed, it also installs the bot dependencies automatically.

## Usage

### Permission approvals

Just use Claude Code normally. Whenever it needs permission to run a tool, your bot will DM you instead of (or in addition to) the terminal prompt.

**Reply options:**
- `Y`, `1`, `yes`, `ok`, `allow` — approve (bot reacts ✅)
- Anything else — deny (bot reacts ❌)
- No reply — auto-deny after timeout (bot reacts ⏰)

**Timeout**: Default is 120 seconds (configurable).

### Idle notifications

When Claude finishes a task and is waiting for input, you get a DM with Claude's last message — so you can see what it said without being at your computer.

### Remote commands (opt-in)

Start the bot to send Claude commands from Discord:

```bash
cd bot && npm start
```

Then DM the bot anything that isn't a Y/N permission response:

```
You: "what's changed on this branch?"
Bot: 🧠 (working...)
Bot: Here are the changes on the current branch: ...
Bot: ✅
```

This works for follow-up instructions, answering questions Claude asked, or starting new tasks — all from your phone.

**Running in the background:**

```bash
nohup node bot/index.js >> ~/.config/claude-approve/bot.log 2>&1 &
```

**Stopping the bot:**

```bash
kill $(pgrep -f "node.*bot/index.js")
```

### How the bot coordinates with hooks

The bot and the permission hook share the same Discord DM channel but stay out of each other's way:

| You send | What happens |
|----------|-------------|
| `Y`, `yes`, `ok`, `allow`, `1` | Ignored by bot — the permission hook picks it up |
| `N`, `no`, `deny` | Ignored by bot — the permission hook picks it up |
| Anything else | Bot runs it as a Claude command via `claude -c -p` |

If a permission request is pending when you send a command, the bot tells you to respond to that first.

### Good to know

When you reply via Discord, the bot starts a new `claude -c -p` session that continues the most recent conversation. Claude sees the full history and your reply, so context carries through naturally. However, if you had an interactive terminal session running, that session won't see the Discord messages — the conversations diverge at that point. Once you start replying from Discord, keep using Discord for that session. When you're back at the terminal, `claude -c` will pick up from wherever the conversation left off (including Discord turns).

## Alexa voice approval (optional)

Approve or deny Claude Code permissions by voice. Your Echo chimes with a yellow ring when a request arrives — say "Alexa, ask Claude Approve to check pending" to hear what Claude wants, then "approve" or "deny."

### Alexa setup

Requires an AWS account (free tier) and an Amazon developer account.

```bash
cd alexa && ./setup.sh
```

The script deploys a DynamoDB table, API Gateway, and two Lambda functions via AWS SAM, then walks you through creating the Alexa skill in the Developer Console (~10 min total).

### Switching modes

Three approval modes: **text** (Discord), **voice** (Alexa), or **off** (terminal prompts).

From Alexa:
```
"Alexa, tell Claude Approve to enable voice mode"
"Alexa, tell Claude Approve to enable text mode"
```

From the CLI:
```bash
claude-approve mode voice    # Alexa approval + yellow ring notifications
claude-approve mode text     # Discord approval
claude-approve mode off      # terminal prompts only
claude-approve mode          # show current mode
```

The mode is stored in DynamoDB so Alexa can change it remotely. Walking away from your desk to do chores? Tell Alexa to switch to voice mode. Heading out the door? Switch to text mode so approvals go to Discord on your phone.

### Alexa voice commands

| You say | What happens |
|---------|-------------|
| "Alexa, ask Claude Approve to check pending" | Reads the pending request aloud |
| "Approve" / "Allow" / "Yes" | Approves the request |
| "Deny" / "Reject" / "No" | Denies the request |
| "Enable voice mode" | Switches to Alexa approval |
| "Enable text mode" | Switches to Discord approval |
| "Status" | Reports current mode |

### Alexa teardown

```bash
cd alexa && ./teardown.sh
```

Deletes the CloudFormation stack. Remember to also delete the skill in the [Alexa Developer Console](https://developer.amazon.com/alexa/console/ask).

## Enable / Disable

Toggle approval on or off without changing your setup:

```bash
claude-approve disable   # use normal terminal prompts
claude-approve enable    # back to remote approval
claude-approve status    # check current state
```

When disabled, Claude Code falls through to its normal terminal permission prompts — no remote messages are sent. When you re-enable, approval picks back up in whatever mode you were using. Enabled by default after install.

## Configuration

Config lives at `~/.config/claude-approve/config`. Edit it directly:

```bash
DISCORD_BOT_TOKEN="your-bot-token"
DISCORD_USER_ID="your-discord-user-id"
REPLY_TIMEOUT=120        # seconds to wait for reply
REPLY_POLL_INTERVAL=3    # seconds between checks
PROJECT_DIR="/path/to/your/project"  # working directory for remote commands

# Alexa settings (added by alexa/setup.sh)
APPROVAL_CHANNEL="discord"          # "discord", "alexa", or "off"
ALEXA_API_URL="https://..."         # API Gateway URL
ALEXA_API_KEY="..."                 # API Gateway API key
```

`PROJECT_DIR` is only used by the remote command bot. The Alexa settings are added automatically by `alexa/setup.sh` — you don't need them for Discord-only use.

## Testing

Run this to send yourself a test DM:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | ./hooks/on-permission-request.sh
```

Reply Y or N in Discord to confirm it's working.

## Sharing with your team

Each person needs to:
1. [Add the bot to a server they're in](https://discord.com/oauth2/authorize?client_id=1473881241521487962&permissions=67584&integration_type=0&scope=bot) (or join a server that already has it)
2. Clone this repo and run `./install.sh` with their own Discord User ID

The same bot works for everyone — each person provides their own User ID and the bot DMs them individually.

## Uninstall

```bash
./uninstall.sh
```

Removes the hooks from Claude Code settings. Optionally deletes your config.

## How it works (technical)

**Hooks** (bash scripts, no dependencies beyond `jq` and `curl`):

1. **`PermissionRequest` hook** (`hooks/on-permission-request.sh`): Fires when Claude needs tool permission. Checks the current mode (via DynamoDB if Alexa is configured, else local config) and routes to either Discord or Alexa. Returns a JSON decision (allow/deny) that Claude Code respects.

2. **Discord path**: Opens a DM channel via Discord API, sends the request, polls for Y/N reply. Creates a lock file at `/tmp/claude-approve.lock` so the remote command bot doesn't intercept.

3. **Alexa path** (`hooks/alexa-request.sh`): POSTs the request to API Gateway (which stores it in DynamoDB and triggers a yellow ring notification), then polls the API for a decision.

4. **`Notification` hook** (`hooks/on-notify.sh`): Fires when Claude is idle. Reads the most recent session file to extract Claude's last message, then sends it as a Discord DM. Runs async so it doesn't block anything.

**Remote command bot** (`bot/index.js`, Node.js + discord.js):

Connects to Discord via WebSocket and listens for DMs. Routes messages based on content: Y/N goes to the hooks, everything else gets run as `claude -c -p "your message"` in the configured project directory. Output is chunked to fit Discord's 2000-character limit and sent back as DM replies.

**Alexa backend** (`alexa/`, AWS SAM):

A DynamoDB table stores the current mode and pending request. Two Lambda functions: an API handler (behind API Gateway with API key auth) for the local hook to POST/poll requests and get/set mode, and an Alexa skill handler for voice interactions. The API handler also sends proactive events (yellow ring notifications) via the Alexa Events API when a request arrives in voice mode.

## License

MIT
