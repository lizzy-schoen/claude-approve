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

### 1. Create a Discord bot

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application**, give it a name (e.g. "Claude Approve"), click Create
3. Go to **Bot** in the sidebar
4. Click **Reset Token** and copy it — you'll need this in a moment
5. Enable **Message Content Intent** under Privileged Gateway Intents
6. Go to **OAuth2** in the sidebar
7. Under **OAuth2 URL Generator**, check the `bot` scope
8. Under **Bot Permissions**, check `Send Messages` and `Read Message History`
9. Copy the generated URL, open it in your browser, and invite the bot to any server you're in

### 2. Get your Discord User ID

1. Open Discord Settings > Advanced > enable **Developer Mode**
2. Right-click your own name anywhere and click **Copy User ID**

### 3. Run the installer

```bash
git clone https://github.com/YOUR_USERNAME/claude-approve.git
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
1. Clone this repo
2. Run `./install.sh` with their own Discord User ID
3. Make sure they're in a server with the bot

You can use the **same bot** for everyone — each person just provides their own User ID and the bot DMs them individually.

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
