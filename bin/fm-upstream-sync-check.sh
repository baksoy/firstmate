#!/usr/bin/env bash
# Daily mechanical sync of this fork's main from upstream/main, with a wake
# only for what actually needs a captain-adjacent judgment call.
#
# Run once a day, directly by the OS (cron or launchd), against the primary
# firstmate checkout - never against a project or a task worktree. It never
# opens a PR against upstream and never pushes anything to upstream; it only
# pulls from upstream and pushes to origin.
#
# Exactly one of three outcomes, in order:
#   1. upstream/main has no commits main lacks: exits 0, no commit, no push,
#      no wake. The common case, silent by design.
#   2. upstream/main has new commits AND merging them is conflict-free (proven
#      with `git merge-tree`, before anything touches the working tree):
#      merges, pushes to origin main, prints one "synced:" line, exits 0.
#      No wake - this is routine.
#   3. Merging would conflict, or any preflight/fetch/merge/push step is
#      unsafe to proceed past: makes no lasting change to the working tree or
#      main, appends exactly one durable wake (kind=signal) naming the exact
#      problem, prints one "wake:" line, and exits 1.
#
# Why a plain wake append rather than a registered process-to-event source:
# a procevent source (bin/fm-procevent.sh) models a long-polling BLOCKING
# CHILD PROCESS that a live watcher arms once and keeps supervising across
# cycles (see bin/fm-procevent-agentmail.sh) - the wrong shape for a script
# that runs to completion once a day and must work with no live session at
# all for the common case. The watcher's own custom-check pattern
# (bin/fm-check-register.sh, state/<id>.check.sh: silent unless actionable,
# one line when it is) is the right SHAPE for this check's own logic, but
# that pattern is task-scoped and polled by the watcher's own live cycle,
# neither of which fits a task-independent, once-a-day, OS-triggered check.
# So this script keeps that check.sh silent-unless-actionable shape internally,
# but reports the actionable case by calling fm_wake_append directly - the same
# durable primitive bin/fm-procevent-agentmail.sh's self-announcing autohandle
# uses to publish a plain fact with no registration lifecycle. Both the
# watcher's live reconcile and the session-start digest already drain that one
# queue, so this adds no second notification channel.
#
# Preflight safety (not merely the three outcomes above): this never touches a
# non-"main" HEAD, a dirty working tree, or an in-progress merge/rebase, and it
# refuses if local main does not exactly match origin/main after fetching -
# the primary checkout is a live session's own working tree, and an unattended
# run must never guess past a state that looks mid-work. Any such refusal is
# reported the same way as a conflict: wake kind=signal, key=upstream-sync-check.
#
# A genuine merge conflict wakes with key=upstream-sync-check. A genuine merge
# conflict predicted by `git merge-tree` wakes with key=upstream-sync-conflict
# and names the commit range and the exact conflicting paths. Every other
# refusal (preflight, fetch, an unexpected merge race, or a failed push) wakes
# with key=upstream-sync-check and names the exact reason. Both are kind=signal
# in the durable wake queue (state/.wake-queue); handle them like any other
# signal wake (AGENTS.md section 8: read the event line, reconcile current
# state only where the action depends on it).
#
# Arming the daily trigger (done by firstmate against the primary checkout
# after this ships, not by this script):
#
#   launchd (preferred on macOS - this is a one-shot calendar job, not a
#   long-lived worker, so it carries no RunAtLoad/KeepAlive):
#     ~/Library/LaunchAgents/dev.firstmate.upstream-sync.plist
#       <?xml version="1.0" encoding="UTF-8"?>
#       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
#         "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#       <plist version="1.0"><dict>
#         <key>Label</key><string>dev.firstmate.upstream-sync</string>
#         <key>ProgramArguments</key><array>
#           <string>/Users/baksoy/Development/firstmate/bin/fm-upstream-sync-check.sh</string>
#         </array>
#         <key>StartCalendarInterval</key><dict>
#           <key>Hour</key><integer>6</integer>
#           <key>Minute</key><integer>0</integer>
#         </dict>
#         <key>StandardOutPath</key>
#           <string>/Users/baksoy/Development/firstmate/state/.upstream-sync-cron.log</string>
#         <key>StandardErrorPath</key>
#           <string>/Users/baksoy/Development/firstmate/state/.upstream-sync-cron.log</string>
#       </dict></plist>
#     then: launchctl bootstrap gui/$(id -u) \
#       ~/Library/LaunchAgents/dev.firstmate.upstream-sync.plist
#
#   cron (portable fallback):
#     0 6 * * * /Users/baksoy/Development/firstmate/bin/fm-upstream-sync-check.sh \
#       >> /Users/baksoy/Development/firstmate/state/.upstream-sync-cron.log 2>&1
#
# Test overrides (never used by the real cron/launchd invocation):
#   FM_ROOT_OVERRIDE   redirect which checkout this script syncs, standard
#                      across firstmate scripts (docs/configuration.md).
#   FM_STATE_OVERRIDE  redirect the durable wake queue, same standard override.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REPO="$FM_ROOT"
UPSTREAM_REMOTE=upstream
ORIGIN_REMOTE=origin
BRANCH=main

wake_and_exit() { # <key> <message>
  fm_wake_append signal "$1" "$2" || printf 'error: cannot append durable wake for: %s\n' "$2" >&2
  printf 'wake: %s\n' "$2"
  exit 1
}

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || { printf 'error: not a git repository: %s\n' "$REPO" >&2; exit 2; }

current_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || echo)
if [ "$current_branch" != "$BRANCH" ]; then
  wake_and_exit upstream-sync-check \
    "primary checkout is not on $BRANCH (on ${current_branch:-a detached HEAD}); skipped today's upstream sync"
fi

if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
  wake_and_exit upstream-sync-check \
    "primary checkout working tree is not clean; skipped today's upstream sync"
fi

if git -C "$REPO" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  wake_and_exit upstream-sync-check \
    "primary checkout already has a merge in progress; skipped today's upstream sync"
fi

if ! git -C "$REPO" fetch --quiet "$ORIGIN_REMOTE" "$BRANCH"; then
  wake_and_exit upstream-sync-check "could not fetch $ORIGIN_REMOTE/$BRANCH"
fi
if ! git -C "$REPO" fetch --quiet "$UPSTREAM_REMOTE" "$BRANCH"; then
  wake_and_exit upstream-sync-check "could not fetch $UPSTREAM_REMOTE/$BRANCH"
fi

local_head=$(git -C "$REPO" rev-parse "$BRANCH") || exit 2
origin_head=$(git -C "$REPO" rev-parse "$ORIGIN_REMOTE/$BRANCH") || exit 2
if [ "$local_head" != "$origin_head" ]; then
  wake_and_exit upstream-sync-check \
    "local $BRANCH ($local_head) does not match $ORIGIN_REMOTE/$BRANCH ($origin_head); skipped today's upstream sync"
fi

upstream_head=$(git -C "$REPO" rev-parse "$UPSTREAM_REMOTE/$BRANCH") || exit 2
new_commit_count=$(git -C "$REPO" rev-list "$BRANCH..$UPSTREAM_REMOTE/$BRANCH" --count) || exit 2
if [ "$new_commit_count" -eq 0 ]; then
  exit 0
fi

merge_base=$(git -C "$REPO" merge-base "$BRANCH" "$UPSTREAM_REMOTE/$BRANCH") || exit 2

mt_output=$(git -C "$REPO" merge-tree --write-tree --merge-base="$merge_base" \
  --name-only --no-messages "$BRANCH" "$UPSTREAM_REMOTE/$BRANCH" 2>&1)
mt_status=$?

if [ "$mt_status" -eq 1 ]; then
  conflicts=$(printf '%s\n' "$mt_output" | tail -n +2 | tr '\n' ' ')
  conflicts=${conflicts% }
  wake_and_exit upstream-sync-conflict \
    "$UPSTREAM_REMOTE/$BRANCH has $new_commit_count new commit(s) ($merge_base..$upstream_head) that would conflict with $BRANCH in: $conflicts"
elif [ "$mt_status" -ne 0 ]; then
  wake_and_exit upstream-sync-check \
    "merge-tree could not evaluate $UPSTREAM_REMOTE/$BRANCH ($merge_base..$upstream_head) against $BRANCH (exit $mt_status): $(printf '%s' "$mt_output" | tr '\n' ' ')"
fi

if ! git -C "$REPO" merge --no-ff --quiet \
  -m "merge: sync fork with upstream kunchenguid/firstmate ($new_commit_count commits)" \
  "$UPSTREAM_REMOTE/$BRANCH"; then
  git -C "$REPO" merge --abort >/dev/null 2>&1 || git -C "$REPO" reset --hard "$local_head" >/dev/null 2>&1
  wake_and_exit upstream-sync-check \
    "merge-tree predicted a clean merge of $UPSTREAM_REMOTE/$BRANCH but the real merge conflicted; aborted, no changes made"
fi

if ! git -C "$REPO" push --quiet "$ORIGIN_REMOTE" "$BRANCH"; then
  git -C "$REPO" reset --hard "$local_head" >/dev/null 2>&1
  wake_and_exit upstream-sync-check \
    "merged $UPSTREAM_REMOTE/$BRANCH cleanly but push to $ORIGIN_REMOTE/$BRANCH failed; local $BRANCH restored to $local_head, nothing pushed"
fi

printf 'synced: %s commit(s) merged from %s/%s and pushed to %s/%s\n' \
  "$new_commit_count" "$UPSTREAM_REMOTE" "$BRANCH" "$ORIGIN_REMOTE" "$BRANCH"
