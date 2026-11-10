#!/usr/bin/env bash
# fm-glimpse-ask.sh - OPT-IN click-to-answer DECISION ENTRY POINT (glimpseui).
#
# A small native window (WKWebView, via the glimpseui npm package) with a prompt
# and one button per option. The clicked option is returned to the caller and the
# exit code says what happened, so firstmate can branch on it. It is the opposite
# of a lavish page: a quick "answer if needed" prompt. Call it ONLY at a moment
# the turn really needs the captain's decision; when nothing is needed, do not
# call it. Nothing in the supervision or turn-end flow calls it - firstmate (the
# model) invokes it deliberately.
#
# RECOMMENDED CALL (machine-read path is --json; its keys are stable):
#   ans=$(bin/fm-glimpse-ask.sh --json --timeout 120 "Merge PR #12?" "Yes" "No" "Not now"); rc=$?
#   if [ "$rc" -eq 0 ]; then
#     pick=$(printf '%s' "$ans" | jq -r .answer)    # the captain's reply, the exact clicked label
#   else
#     : # ANY non-zero exit (off, muted, dismissed, timeout, unavailable, usage):
#       # no answer was given - ask the same question in plain text instead.
#   fi
# Never treat a non-zero exit as a pick, and never infer an answer from a dismissed
# or timed-out window. Plain mode (no --json) prints just the chosen label on
# stdout for exit 0 and nothing otherwise.
#
# Usage:
#   fm-glimpse-ask.sh [--title T] [--timeout SEC] [--position CORNER] [--x N --y N]
#                     [--primary N] [--json] [--] <prompt> <option> [<option>...]
#   fm-glimpse-ask.sh --demo        sample "Merge PR? [Yes] [No] [Not now]"
#   fm-glimpse-ask.sh --status      print whether the popup is enabled/muted/installed
# A prompt (any text, newlines allowed) and two to five distinct, non-empty
# options. Keys 1-5 pick an option, Esc dismisses. --primary N highlights option N
# (default 1). --timeout SEC waits that long (0 = forever); default 120, overridable
# per call or via FM_GLIMPSE_ASK_TIMEOUT. A long prompt scrolls inside the window.
#
# Exit codes (the contract; branch on these):
#   0   answered      the chosen option is the only stdout line
#   10  off           popup disabled or muted; no window was opened
#   11  dismissed     window closed without an answer; NOT a pick
#   12  timeout       no click within --timeout; window closed
#   13  unavailable   node/glimpseui missing or its native binary cannot run
#   2   usage         bad arguments (nothing is printed to stdout)
# --json prints exactly one line on stdout for every outcome except usage:
#   {"outcome":"answered|off|muted|dismissed|timeout|unavailable","answer":"<label>"|null}
# "answer" is non-null only for outcome "answered" (exit 0). Diagnostics go to stderr.
#
# Enable (default OFF - an explicit opt-in per call or per home):
#   FM_GLIMPSE_ASK=1                    for one command, or
#   echo on > "$FM_HOME/config/glimpse-ask"    persistently (echo off to disable)
# Mute (screen-share suppression; beats every enable, keeps working while on):
#   FM_GLIMPSE_ASK_MUTE=1               for one command, or
#   touch "$FM_HOME/state/glimpse-ask.mute"    until you rm it
# Placement: bottom-right of the main screen by default (--position
# bottom-right|bottom-left|top-right|top-left|center, or --x/--y in macOS
# bottom-left-origin screen points). The window floats, has no dock icon, and
# DOES take focus when it appears.
#
# Install (macOS, Xcode Command Line Tools for swiftc; node >= 18):
#   npm install --prefix "$FM_HOME/data/glimpse-ask" glimpseui
# The postinstall compiles the Swift binary. If swiftc dies with "Operation not
# permitted" on a module cache, or "SDK is not supported by the compiler",
# run the install unsandboxed and point the caches somewhere writable:
#   CLANG_MODULE_CACHE_PATH=$TMPDIR/c SWIFT_MODULECACHE_PATH=$TMPDIR/s npm install ...
# A CLT whose SDK and compiler versions disagree needs a CLT update.
# Module lookup order: $FM_GLIMPSE_MODULE (package directory), then
# $FM_HOME/data/glimpse-ask/node_modules/glimpseui, then the global npm root.
#
# Environment: FM_HOME (default: this checkout), FM_GLIMPSE_ASK, FM_GLIMPSE_ASK_MUTE,
# FM_GLIMPSE_ASK_TIMEOUT, FM_GLIMPSE_MODULE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

JSON=0
for a in "$@"; do
  [ "$a" = "--" ] && break
  [ "$a" = "--json" ] && JSON=1
done

# bail <exit> <outcome> <stderr message>: stop before the window opens, honoring --json.
bail() {
  [ "$JSON" -eq 1 ] && printf '{"outcome":"%s","answer":null}\n' "$2"
  echo "fm-glimpse-ask: $3" >&2
  exit "$1"
}

truthy() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|on|true|yes) return 0 ;; *) return 1 ;; esac; }

enabled_reason() {  # prints on|off and the source
  if [ -n "${FM_GLIMPSE_ASK:-}" ]; then
    truthy "$FM_GLIMPSE_ASK" && echo "on (FM_GLIMPSE_ASK)" || echo "off (FM_GLIMPSE_ASK)"
  elif [ -f "$CONFIG/glimpse-ask" ] && truthy "$(head -n1 "$CONFIG/glimpse-ask")"; then
    echo "on (config/glimpse-ask)"
  else
    echo "off (default)"
  fi
}

muted_reason() {
  if truthy "${FM_GLIMPSE_ASK_MUTE:-}"; then echo "FM_GLIMPSE_ASK_MUTE"
  elif [ -e "$STATE/glimpse-ask.mute" ]; then echo "state/glimpse-ask.mute"
  else return 1
  fi
}

resolve_module() {
  local c
  for c in "${FM_GLIMPSE_MODULE:-}" "$DATA/glimpse-ask/node_modules/glimpseui" "$(npm root -g 2>/dev/null)/glimpseui"; do
    [ -n "$c" ] && [ -f "$c/package.json" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  --status)
    echo "enabled: $(enabled_reason)"
    echo "muted: $(muted_reason || echo no)"
    echo "glimpseui: $(resolve_module || echo 'not found')"
    exit 0 ;;
esac

reason=$(enabled_reason)
case "$reason" in off*) bail 10 off "popup is $reason; set FM_GLIMPSE_ASK=1 to try it" ;; esac
if mute=$(muted_reason); then
  bail 10 muted "popup is muted ($mute); no window opened"
fi

command -v node >/dev/null 2>&1 || bail 13 unavailable "node is required"

if module=$(resolve_module); then
  FM_GLIMPSE_MODULE="$module"; export FM_GLIMPSE_MODULE
else
  bail 13 unavailable "glimpseui not found; see the install notes in $0"
fi
exec node "$SCRIPT_DIR/fm-glimpse-ask.mjs" "$@"
