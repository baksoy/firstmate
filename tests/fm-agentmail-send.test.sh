#!/usr/bin/env bash
# Behavior tests for the AgentMail outbound helper (bin/fm-agentmail-send.sh),
# the send/reply half of firstmate's AgentMail email channel.
#
# The network is stubbed with a fakebin `curl` so these stay hermetic: no
# ports, no real AgentMail account, deterministic in CI. jq stays the real
# tool. Exercises: send POSTs the correct inbox/messages/send URL and JSON
# body; reply targets the verified message_id reply endpoint, never a
# thread-based one, and never sends --thread's value to AgentMail; the
# resolved API key reaches AgentMail ONLY via the Authorization header (never
# argv, a file other than the header temp file, or any printed line); every
# call carries an Idempotency-Key; a missing key fails loudly without ever
# invoking curl; and a non-2xx response fails loudly with the status and body.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agentmail-send-tests)
HELPER="$ROOT/bin/fm-agentmail-send.sh"

# A fakebin `curl` that mimics the AgentMail API. Reads its behavior from env
# (FAKE_RESPONSE_CODE/FAKE_RESPONSE_BODY), records the request to
# FAKE_CURL_LOG, and prints the HTTP code to stdout exactly as the real
# `-w '%{http_code}'` would. argv is logged verbatim (unresolved) so a test
# can prove the resolved key never appears there; the Authorization value is
# logged separately, and only when read through curl's `-H "@file"` form, so a
# test can prove the key reaches curl exclusively through that header file.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth="" idem="" headerfile_used=0
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @*) data=1; [ -n "${FAKE_CURL_LOG:-}" ] && cp -- "${2#@}" "${FAKE_CURL_LOG}.data" ;;
        *) data=1; [ -n "${FAKE_CURL_LOG:-}" ] && printf '%s' "$2" > "${FAKE_CURL_LOG}.data" ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @*)
          headerfile_used=1
          while IFS= read -r header; do
            case "$header" in Authorization:*) auth=$header ;; esac
          done < "${2#@}"
          ;;
        Idempotency-Key:*) idem=$2 ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  {
    echo "argv=$argv"
    echo "method=$method"
    echo "url=$url"
    echo "auth=$auth"
    echo "idem=$idem"
    echo "headerfile_used=$headerfile_used"
    echo "data=$data"
  } >> "$FAKE_CURL_LOG"
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_RESPONSE_BODY:-}" > "$ofile"
printf '%s' "${FAKE_RESPONSE_CODE:-200}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"

log_field() {  # <log-file> <field-name>
  grep "^$2=" "$1" | tail -1 | sed "s/^$2=//"
}

# --- send POSTs the correct URL and JSON body --------------------------------
H="$TMP_ROOT/send-basic"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
BODY='{"message_id":"msg_send1","thread_id":"thr_send1"}'
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_1 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY="$BODY" \
  "$HELPER" send --to recipient@example.test --subject "Q3 numbers" --text "here they are")
rc=$?
expect_code 0 "$rc" "send exit code"
assert_contains "$out" "message_id=msg_send1" "send must echo the returned message_id"
assert_contains "$out" "thread_id=thr_send1" "send must echo the returned thread_id"
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/baksoy-firstmate%40agentmail.to/messages/send" ] \
  || fail "send must POST to the default inbox's messages/send endpoint (got: $url)"
[ "$(jq -r '.to' "$LOG.data")" = "recipient@example.test" ] || fail "send body must carry 'to'"
[ "$(jq -r '.subject' "$LOG.data")" = "Q3 numbers" ] || fail "send body must carry 'subject'"
[ "$(jq -r '.text' "$LOG.data")" = "here they are" ] || fail "send body must carry 'text'"
pass "send POSTs the correct default-inbox URL and JSON body"

# --- send honors --inbox -------------------------------------------------------
H="$TMP_ROOT/send-inbox"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_2 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" send --to r@example.test --subject s --text t --inbox other-inbox@agentmail.to >/dev/null
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/other-inbox%40agentmail.to/messages/send" ] \
  || fail "send must honor --inbox (got: $url)"
pass "send honors --inbox"

# --- send reads the body from stdin with --stdin ------------------------------
H="$TMP_ROOT/send-stdin"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
printf 'multi\nline\nbody' | PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_3 \
  FAKE_CURL_LOG="$LOG" FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" send --to r@example.test --subject s --stdin >/dev/null
[ "$(jq -r '.text' "$LOG.data")" = "$(printf 'multi\nline\nbody')" ] \
  || fail "send --stdin must read the body from stdin"
pass "send --stdin reads the body from stdin"

# --- reply targets the verified message_id endpoint, never a thread one ------
H="$TMP_ROOT/reply-basic"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_4 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"msg_reply1","thread_id":"thr_reply1"}' \
  "$HELPER" reply --message msg_original --thread thr_original --text "on it")
rc=$?
expect_code 0 "$rc" "reply exit code"
assert_contains "$out" "message_id=msg_reply1" "reply must echo the returned message_id"
assert_contains "$out" "thread_id=thr_reply1" "reply must echo the returned thread_id"
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/baksoy-firstmate%40agentmail.to/messages/msg_original/reply" ] \
  || fail "reply must target the message_id in the URL path, not a thread_id (got: $url)"
[ "$(jq -r '.text' "$LOG.data")" = "on it" ] || fail "reply body must carry 'text'"
assert_no_grep "thr_original" "$LOG" \
  "the --thread value must never be sent to AgentMail (URL)"
assert_no_grep "thr_original" "$LOG.data" \
  "the --thread value must never be sent to AgentMail (body)"
pass "reply targets the verified message_id endpoint and never sends --thread to AgentMail"

# --- reply works with --thread omitted (it is optional bookkeeping only) -----
H="$TMP_ROOT/reply-no-thread"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_5 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" reply --message msg_only --text "ack")
expect_code 0 "$?" "reply without --thread exit code"
url=$(log_field "$LOG" url)
case "$url" in
  */messages/msg_only/reply) ;;
  *) fail "reply must work with --thread omitted (got: $url)" ;;
esac
pass "reply works with --thread omitted"

# --- reply requires --message ---------------------------------------------
H="$TMP_ROOT/reply-no-message"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
if PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_6 "$HELPER" reply --thread thr_only --text hi 2>/dev/null; then
  fail "reply must refuse to run without --message"
fi
pass "reply refuses to run without --message"

# --- the resolved key reaches AgentMail only via the Authorization header ----
H="$TMP_ROOT/key-scope"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
SECRET="am_super_secret_key_789"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY="$SECRET" FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" send --to r@example.test --subject s --text t)
argv_line=$(log_field "$LOG" argv)
auth_line=$(log_field "$LOG" auth)
headerfile_used=$(log_field "$LOG" headerfile_used)
[ "$headerfile_used" = 1 ] || fail "the Authorization header must be passed to curl via -H \"@file\", never inline"
case "$argv_line" in
  *"$SECRET"*) fail "the resolved key must never appear in curl's argv" ;;
esac
case "$auth_line" in
  "Authorization: Bearer $SECRET") ;;
  *) fail "the Authorization header must carry the resolved key (got: $auth_line)" ;;
esac
case "$out" in
  *"$SECRET"*) fail "the resolved key must never appear in the helper's stdout" ;;
esac
pass "the resolved key reaches AgentMail only via the Authorization header"

# --- every send/reply carries an Idempotency-Key ------------------------------
H="$TMP_ROOT/idem-send"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_7 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" send --to r@example.test --subject s --text t >/dev/null
idem1=$(log_field "$LOG" idem)
[ -n "$idem1" ] && [ "$idem1" != "Idempotency-Key:" ] || fail "send must carry a non-empty Idempotency-Key header"
: > "$LOG"
PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_7 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"message_id":"m","thread_id":"t"}' \
  "$HELPER" reply --message msg_x --text t >/dev/null
idem2=$(log_field "$LOG" idem)
[ -n "$idem2" ] && [ "$idem2" != "Idempotency-Key:" ] || fail "reply must carry a non-empty Idempotency-Key header"
[ "$idem1" != "$idem2" ] || fail "each call must generate a fresh Idempotency-Key"
pass "every send/reply carries a fresh Idempotency-Key"

# --- a missing key fails loudly without ever invoking curl -------------------
H="$TMP_ROOT/no-key"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
ISOLATED_HOME="$TMP_ROOT/isolated-home"
mkdir -p "$ISOLATED_HOME"
printf 'export PATH=/usr/bin:/bin\n' > "$ISOLATED_HOME/.zshrc"
if err=$(env -u AGENTMAIL_API_KEY HOME="$ISOLATED_HOME" PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$LOG" \
  "$HELPER" send --to r@example.test --subject s --text t 2>&1); then
  fail "send must fail when the API key cannot be resolved"
fi
assert_contains "$err" "could not resolve" "a missing key must fail with a clear message"
assert_absent "$LOG" "a missing key must never invoke curl at all"
pass "a missing key fails loudly without ever invoking curl"

# --- a non-2xx response fails loudly with the status and body ----------------
H="$TMP_ROOT/http-failure"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
if err=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_8 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=403 FAKE_RESPONSE_BODY='{"error":"forbidden"}' \
  "$HELPER" send --to r@example.test --subject s --text t 2>&1); then
  fail "send must fail on a non-2xx response"
fi
assert_contains "$err" "403" "a failure must report the HTTP status"
assert_contains "$err" "forbidden" "a failure must report the response body"
pass "a non-2xx response fails loudly with the status and body"

printf 'all fm-agentmail-send tests passed\n'
