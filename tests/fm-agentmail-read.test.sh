#!/usr/bin/env bash
# Behavior tests for the AgentMail inbound-read helper (bin/fm-agentmail-read.sh),
# the read half of firstmate's AgentMail channel and the fix's core artifact: an
# `agentmail` wake carries only a sender-and-subject NOTIFICATION, so before
# reporting or acting firstmate must fetch the FULL message body through this
# helper (never a hand-rolled `curl -H "Authorization: Bearer $KEY"`, which leaks
# the key).
#
# The network is stubbed with a fakebin `curl` so these stay hermetic: no ports,
# no real AgentMail account, deterministic in CI. jq stays the real tool.
# Exercises the observable interface: `get` fetches the exact message endpoint
# and returns the FULL body (not the wake line); `get` honors --inbox; the
# resolved key reaches AgentMail ONLY via the Authorization header file (never
# argv, never stdout); a message id with characters outside the allowed charset
# is refused before curl is ever invoked (path-injection guard); `get` requires
# --message; `list` targets the inbox messages endpoint so a caller can pick an
# id when the wake carried none, and honors --limit; a missing key fails loudly
# without invoking curl; and a non-2xx response fails loudly with the status and
# body rather than silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agentmail-read-tests)
HELPER="$ROOT/bin/fm-agentmail-read.sh"

# A fakebin `curl` that mimics the AgentMail read API. Serves
# FAKE_RESPONSE_BODY into the -o file and prints FAKE_RESPONSE_CODE exactly as
# real curl's `-w '%{http_code}'` would. argv is logged verbatim (unresolved) so
# a test can prove the resolved key never appears there; the Authorization value
# is captured separately and only when read through curl's `-H "@file"` form, so
# a test can prove the key reaches curl exclusively through that header file.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" auth="" accept="" headerfile_used=0
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -H)
      case "$2" in
        @*)
          headerfile_used=1
          while IFS= read -r header; do
            case "$header" in Authorization:*) auth=$header ;; esac
          done < "${2#@}"
          ;;
        Accept:*) accept=$2 ;;
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
    echo "url=$url"
    echo "auth=$auth"
    echo "accept=$accept"
    echo "headerfile_used=$headerfile_used"
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

# The full inbound message body a real AgentMail get returns. The wake line only
# ever carries sender + subject; `text` is content that lives ONLY in the body,
# so a test that sees it back proves the helper fetched the body, not the wake.
FULL_BODY='{"message_id":"msg_abc123","thread_id":"thr_x","from":"vendor@example.test","subject":"Invoice #4021","preview":"Please wire...","text":"Body-only instruction: please wire $9,000 today."}'

# --- get fetches the exact message endpoint and returns the FULL body --------
H="$TMP_ROOT/get-basic"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_1 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY="$FULL_BODY" \
  "$HELPER" get --message msg_abc123)
rc=$?
expect_code 0 "$rc" "get exit code"
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/baksoy-firstmate%40agentmail.to/messages/msg_abc123" ] \
  || fail "get must GET the default inbox's messages/<id> endpoint (got: $url)"
# The whole point of the fix: the caller gets the BODY, which carries content the
# wake line never had. Parse it as JSON and read a body-only field.
[ "$(printf '%s' "$out" | jq -r '.message_id')" = "msg_abc123" ] \
  || fail "get must return the fetched message JSON on stdout"
[ "$(printf '%s' "$out" | jq -r '.text')" = "Body-only instruction: please wire \$9,000 today." ] \
  || fail "get must return the full body text, not just sender/subject"
pass "get fetches the message endpoint and returns the full body"

# --- get honors --inbox ------------------------------------------------------
H="$TMP_ROOT/get-inbox"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_2 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY="$FULL_BODY" \
  "$HELPER" get --message msg_abc123 --inbox other-inbox@agentmail.to >/dev/null
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/other-inbox%40agentmail.to/messages/msg_abc123" ] \
  || fail "get must honor --inbox (got: $url)"
pass "get honors --inbox"

# --- the resolved key reaches AgentMail only via the Authorization header ----
H="$TMP_ROOT/key-scope"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
SECRET="am_super_secret_key_789"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY="$SECRET" FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY="$FULL_BODY" \
  "$HELPER" get --message msg_abc123)
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

# --- get refuses a message id outside the allowed charset, before any curl ---
H="$TMP_ROOT/get-injection"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
if err=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_3 FAKE_CURL_LOG="$LOG" \
  "$HELPER" get --message 'msg/../../admin?x=1' 2>&1); then
  fail "get must refuse a message id containing characters outside [A-Za-z0-9_.:-]"
fi
assert_contains "$err" "characters outside" "an invalid message id must fail with a clear message"
assert_absent "$LOG" "an invalid message id must be rejected before curl is ever invoked"
pass "get refuses a path-injecting message id before invoking curl"

# --- get requires --message --------------------------------------------------
H="$TMP_ROOT/get-no-message"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
if PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_4 "$HELPER" get 2>/dev/null; then
  fail "get must refuse to run without --message"
fi
pass "get refuses to run without --message"

# --- list targets the inbox messages endpoint and honors --limit ------------
H="$TMP_ROOT/list-basic"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
out=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_5 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"messages":[{"message_id":"m1"}]}' \
  "$HELPER" list)
expect_code 0 "$?" "list exit code"
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/baksoy-firstmate%40agentmail.to/messages" ] \
  || fail "list must GET the default inbox's messages endpoint so a caller can pick an id (got: $url)"
[ "$(printf '%s' "$out" | jq -r '.messages[0].message_id')" = "m1" ] \
  || fail "list must return the inbox message-list JSON"
: > "$LOG"
PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_5 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=200 FAKE_RESPONSE_BODY='{"messages":[]}' \
  "$HELPER" list --limit 5 >/dev/null
url=$(log_field "$LOG" url)
[ "$url" = "https://api.agentmail.to/v0/inboxes/baksoy-firstmate%40agentmail.to/messages?limit=5" ] \
  || fail "list must append --limit as a query parameter (got: $url)"
pass "list targets the messages endpoint and honors --limit"

# --- a missing key fails loudly without ever invoking curl -------------------
H="$TMP_ROOT/no-key"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
ISOLATED_HOME="$TMP_ROOT/isolated-home"
mkdir -p "$ISOLATED_HOME"
printf 'export PATH=/usr/bin:/bin\n' > "$ISOLATED_HOME/.zshrc"
if err=$(env -u AGENTMAIL_API_KEY HOME="$ISOLATED_HOME" PATH="$FAKEBIN:$BASE_PATH" FAKE_CURL_LOG="$LOG" \
  "$HELPER" get --message msg_abc123 2>&1); then
  fail "get must fail when the API key cannot be resolved"
fi
assert_contains "$err" "could not resolve" "a missing key must fail with a clear message"
assert_absent "$LOG" "a missing key must never invoke curl at all"
pass "a missing key fails loudly without ever invoking curl"

# --- a non-2xx response fails loudly with the status and body ----------------
H="$TMP_ROOT/http-failure"; mkdir -p "$H"
FAKEBIN=$(make_fake_curl "$H")
LOG="$H/curl.log"
if err=$(PATH="$FAKEBIN:$BASE_PATH" AGENTMAIL_API_KEY=am_test_secret_6 FAKE_CURL_LOG="$LOG" \
  FAKE_RESPONSE_CODE=404 FAKE_RESPONSE_BODY='{"error":"message not found"}' \
  "$HELPER" get --message msg_missing 2>&1); then
  fail "get must fail on a non-2xx response (a read must never fail silently)"
fi
assert_contains "$err" "404" "a failure must report the HTTP status"
assert_contains "$err" "message not found" "a failure must report the response body"
pass "a non-2xx response fails loudly with the status and body"

printf 'all fm-agentmail-read tests passed\n'
