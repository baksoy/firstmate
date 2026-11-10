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
# Stub: STUB_MODE = click:<n> | close | silent. Emits after the window "opens".
cat > "$TD/mod/src/glimpse.mjs" <<'JS'
import { EventEmitter } from 'node:events';
export function open(html, opts) {
  const w = new EventEmitter();
  w.close = () => {};
  setTimeout(() => {
    if (opts.hidden) { w.emit('ready', { screen: { visibleX: 0, visibleY: 0, visibleWidth: 1000, visibleHeight: 800 } }); return; }
    const m = process.env.STUB_MODE || 'silent';
    if (m.startsWith('click:')) w.emit('message', { i: Number(m.slice(6)) });
    else if (m === 'close') w.emit('closed');
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
  assert_equals '{"outcome":"dismissed"}' "$OUT" "stdout"
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
test_missing_module() {
  OUT=$(FM_HOME="$TD/home" FM_GLIMPSE_MODULE="$TD/nope" FM_GLIMPSE_ASK=1 PATH="/usr/bin:/bin" "$ASK" --demo 2>/dev/null); RC=$?
  assert_equals 13 "$RC" "exit code"
  pass "missing glimpseui reports unavailable"
}

fm_test_run test_default_off_opens_nothing test_env_enables_and_click_answers \
  test_config_flag_enables test_mute_beats_enable test_dismissed_is_not_a_pick \
  test_timeout test_json_answer_and_usage test_missing_module
