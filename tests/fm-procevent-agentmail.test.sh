#!/usr/bin/env bash
# Behavior tests for the AgentMail push-email adapter of the process-to-event
# runner (bin/fm-procevent-agentmail.sh + bin/fm-agentmail-ws-listen.mjs).
#
# Exercises the adapter's public commands and the generic runner against a
# minimal local mock WebSocket server (tests/agentmail-mock-ws-fixture.sh),
# never the real agentmail.to service. Proves: source ids are deterministic
# and inbox-scoped; the source never classifies terminal, since a subscribed
# inbox never stops producing mail; self-announcing autohandle wakes exactly
# once per captured generation and is idempotent on replay; a real inbound
# "message.received" event, run end to end through the generic runner,
# produces exactly one correctly-formatted wake and leaves the source armed; a
# "message.sent" event (the inbox's own outbound mail) produces no wake at
# all; and an unresolvable API key produces no wake and no crash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/agentmail-mock-ws-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/agentmail-mock-ws-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-agentmail-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

ADAPTER="$ROOT/bin/fm-procevent-agentmail.sh"

AGENTMAIL_TEST_HOMES=()
BG_PIDS=()
teardown() {
  local pid home seen=$'\n'
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
  for home in ${AGENTMAIL_TEST_HOMES[@]+"${AGENTMAIL_TEST_HOMES[@]}"}; do
    case "$seen" in *$'\n'"$home"$'\n'*) continue ;; esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap teardown EXIT

new_home() { mkdir -p "$1/state"; AGENTMAIL_TEST_HOMES+=("$1"); }

am() { FM_HOME="$1" "$ADAPTER" "${@:2}"; }

wake_payload_count() { grep -c . "$1/state/.wake-queue" 2>/dev/null || echo 0; }

wait_for_file() {  # <path> [tries]
  local n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.05; done
  return 1
}

SERVER_SCRIPT="$TMP_ROOT/mock-ws-server.mjs"
write_agentmail_mock_ws_server "$SERVER_SCRIPT"

# start_mock_server <event-json-or-none> [delay-ms]; echoes "<port> <pid>"
start_mock_server() {
  local event=$1 delay=${2:-20} port_file pid
  port_file=$(mktemp "$TMP_ROOT/port.XXXXXX")
  rm -f "$port_file"
  node "$SERVER_SCRIPT" "$port_file" "$event" "$delay" &
  pid=$!
  BG_PIDS+=("$pid")
  wait_for_file "$port_file" || fail "mock WebSocket server never bound a port"
  printf '%s %s\n' "$(cat "$port_file")" "$pid"
}

# --- source-id is deterministic and inbox-scoped -----------------------------
H="$TMP_ROOT/h-sourceid"; new_home "$H"
sid_a1=$(am "$H" source-id one@example.test)
sid_a2=$(am "$H" source-id one@example.test)
sid_b=$(am "$H" source-id two@example.test)
[ "$sid_a1" = "$sid_a2" ] || fail "source-id must be deterministic for the same inbox"
[ "$sid_a1" != "$sid_b" ] || fail "source-id must differ across inboxes"
case "$sid_a1" in agentmail-*) ;; *) fail "source-id must use the agentmail- prefix" ;; esac
pass "source-id is deterministic and inbox-scoped"

# --- terminal never classifies a captured result as terminal -----------------
H="$TMP_ROOT/h-terminal"; new_home "$H"
RESULT="$TMP_ROOT/terminal-result"
printf 'new email from a@b.test - "hi"\n' > "$RESULT"
if am "$H" terminal "$RESULT"; then
  fail "a subscribed inbox must never classify its result as terminal"
fi
pass "terminal always leaves the source armed"

# --- self-announcing is always true -------------------------------------------
am "$H" self-announcing || fail "the adapter must declare itself self-announcing"
pass "self-announcing is always true"

# --- autohandle wakes exactly once and is idempotent on replay ---------------
H="$TMP_ROOT/h-autohandle"; new_home "$H"
sid=$(am "$H" source-id auto@example.test)
LINE='new email from Alice <alice@example.test> - "Q3 numbers"'
printf '%s\n' "$LINE" > "$TMP_ROOT/auto-src"
durable=$(FM_HOME="$H" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-procevent-lib.sh"
  fm_procevent_capture "$2" "$3" agentmail "$4"
' _ "$ROOT" "$H/state" "$sid" "$TMP_ROOT/auto-src") || fail "could not durably capture a fixture result"
out=$(am "$H" autohandle "$sid" 1 "$durable") || fail "autohandle rejected a genuine capture"
assert_contains "$out" "handled: $sid 1" "autohandle acknowledges through the generic handled channel"
[ "$(wake_payload_count "$H")" = 1 ] || fail "autohandle must append exactly one durable wake"
assert_grep "$LINE" "$H/state/.wake-queue" "the wake payload must carry the captured line verbatim"
assert_grep "procevent-agentmail:$sid:1" "$H/state/.wake-queue" \
  "the wake must be keyed to this exact source and sequence"
am "$H" autohandle "$sid" 1 "$durable" >/dev/null || fail "a replayed autohandle must not fail"
[ "$(wake_payload_count "$H")" = 1 ] || fail "a replayed autohandle must never append a second wake"
pass "autohandle wakes exactly once per capture and is idempotent on replay"

# --- autohandle on a missing capture fails closed, without a partial wake ----
H="$TMP_ROOT/h-autohandle-missing"; new_home "$H"
sid=$(am "$H" source-id missing@example.test)
if am "$H" autohandle "$sid" 1 "$TMP_ROOT/does-not-exist" 2>/dev/null; then
  fail "autohandle must refuse a result file that does not exist"
fi
assert_absent "$H/state/.wake-queue" "a refused autohandle must never create the wake queue"
pass "autohandle on a missing capture fails closed"

# --- end to end: a real inbound message wakes exactly once and stays armed ---
H="$TMP_ROOT/h-received"; new_home "$H"
INBOX="received@example.test"
sid=$(am "$H" source-id "$INBOX")
out=$(am "$H" arm "$INBOX")
assert_contains "$out" "armed: $sid" "arm registers the canonical source id"
read -r PORT SERVER_PID < <(start_mock_server \
  '{"type":"event","event_type":"message.received","message":{"from_":"Priya <priya@example.test>","subject":"Ship it"}}')
start_out=$(AGENTMAIL_API_KEY=am_test_key_received AGENTMAIL_WS_URL="ws://127.0.0.1:$PORT/v0" \
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" start "$sid" 2>&1)
assert_contains "$start_out" "autohandled: $sid" "a received event must be autohandled by the runner itself"
[ "$(wake_payload_count "$H")" = 1 ] || fail "a real inbound message must wake exactly once"
assert_grep 'new email from Priya <priya@example.test> - "Ship it"' "$H/state/.wake-queue" \
  "the wake must carry the exact sender and subject"
assert_present "$H/state/procevent/$sid.source" \
  "a non-terminal inbox source must remain armed after a capture"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
pass "a real inbound message wakes exactly once and leaves the inbox armed"

# --- end to end: the inbox's own outbound reply never wakes ------------------
H="$TMP_ROOT/h-sent"; new_home "$H"
INBOX="sentonly@example.test"
sid=$(am "$H" source-id "$INBOX")
am "$H" arm "$INBOX" >/dev/null
read -r PORT SERVER_PID < <(start_mock_server \
  '{"type":"event","event_type":"message.sent","message":{"from_":"sentonly@example.test","subject":"Re: thanks"}}')
AGENTMAIL_API_KEY=am_test_key_sent AGENTMAIL_WS_URL="ws://127.0.0.1:$PORT/v0" \
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" start "$sid" > "$TMP_ROOT/sent-start.out" 2>&1 &
runner_pid=$!
BG_PIDS+=("$runner_pid")
wait_for_file "$FM_PROCEVENT_CLAIM_ROOT/$sid.claim" || fail "the runner never claimed the sent-only source"
sleep 0.5
assert_absent "$H/state/.wake-queue" "the inbox's own outbound mail must never wake firstmate"
kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
pass "the inbox's own outbound reply never wakes firstmate"

# --- an unresolvable API key fails closed, without a crash or a wake ---------
H="$TMP_ROOT/h-nokey"; new_home "$H"
INBOX="nokey@example.test"
sid=$(am "$H" source-id "$INBOX")
am "$H" arm "$INBOX" >/dev/null
ISOLATED_HOME="$TMP_ROOT/isolated-home"
mkdir -p "$ISOLATED_HOME"
printf 'export PATH=/usr/bin:/bin\n' > "$ISOLATED_HOME/.zshrc"
nokey_out=$(env -u AGENTMAIL_API_KEY HOME="$ISOLATED_HOME" FM_AGENTMAIL_KEY_FAIL_SLEEP=0 \
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" start "$sid" 2>&1)
assert_contains "$nokey_out" "no-result: $sid" "an unresolvable key must leave the source with no captured result"
assert_absent "$H/state/.wake-queue" "an unresolvable key must never publish a wake"
assert_present "$H/state/procevent/$sid.source" "an unresolvable key must leave the source armed for the next attempt"
pass "an unresolvable API key fails closed without a crash or a wake"

printf 'all fm-procevent-agentmail tests passed\n'
