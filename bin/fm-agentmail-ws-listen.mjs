#!/usr/bin/env node
// AgentMail push listener for the "agentmail" process-to-event adapter
// (bin/fm-procevent-agentmail.sh). Blocks on a wss connection, subscribed only
// to "message.received", until exactly one new inbound email arrives, then
// prints one line to stdout and exits 0. Never polls.
//
// Protocol verified against https://docs.agentmail.to/api-reference/websockets
// on 2026-08-21: connect to <AGENTMAIL_WS_URL>?api_key=<key> (query-string
// auth, no header/first-message handshake), send a JSON "subscribe" message
// naming event_types and inbox_ids, then receive JSON "event" messages shaped
// {type:"event", event_type:"message.received", message:{from_|from, subject,
// ...}}. "message.sent" is a distinct event_type for the inbox's own outbound
// mail, so subscribing to only "message.received" already excludes it - no
// client-side sent/received filtering is needed on top of the subscription.
//
// Env:
//   AGENTMAIL_API_KEY        required; never printed, logged, or echoed.
//   AGENTMAIL_INBOX          required; the inbox address to subscribe to.
//   AGENTMAIL_WS_URL         default wss://ws.agentmail.to/v0; override for tests.
//   AGENTMAIL_RECONNECT_MIN_MS  default 1000; initial reconnect delay.
//   AGENTMAIL_RECONNECT_MAX_MS  default 30000; reconnect delay cap.
//
// Uses Node's built-in global WebSocket (stable since Node 22) so this adds no
// npm dependency - node is already part of firstmate's toolchain (see the
// existing bin/*.mjs command-policy scripts).

const WS_URL = process.env.AGENTMAIL_WS_URL || 'wss://ws.agentmail.to/v0';
const INBOX = process.env.AGENTMAIL_INBOX || '';
const API_KEY = process.env.AGENTMAIL_API_KEY || '';
const MIN_BACKOFF_MS = Number(process.env.AGENTMAIL_RECONNECT_MIN_MS) || 1000;
const MAX_BACKOFF_MS = Number(process.env.AGENTMAIL_RECONNECT_MAX_MS) || 30000;

if (!INBOX || !API_KEY) {
  process.exit(1);
}

function sanitizeField(value, fallback) {
  const text = value === undefined || value === null || value === '' ? fallback : String(value);
  return text.replace(/[\t\r\n]+/g, ' ').trim();
}

function connect(backoffMs) {
  let socket;
  try {
    socket = new WebSocket(`${WS_URL}?api_key=${encodeURIComponent(API_KEY)}`);
  } catch {
    scheduleReconnect(backoffMs);
    return;
  }

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({
      type: 'subscribe',
      event_types: ['message.received'],
      inbox_ids: [INBOX],
    }));
  });

  socket.addEventListener('message', (ev) => {
    let payload;
    try {
      payload = JSON.parse(ev.data);
    } catch {
      return;
    }
    if (payload.type !== 'event' || payload.event_type !== 'message.received') {
      return;
    }
    const message = payload.message || {};
    const from = sanitizeField(message.from_ ?? message.from, 'unknown sender');
    const subject = sanitizeField(message.subject, '(no subject)');
    process.stdout.write(`new email from ${from} - "${subject}"\n`);
    try {
      socket.close();
    } catch {
      // already closing; the process exit below is what matters.
    }
    process.exit(0);
  });

  socket.addEventListener('error', () => {
    // The 'close' event always follows and owns reconnect scheduling.
  });

  socket.addEventListener('close', () => {
    scheduleReconnect(backoffMs);
  });
}

function scheduleReconnect(previousBackoffMs) {
  const next = Math.min(previousBackoffMs * 2, MAX_BACKOFF_MS);
  setTimeout(() => connect(next), previousBackoffMs);
}

connect(MIN_BACKOFF_MS);
