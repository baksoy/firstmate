#!/usr/bin/env bash
# AgentMail adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-agentmail.sh arm [<inbox>]
#   fm-procevent-agentmail.sh run <inbox>
#   fm-procevent-agentmail.sh terminal <result-file>
#   fm-procevent-agentmail.sh self-announcing
#   fm-procevent-agentmail.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-agentmail.sh source-id [<inbox>]
#   fm-procevent-agentmail.sh retire [<inbox>]
#
# Wakes firstmate the instant a new INBOUND email lands in an AgentMail inbox,
# over AgentMail's push WebSocket (bin/fm-agentmail-ws-listen.mjs) - never by
# polling. <inbox> defaults to baksoy-firstmate@agentmail.to.
#
# run    Resolves the API key fresh, then execs the listener with it in the
#        child's environment only - never in argv, a file, or a printed line.
#        Prefers the ambient $AGENTMAIL_API_KEY; falls back to the first
#        am_... token in ~/.zshrc. Exits nonzero with no output when the key
#        cannot be resolved, so the runner leaves the source armed for the
#        next reconcile instead of publishing a wake, rather than erroring
#        loudly in a loop. The listener itself blocks indefinitely, retrying a
#        transient disconnect with capped exponential backoff, until exactly
#        one new "message.received" event arrives; it then prints exactly one
#        line and exits 0.
# terminal   Always exits nonzero: a subscribed inbox never stops producing
#        mail, so this source stays armed forever (the same non-terminal
#        shape as Lavish's ongoing "feedback" outcome).
# self-announcing   Always exits 0. autohandle applies a captured result by
#        appending it straight to the durable wake queue as a `signal` (the
#        watcher's existing drain already surfaces it) and marks the result
#        handled itself, in-process, before this generation's runner claim is
#        released - never through a later external `handled` call while a
#        freshly reconciled runner for this same, still-armed, non-terminal
#        source could already hold the next claim.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

DEFAULT_INBOX="baksoy-firstmate@agentmail.to"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cmd_source_id() {
  local inbox=${1:-$DEFAULT_INBOX}
  [ "$#" -le 1 ] || usage
  case "$inbox" in *$'\n'*) die "inbox address cannot contain newlines" ;; esac
  if command -v shasum >/dev/null 2>&1; then
    printf 'agentmail-%s\n' "$(printf '%s' "$inbox" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'agentmail-%s\n' "$(printf '%s' "$inbox" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local inbox=${1:-$DEFAULT_INBOX} id
  [ "$#" -le 1 ] || usage
  id=$(cmd_source_id "$inbox") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register agentmail "$id" -- \
    "$SCRIPT_DIR/fm-procevent-agentmail.sh" run "$inbox" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'inbox: %s\n' "$inbox"
}

cmd_retire() {
  local inbox=${1:-$DEFAULT_INBOX} id
  [ "$#" -le 1 ] || usage
  id=$(cmd_source_id "$inbox") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Resolve the AgentMail API key exactly the way firstmate's other AgentMail use
# resolves it: prefer the ambient environment, else the first am_... token in
# ~/.zshrc. Prints nothing and returns nonzero when unresolvable - the key is
# never logged, echoed, or written to any file by this function or its caller.
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

cmd_run() {
  local inbox=${1:-$DEFAULT_INBOX} key
  [ "$#" -eq 1 ] || usage
  if ! key=$(resolve_api_key) || [ -z "$key" ]; then
    sleep "${FM_AGENTMAIL_KEY_FAIL_SLEEP:-5}"
    exit 1
  fi
  AGENTMAIL_API_KEY="$key" AGENTMAIL_INBOX="$inbox" \
    exec node "$SCRIPT_DIR/fm-agentmail-ws-listen.mjs"
}

cmd_terminal() {
  [ -n "${1:-}" ] || usage
  return 1
}

cmd_self_announcing() {
  [ "$#" -eq 0 ] || usage
  return 0
}

cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} line
  [ -n "$sid" ] && [ -n "$seq" ] && [ -n "$result" ] || usage
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file does not exist: $result"
  fm_procevent_is_handled "$STATE" "$sid" "$seq" && return 0
  line=$(head -1 "$result")
  [ -n "$line" ] || die "captured result is empty"
  fm_wake_append signal "procevent-agentmail:$sid:$seq" "$line" \
    || die "cannot append the durable wake"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq"
}

case "${1-}" in
  arm)             shift; cmd_arm "$@" ;;
  run)             shift; cmd_run "$@" ;;
  retire)          shift; cmd_retire "$@" ;;
  source-id)       shift; cmd_source_id "$@" ;;
  terminal)        shift; [ "$#" -eq 1 ] || usage; cmd_terminal "$@" ;;
  self-announcing) shift; cmd_self_announcing "$@" ;;
  autohandle)      shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
