#!/usr/bin/env bash
# Live guard for bin/fm-secondmate-model-reconcile.sh (live-harness-optin family).
#
# Both live readings the command trusts are surfaces Claude Code controls: the
# --model token in the launched process's argv and the model name its status
# line renders below the composer. A stub can only echo the assumption written
# into it, so this guard launches real Claude Code in an isolated tmux lab and
# requires the command to read both signals, tell a mate launched without its
# pin from one launched on it, and, under --apply, exit the drifted session
# with a typed /exit and prove the relaunch is on the pin. It fails naming the
# harness and version rather than degrading quietly.
#
# No prompt is ever submitted, but each run starts authenticated Claude Code
# sessions on the operator's account, so the guard is opt-in. Run it with
# FM_SECONDMATE_MODEL_LIVE=1 after a Claude Code upgrade and before trusting a
# refreshed docs/verification/runtime-backends.md "Second mate model
# reconcile" entry. The portable counterpart is
# tests/fm-secondmate-model-reconcile.test.sh.
#
# The status line is supplied with --settings so the footer always names the
# model regardless of the operator's own statusLine. The pin is chosen at run
# time to differ from the harness default this host actually launches, read
# from a bare session's own footer, so the drift case is real on any account;
# FM_SECONDMATE_MODEL_LIVE_PIN substitutes an exact fleet pin id.
#
# FM_SECONDMATE_MODEL_LIVE_HERDR=1 additionally runs the --check pass against
# a Herdr endpoint through bin/fm-herdr-lab.sh. That path needs an environment
# whose fleet runs in a single running Herdr `default` session, because the lab
# helper records that session as its tripwire; it is maintainer-verification
# pending until it has run there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SECONDMATE_MODEL_LIVE tmux jq claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

# shellcheck source=bin/fm-secondmate-model-lib.sh
. "$ROOT/bin/fm-secondmate-model-lib.sh"

ORIGINAL_PATH=$PATH
CLAUDE_BIN=$(command -v claude)
VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$VERSION" ] || VERSION=version-unknown
HV="Claude Code ($VERSION)"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-model-live.XXXXXX")
LAB="$TMP_ROOT/home"
TMUX_DIR=
HERDR_SESSION_NAME=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$TMUX_DIR" ]; then
    TMUX_TMPDIR="$TMUX_DIR" tmux kill-server >/dev/null 2>&1 || true
    "$LAB_HOME_HELPER" teardown "$LAB" >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$HERDR_SESSION_NAME" ]; then
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_SESSION_NAME" || rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

"$LAB_HOME_HELPER" create "$LAB" >/dev/null || fail "could not create the lab home"
TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB") || fail "could not create the lab tmux socket dir"
export TMUX_TMPDIR="$TMUX_DIR"
unset TMUX TMUX_PANE
SES=mlive

# The status line prints only the model display name, so the footer reading
# never depends on the operator's own statusLine configuration.
SETTINGS='{"feedbackDrafts":"off","statusLine":{"type":"command","command":"jq -r .model.display_name"}}'

claude_cmd() {  # [--model <m>] -> shell command line launching Claude Code
  local cmd
  cmd="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 '$CLAUDE_BIN' --dangerously-skip-permissions --settings '$SETTINGS'"
  [ "$#" -eq 0 ] || cmd="$cmd --model '$2'"
  printf '%s' "$cmd"
}

launch_tmux() {  # <window> [--model <m>]
  local win=$1
  shift
  if tmux has-session -t "$SES" 2>/dev/null; then
    tmux new-window -d -t "$SES:" -n "$win" -c "$ROOT" "$(claude_cmd "$@")"
  else
    tmux new-session -d -s "$SES" -n "$win" -x 160 -y 45 -c "$ROOT" "$(claude_cmd "$@")"
  fi
}

# Wait until the composer footer renders a model name, accepting Claude's
# folder-trust prompt once (it preselects "No, exit", so move to Yes first).
wait_footer_tmux() {  # <window> -> prints the rendered footer model
  local win=$1 i=0 trusted=0 screen model
  while [ "$i" -lt 90 ]; do
    screen=$(tmux capture-pane -p -t "$SES:$win" 2>/dev/null || true)
    case "$screen" in
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          tmux send-keys -t "$SES:$win" Down Enter
        fi
        ;;
      *'bypass permissions on'*)
        if model=$(fm_sm_model_footer_model "$screen"); then
          printf '%s' "$model"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  printf '%s\n' "$screen" >&2
  return 1
}

# Discover the default this host launches, then pin a different family.
launch_tmux probe
DEFAULT_MODEL=$(wait_footer_tmux probe) || fail "$HV never rendered a model-naming footer in the tmux lab"
tmux kill-window -t "$SES:probe"
DEFAULT_KEY=$(fm_sm_model_key "$DEFAULT_MODEL") || fail "$HV renders an unrecognized default model name '$DEFAULT_MODEL'"
case "$DEFAULT_KEY" in sonnet*) PIN=haiku ;; *) PIN=sonnet ;; esac
# FM_SECONDMATE_MODEL_LIVE_PIN pins an exact model id instead, for proving a
# fleet pin's id spelling reads back as the display name its footer renders.
if [ -n "${FM_SECONDMATE_MODEL_LIVE_PIN:-}" ]; then
  PIN=$FM_SECONDMATE_MODEL_LIVE_PIN
  PIN_KEY=$(fm_sm_model_key "$PIN") || fail "FM_SECONDMATE_MODEL_LIVE_PIN '$PIN' is not a recognizable Claude model id"
  fm_sm_model_keys_match "$PIN_KEY" "$DEFAULT_KEY" \
    && fail "FM_SECONDMATE_MODEL_LIVE_PIN '$PIN' is this host's default model, so a bare launch cannot drift from it"
fi
printf '# %s launches %s by default here; pinning the lab mates to %s\n' "$HV" "$DEFAULT_MODEL" "$PIN"

# Two registered mates: one launched on its pin, one launched bare the way a
# resurrected session comes back.
: > "$LAB/data/secondmates.md"
printf 'claude\n' > "$LAB/config/secondmate-harness"
for id in onpin drift; do
  mkdir -p "$TMP_ROOT/$id-home"
  printf '%s\n' "- $id - live lab mate (home: $TMP_ROOT/$id-home; scope: tests; projects: ; added 2026-10-01)" >> "$LAB/data/secondmates.md"
  printf 'claude %s\n' "$PIN" > "$LAB/config/secondmate-harness.$id"
  printf '%s\n' "window=$SES:fm-$id" "endpoint_task_id=$id" "worktree=$TMP_ROOT/$id-home" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "model=$PIN" "effort=default" \
    "backend=tmux" "home=$TMP_ROOT/$id-home" > "$LAB/state/$id.meta"
done
launch_tmux fm-onpin --model "$PIN"
launch_tmux fm-drift
wait_footer_tmux fm-onpin >/dev/null || fail "$HV never rendered the pinned session's footer"
wait_footer_tmux fm-drift >/dev/null || fail "$HV never rendered the bare session's footer"

reconcile() {
  FM_HOME="$LAB" FM_SECONDMATE_MODEL_POLL=1 "$ROOT/bin/fm-secondmate-model-reconcile.sh" "$@"
}

rc=0
out=$(reconcile --check 2>&1) || rc=$?
printf '%s\n' "$out" | sed 's/^/# /'
[ "$rc" = 3 ] || fail "$HV: --check must exit 3 with a drifted mate, got $rc"
case "$out" in
  *"on-pin: onpin - pin $PIN; live argv: --model $PIN (match); footer: "*" (match)"*) ;;
  *) fail "$HV: the pinned session was not read on-pin from both argv and footer" ;;
esac
case "$out" in
  *"drifted: drift - pin $PIN; live argv: launched without --model; footer: "*" (mismatch)"*) ;;
  *) fail "$HV: the bare session was not read as drifted from both argv and footer" ;;
esac
printf 'ok - live --check: %s argv and footer readings separate the pinned and the bare session\n' "$HV"

# The relaunch seam starts the pinned session in the recorded window, the way
# bin/fm-spawn.sh republishes the endpoint, and records the argv it received.
# The pinned launcher is written out so the settings JSON never passes
# through another layer of shell quoting.
# shellcheck disable=SC2016  # $1 belongs to the written launcher
printf '#!/usr/bin/env bash\nexec env %s --model "$1"\n' "$(claude_cmd)" > "$TMP_ROOT/launch-pinned"
chmod +x "$TMP_ROOT/launch-pinned"
cat > "$TMP_ROOT/spawn-stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/spawn.log"
id=\$1; model=
while [ "\$#" -gt 0 ]; do [ "\$1" = --model ] && model=\$2; shift; done
TMUX_TMPDIR='$TMUX_DIR' tmux new-window -d -t '$SES:' -n "fm-\$id" -c '$ROOT' "'$TMP_ROOT/launch-pinned' '\$model'"
SH
chmod +x "$TMP_ROOT/spawn-stub"
onpin_pid=$(tmux display-message -p -t "$SES:fm-onpin" '#{pane_pid}')

rc=0
out=$(FM_SECONDMATE_MODEL_SPAWN="$TMP_ROOT/spawn-stub" FM_SECONDMATE_MODEL_CONFIRM_WAIT=90 reconcile --apply 2>&1) || rc=$?
printf '%s\n' "$out" | sed 's/^/# /'
[ "$rc" = 0 ] || fail "$HV: --apply must exit 0 once the drifted session is repaired, got $rc"
case "$out" in
  *"repaired: drift - was: pin $PIN; live argv: launched without --model; "*"now: pin $PIN; live argv: --model $PIN (match); footer: "*" (match)"*) ;;
  *) fail "$HV: the drifted session was not exited by /exit and proven back on the pin" ;;
esac
grep -Fqx "drift $TMP_ROOT/drift-home --secondmate --harness claude --model $PIN" "$TMP_ROOT/spawn.log" \
  || fail "the relaunch did not receive the pin verbatim: $(cat "$TMP_ROOT/spawn.log")"
grep -q '^onpin ' "$TMP_ROOT/spawn.log" && fail "the on-pin session must never be relaunched"
[ "$(tmux display-message -p -t "$SES:fm-onpin" '#{pane_pid}')" = "$onpin_pid" ] \
  || fail "the on-pin session must keep its process"
printf 'ok - live --apply: %s exits on a typed /exit and the relaunch is proven on the pin\n' "$HV"

# --- Herdr endpoint (maintainer-verification pending) -----------------------
[ "${FM_SECONDMATE_MODEL_LIVE_HERDR:-0}" = 1 ] || exit 0
command -v herdr >/dev/null 2>&1 || fail "FM_SECONDMATE_MODEL_LIVE_HERDR=1 but herdr is not installed"
[ -x "$HERDR_LAB_HELPER" ] || fail "FM_SECONDMATE_MODEL_LIVE_HERDR=1 but the Herdr lab helper is not executable at $HERDR_LAB_HELPER"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_SESSION_NAME=$("$HERDR_LAB_HELPER" name model-reconcile-live)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# Every adapter call carries a trailing --session; route it through the lab
# helper and refuse any other session.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_SESSION_NAME" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $HERDR_SESSION_NAME" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_SESSION_NAME" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$HERDR_LAB_HELPER" provision "$HERDR_SESSION_NAME" || fail "could not provision the isolated Herdr lab"
HV_HERDR="$HV on $(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1)"

hlab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_SESSION_NAME" "$@"; }
for id in onpin drift; do
  ws=$(hlab workspace create --cwd "$ROOT" --label "fm-$id" --no-focus) || fail "could not create the Herdr lab workspace for $id"
  pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "workspace create returned no pane id for $id"
  if [ "$id" = onpin ]; then
    hlab pane run "$pane" "$(claude_cmd --model "$PIN")" >/dev/null || fail "could not launch $HV_HERDR for $id"
  else
    hlab pane run "$pane" "$(claude_cmd)" >/dev/null || fail "could not launch $HV_HERDR for $id"
  fi
  printf '%s\n' "window=$HERDR_SESSION_NAME:$pane" "herdr_session=$HERDR_SESSION_NAME" "endpoint_task_id=$id" \
    "worktree=$TMP_ROOT/$id-home" "harness=claude" "kind=secondmate" "mode=secondmate" "model=$PIN" \
    "effort=default" "backend=herdr" "home=$TMP_ROOT/$id-home" > "$LAB/state/$id.meta"
  i=0 trusted=0 ready=0
  while [ "$i" -lt 90 ]; do
    screen=$(hlab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'Yes, I trust this folder'*)
        [ "$trusted" = 1 ] || { trusted=1; hlab pane send-keys "$pane" down enter >/dev/null; }
        ;;
      *'bypass permissions on'*)
        fm_sm_model_footer_model "$screen" >/dev/null && { ready=1; break; }
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" = 1 ] || fail "$HV_HERDR never rendered a model-naming footer for $id"
done

rc=0
out=$(PATH="$FAKEBIN:$ORIGINAL_PATH" reconcile --check 2>&1) || rc=$?
printf '%s\n' "$out" | sed 's/^/# /'
[ "$rc" = 3 ] || fail "$HV_HERDR: --check must exit 3 with a drifted mate, got $rc"
case "$out" in
  *"on-pin: onpin - pin $PIN; live argv: --model $PIN (match); footer: "*" (match)"*) ;;
  *) fail "$HV_HERDR: the pinned Herdr session was not read on-pin from both argv and footer" ;;
esac
case "$out" in
  *"drifted: drift - pin $PIN; live argv: launched without --model; footer: "*" (mismatch)"*) ;;
  *) fail "$HV_HERDR: the bare Herdr session was not read as drifted from both argv and footer" ;;
esac
printf 'ok - live Herdr --check: %s argv and footer readings separate the pinned and the bare session\n' "$HV_HERDR"
