import { DynamoDBClient, PutItemCommand, GetItemCommand } from "@aws-sdk/client-dynamodb";
import { randomUUID } from "crypto";

const ddb = new DynamoDBClient({});
const TABLE = process.env.TABLE_NAME;
const ALEXA_CLIENT_ID = process.env.ALEXA_CLIENT_ID || "";
const ALEXA_CLIENT_SECRET = process.env.ALEXA_CLIENT_SECRET || "";

// Cache the OAuth token in Lambda memory (survives across warm invocations)
let cachedToken = null;
let tokenExpiresAt = 0;

export async function handler(event) {
  const method = event.httpMethod;
  const path = event.resource || event.path;

  // Route: GET /mode
  if (method === "GET" && path === "/mode") {
    const result = await ddb.send(new GetItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "MODE" } },
    }));
    const mode = result.Item?.mode?.S || "discord";
    return respond(200, { mode });
  }

  // Route: PUT /mode
  if (method === "PUT" && path === "/mode") {
    const body = JSON.parse(event.body || "{}");
    const mode = body.mode;
    if (!["discord", "alexa", "off"].includes(mode)) {
      return respond(400, { error: "mode must be 'discord', 'alexa', or 'off'" });
    }
    const now = Math.floor(Date.now() / 1000);
    await ddb.send(new PutItemCommand({
      TableName: TABLE,
      Item: {
        pk: { S: "MODE" },
        mode: { S: mode },
        updatedAt: { N: String(now) },
      },
    }));
    return respond(200, { mode });
  }

  // Route: POST /request
  if (method === "POST" && path === "/request") {
    const body = JSON.parse(event.body || "{}");
    const requestId = randomUUID();
    const now = Math.floor(Date.now() / 1000);

    await ddb.send(new PutItemCommand({
      TableName: TABLE,
      Item: {
        pk: { S: "CURRENT" },
        requestId: { S: requestId },
        toolName: { S: body.toolName || "unknown" },
        toolDetail: { S: (body.toolDetail || "").slice(0, 500) },
        status: { S: "pending" },
        createdAt: { N: String(now) },
        decidedAt: { N: "0" },
        ttl: { N: String(now + 3600) },
      },
    }));

    // Send proactive notification if in alexa mode
    try {
      const modeResult = await ddb.send(new GetItemCommand({
        TableName: TABLE,
        Key: { pk: { S: "MODE" } },
      }));
      const currentMode = modeResult.Item?.mode?.S || "unknown";
      console.log(`Mode: ${currentMode}, ClientID set: ${!!ALEXA_CLIENT_ID}, ClientSecret set: ${!!ALEXA_CLIENT_SECRET}`);
      if (currentMode === "alexa") {
        console.log("Sending notification...");
        const toolName = body.toolName || "unknown";
        const toolDetail = (body.toolDetail || "").slice(0, 500);
        await sendNotification(requestId, toolName, toolDetail);
        console.log("Notification sent successfully");
      } else {
        console.log("Skipping proactive notification");
      }
    } catch (err) {
      console.error("Proactive event failed (non-fatal):", err.message, err.stack);
    }

    return respond(200, { requestId });
  }

  // Route: GET /request
  if (method === "GET" && path === "/request") {
    const result = await ddb.send(new GetItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "CURRENT" } },
    }));

    if (!result.Item) return respond(200, { status: "none" });

    const item = result.Item;
    const qsRequestId = event.queryStringParameters?.requestId;

    if (qsRequestId && item.requestId.S !== qsRequestId) {
      return respond(200, { status: "none" });
    }

    return respond(200, {
      status: item.status.S,
      requestId: item.requestId.S,
      toolName: item.toolName.S,
      toolDetail: item.toolDetail.S,
    });
  }

  return respond(400, { error: "Unsupported route" });
}

// --- Proactive Events ---

async function getAlexaToken() {
  const now = Date.now();
  if (cachedToken && now < tokenExpiresAt) return cachedToken;

  const params = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: ALEXA_CLIENT_ID,
    client_secret: ALEXA_CLIENT_SECRET,
    scope: "alexa::proactive_events",
  });

  const res = await fetch("https://api.amazon.com/auth/o2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  if (!res.ok) {
    throw new Error(`Alexa OAuth failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  cachedToken = data.access_token;
  // Expire 5 minutes early to be safe
  tokenExpiresAt = now + (data.expires_in - 300) * 1000;
  return cachedToken;
}

async function sendNotification(requestId, toolName, toolDetail) {
  // Tier 1: Notifications API — yellow ring + chime (needs session token)
  const notifSent = await trySendDeviceNotification(toolName, toolDetail);
  if (notifSent) return;

  // Tier 2: Proactive Events API — lands in notification feed
  console.log("Notifications API unavailable, falling back to Proactive Events...");
  await sendProactiveEvent(requestId);
}

// Notifications API — sends a device notification (yellow ring + chime)
// Uses the session API token saved by the skill handler on each interaction.
async function trySendDeviceNotification(toolName, toolDetail) {
  try {
    const tokenResult = await ddb.send(new GetItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "API_TOKEN" } },
    }));
    const apiAccessToken = tokenResult.Item?.apiAccessToken?.S;
    const apiEndpoint = tokenResult.Item?.apiEndpoint?.S;
    if (!apiAccessToken || !apiEndpoint) {
      console.log("No saved API token — interact with the skill once to prime it");
      return false;
    }

    const detail = toolDetail ? `${toolName}: ${toolDetail}` : toolName;
    const body = {
      displayInfo: {
        content: [{
          locale: "en-US",
          toast: { primaryText: "Agent Orange" },
          title: "Agent Orange",
          bodyItems: [
            { primaryText: detail.slice(0, 200) },
          ],
        }],
      },
      referenceId: `agent-orange-${Date.now()}`,
      expiryTime: new Date(Date.now() + 3600 * 1000).toISOString(),
      spokenInfo: {
        content: [{
          locale: "en-US",
          text: `Approval needed for ${toolName}.`,
        }],
      },
    };

    const res = await fetch(`${apiEndpoint}/v2/notifications`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiAccessToken}`,
      },
      body: JSON.stringify(body),
    });

    const responseText = await res.text();
    console.log(`Notifications API response: ${res.status} ${responseText}`);
    if (res.ok || res.status === 201) {
      // Save notification ID so it can be deleted on approve/deny
      try {
        const parsed = JSON.parse(responseText);
        if (parsed.id) {
          await ddb.send(new PutItemCommand({
            TableName: TABLE,
            Item: {
              pk: { S: "NOTIFICATION" },
              notificationId: { S: parsed.id },
              apiAccessToken: { S: apiAccessToken },
              apiEndpoint: { S: apiEndpoint },
              ttl: { N: String(Math.floor(Date.now() / 1000) + 3600) },
            },
          }));
          console.log(`Saved notification ID: ${parsed.id}`);
        }
      } catch (e) {
        console.warn("Failed to save notification ID:", e.message);
      }
      console.log("Device notification sent (yellow ring + chime)");
      return true;
    }
    console.warn(`Notifications API failed: ${res.status} — falling back`);
    return false;
  } catch (e) {
    console.warn("Notifications API error:", e.message);
    return false;
  }
}

// Proactive Events API — fallback (adds to notification feed)
async function sendProactiveEvent(requestId) {
  const token = await getAlexaToken();
  const now = new Date().toISOString();
  const expiry = new Date(Date.now() + 3600 * 1000).toISOString();

  let audience = { type: "Multicast", payload: {} };
  try {
    const userResult = await ddb.send(new GetItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "USER" } },
    }));
    const userId = userResult.Item?.userId?.S;
    if (userId) {
      audience = { type: "Unicast", payload: { user: userId } };
      console.log("Using Unicast notification");
    } else {
      console.log("No saved userId, using Multicast");
    }
  } catch (e) {
    console.warn("Failed to get userId, using Multicast:", e.message);
  }

  const event = {
    timestamp: now,
    referenceId: requestId,
    expiryTime: expiry,
    event: {
      name: "AMAZON.MessageAlert.Activated",
      payload: {
        state: { status: "UNREAD", freshness: "NEW" },
        messageGroup: {
          creator: { name: "Claude" },
          count: 1,
          urgency: "URGENT",
        },
      },
    },
    localizedAttributes: [
      { locale: "en-US", providerName: "Agent Orange" },
    ],
    relevantAudience: audience,
  };

  const res = await fetch(
    "https://api.amazonalexa.com/v1/proactiveEvents/stages/development",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(event),
    }
  );

  const responseText = await res.text();
  console.log(`Proactive event response: ${res.status} ${responseText}`);
  if (!res.ok) {
    console.error(`Proactive event FAILED: ${res.status} ${responseText}`);
  }
}

function respond(code, body) {
  return {
    statusCode: code,
    body: JSON.stringify(body),
    headers: { "Content-Type": "application/json" },
  };
}
