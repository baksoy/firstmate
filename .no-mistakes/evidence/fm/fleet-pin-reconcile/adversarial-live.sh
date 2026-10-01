#!/usr/bin/env bash
# Adversarial live drive of bin/fm-secondmate-model-reconcile.sh against REAL
# Claude Code sessions in a disposable lab home on a private tmux socket.
# Run from the gate worktree: bash <this> <worktree-root>
set -u
ROOT=$1
EV=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/bin/fm-secondmate-model-lib.sh"
CLAUDE_BIN=$(command -v claude) || { echo "claude missing"; exit 1; }
PIN='us.anthropic.claude-sonnet-5-5[1m]'

TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-adv.XXXXXX")
LAB="$TMP/home"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
export TMUX_TMPDIR="$TMUX_DIR"
unset TMUX TMUX_PANE
SES=adv
cleanup() {
  tmux kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

log() { printf '%s\n' "$*" | tee -a "$EV/adversarial-live.log"; }
: > "$EV/adversarial-live.log"
PASS=0 FAIL=0
check() {  # <name> <cond-rc>
  if [ "$2" = 0 ]; then log "PASS - $1"; PASS=$((PASS+1)); else log "FAIL - $1"; FAIL=$((FAIL+1)); fi
}

# Settings files: footer prints the model name; "nofoot" prints no model.
printf '%s\n' '{"feedbackDrafts":"off","statusLine":{"type":"command","command":"jq -r .model.display_name"}}' > "$TMP/s-footer.json"
printf '%s\n' '{"feedbackDrafts":"off","statusLine":{"type":"command","command":"echo lab-status"}}' > "$TMP/s-nofoot.json"
# busy mate: real Claude lifecycle hooks write the firstmate busy record,
# wired the way bin/fm-spawn.sh wires them.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" busy --state idle --source claude-hook --event stop) || { echo "arm failed"; exit 1; }
BE="$ROOT/bin/fm-busy-event.sh"
jq -n --arg sub "'$BE' apply '$LAB/state' busy busy --gen $GEN --source claude-hook --event user-prompt-submit 2>/dev/null || true" \
      --arg stop "'$BE' apply '$LAB/state' busy idle --gen $GEN --source claude-hook --event stop 2>/dev/null || true" '
  {feedbackDrafts:"off", statusLine:{type:"command",command:"jq -r .model.display_name"},
   hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$sub}]}],
          Stop:[{hooks:[{type:"command",command:$stop}]}]}}' > "$TMP/s-busy.json"

launcher() {  # <settings-file> [model] -> path of a launcher script
  local f="$TMP/launch.$RANDOM"
  { printf '#!/usr/bin/env bash\nexec env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 %q --dangerously-skip-permissions --settings %q' "$CLAUDE_BIN" "$1"
    [ -z "${2:-}" ] || printf ' --model %q' "$2"; printf '\n'; } > "$f"
  chmod +x "$f"; printf '%s' "$f"
}
launch() {  # <id> <settings> [model]
  local id=$1 cmd; cmd=$(launcher "$2" "${3:-}")
  mkdir -p "$TMP/$id-home"
  if tmux has-session -t "$SES" 2>/dev/null; then
    tmux new-window -d -t "$SES:" -n "fm-$id" -c "$TMP/$id-home" "$cmd"
  else
    tmux new-session -d -s "$SES" -n "fm-$id" -x 160 -y 45 -c "$TMP/$id-home" "$cmd"
  fi
}
wait_ready() {  # <id> [need-footer]
  local i=0 t=0 s
  while [ $i -lt 90 ]; do
    s=$(tmux capture-pane -p -t "$SES:fm-$1" 2>/dev/null || true)
    case "$s" in
      *'Yes, I trust this folder'*) [ $t = 1 ] || { t=1; tmux send-keys -t "$SES:fm-$1" Down Enter; } ;;
      *'bypass permissions on'*)
        if [ -z "${2:-}" ] || fm_sm_model_footer_model "$s" >/dev/null; then return 0; fi ;;
    esac
    i=$((i+1)); sleep 1
  done
  printf '%s\n' "$s" >&2; return 1
}

: > "$LAB/data/secondmates.md"
printf 'claude\n' > "$LAB/config/secondmate-harness"
reg() {  # <id> <pin-line>
  printf '%s\n' "- $1 - adversarial lab mate (home: $TMP/$1-home; scope: tests; projects: ; added 2026-10-01)" >> "$LAB/data/secondmates.md"
  printf '%s\n' "$2" > "$LAB/config/secondmate-harness.$1"
  printf '%s\n' "window=$SES:fm-$1" "endpoint_task_id=$1" "worktree=$TMP/$1-home" "harness=claude" \
    "kind=secondmate" "mode=secondmate" "model=$PIN" "effort=default" "backend=tmux" "home=$TMP/$1-home" > "$LAB/state/$1.meta"
}
# Registry order = check order: busy first so it is read while mid-turn.
reg busy        "claude $PIN"
reg draft       "claude $PIN"
reg alias       "claude $PIN"
reg aliasnofoot "claude $PIN"
reg aliaspin    "claude sonnet"
reg dflt        "claude default xhigh"

launch busy        "$TMP/s-busy.json"
launch draft       "$TMP/s-footer.json"
launch alias       "$TMP/s-footer.json" sonnet
launch aliasnofoot "$TMP/s-nofoot.json" sonnet
launch aliaspin    "$TMP/s-footer.json" "$PIN"
launch dflt        "$TMP/s-footer.json"
for id in busy draft alias aliaspin dflt; do wait_ready "$id" footer || { log "FAIL - $id never became ready"; exit 1; }; done
wait_ready aliasnofoot || { log "FAIL - aliasnofoot never became ready"; exit 1; }

reconcile() { FM_HOME="$LAB" FM_SECONDMATE_MODEL_POLL=1 "$ROOT/bin/fm-secondmate-model-reconcile.sh" "$@"; }

log "## Phase 1: --check (Claude Code $("$CLAUDE_BIN" --version | head -1))"
rc=0; out=$(reconcile --check 2>&1) || rc=$?
log "$out"; log "exit=$rc"
check "check exits 3 when drift exists" "$([ $rc = 3 ]; echo $?)"
has() { case "$out" in *"$1"*) return 0 ;; esac; return 1; }
has "drifted: alias - pin $PIN; live argv: --model sonnet (mismatch); footer: Sonnet 5 (mismatch)"; check "versioned pin: alias-launched session (--model sonnet, footer Sonnet 5) is drifted" $?
has "drifted: aliasnofoot - pin $PIN; live argv: --model sonnet (mismatch); footer: unreadable"; check "versioned pin: alias-launched session with unreadable footer is drifted, not a silent pass" $?
has "on-pin: aliaspin - pin sonnet; live argv: --model $PIN (match); footer: Sonnet 5.5 (match)"; check "alias pin 'sonnet' accepts a session running Sonnet 5.5" $?
has "unpinned: dflt - its pin names no model"; check "pin 'claude default xhigh' reports unpinned, never drifted" $?
has "drifted: draft - pin $PIN; live argv: launched without --model; footer: Opus"; check "bare (resurrect-like) session is drifted from live evidence" $?

# Phase 2 setup: a real mid-turn agent, and a captain's unsubmitted draft.
tmux send-keys -t "$SES:fm-busy" -l 'Use the Bash tool to run exactly: sleep 75 ; then reply with the single word done.'
sleep 1; tmux send-keys -t "$SES:fm-busy" Enter
i=0; while [ $i -lt 60 ]; do grep -q 'busy' "$LAB/state/busy.busy-state" 2>/dev/null && break; i=$((i+1)); sleep 1; done
log "busy record after submit: $(cat "$LAB/state/busy.busy-state" 2>/dev/null)"
DRAFT='LAB-DRAFT captain unsent steer keep me'
tmux send-keys -t "$SES:fm-draft" -l "$DRAFT"
sleep 2
draft_pid=$(tmux display-message -p -t "$SES:fm-draft" '#{pane_pid}')
busy_pid=$(tmux display-message -p -t "$SES:fm-busy" '#{pane_pid}')
aliaspin_pid=$(tmux display-message -p -t "$SES:fm-aliaspin" '#{pane_pid}')
dflt_pid=$(tmux display-message -p -t "$SES:fm-dflt" '#{pane_pid}')
tmux capture-pane -p -t "$SES:fm-draft" > "$EV/draft-pane-before-apply.txt"

# Relaunch seam: start the pinned session in the recorded window, recording argv.
cat > "$TMP/spawn-stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/spawn.log"
id=\$1; model=
while [ "\$#" -gt 0 ]; do [ "\$1" = --model ] && model=\$2; shift; done
cmd=\$(printf '#!/usr/bin/env bash\nexec env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false %q --dangerously-skip-permissions --settings %q --model %q\n' '$CLAUDE_BIN' '$TMP/s-footer.json' "\$model")
printf '%s' "\$cmd" > "$TMP/relaunch.\$id"; chmod +x "$TMP/relaunch.\$id"
TMUX_TMPDIR='$TMUX_DIR' tmux new-window -d -t '$SES:' -n "fm-\$id" -c "$TMP/\$id-home" "$TMP/relaunch.\$id"
SH
chmod +x "$TMP/spawn-stub"
: > "$TMP/spawn.log"

log "## Phase 2: --apply while busy is mid-turn and draft holds unsent text"
rc=0; out=$(FM_SECONDMATE_MODEL_SPAWN="$TMP/spawn-stub" FM_SECONDMATE_MODEL_CONFIRM_WAIT=90 reconcile --apply 2>&1) || rc=$?
log "$out"; log "exit=$rc"; log "spawn.log:"; log "$(cat "$TMP/spawn.log")"
check "apply exits 3 while refused mates remain drifted" "$([ $rc = 3 ]; echo $?)"
has "drifted: busy - not repaired: the agent is mid-turn"; check "mid-turn real agent is refused (busy guard on tmux)" $?
has "drifted: draft - not repaired: its composer is 'pending'"; check "pending composer text refuses the repair" $?
has "repaired: alias - was: pin $PIN; live argv: --model sonnet (mismatch)"; check "alias-launched session repaired onto versioned pin" $?
has "repaired: aliasnofoot - "; check "alias-launched no-footer session repaired onto versioned pin" $?
grep -Fqx "alias $TMP/alias-home --secondmate --harness claude --model $PIN" "$TMP/spawn.log"; check "relaunch got the pin verbatim (alias)" $?
! grep -Eq '^(busy|draft|aliaspin|dflt) ' "$TMP/spawn.log"; check "busy/draft/on-pin/unpinned mates never relaunched" $?
[ "$(tmux display-message -p -t "$SES:fm-draft" '#{pane_pid}')" = "$draft_pid" ]; check "draft session kept its process" $?
[ "$(tmux display-message -p -t "$SES:fm-busy" '#{pane_pid}')" = "$busy_pid" ]; check "busy session kept its process" $?
[ "$(tmux display-message -p -t "$SES:fm-aliaspin" '#{pane_pid}')" = "$aliaspin_pid" ] && [ "$(tmux display-message -p -t "$SES:fm-dflt" '#{pane_pid}')" = "$dflt_pid" ]; check "on-pin and unpinned sessions kept their processes" $?
tmux capture-pane -p -t "$SES:fm-draft" > "$EV/draft-pane-after-apply.txt"
grep -Fq "$DRAFT" "$EV/draft-pane-after-apply.txt"; check "the captain's draft text is still in the composer after --apply" $?
for id in busy draft aliaspin dflt; do
  if [ "$(cat "$LAB/config/secondmate-harness.$id")" = "$(case $id in aliaspin) echo "claude sonnet";; dflt) echo "claude default xhigh";; *) echo "claude $PIN";; esac)" ]; then :; else log "pin file changed: $id"; FAIL=$((FAIL+1)); fi
done

log "## Phase 3: turn ends, captain clears draft, rerun --apply"
i=0; while [ $i -lt 150 ]; do grep -q ' idle \|idle' "$LAB/state/busy.busy-state" 2>/dev/null && ! grep -q 'state=busy\|^busy' "$LAB/state/busy.busy-state" && break; i=$((i+1)); sleep 1; done
sleep 3
log "busy record after turn: $(cat "$LAB/state/busy.busy-state" 2>/dev/null)"
tmux capture-pane -p -t "$SES:fm-busy" > "$EV/busy-pane-after-turn.txt"
tmux send-keys -t "$SES:fm-draft" C-u; sleep 2
: > "$TMP/spawn.log"
rc=0; out=$(FM_SECONDMATE_MODEL_SPAWN="$TMP/spawn-stub" FM_SECONDMATE_MODEL_CONFIRM_WAIT=90 reconcile --apply 2>&1) || rc=$?
log "$out"; log "exit=$rc"; log "spawn.log:"; log "$(cat "$TMP/spawn.log")"
check "rerun exits 0 once nothing is left drifted" "$([ $rc = 0 ]; echo $?)"
has "repaired: busy - "; check "busy mate repaired after its turn ended" $?
has "repaired: draft - "; check "draft mate repaired once composer is clear" $?
has "on-pin: alias - pin $PIN; live argv: --model $PIN (match); footer: Sonnet 5.5 (match)"; check "previously repaired alias mate now reads on-pin (Sonnet 5.5)" $?
rc=0; out=$(reconcile --check 2>&1) || rc=$?
log "## Final --check"; log "$out"; log "exit=$rc"
check "final --check exits 0" "$([ $rc = 0 ]; echo $?)"
log "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
