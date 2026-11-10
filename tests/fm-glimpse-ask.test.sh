#!/usr/bin/env bash
# Behavior test for bin/fm-glimpse-ask.sh: gating, mute, and the answered /
# dismissed / timeout outcomes, driven through a stub glimpseui module so no
# native window is opened. The real window is exercised by the manual demo.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$ROOT/bin/fm-glimpse-ask.sh"
TD=$(fm_test_tmproot fm-glimpse-ask) || exit 1
mkdir -p "$TD/home/config" "$TD/home/state" "$TD/mod/src"
cat > "$TD/mod/package.json" <<'JSON'
{"name":"glimpseui","type":"module","main":"src/glimpse.mjs","exports":{".":"./src/glimpse.mjs"}}
JSON
# Stub: STUB_MODE = click:<n> | text:<string> | close | silent | error | throw. Emits after the window "opens".
# The last stub-received html/options are written to $STUB_LOG when set.
cat > "$TD/mod/src/glimpse.mjs" <<'JS'
import { EventEmitter } from 'node:events';
import { writeFileSync } from 'node:fs';
export function open(html, opts) {
  if (!opts.hidden && process.env.STUB_MODE === 'throw') throw new Error('native binary cannot run');
  if (!opts.hidden && process.env.STUB_LOG) writeFileSync(process.env.STUB_LOG, JSON.stringify({ html, opts }));
  const w = new EventEmitter();
  w.close = () => {};
  setTimeout(() => {
    if (opts.hidden) { w.emit('ready', { screen: { visibleX: 0, visibleY: 0, visibleWidth: 1000, visibleHeight: 800 } }); return; }
    const m = process.env.STUB_MODE || 'silent';
    if (m.startsWith('click:')) w.emit('message', { i: Number(m.slice(6)) });
    else if (m.startsWith('text:')) w.emit('message', { text: m.slice(5) });
    else if (m === 'close') w.emit('closed');
    else if (m === 'error') w.emit('error', new Error('stub native failure'));
  }, 20);
  return w;
}
JS

run() {  # <stub-mode> [env...] -- args ; sets OUT and RC
  local mode=$1; shift
  OUT=$(env STUB_MODE="$mode" FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/mod" "$@" 2>/dev/null); RC=$?
}

test_default_off_opens_nothing() {
  run click:0 "$ASK" --demo
  assert_equals 10 "$RC" "exit code"
  assert_equals "" "$OUT" "stdout"
  pass "popup is off by default (exit 10, no stdout)"
}
test_env_enables_and_click_answers() {
  run click:1 FM_GLIMPSE_ASK=1 "$ASK" --demo
  assert_equals 0 "$RC" "exit code"
  assert_equals "No" "$OUT" "stdout"
  pass "enabled click prints the chosen option"
}
test_config_flag_enables() {
  echo on > "$TD/home/config/glimpse-ask"
  run click:2 "$ASK" --demo
  rm -f "$TD/home/config/glimpse-ask"
  assert_equals 0 "$RC" "exit code"
  assert_equals "Not now" "$OUT" "stdout"
  pass "config/glimpse-ask enables the popup"
}
test_mute_beats_enable() {
  touch "$TD/home/state/glimpse-ask.mute"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --demo
  rm -f "$TD/home/state/glimpse-ask.mute"
  assert_equals 10 "$RC" "exit code"
  assert_equals "" "$OUT" "stdout"
  run click:0 FM_GLIMPSE_ASK=1 FM_GLIMPSE_ASK_MUTE=1 "$ASK" --demo
  assert_equals 10 "$RC" "exit code"
  pass "mute suppresses the popup even when enabled"
}
test_dismissed_is_not_a_pick() {
  run close FM_GLIMPSE_ASK=1 "$ASK" --demo
  assert_equals 11 "$RC" "exit code"
  assert_equals "" "$OUT" "stdout"
  run close FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals '{"outcome":"dismissed","answer":null}' "$OUT" "stdout"
  pass "closing without a click is a distinct dismissed outcome"
}
test_timeout() {
  run silent FM_GLIMPSE_ASK=1 "$ASK" --timeout 1 --demo
  assert_equals 12 "$RC" "exit code"
  assert_equals "" "$OUT" "stdout"
  pass "no click before the timeout exits 12"
}
test_json_answer_and_usage() {
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals '{"outcome":"answered","answer":"Yes"}' "$OUT" "stdout"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "only a prompt"
  assert_equals 2 "$RC" "exit code"
  pass "json output and usage refusal"
}
test_json_shape_every_outcome() {
  run click:2 FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals '{"outcome":"answered","answer":"Not now"}' "$OUT" "answered"
  run close FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals '{"outcome":"dismissed","answer":null}' "$OUT" "dismissed"
  run silent FM_GLIMPSE_ASK=1 "$ASK" --json --timeout 1 --demo
  assert_equals '{"outcome":"timeout","answer":null}' "$OUT" "timeout"
  assert_equals 12 "$RC" "timeout exit"
  run click:0 "$ASK" --json --demo
  assert_equals '{"outcome":"off","answer":null}' "$OUT" "off"
  assert_equals 10 "$RC" "off exit"
  run click:0 FM_GLIMPSE_ASK=1 FM_GLIMPSE_ASK_MUTE=1 "$ASK" --json --demo
  assert_equals '{"outcome":"muted","answer":null}' "$OUT" "muted"
  assert_equals 10 "$RC" "muted exit"
  pass "--json carries a stable {outcome, answer} object for every outcome"
}
test_caller_pattern() {
  local ans pick rc
  ans=$(STUB_MODE=click:1 FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/mod" FM_GLIMPSE_ASK=1 "$ASK" --json --timeout 5 "Merge it?" "Ship it" "Hold on" 2>/dev/null); rc=$?
  assert_equals 0 "$rc" "exit code"
  pick=$(printf '%s' "$ans" | sed -n 's/.*"answer":"\([^"]*\)".*/\1/p')
  assert_equals "Hold on" "$pick" "parsed answer"
  ans=$(STUB_MODE=close FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/mod" FM_GLIMPSE_ASK=1 "$ASK" --json --timeout 5 "Merge it?" "Ship it" "Hold on" 2>/dev/null); rc=$?
  assert_not_equals 0 "$rc" "dismissed must be non-zero so the caller falls back to text"
  pass "documented caller pattern: exit 0 yields the answer, non-zero falls back"
}
test_multi_option_labels() {
  run click:4 FM_GLIMPSE_ASK=1 "$ASK" "Pick a path" "Option A (fast)" "Option B: slow & safe" "C <html>" "D \"quoted\"" "E it's"
  assert_equals 0 "$RC" "exit code"
  assert_equals "E it's" "$OUT" "last of five"
  run click:1 FM_GLIMPSE_ASK=1 "$ASK" "Pick a path" "Option A (fast)" "Option B: slow & safe" "C <html>"
  assert_equals "Option B: slow & safe" "$OUT" "label with spaces and ampersand"
  run click:3 FM_GLIMPSE_ASK=1 "$ASK" --json "Pick" "one" "two" "three" "four"
  assert_equals '{"outcome":"answered","answer":"four"}' "$OUT" "json 4th"
  pass "multi-option labels render and return the exact clicked label"
}
test_option_count_bounds() {
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "q" "only"
  assert_equals 2 "$RC" "one option"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "q" a b c d e f
  assert_equals 2 "$RC" "six options"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "q" a a
  assert_equals 2 "$RC" "duplicate options"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "q" a " "
  assert_equals 2 "$RC" "blank option"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" "q" a b --primary 3
  assert_equals 2 "$RC" "primary out of range"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --json "q" a
  assert_equals "" "$OUT" "usage prints nothing on stdout"
  run click:4 FM_GLIMPSE_ASK=1 "$ASK" "q" a b c d e
  assert_equals 0 "$RC" "five options ok"
  pass "2-5 distinct non-empty options enforced; usage exits 2 with no stdout"
}
test_odd_prompts_never_crash() {
  local long odd
  long=$(printf 'word %.0s' $(seq 1 600))
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "$long" "Yes" "No"
  assert_equals 0 "$RC" "long prompt exit"
  assert_equals "Yes" "$OUT" "long prompt answer"
  assert_contains "$(cat "$TD/log.json")" '"height":480' "tall prompt height is clamped"
  odd=$'multi\nline <script>alert(1)</script> "q" \'s & \\ $(rm -rf x) `x`'
  run click:1 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "$odd" "Yes" "No"
  assert_equals 0 "$RC" "odd prompt exit"
  assert_equals "No" "$OUT" "odd prompt answer"
  assert_not_contains "$(cat "$TD/log.json")" '<script>alert' "prompt is HTML-escaped"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" -- "--not-a-flag" "Yes" "No"
  assert_equals 0 "$RC" "flag-like prompt after --"
  pass "long, odd, and flag-like prompts neither crash nor corrupt the answer"
}
test_small_unobtrusive_window() {
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "Merge?" "Yes" "No"
  local log; log=$(cat "$TD/log.json")
  assert_contains "$log" '"floating":true' "floating"
  assert_contains "$log" '"noDock":true' "no dock icon"
  assert_contains "$log" '"frameless":true' "frameless"
  assert_contains "$log" '"width":400' "compact width for a short prompt"
  assert_contains "$log" '"x":576' "bottom-right x (1000-400-24)"
  assert_contains "$log" '"y":24' "bottom margin"
  assert_contains "$log" '#066AFE' "blueprint accent"
  pass "window is small, floating, dockless, bottom-right, blueprint-styled"
}
test_long_prompt_gets_wide_roomy_window() {
  local title='Fleet Memory: bigger model (mpnet) did NOT win back the paraphrase query & cost 5.4x more. Next move?'
  local opt='Try the pipeline fix first (union pools + query expansion)'
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "$title" "$opt" "Ship the bigger model anyway" "Not now"
  assert_equals 0 "$RC" "long real-world prompt exit"
  assert_equals "$opt" "$OUT" "long label returned exactly"
  local log; log=$(cat "$TD/log.json")
  assert_contains "$log" '"width":540' "wide window for a long title and long labels"
  assert_contains "$log" '"x":436' "bottom-right x (1000-540-24)"
  assert_contains "$log" 'class=\"row stack\"' "long labels stack one per line"
  assert_not_contains "$log" '"height":150' "height grows past the minimum"
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "Merge PR?" "Yes" "No"
  assert_not_contains "$(cat "$TD/log.json")" 'row stack' "short labels stay on one compact row"
  pass "long titles and labels get a wider, stacked, taller window; short ones stay compact"
}
test_freetext_outcome() {
  run text:"why not wait a day?" FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals 14 "$RC" "freetext exit"
  assert_equals '{"outcome":"freetext","answer":"why not wait a day?"}' "$OUT" "freetext json"
  run text:"  padded & <b>quoted</b> \"x\"  " FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals '{"outcome":"freetext","answer":"padded & <b>quoted</b> \"x\""}' "$OUT" "trimmed, escaped json"
  run text:"a question" FM_GLIMPSE_ASK=1 "$ASK" --demo
  assert_equals 14 "$RC" "plain exit"
  assert_equals "FREETEXT: a question" "$OUT" "plain mode prefix"
  run text:"Yes" FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals 14 "$RC" "typing a preset's label is still free text"
  assert_equals '{"outcome":"freetext","answer":"Yes"}' "$OUT" "label-lookalike stays freetext"
  run text:"   " FM_GLIMPSE_ASK=1 "$ASK" --json --timeout 1 --demo
  assert_equals 12 "$RC" "blank text is ignored (times out)"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals 0 "$RC" "preset pick still exits 0"
  assert_equals '{"outcome":"answered","answer":"Yes"}' "$OUT" "preset pick unchanged"
  pass "free text exits 14 with outcome freetext, distinct from a preset pick"
}
test_freetext_caller_pattern() {
  local ans rc msg
  ans=$(STUB_MODE="text:hold on, one question" FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/mod" FM_GLIMPSE_ASK=1 "$ASK" --json --timeout 5 "Merge it?" "Ship it" "Hold on" 2>/dev/null); rc=$?
  msg=""
  case "$rc" in
    0)  msg="PICK" ;;
    14) msg=$(printf '%s' "$ans" | sed -n 's/.*"answer":"\([^"]*\)".*/\1/p') ;;
  esac
  assert_equals "hold on, one question" "$msg" "caller branches free text off exit 14"
  pass "documented caller pattern: exit 14 yields the free-form message"
}
test_free_text_ui_present() {
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "Merge?" "Yes" "No"
  local log; log=$(cat "$TD/log.json")
  assert_contains "$log" 'type=\"text\"' "text input rendered"
  assert_contains "$log" 'or type a comment / question / other' "escape-hatch placeholder"
  assert_contains "$log" '>Send<' "send button"
  assert_not_contains "$log" 'autofocus' "keys 1-5 stay live until the captain clicks the field"
  assert_contains "$log" '"width":400' "short prompt keeps the compact width"
  assert_not_contains "$log" '"height":150' "height accounts for the extra row"
  pass "every popup renders the free-text field below the options"
}
test_live_vs_demo_mode() {
  local live demo
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" "Merge?" "Yes" "No"
  live=$(cat "$TD/log.json")
  assert_contains "$live" 'live decision' "default is the live look"
  assert_not_contains "$live" 'not a real decision' "live has no demo ribbon"
  assert_not_contains "$live" 'class=\"demo\"' "live body is not demo-styled"
  assert_not_contains "$live" '(DEMO)' "live window title is plain"
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" --demo
  demo=$(cat "$TD/log.json")
  assert_contains "$demo" 'not a real decision' "--demo shows the ribbon"
  assert_contains "$demo" 'class=\"demo\"' "--demo body is demo-styled"
  assert_contains "$demo" '(DEMO)' "--demo window title is marked"
  assert_not_contains "$demo" 'live decision' "demo never reads as live"
  for flags in "--mode demo" "--test"; do
    # shellcheck disable=SC2086
    run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" $flags "Merge?" "Yes" "No"
    assert_contains "$(cat "$TD/log.json")" 'not a real decision' "$flags marks a custom prompt as demo"
  done
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" --mode live "Merge?" "Yes" "No"
  assert_contains "$(cat "$TD/log.json")" 'live decision' "--mode live is the live look"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --mode bogus "Merge?" "Yes" "No"
  assert_equals 2 "$RC" "bad mode is a usage error"
  assert_contains "$("$ASK" --help)" "--mode demo" "mode flag documented"
  pass "demo and live popups render distinguishably; default is live"
}
test_demo_mode_keeps_contracts() {
  run click:1 FM_GLIMPSE_ASK=1 "$ASK" --json --mode demo "Merge?" "Yes" "No"
  assert_equals '{"outcome":"answered","answer":"No"}' "$OUT" "demo pick json"
  run text:"why" FM_GLIMPSE_ASK=1 "$ASK" --json --test "Merge?" "Yes" "No"
  assert_equals 14 "$RC" "demo freetext exit"
  assert_equals '{"outcome":"freetext","answer":"why"}' "$OUT" "demo freetext json"
  run close FM_GLIMPSE_ASK=1 "$ASK" --json --test "Merge?" "Yes" "No"
  assert_equals 11 "$RC" "demo dismissed exit"
  run silent FM_GLIMPSE_ASK=1 "$ASK" --json --test --timeout 1 "Merge?" "Yes" "No"
  assert_equals 12 "$RC" "demo timeout exit"
  run click:0 "$ASK" --json --test "Merge?" "Yes" "No"
  assert_equals 10 "$RC" "demo still gated by the toggle"
  run click:0 FM_GLIMPSE_ASK=1 FM_GLIMPSE_ASK_MUTE=1 "$ASK" --json --test "Merge?" "Yes" "No"
  assert_equals '{"outcome":"muted","answer":null}' "$OUT" "demo still honors mute"
  run click:0 FM_GLIMPSE_ASK=1 STUB_LOG="$TD/log.json" "$ASK" --test "Merge?" "Yes" "No"
  assert_contains "$(cat "$TD/log.json")" 'type=\"text\"' "demo keeps the free-text field"
  assert_contains "$(cat "$TD/log.json")" '"width":400' "demo keeps the width logic"
  pass "demo mode is visual only: exits, json, gating, mute, free text unchanged"
}
test_unavailable_paths() {
  run throw FM_GLIMPSE_ASK=1 "$ASK" --json --demo
  assert_equals 13 "$RC" "open throws"
  assert_equals '{"outcome":"unavailable","answer":null}' "$OUT" "open throws json"
  run error FM_GLIMPSE_ASK=1 "$ASK" --demo
  assert_equals 13 "$RC" "native error event"
  assert_equals "" "$OUT" "native error stdout"
  OUT=$(FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/nope" FM_GLIMPSE_ASK=1 PATH="/usr/bin:/bin" "$ASK" --json --demo 2>/dev/null); RC=$?
  assert_equals 13 "$RC" "module gone"
  assert_equals '{"outcome":"unavailable","answer":null}' "$OUT" "module gone json"
  pass "unavailable glimpseui exits 13 cleanly without hanging"
}
test_timeout_default_and_override() {
  run silent FM_GLIMPSE_ASK=1 FM_GLIMPSE_ASK_TIMEOUT=1 "$ASK" --demo
  assert_equals 12 "$RC" "env timeout"
  run silent FM_GLIMPSE_ASK=1 FM_GLIMPSE_ASK_TIMEOUT=60 "$ASK" --timeout 1 --demo
  assert_equals 12 "$RC" "flag beats env"
  run silent FM_GLIMPSE_ASK=1 "$ASK" --timeout -3 --demo
  assert_equals 2 "$RC" "negative timeout"
  assert_contains "$("$ASK" --help)" "default 120" "default documented"
  pass "default timeout is 120s and overridable by flag and env"
}
test_status_and_gating_precedence() {
  echo off > "$TD/home/config/glimpse-ask"
  run click:0 "$ASK" --demo
  assert_equals 10 "$RC" "config off"
  run click:0 FM_GLIMPSE_ASK=1 "$ASK" --demo
  assert_equals 0 "$RC" "env on beats config off"
  run click:0 FM_GLIMPSE_ASK=0 "$ASK" --demo
  assert_equals 10 "$RC" "env off"
  echo on > "$TD/home/config/glimpse-ask"
  run click:0 FM_GLIMPSE_ASK=0 "$ASK" --demo
  rm -f "$TD/home/config/glimpse-ask"
  assert_equals 10 "$RC" "env off beats config on"
  touch "$TD/home/state/glimpse-ask.mute"
  run click:0 "$ASK" --status
  rm -f "$TD/home/state/glimpse-ask.mute"
  assert_contains "$OUT" "muted: state/glimpse-ask.mute" "status shows mute"
  pass "toggle precedence and mute reporting"
}
test_missing_module() {
  OUT=$(FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/nope" FM_GLIMPSE_ASK=1 PATH="/usr/bin:/bin" "$ASK" --demo 2>/dev/null); RC=$?
  assert_equals 13 "$RC" "exit code"
  pass "missing glimpseui reports unavailable"
}

fm_test_run test_default_off_opens_nothing test_env_enables_and_click_answers \
  test_config_flag_enables test_mute_beats_enable test_dismissed_is_not_a_pick \
  test_timeout test_json_answer_and_usage test_missing_module \
  test_json_shape_every_outcome test_caller_pattern test_multi_option_labels \
  test_option_count_bounds test_odd_prompts_never_crash test_small_unobtrusive_window \
  test_long_prompt_gets_wide_roomy_window test_freetext_outcome test_freetext_caller_pattern test_free_text_ui_present \
  test_live_vs_demo_mode test_demo_mode_keeps_contracts \
  test_unavailable_paths test_timeout_default_and_override test_status_and_gating_precedence
