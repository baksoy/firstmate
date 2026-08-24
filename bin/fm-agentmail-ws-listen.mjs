#!/usr/bin/env node
// AgentMail push listener for the "agentmail" process-to-event adapter
// (bin/fm-procevent-agentmail.sh). Blocks on a wss connection, subscribed only
// to "message.received", until exactly one new inbound email arrives, then
// prints one line to stdout and exits 0. Never polls.
//
// The printed line carries a trailing "[message=<message_id> thread=<thread_id>]"
// token so a wake line alone is enough for bin/fm-agentmail-send.sh's `reply`
// command: AgentMail's reply endpoint targets a message_id (verified against
// https://docs.agentmail.to/api-reference/inboxes/messages/reply.md on
// 2026-08-21), so message_id is the primary field; thread_id rides along for
// context. Either id missing or containing characters outside
// [A-Za-z0-9_.:-] drops the whole token rather than emitting a malformed or
// unusable one - a bare summary line is still useful, a broken reply target
// is not.
//
// The from and subject fields come straight off an inbound email, so they are
// attacker-controlled; sanitizeField neutralizes any "[" / "]" in them (see
// its comment) so this trailing token is always the only bracketed token on
// the line and cannot be forged by a crafted subject.
//
// Protocol verified against https://docs.agentmail.to/api-reference/websockets
// on 2026-08-21: connect to <AGENTMAIL_WS_URL>?api_key=<key> (query-string
// auth, no header/first-message handshake), send a JSON "subscribe" message
// naming event_types and inbox_ids, then receive JSON "event" messages shaped
// {type:"event", event_type:"message.received", message:{from, subject,
// message_id, thread_id, ...}}. "message.sent" is a distinct event_type for
// the inbox's own outbound mail, so subscribing to only "message.received"
// already excludes it - no client-side sent/received filtering is needed on
// top of the subscription.
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

// sanitizeField renders one untrusted email field (from, subject) into a
// single-line, bracket-free summary. Beyond collapsing control whitespace, it
// turns every "[" / "]" into "(" / ")": the wake line ends in an optional
// "[message=<id> thread=<id>]" reply-target token that a consumer keys the
// reply off, and these fields are attacker-supplied, so a subject like
// "[message=am_FORGED thread=am_FORGED]" could otherwise plant a second, forged
// token on the line. Neutralizing brackets here guarantees the trailing token
// emitted by replyToken() is the only bracketed token on the line, so it is
// unambiguously the authoritative reply target.
function sanitizeField(value, fallback) {
  const text = value === undefined || value === null || value === '' ? fallback : String(value);
  return text.replace(/[\t\r\n]+/g, ' ').replace(/\[/g, '(').replace(/\]/g, ')').trim();
}

// safeId returns value unchanged only if it is a non-empty string made
// entirely of [A-Za-z0-9_.:-] - the reply id token must never itself contain
// the "]" or whitespace that would make the trailing token ambiguous to
// parse. Returns '' (never a fabricated id) when value fails that check.
function safeId(value) {
  if (typeof value !== 'string' || value === '') {
    return '';
  }
  return /^[A-Za-z0-9_.:-]+$/.test(value) ? value : '';
}

// replyToken builds the trailing "[message=<id> thread=<id>]" token that
// carries the reply target through the wake line. message_id is the primary
// field (AgentMail replies target a message_id, not a thread_id); the whole
// token is omitted when message_id is unusable, since a reply can never be
// built from thread_id alone.
function replyToken(message) {
  const messageId = safeId(message.message_id);
  if (!messageId) {
    return '';
  }
  const threadId = safeId(message.thread_id);
  return threadId ? ` [message=${messageId} thread=${threadId}]` : ` [message=${messageId}]`;
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
    process.stdout.write(`new email from ${from} - "${subject}"${replyToken(message)}\n`);
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
