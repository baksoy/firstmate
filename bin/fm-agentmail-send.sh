#!/usr/bin/env bash
# Send and reply to email through the AgentMail REST API - the outbound half
# of firstmate's AgentMail channel. bin/fm-procevent-agentmail.sh and
# bin/fm-agentmail-ws-listen.mjs own the inbound half (they wake firstmate on
# a new inbound email); this script is what firstmate calls to answer one.
#
# Usage:
#   fm-agentmail-send.sh send --to <addr> --subject <s> (--text <t> | --stdin) [--inbox <addr>]
#   fm-agentmail-send.sh reply --message <message_id> [--thread <thread_id>] (--text <t> | --stdin) [--inbox <addr>]
#
# Outbound email to real people is high-consent. This script has no recipient
# allow/block policy and no autonomous-send loop of its own - it sends
# exactly what it is told to send. Firstmate's own operating rules (AGENTS.md)
# decide WHEN a reply is warranted and to whom; this is only the transport.
#
# API: https://api.agentmail.to/v0 (override with $AGENTMAIL_API_BASE, tests
# only). Auth: "Authorization: Bearer <key>" header - the key is NEVER placed
# in argv, a file other than a 0600 curl header temp file, or any printed or
# logged line. <inbox> defaults to baksoy-firstmate@agentmail.to. Key
# resolution matches bin/fm-procevent-agentmail.sh exactly: prefer the ambient
# $AGENTMAIL_API_KEY, else fall back to the first am_... token in ~/.zshrc.
#
# send   POST /v0/inboxes/<inbox>/messages/send {to, subject, text} ->
#        {message_id, thread_id}. Verified live 2026-08-21.
# reply  POST /v0/inboxes/<inbox>/messages/<message_id>/reply {text} ->
#        {message_id, thread_id}. Verified against
#        https://docs.agentmail.to/api-reference/inboxes/messages/reply.md on
#        2026-08-21: AgentMail's reply endpoint targets a message_id in the
#        URL path - there is no thread-based reply endpoint - so --message is
#        required. --thread is accepted only so a caller can pass through the
#        inbound wake line's "thread=" token without stripping it first; it is
#        never sent to AgentMail.
#
# Every send/reply carries a fresh random Idempotency-Key header (per
# https://docs.agentmail.to/idempotency.md) so a retried call cannot duplicate
# a message.
#
# On success, prints one line: "message_id=<id> thread_id=<id>". On any HTTP
# failure, prints the status code and response body to stderr and exits
# nonzero - a send is an explicit action, so unlike the inbound listener it
# must never fail silently.
set -u

DEFAULT_INBOX="baksoy-firstmate@agentmail.to"
API_BASE="${AGENTMAIL_API_BASE:-https://api.agentmail.to}"

die() { printf 'fm-agentmail-send: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'EOF' >&2
usage: fm-agentmail-send.sh send --to <addr> --subject <s> (--text <t> | --stdin) [--inbox <addr>]
       fm-agentmail-send.sh reply --message <message_id> [--thread <thread_id>] (--text <t> | --stdin) [--inbox <addr>]
EOF
}

help() {
  cat <<'EOF'
usage: fm-agentmail-send.sh send --to <addr> --subject <s> (--text <t> | --stdin) [--inbox <addr>]
       fm-agentmail-send.sh reply --message <message_id> [--thread <thread_id>] (--text <t> | --stdin) [--inbox <addr>]

send
  --to <addr>       Recipient email address. Required.
  --subject <s>      Message subject. Required.
  --text <t>         Message body. Required unless --stdin is given.
  --stdin            Read the message body from stdin instead of --text.
  --inbox <addr>     Sending inbox. Default: baksoy-firstmate@agentmail.to.

reply
  --message <id>     The message_id to reply to. Required - AgentMail's reply
                      endpoint targets a message_id, not a thread_id.
  --thread <id>      Optional. Accepted for caller bookkeeping only (e.g. to
                      pass through the inbound wake line's thread token
                      unstripped); never sent to AgentMail.
  --text <t>         Reply body. Required unless --stdin is given.
  --stdin            Read the reply body from stdin instead of --text.
  --inbox <addr>     Replying inbox. Default: baksoy-firstmate@agentmail.to.

On success: prints "message_id=<id> thread_id=<id>" and exits 0.
On failure: prints the HTTP status and response body to stderr and exits nonzero.
EOF
}

# Resolve the AgentMail API key exactly the way
# bin/fm-procevent-agentmail.sh's resolve_api_key does: prefer the ambient
# environment, else the first am_... token in ~/.zshrc. Never echoes,
# logs, or writes the key anywhere; returns nonzero when unresolvable.
resolve_api_key() {
  local key
  if [ -n "${AGENTMAIL_API_KEY:-}" ]; then
    printf '%s\n' "$AGENTMAIL_API_KEY"
    return 0
  fi
  key=$(grep -oE 'am_[A-Za-z0-9_]+' "$HOME/.zshrc" 2>/dev/null | head -1)
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# 32 hex chars of /dev/urandom entropy, prefixed for readability. Portable
# across macOS and Linux (no uuidgen dependency) and always within the
# Idempotency-Key charset (A-Z a-z 0-9 - . _ ~).
random_idempotency_key() {
  local hex
  hex=$(LC_ALL=C od -An -v -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$hex" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#hex}" -eq 32 ] || return 1
  printf 'fm-send-%s\n' "$hex"
}

TMP_FILES=()
cleanup_tmp_files() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup_tmp_files EXIT

make_tmp_file() {  # <var-name>
  local file
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-agentmail-send.XXXXXX") || return 1
  TMP_FILES+=("$file")
  printf -v "$1" '%s' "$file"
}

# Write the bearer header to a 0600 temp file so curl's `-H "@file"` form
# keeps the key out of argv entirely - the same idiom as
# bin/fm-x-lib.sh:fmx_auth_header_file.
auth_header_file() {  # <key> <out-var-name>
  local key=$1 out_file
  case "$key" in *$'\n'*|*$'\r'*) return 1 ;; esac
  make_tmp_file out_file || return 1
  printf 'Authorization: Bearer %s\n' "$key" > "$out_file" || return 1
  printf -v "$2" '%s' "$out_file"
}

url_encode() {  # <value>
  jq -rn --arg v "$1" '$v|@uri'
}

post_json() {  # <url> <payload-file> <idempotency-key> <auth-header-file> <body-file>
  local url=$1 payload_file=$2 idem=$3 auth_file=$4 body_file=$5 code rc
  code=$(curl -m 30 -s -o "$body_file" -w '%{http_code}' \
    -X POST \
    -H "@$auth_file" \
    -H "Idempotency-Key: $idem" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload_file" \
    "$url" 2>/dev/null)
  rc=$?
  [ "$rc" = 0 ] || return 4
  printf '%s\n' "$code"
}

# report_failure <status> <body-file>: fail loudly, per contract - a send
# never fails silently.
report_failure() {
  printf 'fm-agentmail-send: request failed: HTTP %s\n' "$1" >&2
  if [ -s "$2" ]; then
    cat "$2" >&2
  fi
  exit 1
}

send_or_reply() {  # <url> <payload-file>
  local url=$1 payload_file=$2 key idem auth_file body_file code message_id thread_id
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  if ! key=$(resolve_api_key) || [ -z "$key" ]; then
    die "could not resolve AGENTMAIL_API_KEY (checked the environment and ~/.zshrc)"
  fi
  idem=$(random_idempotency_key) || die "could not generate an Idempotency-Key"
  auth_header_file "$key" auth_file || die "could not prepare the auth header"
  make_tmp_file body_file || die "could not prepare a response temp file"
  code=$(post_json "$url" "$payload_file" "$idem" "$auth_file" "$body_file")
  case $? in
    0) : ;;
    4) die "request to AgentMail failed (transport error)" ;;
    *) die "request to AgentMail failed" ;;
  esac
  case "$code" in
    2[0-9][0-9])
      message_id=$(jq -r '.message_id // ""' "$body_file" 2>/dev/null)
      thread_id=$(jq -r '.thread_id // ""' "$body_file" 2>/dev/null)
      [ -n "$message_id" ] && [ -n "$thread_id" ] \
        || die "AgentMail returned HTTP $code with no message_id/thread_id in the body"
      printf 'message_id=%s thread_id=%s\n' "$message_id" "$thread_id"
      ;;
    *) report_failure "$code" "$body_file" ;;
  esac
}

cmd_send() {
  local to='' subject='' text='' use_stdin=0 inbox="$DEFAULT_INBOX" payload_file url
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to) shift; [ "$#" -ge 1 ] || die "missing value for --to"; to=$1 ;;
      --subject) shift; [ "$#" -ge 1 ] || die "missing value for --subject"; subject=$1 ;;
      --text) shift; [ "$#" -ge 1 ] || die "missing value for --text"; text=$1 ;;
      --stdin) use_stdin=1 ;;
      --inbox) shift; [ "$#" -ge 1 ] || die "missing value for --inbox"; inbox=$1 ;;
      -h|--help) help; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [ -n "$to" ] || die "--to is required"
  [ -n "$subject" ] || die "--subject is required"
  if [ "$use_stdin" = 1 ]; then
    [ -z "$text" ] || die "--text and --stdin are mutually exclusive"
    text=$(cat)
  fi
  [ -n "$text" ] || die "--text or --stdin is required"

  make_tmp_file payload_file || die "could not prepare a request temp file"
  jq -n --arg to "$to" --arg subject "$subject" --arg text "$text" \
    '{to:$to, subject:$subject, text:$text}' > "$payload_file" \
    || die "could not build the request payload"

  url="$API_BASE/v0/inboxes/$(url_encode "$inbox")/messages/send"
  send_or_reply "$url" "$payload_file"
}

cmd_reply() {
  local message_id='' thread_id='' text='' use_stdin=0 inbox="$DEFAULT_INBOX" payload_file url
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; [ "$#" -ge 1 ] || die "missing value for --message"; message_id=$1 ;;
      --thread) shift; [ "$#" -ge 1 ] || die "missing value for --thread"; thread_id=$1 ;;
      --text) shift; [ "$#" -ge 1 ] || die "missing value for --text"; text=$1 ;;
      --stdin) use_stdin=1 ;;
      --inbox) shift; [ "$#" -ge 1 ] || die "missing value for --inbox"; inbox=$1 ;;
      -h|--help) help; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  : "$thread_id"  # accepted for caller bookkeeping only; never sent to AgentMail.
  [ -n "$message_id" ] || die "--message is required (AgentMail replies target a message_id)"
  if [ "$use_stdin" = 1 ]; then
    [ -z "$text" ] || die "--text and --stdin are mutually exclusive"
    text=$(cat)
  fi
  [ -n "$text" ] || die "--text or --stdin is required"

  make_tmp_file payload_file || die "could not prepare a request temp file"
  jq -n --arg text "$text" '{text:$text}' > "$payload_file" \
    || die "could not build the request payload"

  url="$API_BASE/v0/inboxes/$(url_encode "$inbox")/messages/$(url_encode "$message_id")/reply"
  send_or_reply "$url" "$payload_file"
}

case "${1-}" in
  send) shift; cmd_send "$@" ;;
  reply) shift; cmd_reply "$@" ;;
  -h|--help|help) help; exit 0 ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
