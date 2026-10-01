#!/usr/bin/env bash
# tests/fm-secondmate-model-reconcile.test.sh - portable regression for
# bin/fm-secondmate-model-reconcile.sh and its pure logic in
# bin/fm-secondmate-model-lib.sh.
#
# The pure half pins pin/display normalization, the --model argv reading, the
# footer-region bound, the drift verdict table, and the report vocabulary.
# The process half runs REAL stand-in processes named claude in a REAL tmux
# server on a private socket, with no harness and no credentials, and drives
# the command end to end: --check over a registry of mates whose launch argv
# and rendered footer are pushed apart on purpose, and --apply over a drifted
# mate whose stand-in exits only on a typed /exit, plus drifted mates the
# repair must refuse: one mid-turn and one with pending composer text. The live Claude Code
# counterpart is tests/fm-secondmate-model-reconcile-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-secondmate-model-lib.sh
. "$ROOT/bin/fm-secondmate-model-lib.sh"

# --- pure logic --------------------------------------------------------------

key_is() {  # <input> <expected-key>
  local got
  got=$(fm_sm_model_key "$1") || got=UNREADABLE
  assert_equals "$2" "$got" "model key of '$1'"
}
key_is 'us.anthropic.claude-sonnet-5-5[1m]' 'sonnet 5.5'
key_is 'claude-sonnet-5' 'sonnet 5'
key_is 'claude-sonnet-4-20250514' 'sonnet 4'
key_is 'claude-opus-4-1-20250805' 'opus 4.1'
key_is 'anthropic.claude-haiku-4-5-20251001-v1:0' 'haiku 4.5'
key_is 'Opus 5.5 (1M context)' 'opus 5.5'
key_is 'Sonnet 5.5' 'sonnet 5.5'
key_is 'sonnet' 'sonnet'
key_is 'opus[1m]' 'opus'
key_is 'gpt-5.5' 'UNREADABLE'
pass "pin ids and display names normalize to one family/version key, ignoring provider, context, and date suffixes"

fm_sm_model_keys_match 'sonnet 5.5' 'sonnet 5.5' || fail "identical keys must match"
fm_sm_model_keys_match 'sonnet' 'sonnet 5.5' || fail "a bare alias pin must accept any version of its family"
! fm_sm_model_keys_match 'sonnet 5.5' 'sonnet' || fail "a versioned pin must not accept an observed bare alias"
! fm_sm_model_keys_match 'sonnet 5' 'sonnet 5.5' || fail "sonnet 5 and sonnet 5.5 are different models"
! fm_sm_model_keys_match 'sonnet' 'opus 5.5' || fail "an alias must not match another family"
pass "key matching separates versions and lets only a bare alias pin accept its family"

assert_equals 'us.anthropic.claude-sonnet-5-5[1m]' \
  "$(fm_sm_model_argv_model 'claude --model us.anthropic.claude-sonnet-5-5[1m] --effort xhigh')" \
  "--model <id> argv reading keeps the [1m] suffix verbatim"
assert_equals 'opus' "$(fm_sm_model_argv_model '/usr/local/bin/claude --model=opus')" "--model=<id> argv reading"
if fm_sm_model_argv_model 'claude --dangerously-skip-permissions' >/dev/null; then
  fail "a launch with no --model must read as absent"
fi
pass "the launch argv yields the --model token verbatim, or absent"

SCREEN=$(printf '%s\n' \
  '⏺ The fleet pins Sonnet 5.5 for every mate.' \
  '────────────────────────────────────────' \
  '❯ ' \
  '────────────────────────────────────────' \
  '  🤖 Opus 5.5 (1M context) ● high | 📂 firstmate' \
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)')
assert_equals 'Opus 5.5' "$(fm_sm_model_footer_model "$SCREEN")" \
  "the footer model is read below the composer's bottom rule, not from conversation text above it"
if fm_sm_model_footer_model "$(printf 'no rules here\nSonnet 5.5\n')" >/dev/null; then
  fail "a screen without a composer rule has no readable footer"
fi
pass "the footer reading is bounded to the status-line region"

verdict_is() {  # <argv> <footer> <expected>
  assert_equals "$3" "$(fm_sm_model_verdict "$1" "$2")" "verdict for argv=$1 footer=$2"
}
verdict_is match match on-pin
verdict_is match unreadable on-pin
verdict_is unreadable match on-pin
verdict_is absent match on-pin
verdict_is match mismatch drifted
verdict_is mismatch match drifted
verdict_is absent mismatch drifted
verdict_is absent unreadable drifted
verdict_is unreadable mismatch drifted
verdict_is unreadable unreadable unknown
pass "the verdict treats any positive off-pin signal as drift and nothing readable as unknown"

assert_equals 'repaired: alpha - x' "$(fm_sm_model_report_line repaired alpha x)" "report line shape"
assert_equals 'summary: 3 checked, 1 on-pin, 1 drifted, 0 repaired, 0 failed, 1 skipped, 0 unpinned, 0 unknown' \
  "$(fm_sm_model_summary_line 3 1 1 0 0 1 0 0)" "summary line shape"
pass "report and summary lines keep their documented shape"

# --- real processes in a private tmux server --------------------------------

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: no C compiler for the claude stand-in"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-model-reconcile-$$"
LAB=$(fm_test_tmproot fm-model-reconcile) || fail "could not create a temp root"
SES=mlab
trap '"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; fm_test_cleanup' EXIT

# bin/backends/tmux.sh calls bare tmux; the shim keeps every call on the
# private socket so the host's real sessions are never touched.
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# The stand-in is a real native process reached through a symlink named
# claude, so the kernel's process table carries the name and argv a real
# launch would. It exits only when a line reading /exit arrives on its tty,
# and appends every line it receives to $STANDIN_LOG.
printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' '#include <string.h>' '#include <unistd.h>' \
  'int main(void){char b[256];const char*p=getenv("STANDIN_LOG");while(fgets(b,sizeof b,stdin)){b[strcspn(b,"\n")]=0;if(p){FILE*f=fopen(p,"a");if(f){fprintf(f,"%s\n",b);fclose(f);}}if(strcmp(b,"/exit")==0)return 0;}for(;;)sleep(1);}' \
  > "$LAB/standin.c"
"$CC_BIN" -o "$LAB/bin/standin" "$LAB/standin.c" 2>/dev/null || { echo "skip: could not build the claude stand-in"; exit 0; }
ln -s "$LAB/bin/standin" "$LAB/bin/claude"

PIN='us.anthropic.claude-sonnet-5-5[1m]'
HOME_DIR="$LAB/home"

# screen <footer-model>: a Claude-shaped viewport whose status line names
# <footer-model>, with a different model quoted in the conversation above and
# the cursor parked in the composer, so typed input echoes there.
screen_cmd() {  # <footer-model|-> -> printf command
  if [ "$1" = - ]; then
    printf "printf '%%s\\\\n' 'conversation mentions Opus 5.5'"
  else
    printf "printf '%%s\\\\n' 'conversation mentions Haiku 4.5' '────────────────────' '❯ ' '────────────────────' '  🤖 %s ● high'; printf '\\\\033[3A\\\\033[2C'" "$1"
  fi
}

# launch <id> <footer-model|-> [claude-args...]: a tmux window fm-<id> running
# the stand-in under a shell, the way a spawn leaves a live mate.
launch() {
  local id=$1 footer=$2
  shift 2
  local cmd args='' a
  for a in "$@"; do args="$args '$a'"; done
  cmd="$(screen_cmd "$footer"); STANDIN_LOG='$LAB/$id.lines' '$LAB/bin/claude'$args"
  if tmux has-session -t "$SES" 2>/dev/null; then
    tmux new-window -d -t "$SES" -n "fm-$id" "$cmd"
  else
    tmux new-session -d -s "$SES" -n "fm-$id" -x 160 -y 40 "$cmd"
  fi
}

add_mate() {  # <id> <pin-line|-> [remote]
  local id=$1 pin=$2 remote=${3:-}
  mkdir -p "$LAB/$id-home"
  if [ -n "$remote" ]; then
    printf '%s\n' "- $id - remote test mate (host: elsewhere; root: /srv/fm; home: /srv/fm/$id; scope: tests; projects: ; added 2026-10-01)" >> "$HOME_DIR/data/secondmates.md"
  else
    printf '%s\n' "- $id - test mate (home: $LAB/$id-home; scope: tests; projects: ; added 2026-10-01)" >> "$HOME_DIR/data/secondmates.md"
  fi
  [ "$pin" = - ] || printf '%s\n' "$pin" > "$HOME_DIR/config/secondmate-harness.$id"
  {
    echo "window=$SES:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$LAB/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "model=$PIN"
    echo "effort=default"
    echo "backend=tmux"
    echo "home=$LAB/$id-home"
  } > "$HOME_DIR/state/$id.meta"
}

printf 'claude\n' > "$HOME_DIR/config/secondmate-harness"
: > "$HOME_DIR/data/secondmates.md"
add_mate alpha "claude $PIN"
add_mate bravo "claude $PIN"
add_mate charlie "claude $PIN xhigh"
add_mate delta "claude $PIN"
add_mate echo -
add_mate foxtrot "claude $PIN" remote
add_mate golf "codex gpt-5.5"
add_mate hotel "claude default xhigh"
add_mate india "claude $PIN"
add_mate juliet "claude $PIN"
add_mate kilo "claude $PIN"

launch alpha 'Sonnet 5.5' --model "$PIN"
launch bravo 'Opus 5.5 (1M context)'
launch charlie 'Opus 5.5 (1M context)' --model "$PIN"
launch delta - --model "$PIN"
launch echo 'Opus 5.5'
launch hotel 'Opus 5.5'
launch india 'Opus 5.5'
launch juliet 'Opus 5.5'
launch kilo - --model sonnet

# The stand-in's kernel name is its real file (standin on macOS), so liveness
# is read through the backend's own agent classifier, which also reads argv0.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
agent_up() {  # <id>
  [ "$(fm_backend_agent_state tmux "$SES:fm-$1")" = alive ]
}
wait_alive() {  # <id>
  local i=0
  while [ "$i" -lt 50 ]; do
    agent_up "$1" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
for id in alpha bravo charlie delta echo hotel india juliet kilo; do
  wait_alive "$id" || fail "stand-in for $id never became the pane's foreground process"
done

reconcile() {
  FM_HOME="$HOME_DIR" FM_SECONDMATE_MODEL_POLL=1 "$ROOT/bin/fm-secondmate-model-reconcile.sh" "$@"
}

rc=0
out=$(reconcile --check 2>&1) || rc=$?
assert_equals 3 "$rc" "--check exits 3 while a mate is drifted"
assert_contains "$out" "on-pin: alpha - pin $PIN; live argv: --model $PIN (match); footer: Sonnet 5.5 (match)" "argv and footer both on the pin"
assert_contains "$out" "drifted: bravo - pin $PIN; live argv: launched without --model; footer: Opus 5.5 (mismatch)" "a launch that lost its --model is drift"
assert_contains "$out" "drifted: charlie - pin $PIN; live argv: --model $PIN (match); footer: Opus 5.5 (mismatch)" "an in-session switch the argv cannot see is drift"
assert_contains "$out" "on-pin: delta - pin $PIN; live argv: --model $PIN (match); footer: unreadable" "argv alone carries the verdict when no footer renders"
assert_contains "$out" "unpinned: echo - its pin names no model" "a pin without a model is reported, not judged"
assert_contains "$out" "skipped: foxtrot - remote mate" "a remote mate is skipped"
assert_contains "$out" "skipped: golf - pinned harness is 'codex'" "a non-claude pin is skipped"
assert_contains "$out" "unpinned: hotel - its pin names no model" "a 'default' model pin passes no --model, so it is unpinned, never drift"
assert_contains "$out" "drifted: kilo - pin $PIN; live argv: --model sonnet (mismatch); footer: unreadable" "a bare alias launch does not satisfy a versioned pin"
assert_contains "$out" "summary: 11 checked, 2 on-pin, 5 drifted, 0 repaired, 0 failed, 2 skipped, 2 unpinned, 0 unknown" "check summary"
# Divergence guard: charlie's two signals genuinely disagree, so the case
# cannot pass vacuously by losing one of them.
case "$out" in *"charlie - pin $PIN; live argv: --model $PIN (match); footer: Opus 5.5 (mismatch)"*) ;; *) fail "charlie's signals were not driven apart" ;; esac
agent_up bravo || fail "--check must leave a drifted mate running"
pass "--check reads argv and footer from real processes and reports each mate"

out=$(reconcile --check alpha 2>&1) || fail "--check alpha should exit 0 for an on-pin mate: $out"
assert_contains "$out" "summary: 1 checked, 1 on-pin" "an id filter restricts the pass"
rc=0
reconcile --check nosuchmate >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" "an unregistered id is refused"
pass "an id filter restricts the pass to registered mates"

# The relaunch seam records its argv and starts the pinned stand-in in the
# same window name, the way fm-spawn republishes the endpoint.
cat > "$LAB/bin/spawn-stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/spawn.log"
id=\$1; model=
# Prove the repair holds the lease and the liveness lock across the relaunch.
lease=\$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lease.sh" check "\$id" 2>/dev/null) || lease=none
lock=free; [ -e "$HOME_DIR/state/.secondmate-liveness-\$id.lock" ] && lock=held
printf '%s lease=%s lock=%s\n' "\$id" "\${lease%% *}" "\$lock" >> "$LAB/held.log"
while [ "\$#" -gt 0 ]; do [ "\$1" = --model ] && model=\$2; shift; done
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SES" -n "fm-\$id" \
  "printf '%s\\\\n' '────────────────────' '❯ ' '────────────────────' '  🤖 Sonnet 5.5 ● high'; '$LAB/bin/claude' --model '\$model'"
SH
chmod +x "$LAB/bin/spawn-stub"
alpha_pid=$(tmux display-message -p -t "$SES:fm-alpha" '#{pane_pid}')

out=$(FM_SECONDMATE_MODEL_SPAWN="$LAB/bin/spawn-stub" FM_SECONDMATE_MODEL_CONFIRM_WAIT=10 \
  reconcile --apply alpha bravo charlie 2>&1) || fail "--apply should exit 0 once every drifted mate is repaired: $out"
assert_contains "$out" "on-pin: alpha" "an on-pin mate is left alone under --apply"
assert_contains "$out" "repaired: bravo - was: pin $PIN; live argv: launched without --model; footer: Opus 5.5 (mismatch); now: pin $PIN; live argv: --model $PIN (match); footer: Sonnet 5.5 (match)" "bravo repaired"
assert_contains "$out" "repaired: charlie" "charlie repaired"
assert_contains "$out" "summary: 3 checked, 1 on-pin, 0 drifted, 2 repaired, 0 failed" "apply summary"
log=$(cat "$LAB/spawn.log")
assert_contains "$log" "bravo $LAB/bravo-home --secondmate --harness claude --model $PIN" "relaunch passes the pin verbatim with the mate home"
assert_not_contains "$(grep '^bravo ' "$LAB/spawn.log")" "--effort" "a pin without effort passes none"
assert_contains "$(grep '^charlie ' "$LAB/spawn.log")" "--model $PIN --effort xhigh" "a pinned effort is passed"
assert_not_contains "$log" "alpha" "an on-pin mate is never relaunched"
assert_equals "$alpha_pid" "$(tmux display-message -p -t "$SES:fm-alpha" '#{pane_pid}')" "the on-pin mate keeps its process"
assert_contains "$(cat "$LAB/held.log")" "bravo lease=main lock=held" "the relaunch runs under this actor's lease and the liveness lock"
assert_contains "$(cat "$LAB/held.log")" "charlie lease=main lock=held" "each repair holds its own lease and lock"
[ ! -e "$HOME_DIR/state/.secondmate-liveness-bravo.lock" ] || fail "the liveness lock taken for the repair must be released"
[ ! -e "$HOME_DIR/state/.lease-bravo" ] || fail "the lease taken for the repair must be released"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lease.sh" check bravo 2>&1) && fail "bravo must be unleased after the repair: $out"
out=$(reconcile --check bravo charlie 2>&1) || fail "a repaired mate must check on-pin afterwards: $out"
pass "--apply exits a drifted stand-in with a typed /exit, relaunches it on the pin, and leaves on-pin mates untouched"

# A mid-turn mate and a mate with pending composer text are refused before any
# input reaches them; the pending text survives to be submitted as typed.
"$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" india >/dev/null || fail "could not arm india's busy record"
tmux send-keys -t "$SES:fm-juliet" -l 'draft steer'
: > "$LAB/spawn.log"
rc=0
out=$(FM_SECONDMATE_MODEL_SPAWN="$LAB/bin/spawn-stub" FM_SECONDMATE_MODEL_CONFIRM_WAIT=2 FM_SECONDMATE_MODEL_EXIT_WAIT=2 \
  reconcile --apply india juliet 2>&1) || rc=$?
assert_equals 3 "$rc" "--apply exits 3 while a refused mate is still drifted"
assert_contains "$out" "drifted: india - not repaired: the agent is mid-turn" "a busy tmux mate is refused"
assert_contains "$out" "drifted: juliet - not repaired: its composer is 'pending', not proven empty" "pending composer text refuses the repair"
assert_contains "$out" "summary: 2 checked, 0 on-pin, 2 drifted, 0 repaired, 0 failed" "refusal summary"
agent_up india || fail "a mid-turn mate must keep running"
agent_up juliet || fail "a mate with pending composer text must keep running"
[ ! -s "$LAB/spawn.log" ] || fail "a refused mate must never be relaunched: $(cat "$LAB/spawn.log")"
[ ! -e "$LAB/india.lines" ] || fail "nothing may be typed into a mid-turn mate: $(cat "$LAB/india.lines")"
[ ! -e "$HOME_DIR/state/.secondmate-liveness-juliet.lock" ] || fail "a refused repair must release the liveness lock"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lease.sh" check juliet 2>&1) && fail "juliet must be unleased after the refusal: $out"
tmux send-keys -t "$SES:fm-juliet" Enter
i=0
while [ ! -s "$LAB/juliet.lines" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_equals 'draft steer' "$(cat "$LAB/juliet.lines" 2>/dev/null)" "the pending composer text is preserved intact"
pass "--apply refuses a mid-turn mate and preserves pending composer text instead of clearing it"
