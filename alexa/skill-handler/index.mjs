import Alexa from "ask-sdk-core";
import { DynamoDBClient, GetItemCommand, PutItemCommand, UpdateItemCommand, DeleteItemCommand } from "@aws-sdk/client-dynamodb";

const ddb = new DynamoDBClient({});
const TABLE = process.env.TABLE_NAME;

// --- DynamoDB helpers ---

async function getPending() {
  const result = await ddb.send(new GetItemCommand({
    TableName: TABLE,
    Key: { pk: { S: "CURRENT" } },
  }));
  if (!result.Item || result.Item.status.S !== "pending") return null;
  return {
    requestId: result.Item.requestId.S,
    toolName: result.Item.toolName.S,
    toolDetail: result.Item.toolDetail.S,
  };
}

async function setDecision(decision) {
  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new UpdateItemCommand({
    TableName: TABLE,
    Key: { pk: { S: "CURRENT" } },
    UpdateExpression: "SET #s = :decision, decidedAt = :now",
    ConditionExpression: "#s = :pending",
    ExpressionAttributeNames: { "#s": "status" },
    ExpressionAttributeValues: {
      ":decision": { S: decision },
      ":pending": { S: "pending" },
      ":now": { N: String(now) },
    },
  }));
}

async function getMode() {
  const result = await ddb.send(new GetItemCommand({
    TableName: TABLE,
    Key: { pk: { S: "MODE" } },
  }));
  return result.Item?.mode?.S || "discord";
}

async function setMode(mode) {
  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new PutItemCommand({
    TableName: TABLE,
    Item: {
      pk: { S: "MODE" },
      mode: { S: mode },
      updatedAt: { N: String(now) },
    },
  }));
}

function describeRequest(pending) {
  return pending.toolName;
}

// Save user ID for unicast proactive events
async function saveUserId(userId) {
  if (!userId) return;
  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new PutItemCommand({
    TableName: TABLE,
    Item: {
      pk: { S: "USER" },
      userId: { S: userId },
      updatedAt: { N: String(now) },
    },
  }));
}

// Save API access token + endpoint for Notifications API (yellow ring + chime)
async function saveApiToken(apiAccessToken, apiEndpoint) {
  if (!apiAccessToken || !apiEndpoint) return;
  const now = Math.floor(Date.now() / 1000);
  await ddb.send(new PutItemCommand({
    TableName: TABLE,
    Item: {
      pk: { S: "API_TOKEN" },
      apiAccessToken: { S: apiAccessToken },
      apiEndpoint: { S: apiEndpoint },
      updatedAt: { N: String(now) },
      ttl: { N: String(now + 3600) },
    },
  }));
}

// Delete the active notification (dismiss yellow ring) after approve/deny
async function deleteNotification(apiAccessToken, apiEndpoint) {
  if (!apiAccessToken || !apiEndpoint) return;
  try {
    const result = await ddb.send(new GetItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "NOTIFICATION" } },
    }));
    const notificationId = result.Item?.notificationId?.S;
    if (!notificationId) return;

    const res = await fetch(`${apiEndpoint}/v2/notifications/${notificationId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${apiAccessToken}` },
    });
    console.log(`Delete notification ${notificationId}: ${res.status}`);

    // Clean up the DynamoDB record
    await ddb.send(new DeleteItemCommand({
      TableName: TABLE,
      Key: { pk: { S: "NOTIFICATION" } },
    }));
  } catch (e) {
    console.warn("Failed to delete notification:", e.message);
  }
}

// --- Debug + Intent handlers ---

const DebugInterceptor = {
  async process(input) {
    const reqType = input.requestEnvelope?.request?.type;
    const intentName = input.requestEnvelope?.request?.intent?.name;
    console.log(`REQUEST TYPE: ${reqType}, INTENT: ${intentName || "N/A"}`);
    // Save user ID on every interaction for unicast notifications
    const userId = input.requestEnvelope?.session?.user?.userId
      || input.requestEnvelope?.context?.System?.user?.userId;
    if (userId) {
      try { await saveUserId(userId); } catch (e) { console.warn("Failed to save userId:", e.message); }
    }
    // Save API access token for Notifications API (yellow ring + chime)
    const apiAccessToken = input.requestEnvelope?.context?.System?.apiAccessToken;
    const apiEndpoint = input.requestEnvelope?.context?.System?.apiEndpoint;
    if (apiAccessToken && apiEndpoint) {
      try { await saveApiToken(apiAccessToken, apiEndpoint); } catch (e) { console.warn("Failed to save apiToken:", e.message); }
    }
  },
};

const LaunchRequestHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "LaunchRequest";
  },
  async handle(input) {
    const pending = await getPending();
    if (pending) {
      return input.responseBuilder
        .speak(`Approval needed for ${describeRequest(pending)}. Say approve or deny.`)
        .reprompt("Say approve or deny.")
        .withShouldEndSession(false)
        .getResponse();
    }
    return input.responseBuilder
      .speak("Agent Orange. No pending requests right now.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

const CheckPendingHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "CheckPendingIntent";
  },
  async handle(input) {
    const pending = await getPending();
    if (!pending) {
      return input.responseBuilder
        .speak("No pending requests right now.")
        .withShouldEndSession(true)
        .getResponse();
    }
    return input.responseBuilder
      .speak(`Approval needed for ${describeRequest(pending)}. Say approve or deny.`)
      .reprompt("Say approve or deny.")
      .withShouldEndSession(false)
      .getResponse();
  },
};

const ApproveHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "ApproveIntent";
  },
  async handle(input) {
    const pending = await getPending();
    if (!pending) {
      return input.responseBuilder
        .speak("Nothing pending to approve.")
        .withShouldEndSession(true)
        .getResponse();
    }
    try {
      await setDecision("approved");
      const token = input.requestEnvelope?.context?.System?.apiAccessToken;
      const endpoint = input.requestEnvelope?.context?.System?.apiEndpoint;
      await deleteNotification(token, endpoint);
      return input.responseBuilder
        .speak(`Approved ${pending.toolName}.`)
        .withShouldEndSession(true)
        .getResponse();
    } catch {
      return input.responseBuilder
        .speak("That request was already handled.")
        .withShouldEndSession(true)
        .getResponse();
    }
  },
};

const DenyHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "DenyIntent";
  },
  async handle(input) {
    const pending = await getPending();
    if (!pending) {
      return input.responseBuilder
        .speak("Nothing pending to deny.")
        .withShouldEndSession(true)
        .getResponse();
    }
    try {
      await setDecision("denied");
      const token = input.requestEnvelope?.context?.System?.apiAccessToken;
      const endpoint = input.requestEnvelope?.context?.System?.apiEndpoint;
      await deleteNotification(token, endpoint);
      return input.responseBuilder
        .speak("Denied.")
        .withShouldEndSession(true)
        .getResponse();
    } catch {
      return input.responseBuilder
        .speak("That request was already handled.")
        .withShouldEndSession(true)
        .getResponse();
    }
  },
};

const EnableVoiceModeHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "EnableVoiceModeIntent";
  },
  async handle(input) {
    await setMode("alexa");
    return input.responseBuilder
      .speak("Voice mode enabled. You'll get notifications here.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

const EnableTextModeHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "EnableTextModeIntent";
  },
  async handle(input) {
    await setMode("discord");
    return input.responseBuilder
      .speak("Text mode enabled. Approvals will go through Discord.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

const DisableHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "DisableIntent";
  },
  async handle(input) {
    await setMode("off");
    return input.responseBuilder
      .speak("Agent Orange disabled. Approvals will fall through to the terminal.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

const StatusHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "StatusIntent";
  },
  async handle(input) {
    const mode = await getMode();
    const modeNames = { discord: "text mode", alexa: "voice mode", off: "disabled" };
    const name = modeNames[mode] || mode;
    return input.responseBuilder
      .speak(`Agent Orange is currently in ${name}.`)
      .withShouldEndSession(true)
      .getResponse();
  },
};

const HelpHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "AMAZON.HelpIntent";
  },
  handle(input) {
    return input.responseBuilder
      .speak("You can say check pending to hear what Claude needs, then say approve or deny. You can also say enable voice mode, enable text mode, or disable.")
      .reprompt("Say check pending, approve, deny, or help.")
      .withShouldEndSession(false)
      .getResponse();
  },
};

const CancelStopHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && (Alexa.getIntentName(input.requestEnvelope) === "AMAZON.CancelIntent"
        || Alexa.getIntentName(input.requestEnvelope) === "AMAZON.StopIntent");
  },
  handle(input) {
    return input.responseBuilder
      .speak("Goodbye.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

const FallbackHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "IntentRequest"
      && Alexa.getIntentName(input.requestEnvelope) === "AMAZON.FallbackIntent";
  },
  handle(input) {
    return input.responseBuilder
      .speak("I didn't understand that. Say check pending, approve, deny, or help.")
      .reprompt("Say check pending, approve, deny, or help.")
      .withShouldEndSession(false)
      .getResponse();
  },
};

const SessionEndedHandler = {
  canHandle(input) {
    return Alexa.getRequestType(input.requestEnvelope) === "SessionEndedRequest";
  },
  handle(input) {
    return input.responseBuilder.getResponse();
  },
};

const ErrorHandler = {
  canHandle() {
    return true;
  },
  handle(input, error) {
    console.error("Error:", error.message);
    return input.responseBuilder
      .speak("Sorry, something went wrong. Please try again.")
      .withShouldEndSession(true)
      .getResponse();
  },
};

// Catch-all for unhandled request types (e.g. ProactiveSubscriptionChanged)
const CatchAllHandler = {
  canHandle() {
    return true;
  },
  handle(input) {
    const reqType = input.requestEnvelope?.request?.type;
    console.log(`CatchAll handling request type: ${reqType}`);
    return input.responseBuilder.getResponse();
  },
};

export const handler = Alexa.SkillBuilders.custom()
  .addRequestHandlers(
    LaunchRequestHandler,
    CheckPendingHandler,
    ApproveHandler,
    DenyHandler,
    EnableVoiceModeHandler,
    EnableTextModeHandler,
    DisableHandler,
    StatusHandler,
    HelpHandler,
    CancelStopHandler,
    FallbackHandler,
    SessionEndedHandler,
    CatchAllHandler,
  )
  .addRequestInterceptors(DebugInterceptor)
  .addErrorHandlers(ErrorHandler)
  .lambda();
