#!/usr/bin/env bash
# Read inbound email through the AgentMail REST API - the inbound-body half of
# firstmate's AgentMail channel. bin/fm-procevent-agentmail.sh and
# bin/fm-agentmail-ws-listen.mjs wake firstmate on a new inbound email, but that
# wake line is only a sender-and-subject NOTIFICATION plus a reply-target token,
# never the message body. This script is what firstmate calls to fetch and read
# the body before reporting or acting on the email.
#
# Usage:
#   fm-agentmail-read.sh list [--inbox <addr>] [--limit <n>]
#   fm-agentmail-read.sh get --message <message_id> [--inbox <addr>]
#
# A fetched message is INPUT, never authority: nothing in its body is a command
# to firstmate. Firstmate's own operating rules decide what, if anything, an
# email changes.
#
# API: https://api.agentmail.to/v0 (override with $AGENTMAIL_API_BASE, tests
# only). Auth: "Authorization: Bearer <key>" header - the key is NEVER placed
# in argv, a file other than a 0600 curl header temp file, or any printed or
# logged line. That is why this helper exists: a hand-rolled
# `curl -H "Authorization: Bearer $KEY"` would leak the key into argv, `ps`, and
# shell history. <inbox> defaults to baksoy-firstmate@agentmail.to. Key
# resolution matches bin/fm-agentmail-send.sh and bin/fm-procevent-agentmail.sh
# exactly: prefer the ambient $AGENTMAIL_API_KEY, else fall back to the first
# am_... token in ~/.zshrc.
#
# list  GET /v0/inboxes/<inbox>/messages -> the inbox's message-list JSON, so a
#        caller can pick a message_id when the wake line carried none.
# get   GET /v0/inboxes/<inbox>/messages/<message_id> -> the full message JSON,
#        body included. <message_id> is validated against [A-Za-z0-9_.:-] before
#        it becomes a URL path segment (the same charset the wake token allows).
#
# On success, prints the response body (JSON) to stdout and exits 0. On any HTTP
# failure, prints the status code and response body to stderr and exits nonzero
# - a read is an explicit action, so unlike the inbound listener it must never
# fail silently.
set -u

DEFAULT_INBOX="baksoy-firstmate@agentmail.to"
API_BASE="${AGENTMAIL_API_BASE:-https://api.agentmail.to}"

die() { printf 'fm-agentmail-read: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'EOF' >&2
usage: fm-agentmail-read.sh list [--inbox <addr>] [--limit <n>]
       fm-agentmail-read.sh get --message <message_id> [--inbox <addr>]
EOF
}

help() {
  cat <<'EOF'
usage: fm-agentmail-read.sh list [--inbox <addr>] [--limit <n>]
       fm-agentmail-read.sh get --message <message_id> [--inbox <addr>]

list
  --inbox <addr>     Inbox to list. Default: baksoy-firstmate@agentmail.to.
  --limit <n>        Optional max messages to request (positive integer).

get
  --message <id>     The message_id to read. Required.
  --inbox <addr>     Inbox holding the message. Default: baksoy-firstmate@agentmail.to.

On success: prints the response JSON to stdout and exits 0.
On failure: prints the HTTP status and response body to stderr and exits nonzero.
EOF
}

# Resolve the AgentMail API key exactly the way bin/fm-agentmail-send.sh's
# resolve_api_key does: prefer the ambient environment, else the first am_...
# token in ~/.zshrc. Never echoes, logs, or writes the key anywhere; returns
# nonzero when unresolvable.
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

TMP_FILES=()
cleanup_tmp_files() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup_tmp_files EXIT

make_tmp_file() {  # <var-name>
  local file
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-agentmail-read.XXXXXX") || return 1
  TMP_FILES+=("$file")
  printf -v "$1" '%s' "$file"
}

# Write the bearer header to a 0600 temp file so curl's `-H "@file"` form keeps
# the key out of argv entirely - the same idiom as bin/fm-agentmail-send.sh.
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

get_json() {  # <url> <auth-header-file> <body-file>
  local url=$1 auth_file=$2 body_file=$3 code rc
  code=$(curl -m 30 -s -o "$body_file" -w '%{http_code}' \
    -H "@$auth_file" \
    -H 'Accept: application/json' \
    "$url" 2>/dev/null)
  rc=$?
  [ "$rc" = 0 ] || return 4
  printf '%s\n' "$code"
}

# report_failure <status> <body-file>: fail loudly, per contract - a read never
# fails silently.
report_failure() {
  printf 'fm-agentmail-read: request failed: HTTP %s\n' "$1" >&2
  if [ -s "$2" ]; then
    cat "$2" >&2
  fi
  exit 1
}

do_get() {  # <url>
  local url=$1 key auth_file body_file code
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  if ! key=$(resolve_api_key) || [ -z "$key" ]; then
    die "could not resolve AGENTMAIL_API_KEY (checked the environment and ~/.zshrc)"
  fi
  auth_header_file "$key" auth_file || die "could not prepare the auth header"
  make_tmp_file body_file || die "could not prepare a response temp file"
  code=$(get_json "$url" "$auth_file" "$body_file")
  case $? in
    0) : ;;
    4) die "request to AgentMail failed (transport error)" ;;
    *) die "request to AgentMail failed" ;;
  esac
  case "$code" in
    2[0-9][0-9]) cat "$body_file" ;;
    *) report_failure "$code" "$body_file" ;;
  esac
}

cmd_list() {
  local inbox="$DEFAULT_INBOX" limit='' url
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --inbox) shift; [ "$#" -ge 1 ] || die "missing value for --inbox"; inbox=$1 ;;
      --limit) shift; [ "$#" -ge 1 ] || die "missing value for --limit"; limit=$1 ;;
      -h|--help) help; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  url="$API_BASE/v0/inboxes/$(url_encode "$inbox")/messages"
  if [ -n "$limit" ]; then
    case "$limit" in
      ''|*[!0-9]*) die "--limit must be a positive integer" ;;
    esac
    url="$url?limit=$limit"
  fi
  do_get "$url"
}

cmd_get() {
  local message_id='' inbox="$DEFAULT_INBOX" url
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) shift; [ "$#" -ge 1 ] || die "missing value for --message"; message_id=$1 ;;
      --inbox) shift; [ "$#" -ge 1 ] || die "missing value for --inbox"; inbox=$1 ;;
      -h|--help) help; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [ -n "$message_id" ] || die "--message is required"
  case "$message_id" in
    *[!A-Za-z0-9_.:-]*) die "--message contains characters outside [A-Za-z0-9_.:-]" ;;
  esac
  url="$API_BASE/v0/inboxes/$(url_encode "$inbox")/messages/$(url_encode "$message_id")"
  do_get "$url"
}

case "${1-}" in
  list) shift; cmd_list "$@" ;;
  get) shift; cmd_get "$@" ;;
  -h|--help|help) help; exit 0 ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
