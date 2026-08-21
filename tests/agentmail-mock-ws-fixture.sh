#!/usr/bin/env bash
# tests/agentmail-mock-ws-fixture.sh - a minimal stdlib-only WebSocket server
# used to drive tests/fm-procevent-agentmail.test.sh's end-to-end scenarios
# against bin/fm-agentmail-ws-listen.mjs without reaching the real
# agentmail.to service.
#
# It speaks just enough of RFC 6455 to matter here: it completes the upgrade
# handshake for any request, then - after an optional delay - writes exactly
# one unmasked text frame carrying the given JSON body to the first client
# that connects, and otherwise leaves the connection open. It never parses or
# needs to parse what the client sends, since these tests only assert on what
# the listener does after receiving a server-pushed event.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/agentmail-mock-ws-fixture.sh"
#   write_agentmail_mock_ws_server <script-path>
#   node <script-path> <port-file> <event-json|none> [delay-ms]
#
# <port-file> receives the bound ephemeral port once the server is listening.

write_agentmail_mock_ws_server() {  # <script-path>
  cat > "$1" <<'MJS'
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const [, , portFile, eventJson, delayMsRaw] = process.argv;
const delayMs = Number(delayMsRaw) || 50;

function textFrame(payload) {
  const body = Buffer.from(payload, 'utf8');
  const len = body.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  }
  return Buffer.concat([header, body]);
}

const server = http.createServer();
server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto
    .createHash('sha1')
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  if (eventJson && eventJson !== 'none') {
    setTimeout(() => {
      try {
        socket.write(textFrame(eventJson));
      } catch {
        // The client is already gone; nothing left to push to.
      }
    }, delayMs);
  }
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
MJS
}
