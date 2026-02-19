# claude-approve

Get a Discord DM when Claude Code needs your permission — reply to approve or deny from your phone.

Uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) + a Discord bot to turn permission prompts into DM conversations.

## How it works

```
Claude wants to run: npm test
  → Your bot DMs you: "Claude wants to use: Bash — npm test — Reply Y to allow, N to deny."
  → You reply "Y" in Discord
  → Bot reacts ✅ and Claude continues
```

When Claude finishes a task and is waiting for your next prompt, you get a heads-up DM too.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- A Discord account
- `jq` and `curl` installed (`brew install jq` on macOS)

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

It'll ask for your bot token, user ID, and timeout preferences, then wire everything up.

## Usage

Just use Claude Code normally. Whenever it needs permission to run a tool, your bot will DM you instead of (or in addition to) the terminal prompt.

**Reply options:**
- `Y`, `1`, `yes`, `ok`, `allow` — approve (bot reacts ✅)
- Anything else — deny (bot reacts ❌)
- No reply — auto-deny after timeout (bot reacts ⏰)

**Timeout**: Default is 120 seconds (configurable).

## Enable / Disable

Toggle Discord approval on or off without changing your setup:

```bash
claude-approve disable   # use normal terminal prompts
claude-approve enable    # back to Discord approval
claude-approve status    # check current state
```

When disabled, Claude Code falls through to its normal terminal permission prompts — no Discord messages are sent. When you re-enable, Discord approval picks back up immediately. Enabled by default after install.

## Configuration

Config lives at `~/.config/claude-approve/config`. Edit it directly:

```bash
DISCORD_BOT_TOKEN="your-bot-token"
DISCORD_USER_ID="your-discord-user-id"
REPLY_TIMEOUT=120        # seconds to wait for reply
REPLY_POLL_INTERVAL=3    # seconds between checks
```

## What triggers a DM?

| Event | What happens |
|-------|-------------|
| Claude needs permission to use a tool | Two-way DM — reply to approve/deny |
| Claude is idle, waiting for input | One-way DM — just a heads up |

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

This uses two Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks):

1. **`PermissionRequest` hook** (`hooks/on-permission-request.sh`): Fires when Claude needs tool permission. Opens a DM channel via Discord API, sends the request, then polls for your reply message. Returns a JSON decision (allow/deny) that Claude Code respects. Adds emoji reactions to confirm the outcome.

2. **`Notification` hook** (`hooks/on-notify.sh`): Fires when Claude is idle. Sends a one-way DM. Runs async so it doesn't block anything.

The permission hook is blocking by design — Claude Code is already waiting for a decision, so the script holds that spot while it waits for your Discord reply.

## License

MIT
