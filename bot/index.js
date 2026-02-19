import { readFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { Client, GatewayIntentBits, ChannelType, Partials } from "discord.js";

// --- Config ---

const CONFIG_PATH =
  process.env.CLAUDE_APPROVE_CONFIG ||
  join(homedir(), ".config/claude-approve/config");

function loadConfig() {
  if (!existsSync(CONFIG_PATH)) {
    console.error(`Config not found at ${CONFIG_PATH}. Run install.sh first.`);
    process.exit(1);
  }
  const config = {};
  for (const line of readFileSync(CONFIG_PATH, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq);
    const val = trimmed.slice(eq + 1).replace(/^["']|["']$/g, "");
    config[key] = val;
  }
  if (!config.DISCORD_BOT_TOKEN || !config.DISCORD_USER_ID) {
    console.error("Config must include DISCORD_BOT_TOKEN and DISCORD_USER_ID.");
    process.exit(1);
  }
  return config;
}

const config = loadConfig();
const PROJECT_DIR = config.PROJECT_DIR || process.cwd();
const LOCK_FILE = "/tmp/claude-approve.lock";
const YN_PATTERN = /^(1|y|yes|n|no|allow|ok|deny|reject)$/i;

// --- Lock file check ---

function isPermissionPending() {
  if (!existsSync(LOCK_FILE)) return false;
  try {
    const pid = parseInt(readFileSync(LOCK_FILE, "utf8").trim(), 10);
    process.kill(pid, 0); // signal 0 = check if process exists
    return true;
  } catch {
    return false; // stale lock or unreadable
  }
}

// --- Claude runner ---

let running = false;

function runClaude(prompt) {
  return new Promise((resolve, reject) => {
    running = true;
    let stdout = "";
    let stderr = "";

    const proc = spawn(
      "claude",
      ["-c", "-p", prompt, "--output-format", "text"],
      {
        cwd: PROJECT_DIR,
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env },
      }
    );

    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    proc.on("close", (code) => {
      running = false;
      if (code === 0) {
        resolve(stdout.trim() || "(No output)");
      } else {
        reject(new Error(stderr.trim() || `claude exited with code ${code}`));
      }
    });

    proc.on("error", (err) => {
      running = false;
      reject(err);
    });
  });
}

// --- Discord message chunking ---

function chunkText(text, maxLen = 1990) {
  if (text.length <= maxLen) return [text];

  const chunks = [];
  let remaining = text;

  while (remaining.length > 0) {
    if (remaining.length <= maxLen) {
      chunks.push(remaining);
      break;
    }

    // Try to split at a newline near the limit
    let splitAt = remaining.lastIndexOf("\n", maxLen);
    if (splitAt < maxLen * 0.5) {
      // No good newline — try a space
      splitAt = remaining.lastIndexOf(" ", maxLen);
    }
    if (splitAt < maxLen * 0.3) {
      // No good break — hard split
      splitAt = maxLen;
    }

    chunks.push(remaining.slice(0, splitAt));
    remaining = remaining.slice(splitAt).trimStart();
  }

  return chunks;
}

// --- Discord bot ---

const client = new Client({
  intents: [
    GatewayIntentBits.DirectMessages,
    GatewayIntentBits.DirectMessageTyping,
    GatewayIntentBits.MessageContent,
  ],
  partials: [Partials.Channel],
});

client.on("clientReady", () => {
  console.log(`Bot logged in as ${client.user.tag}`);
  console.log(`Project directory: ${PROJECT_DIR}`);
  console.log("Listening for Discord DMs...");
});

client.on("messageCreate", async (message) => {
  // Only handle DMs from the configured user
  if (message.channel.type !== ChannelType.DM) return;
  if (message.author.id !== config.DISCORD_USER_ID) return;
  if (message.author.bot) return;

  const content = message.content.trim();
  if (!content) return;

  // Y/N-style messages — let the bash hook handle them
  if (YN_PATTERN.test(content)) return;

  // Permission request is pending — tell user to respond to that first
  if (isPermissionPending()) {
    await message.reply(
      "A permission request is pending — reply **Y** or **N** to that first."
    );
    return;
  }

  // Already running a command
  if (running) {
    await message.reply(
      "Claude is still working on your previous request. Please wait."
    );
    return;
  }

  // Run the command
  await message.react("\u{1F9E0}"); // 🧠

  // Keep the typing indicator alive
  const typingInterval = setInterval(() => {
    message.channel.sendTyping().catch(() => {});
  }, 8000);
  message.channel.sendTyping().catch(() => {});

  try {
    console.log(`[command] ${content}`);
    const result = await runClaude(content);

    clearInterval(typingInterval);

    const chunks = chunkText(result);
    for (const chunk of chunks) {
      await message.channel.send(chunk);
    }

    await message.react("\u2705").catch(() => {}); // ✅
    console.log(`[done] sent ${chunks.length} message(s)`);
  } catch (err) {
    clearInterval(typingInterval);

    const errMsg = err.message || String(err);
    await message.channel.send(`**Error:** ${errMsg.slice(0, 1900)}`);
    await message.react("\u274C").catch(() => {}); // ❌
    console.error(`[error] ${errMsg}`);
  }
});

// --- Start ---

client.login(config.DISCORD_BOT_TOKEN);

process.on("SIGINT", () => {
  console.log("Shutting down...");
  client.destroy();
  process.exit(0);
});

process.on("SIGTERM", () => {
  client.destroy();
  process.exit(0);
});
