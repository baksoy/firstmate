#!/usr/bin/env bash
# Reconcile every registered second mate's actually-running model against its
# recorded pin, and with --apply relaunch any mate that drifted onto the pin.
#
# Usage: fm-secondmate-model-reconcile.sh --check|--apply [<secondmate-id>...] [--help]
#
#   --check   report only; touches nothing.
#   --apply   report, then relaunch each drifted mate onto its pin.
#   <id>...   restrict the pass to these registered mates (default: every
#             mate in data/secondmates.md).
#
# Why this exists: a Herdr restart resurrects each Claude Code agent from its
# saved session but drops the launch flags, so a mate pinned to one model
# comes back on the harness default. The mate's own recorded metadata still
# names the pinned model, because nothing rewrote it, so that record cannot
# detect the drift; the mate itself cannot repair it either when the pinned
# model is absent from the interactive picker. The upstream fixes - Herdr
# resurrecting with the original argv, and bin/fm-secondmate-restart.sh
# proving the pin survived its relaunch - are separate follow-ups; this
# command detects and repairs the symptom from live evidence.
#
# The pin is the only source of truth: config/secondmate-harness.<id> above
# config/secondmate-harness, resolved through bin/fm-harness.sh. This command
# never edits a pin. Only a pin whose harness is claude is checked, because
# both live readings below are verified for Claude Code alone.
#
# Live model, read at check time from the mate's current endpoint (resolved
# from state/<id>.meta, never cached):
#   argv    the --model token of the Claude Code process under the endpoint's
#           shell, from the kernel process table. A launch carrying no --model
#           is a positive drift signal unless the footer proves otherwise.
#   footer  the model name the status line renders below the composer's
#           bottom rule. It catches an in-session model switch the argv cannot
#           see. It is present only when the operator's Claude Code statusLine
#           prints the model name; without one, argv alone carries the verdict.
# bin/fm-secondmate-model-lib.sh owns the normalization and verdict rules.
#
# Report lines, one per mate, then one summary line:
#   on-pin:    every readable signal matches the pin; left untouched.
#   drifted:   a signal names another model; under --apply the line says why
#              the repair was not attempted (lease, liveness episode, mid-turn).
#   repaired:  relaunched and the live signals now match the pin.
#   failed:    a repair step refused or the relaunch did not land on the pin.
#   skipped:   not checkable here (remote, non-claude pin, endpoint not alive,
#              unsupported backend).
#   unpinned:  the pin names no model, so there is nothing to drift from.
#   unknown:   no signal was readable; no repair is attempted on no evidence.
#
# Repair (--apply), per drifted local mate on a tmux or herdr endpoint:
#   1. Claim the task lease (bin/fm-lease.sh claim) and the mate's liveness
#      lock, so the liveness sweep and watcher tick stand down for this mate
#      instead of observing the deliberate exit as a death and relaunching it.
#      A lease this actor already held is kept afterwards; one taken here is
#      released.
#   2. Refuse a mid-turn agent. Clear the composer with C-u, refuse if text
#      is still pending, then type /exit and press Enter, once more if the
#      agent is still up. bin/fm-control.sh relaunch is not used because its
#      submit-confirmed exit refuses on current Claude Code under Herdr.
#   3. Once the agent has exited, close the leftover shell endpoint exactly as
#      the liveness relaunch does, then relaunch through
#      `bin/fm-spawn.sh <id> <home> --secondmate --harness <h> --model <m>
#      [--effort <e>]`, the pin passed explicitly and verbatim.
#   4. Re-read both live signals on the new endpoint until they match the pin
#      or FM_SECONDMATE_MODEL_CONFIRM_WAIT expires; when the footer was
#      readable before the repair, the wait holds out for it to render the pin.
# If the liveness sweep nevertheless races a repair (for example the lock was
# free between exit and relaunch on another supervisor), it reports a
# `check: secondmate <id> auto-relaunched` or `auto-relaunch failed` wake. It
# cannot create a duplicate endpoint: fm-spawn's per-task lock makes one of
# the two relaunches stand down, and the sweep's own relaunch re-resolves the
# same pin. Reconcile the mate's current state and rerun --check.
#
# Environment knobs:
#   FM_SECONDMATE_MODEL_EXIT_WAIT     seconds to wait for /exit to land (30)
#   FM_SECONDMATE_MODEL_CONFIRM_WAIT  seconds to wait for the relaunch to show the pin (120)
#   FM_SECONDMATE_MODEL_POLL          seconds between live re-reads (2)
#   FM_SECONDMATE_MODEL_SPAWN         relaunch command (bin/fm-spawn.sh); a test seam
#
# Exit status: 0 no mate is left drifted, failed, or unknown; 3 at least one
# is; 1 the input itself is unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,80{s/^# \{0,1\}//;p;}' "$0"
}

MODE=
IDS=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
    *)
      id=${arg#fm-}
      case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
      IDS+=("$id")
      ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-model-reconcile refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }
REGISTRY="$FM_HOME/data/secondmates.md"
[ -f "$REGISTRY" ] || { echo "error: no second mate registry at $REGISTRY" >&2; exit 1; }

EXIT_WAIT=${FM_SECONDMATE_MODEL_EXIT_WAIT:-30}
CONFIRM_WAIT=${FM_SECONDMATE_MODEL_CONFIRM_WAIT:-120}
POLL=${FM_SECONDMATE_MODEL_POLL:-2}
SPAWN=${FM_SECONDMATE_MODEL_SPAWN:-$FM_ROOT/bin/fm-spawn.sh}
for knob in "EXIT_WAIT=$EXIT_WAIT" "CONFIRM_WAIT=$CONFIRM_WAIT" "POLL=$POLL"; do
  case "${knob#*=}" in
    ''|*[!0-9]*) echo "error: FM_SECONDMATE_MODEL_${knob%%=*} must be a non-negative integer: ${knob#*=}" >&2; exit 2 ;;
  esac
done
[ "$POLL" -gt 0 ] || { echo "error: FM_SECONDMATE_MODEL_POLL must be positive" >&2; exit 2; }

export FM_HOME
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-model-lib.sh
. "$SCRIPT_DIR/fm-secondmate-model-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
ACTOR=$(fm_lease_actor) || exit 2

# Registered mates, in registry order, restricted to the named ids.
MATES=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in "- "*) ;; *) continue ;; esac
  if ! secondmate_registry_parse_line "$line"; then
    echo "secondmate registry: skipped malformed entry: $line" >&2
    continue
  fi
  MATES+=("$SECONDMATE_REGISTRY_ID|$SECONDMATE_REGISTRY_REMOTE")
done < "$REGISTRY"
if [ "${#IDS[@]}" -gt 0 ]; then
  for id in "${IDS[@]}"; do
    case " ${MATES[*]:-} " in
      *" $id|"*) ;;
      *) echo "error: '$id' is not a registered second mate in $REGISTRY" >&2; exit 1 ;;
    esac
  done
fi

# The command line of the Claude Code process under <backend> <target>: the
# shallowest descendant of the endpoint's root process (inclusive) whose
# executable name is claude. Prints nothing and returns 1 when none is found.
agent_args() {  # <backend> <target>
  local backend=$1 target=$2 root info
  case "$backend" in
    tmux)
      root=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      ;;
    herdr)
      fm_backend_source herdr || return 1
      fm_backend_herdr_parse_target "$target" || return 1
      info=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || return 1
      root=$(printf '%s' "$info" | jq -er '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  ps -axo pid=,ppid=,args= 2>/dev/null | awk -v root="$root" '
    {
      pid = $1; ppid = $2
      line = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      args[pid] = line
      kids[ppid] = kids[ppid] " " pid
    }
    END {
      n = 1; queue[1] = root
      for (i = 1; i <= n; i++) {
        p = queue[i]
        split(args[p], words, /[[:space:]]+/)
        exe = words[1]; sub(/.*\//, "", exe)
        if (exe ~ /claude/) { print args[p]; exit 0 }
        c = split(kids[p], ch, " ")
        for (j = 1; j <= c; j++) if (ch[j] != "") queue[++n] = ch[j]
      }
      exit 1
    }
  '
}

# Read both live signals for one endpoint into LIVE_ARGV / LIVE_ARGV_MODEL /
# LIVE_FOOTER / LIVE_FOOTER_MODEL / LIVE_VERDICT against <pin> and its key.
LIVE_ARGV=unreadable LIVE_ARGV_MODEL='' LIVE_FOOTER=unreadable LIVE_FOOTER_MODEL='' LIVE_VERDICT=unknown
read_live() {  # <backend> <target> <pin-model> <pin-key>
  local backend=$1 target=$2 pin=$3 pin_key=$4 args screen
  LIVE_ARGV=unreadable LIVE_ARGV_MODEL='' LIVE_FOOTER=unreadable LIVE_FOOTER_MODEL=''
  if args=$(agent_args "$backend" "$target") && [ -n "$args" ]; then
    if LIVE_ARGV_MODEL=$(fm_sm_model_argv_model "$args"); then
      if [ "$LIVE_ARGV_MODEL" = "$pin" ]; then
        LIVE_ARGV=match
      elif [ -n "$pin_key" ]; then
        LIVE_ARGV=$(fm_sm_model_signal "$pin_key" "$LIVE_ARGV_MODEL")
        # An argv token outside the known id grammar is still a different
        # string from the pin, which is all the launch flag can tell us.
        [ "$LIVE_ARGV" != unreadable ] || LIVE_ARGV=mismatch
      else
        LIVE_ARGV=mismatch
      fi
    else
      LIVE_ARGV=absent
    fi
  fi
  if [ -n "$pin_key" ] && fm_backend_visible_capture_supported "$backend" \
    && screen=$(fm_backend_visible_capture "$backend" "$target" 2>/dev/null); then
    if LIVE_FOOTER_MODEL=$(fm_sm_model_footer_model "$screen"); then
      LIVE_FOOTER=$(fm_sm_model_signal "$pin_key" "$LIVE_FOOTER_MODEL")
    fi
  fi
  LIVE_VERDICT=$(fm_sm_model_verdict "$LIVE_ARGV" "$LIVE_FOOTER")
}

live_detail() {  # <pin>
  local argv footer
  case "$LIVE_ARGV" in
    absent) argv='launched without --model' ;;
    unreadable) argv='unreadable' ;;
    *) argv="--model $LIVE_ARGV_MODEL ($LIVE_ARGV)" ;;
  esac
  case "$LIVE_FOOTER" in
    unreadable) footer='unreadable' ;;
    *) footer="$LIVE_FOOTER_MODEL ($LIVE_FOOTER)" ;;
  esac
  printf 'pin %s; live argv: %s; footer: %s' "$1" "$argv" "$footer"
}

wait_agent_gone() {  # <backend> <target> <seconds> -> 0 when dead or missing
  local backend=$1 target=$2 waited=0
  while :; do
    case "$(fm_backend_agent_state "$backend" "$target")" in dead|missing) return 0 ;; esac
    [ "$waited" -lt "$3" ] || return 1
    sleep "$POLL"
    waited=$((waited + POLL))
  done
}

send_literal() {  # <backend> <target> <text>
  fm_backend_source "$1" || return 1
  case "$1" in
    tmux) fm_backend_tmux_send_literal "$2" "$3" ;;
    herdr) fm_backend_herdr_send_literal "$2" "$3" ;;
    *) return 1 ;;
  esac
}

first_line() {
  printf '%s\n' "$1" | awk 'NF { gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/^error: /, ""); print; exit }'
}

# Per-mate repair. Prints the report line itself and returns 0 on repaired.
REPAIR_LEASE_KEPT=0
repair_mate() {  # <id> <meta> <backend> <target> <harness> <pin-model> <pin-effort> <pin-key>
  local id=$1 meta=$2 backend=$3 target=$4 harness=$5 pin=$6 effort=$7 pin_key=$8
  local home out rc=0 composer waited seen_alive new_meta_target before before_footer
  before=$(live_detail "$pin")
  before_footer=$LIVE_FOOTER
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || { fm_sm_model_report_line failed "$id" "state/$id.meta records no home=; $before"; return 1; }

  REPAIR_LEASE_KEPT=0
  if fm_lease_live "$id" && [ "$FM_LEASE_ACTOR" = "$ACTOR" ]; then
    REPAIR_LEASE_KEPT=1
  fi
  out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lease.sh" claim "$id" 2>&1) || rc=$?
  if [ "$rc" -eq 6 ]; then
    fm_sm_model_report_line drifted "$id" "not repaired: another supervision actor holds its lease; $before"
    return 2
  elif [ "$rc" -ne 0 ]; then
    fm_sm_model_report_line failed "$id" "lease claim failed: $(first_line "$out"); $before"
    return 1
  fi
  if ! fm_secondmate_liveness_lock "$id"; then
    release_lease "$id"
    fm_sm_model_report_line drifted "$id" "not repaired: a liveness episode is in progress for it; rerun after it settles; $before"
    return 2
  fi

  if [ "$(fm_backend_busy_state "$backend" "$target")" = busy ]; then
    finish_repair "$id"
    fm_sm_model_report_line drifted "$id" "not repaired: the agent is mid-turn; rerun when it is idle; $before"
    return 2
  fi
  fm_backend_send_key "$backend" "$target" C-u >/dev/null 2>&1 || true
  sleep 0.3
  composer=$(fm_backend_composer_state "$backend" "$target")
  case "$composer" in
    pending|pending-unproven)
      finish_repair "$id"
      fm_sm_model_report_line failed "$id" "the composer still holds text after C-u, so /exit was not typed; $before"
      return 1
      ;;
  esac
  if ! send_literal "$backend" "$target" /exit >/dev/null 2>&1; then
    finish_repair "$id"
    fm_sm_model_report_line failed "$id" "could not type /exit into its endpoint; $before"
    return 1
  fi
  sleep 1
  fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1 || true
  if ! wait_agent_gone "$backend" "$target" $((EXIT_WAIT / 2)); then
    fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1 || true
    if ! wait_agent_gone "$backend" "$target" $((EXIT_WAIT - EXIT_WAIT / 2)); then
      finish_repair "$id"
      fm_sm_model_report_line failed "$id" "the agent did not exit within ${EXIT_WAIT}s of /exit; it is still running unchanged; $before"
      return 1
    fi
  fi
  fm_backend_kill "$backend" "$target" >/dev/null 2>&1 || true

  local spawn_args=("$id" "$home" --secondmate --harness "$harness" --model "$pin")
  [ -z "$effort" ] || spawn_args+=(--effort "$effort")
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_SPAWN_NO_GUARD=1 "$SPAWN" "${spawn_args[@]}" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    finish_repair "$id"
    fm_sm_model_report_line failed "$id" "the agent exited but the relaunch failed: $(first_line "$out"); the liveness sweep will relaunch it on the pin; $before"
    return 1
  fi

  waited=0 seen_alive=0
  LIVE_ARGV=unreadable LIVE_ARGV_MODEL='' LIVE_FOOTER=unreadable LIVE_FOOTER_MODEL='' LIVE_VERDICT=unknown
  while :; do
    new_meta_target=$(fm_backend_target_of_meta "$meta")
    backend=$(fm_backend_of_meta "$meta")
    if [ -n "$new_meta_target" ] && [ "$(fm_backend_agent_state "$backend" "$new_meta_target")" = alive ]; then
      seen_alive=1
      read_live "$backend" "$new_meta_target" "$pin" "$pin_key"
      # A footer that rendered before the repair must render the pin again;
      # the fresh session's argv alone settles only at the deadline.
      if [ "$LIVE_VERDICT" = on-pin ] && { [ "$before_footer" = unreadable ] || [ "$LIVE_FOOTER" = match ]; }; then
        break
      fi
    fi
    [ "$waited" -lt "$CONFIRM_WAIT" ] || break
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  finish_repair "$id"
  if [ "$LIVE_VERDICT" = on-pin ]; then
    fm_sm_model_report_line repaired "$id" "was: $before; now: $(live_detail "$pin")"
    return 0
  fi
  if [ "$seen_alive" = 0 ]; then
    fm_sm_model_report_line failed "$id" "relaunched but no live agent appeared on its recorded endpoint within ${CONFIRM_WAIT}s; was: $before"
    return 1
  fi
  fm_sm_model_report_line failed "$id" "relaunched but not proven on the pin within ${CONFIRM_WAIT}s; was: $before; now: $(live_detail "$pin")"
  return 1
}

release_lease() {  # <id>
  [ "$REPAIR_LEASE_KEPT" = 1 ] || FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lease.sh" release "$1" >/dev/null 2>&1 || true
}

finish_repair() {  # <id>
  fm_secondmate_liveness_unlock "$1"
  release_lease "$1"
}

checked=0 n_on=0 n_drift=0 n_repaired=0 n_failed=0 n_skipped=0 n_unpinned=0 n_unknown=0
for entry in "${MATES[@]+"${MATES[@]}"}"; do
  id=${entry%|*}
  remote=${entry#*|}
  if [ "${#IDS[@]}" -gt 0 ]; then
    case " ${IDS[*]} " in *" $id "*) ;; *) continue ;; esac
  fi
  checked=$((checked + 1))
  if [ "$remote" = 1 ]; then
    fm_sm_model_report_line skipped "$id" "remote mate; its live model is not readable from this host"
    n_skipped=$((n_skipped + 1)); continue
  fi
  harness=$("$FM_ROOT/bin/fm-harness.sh" secondmate "$id" 2>/dev/null || true)
  pin=$("$FM_ROOT/bin/fm-harness.sh" secondmate-model "$id" 2>/dev/null || true)
  effort=$("$FM_ROOT/bin/fm-harness.sh" secondmate-effort "$id" 2>/dev/null || true)
  case "$effort" in low|medium|high|xhigh|max|ultra) ;; *) effort= ;; esac
  if [ "$harness" != claude ]; then
    fm_sm_model_report_line skipped "$id" "pinned harness is '${harness:-unresolved}'; live model reading is verified for claude only"
    n_skipped=$((n_skipped + 1)); continue
  fi
  if [ -z "$pin" ]; then
    fm_sm_model_report_line unpinned "$id" "its pin names no model"
    n_unpinned=$((n_unpinned + 1)); continue
  fi
  pin_key=$(fm_sm_model_key "$pin" || true)
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    fm_sm_model_report_line skipped "$id" "no state/$id.meta; it is not running from this home"
    n_skipped=$((n_skipped + 1)); continue
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  case "$backend" in tmux|herdr) ;; *)
    fm_sm_model_report_line skipped "$id" "backend '$backend' has no verified agent-state and process read here"
    n_skipped=$((n_skipped + 1)); continue ;;
  esac
  state=$( [ -n "$target" ] && fm_backend_agent_state "$backend" "$target" || printf 'missing')
  if [ "$state" != alive ]; then
    fm_sm_model_report_line skipped "$id" "endpoint is $state, not a live agent; the liveness sweep owns its recovery"
    n_skipped=$((n_skipped + 1)); continue
  fi
  read_live "$backend" "$target" "$pin" "$pin_key"
  case "$LIVE_VERDICT" in
    on-pin)
      fm_sm_model_report_line on-pin "$id" "$(live_detail "$pin")"
      n_on=$((n_on + 1))
      ;;
    unknown)
      fm_sm_model_report_line unknown "$id" "$(live_detail "$pin")"
      n_unknown=$((n_unknown + 1))
      ;;
    drifted)
      if [ "$MODE" = check ]; then
        fm_sm_model_report_line drifted "$id" "$(live_detail "$pin")"
        n_drift=$((n_drift + 1))
      else
        rrc=0
        repair_mate "$id" "$meta" "$backend" "$target" "$harness" "$pin" "$effort" "$pin_key" || rrc=$?
        case "$rrc" in
          0) n_repaired=$((n_repaired + 1)) ;;
          2) n_drift=$((n_drift + 1)) ;;
          *) n_failed=$((n_failed + 1)) ;;
        esac
      fi
      ;;
  esac
done

fm_sm_model_summary_line "$checked" "$n_on" "$n_drift" "$n_repaired" "$n_failed" "$n_skipped" "$n_unpinned" "$n_unknown"
[ $((n_drift + n_failed + n_unknown)) -eq 0 ] || exit 3
exit 0
