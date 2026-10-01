#!/usr/bin/env bash
# fm-secondmate-model-lib.sh - pure model-identity logic for
# bin/fm-secondmate-model-reconcile.sh: pin normalization, the launch-argv and
# rendered-footer readings, the drift verdict, and the report vocabulary.
#
# Sourcing has no side effects and every function reads only its arguments,
# so tests/fm-secondmate-model-reconcile.test.sh pins this logic directly while
# the command owns every process, pane, and lifecycle read.
#
# Model identity is compared as a normalized "<family> <version>" key, never
# as raw strings, because the two live signals spell the same model
# differently: the launch argv carries the pinned id verbatim
# (us.anthropic.claude-sonnet-5-5[1m]) while Claude Code's status line renders
# its display name (Sonnet 5.5). A provider prefix, a context suffix such as
# [1m] or "(1M context)", and a date or revision suffix are not part of the
# identity. A bare family alias pin (sonnet) carries no version and accepts any
# version of that family; a versioned pin never accepts a bare alias.

# fm_sm_model_key: the normalized "<family> <version>" key of one model id or
# display name, or "<family>" for a bare alias; prints nothing and returns 1
# for anything unrecognizable, which callers treat as unreadable rather than
# as a different model.
fm_sm_model_key() {  # <id-or-display-name>
  local text id_re display_re alias_re
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # The optional minor is one or two digits and must end at a non-digit, so a
  # date suffix (claude-sonnet-4-20250514) is never read as a minor version.
  id_re='claude-(opus|sonnet|haiku|fable)-([0-9]+)(-([0-9]{1,2}))?([^0-9]|$)'
  display_re='(^|[^a-z])(opus|sonnet|haiku|fable)[[:space:]]+([0-9]+)(\.([0-9]+))?([^0-9.]|$)'
  alias_re='^[[:space:]]*(opus|sonnet|haiku|fable)(\[[^]]*\])?[[:space:]]*$'
  if [[ "$text" =~ $id_re ]]; then
    if [ -n "${BASH_REMATCH[4]}" ]; then
      printf '%s %s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
    else
      printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  elif [[ "$text" =~ $display_re ]]; then
    if [ -n "${BASH_REMATCH[5]}" ]; then
      printf '%s %s.%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"
    else
      printf '%s %s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
  elif [[ "$text" =~ $alias_re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# fm_sm_model_keys_match: whether an observed key satisfies the pin key. A pin
# with no version (a bare alias) accepts any version of its family; a
# versioned pin needs the exact key, so an observed bare alias, sonnet 5, and
# sonnet 5.5 are all different from a sonnet 5.5 pin.
fm_sm_model_keys_match() {  # <pin-key> <observed-key>
  local pin=$1 observed=$2
  [ -n "$pin" ] && [ -n "$observed" ] || return 1
  [ "$pin" = "$observed" ] && return 0
  case "$pin" in *' '*) return 1 ;; esac
  [ "$pin" = "${observed%% *}" ]
}

# fm_sm_model_argv_model: the --model value from one process's argument line
# (`ps -o args=` form). Accepts `--model <id>` and `--model=<id>`. Returns 1
# with no output when the process carries no --model at all. The line is
# split without globbing, so an id such as ...[1m] is never expanded.
fm_sm_model_argv_model() {  # <args-line>
  local words want=0 word
  read -r -a words <<< "$1"
  for word in "${words[@]+"${words[@]}"}"; do
    if [ "$want" = 1 ]; then
      printf '%s' "$word"
      return 0
    fi
    case "$word" in
      --model) want=1 ;;
      --model=*) printf '%s' "${word#--model=}"; return 0 ;;
    esac
  done
  return 1
}

# fm_sm_model_footer_region: the lines below the LAST horizontal rule on a
# Claude Code screen - the composer's bottom border - which is where the
# status line renders. Bounding the read there keeps a model name quoted in
# the conversation above the composer from being read as the live model.
# Prints nothing when the screen carries no rule.
fm_sm_model_footer_region() {  # <screen>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*────────────/ { buf = ""; seen = 1; next }
    seen { buf = buf $0 "\n" }
    END { if (seen) printf "%s", buf }
  '
}

# fm_sm_model_footer_model: the first recognizable model name in the footer
# region of <screen>, as rendered (for the report), or nothing.
fm_sm_model_footer_model() {  # <screen>
  local region line found
  region=$(fm_sm_model_footer_region "$1")
  [ -n "$region" ] || return 1
  while IFS= read -r line; do
    found=$(printf '%s' "$line" | grep -Eio '(opus|sonnet|haiku|fable)[[:space:]]+[0-9]+(\.[0-9]+)?|claude-(opus|sonnet|haiku|fable)-[0-9]+(-[0-9]{1,2})?' | head -n 1)
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
  done <<< "$region"
  return 1
}

# fm_sm_model_signal: one signal's verdict against the pin key.
#   match | mismatch | unreadable
fm_sm_model_signal() {  # <pin-key> <observed-model-text>
  local pin_key=$1 observed=$2 key
  [ -n "$observed" ] || { printf 'unreadable'; return 0; }
  key=$(fm_sm_model_key "$observed") || { printf 'unreadable'; return 0; }
  if fm_sm_model_keys_match "$pin_key" "$key"; then
    printf 'match'
  else
    printf 'mismatch'
  fi
}

# fm_sm_model_verdict: the per-mate verdict from the two signal readings.
#   <argv-signal> is match | mismatch | absent | unreadable, where absent means
#     the agent process was found and carries no --model flag.
#   <footer-signal> is match | mismatch | unreadable.
# Prints on-pin | drifted | unknown.
#   - Any readable signal that positively names another model is drift, so an
#     in-session model switch the argv cannot see still counts.
#   - Otherwise a matching signal is on-pin; a matching footer outranks an
#     absent flag because it reports the model actually running.
#   - An absent flag with no readable footer is drift: the pinned model was
#     never passed, which is exactly the resurrected-without-flags failure.
#   - Nothing readable is unknown and licenses no repair.
fm_sm_model_verdict() {  # <argv-signal> <footer-signal>
  local argv=$1 footer=$2
  if [ "$argv" = mismatch ] || [ "$footer" = mismatch ]; then
    printf 'drifted'
  elif [ "$footer" = match ] || [ "$argv" = match ]; then
    printf 'on-pin'
  elif [ "$argv" = absent ]; then
    printf 'drifted'
  else
    printf 'unknown'
  fi
}

# fm_sm_model_report_line: one report line, `<outcome>: <id> - <detail>`. The
# outcome vocabulary is on-pin, drifted, repaired, failed, skipped, unpinned,
# and unknown; bin/fm-secondmate-model-reconcile.sh --help owns its meaning.
fm_sm_model_report_line() {  # <outcome> <id> <detail>
  printf '%s: %s - %s\n' "$1" "$2" "$3"
}

# fm_sm_model_summary_line: the closing tally line.
fm_sm_model_summary_line() {  # <checked> <on-pin> <drifted> <repaired> <failed> <skipped> <unpinned> <unknown>
  printf 'summary: %s checked, %s on-pin, %s drifted, %s repaired, %s failed, %s skipped, %s unpinned, %s unknown\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}
