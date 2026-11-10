#!/usr/bin/env bash
# fm-glimpse-ask.sh - OPT-IN, experimental click-to-answer decision popup (glimpseui).
#
# A small native window (WKWebView, via the glimpseui npm package) with a prompt
# and one button per option. The clicked option is printed on stdout and the
# exit code says what happened, so a caller can branch on it. This is the
# opposite of a lavish page: a quick "answer if needed" prompt. Pop it ONLY when
# the turn really needs a decision; when nothing is needed, do not call it.
# It is a local trial: nothing in the supervision or turn-end flow calls it.
#
# Usage:
#   fm-glimpse-ask.sh [--title T] [--timeout SEC] [--position CORNER] [--x N --y N]
#                     [--primary N] [--json] [--] <prompt> <option> [<option>...]
#   fm-glimpse-ask.sh --demo        sample "Merge PR? [Yes] [No] [Not now]"
#   fm-glimpse-ask.sh --status      print whether the popup is enabled/muted/installed
# Two to six options. Keys 1-9 pick an option, Esc dismisses. --primary N
# highlights option N (default 1). --timeout 0 waits forever (default 120).
#
# Exit codes:
#   0   answered      the chosen option is the only stdout line
#   10  off           popup disabled or muted; no window was opened, no stdout
#   11  dismissed     window closed without an answer; NOT a pick
#   12  timeout       no click within --timeout; window closed
#   13  unavailable   glimpseui missing or its native binary cannot run
#   2   usage
# --json prints {"outcome":"answered|dismissed|timeout","answer":"..."} instead.
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
# FM_GLIMPSE_MODULE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

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
case "$reason" in off*) echo "fm-glimpse-ask: popup is $reason; set FM_GLIMPSE_ASK=1 to try it" >&2; exit 10 ;; esac
if mute=$(muted_reason); then
  echo "fm-glimpse-ask: popup is muted ($mute); no window opened" >&2
  exit 10
fi

command -v node >/dev/null 2>&1 || { echo "error: node is required" >&2; exit 13; }
if module=$(resolve_module); then
  FM_GLIMPSE_MODULE="$module"; export FM_GLIMPSE_MODULE
else
  echo "error: glimpseui not found; see the install notes in $0" >&2
  exit 13
fi
exec node "$SCRIPT_DIR/fm-glimpse-ask.mjs" "$@"
