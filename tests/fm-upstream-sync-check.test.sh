#!/usr/bin/env bash
# Behavior tests for fm-upstream-sync-check.sh.
#
# Three fixtures model the primary checkout's real remote shape: a bare
# "upstream" repo, a bare "origin" repo that starts as a mirror of it, and a
# checkout cloned from origin with an "upstream" remote added, exactly like
# this fork's real main. A separate work copy pushes into the bare upstream so
# the checkout fixture itself is the only stand-in for the live primary
# checkout the real script would run against.
#
# Pinned behavior: no commits upstream/main has that main lacks is a silent
# no-op; a conflict-free divergence is merged with --no-ff and pushed to the
# fixture origin with no wake; a genuine conflict changes nothing in the
# checkout and fires exactly one durable signal wake naming the conflicting
# path; a preflight violation (dirty tree) also changes nothing and fires a
# signal wake, under the generic check key rather than the conflict key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-check-tests)

# --- fixtures ---------------------------------------------------------------

# new_home: a fresh isolated home dir with its own state/, so no two tests ever
# share a wake queue. Built with mktemp rather than a manually incremented
# counter, because `home=$(new_home)` runs the function in a subshell - any
# counter update inside it would never reach the caller.
new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$h/state"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_fixture <home> <name>: a bare upstream repo and a bare origin repo that
# starts as its mirror, a work copy wired to upstream for advancing it, and the
# checkout fixture itself (cloned from origin, with an upstream remote added)
# that stands in for the primary checkout.
build_fixture() {
  local home=$1 name=$2 upstream_bare origin_bare work checkout upstream_abs origin_abs
  upstream_bare="$home/$name-upstream.git"
  origin_bare="$home/$name-origin.git"
  work="$home/$name-work"
  checkout="$home/$name-checkout"

  git init -q --bare "$upstream_bare"
  upstream_abs=$(cd "$upstream_bare" && pwd)

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" shared.txt v0 C0
  git -C "$work" remote add upstream "file://$upstream_abs"
  git -C "$work" push -q upstream main

  git clone --quiet --bare "$upstream_bare" "$origin_bare"
  origin_abs=$(cd "$origin_bare" && pwd)

  git clone --quiet "file://$origin_abs" "$checkout"
  git -C "$checkout" remote add upstream "file://$upstream_abs"

  printf '%s\n' "$checkout"
}

# advance_upstream <home> <name> <file> <content> <msg>: push one more commit
# to <name>'s bare upstream via its work copy.
advance_upstream() {
  local home=$1 name=$2 file=$3 content=$4 msg=$5 work
  work="$home/$name-work"
  printf '%s\n' "$content" > "$work/$file"
  git -C "$work" add "$file"
  git -C "$work" commit -qm "$msg"
  git -C "$work" push -q upstream main
}

# advance_checkout <home> <name> <file> <content> <msg>: commit and push a
# fork-only commit from the checkout fixture itself to its bare origin.
advance_checkout() {
  local home=$1 name=$2 file=$3 content=$4 msg=$5 checkout
  checkout="$home/$name-checkout"
  printf '%s\n' "$content" > "$checkout/$file"
  git -C "$checkout" add "$file"
  git -C "$checkout" commit -qm "$msg"
  git -C "$checkout" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }
origin_bare_head() { git --git-dir="$1" rev-parse main; }

# run_check <home> <checkout>: run the script against the checkout fixture,
# with the wake queue isolated under the fixture home's own state/ dir.
# stdout and stderr are captured separately.
run_check() {
  local home=$1 checkout=$2 outf errf status
  outf="$home/.out"; errf="$home/.err"
  FM_ROOT_OVERRIDE="$checkout" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-upstream-sync-check.sh" >"$outf" 2>"$errf"
  status=$?
  CHECK_OUT=$(cat "$outf")
  return "$status"
}

wake_queue_file() { printf '%s\n' "$1/state/.wake-queue"; }

# --- tests ------------------------------------------------------------------

test_no_new_upstream_commits_is_noop() {
  local home checkout before status wq
  home=$(new_home)
  checkout=$(build_fixture "$home" alpha)
  before=$(head_sha "$checkout")

  set +e
  run_check "$home" "$checkout"
  status=$?
  set -e

  expect_code 0 "$status" "no-op case exits 0"
  assert_not_contains "$CHECK_OUT" "synced:" "no-op case does not report a sync"
  assert_not_contains "$CHECK_OUT" "wake:" "no-op case does not report a wake"
  wq=$(wake_queue_file "$home")
  assert_absent "$wq" "no-op case must not create a wake queue"
  [ "$(head_sha "$checkout")" = "$before" ] || fail "no-op case moved local main"
  [ -z "$(git -C "$checkout" status --porcelain)" ] || fail "no-op case left a dirty tree"
  pass "no upstream commits main lacks is a silent no-op"
}

test_clean_divergence_merges_and_pushes() {
  local home checkout status parents merged_head origin_head wq
  home=$(new_home)
  checkout=$(build_fixture "$home" beta)
  advance_checkout "$home" beta fork-only.txt fork "fork-only work"
  advance_upstream "$home" beta upstream-only.txt up "upstream-only work"

  set +e
  run_check "$home" "$checkout"
  status=$?
  set -e

  expect_code 0 "$status" "clean divergence exits 0"
  assert_contains "$CHECK_OUT" "synced: 1 commit(s) merged from upstream/main and pushed to origin/main" \
    "clean divergence reports the sync"
  assert_not_contains "$CHECK_OUT" "wake:" "clean divergence must not wake"
  wq=$(wake_queue_file "$home")
  { [ ! -e "$wq" ] || [ -z "$(cat "$wq")" ]; } || fail "clean divergence must not queue a wake"

  merged_head=$(head_sha "$checkout")
  parents=$(git -C "$checkout" log -1 --pretty=%P "$merged_head" | wc -w | tr -d ' ')
  [ "$parents" = 2 ] || fail "expected a real 2-parent merge commit, got $parents parent(s)"
  grep -q "merge: sync fork with upstream kunchenguid/firstmate (1 commits)" \
    <(git -C "$checkout" log -1 --pretty=%s "$merged_head") \
    || fail "merge commit message does not match the expected style"

  origin_head=$(origin_bare_head "$home/beta-origin.git")
  [ "$origin_head" = "$merged_head" ] || fail "merge was not pushed to the fixture origin"
  [ -f "$checkout/fork-only.txt" ] && [ -f "$checkout/upstream-only.txt" ] \
    || fail "merged tree is missing content from one side"
  pass "a conflict-free divergence is merged with --no-ff and pushed, with no wake"
}

test_genuine_conflict_makes_no_changes_and_wakes() {
  local home checkout status before origin_before wq wake_line
  home=$(new_home)
  checkout=$(build_fixture "$home" gamma)
  advance_checkout "$home" gamma shared.txt "fork change" "fork edits shared.txt"
  advance_upstream "$home" gamma shared.txt "upstream change" "upstream edits shared.txt"
  before=$(head_sha "$checkout")
  origin_before=$(origin_bare_head "$home/gamma-origin.git")

  set +e
  run_check "$home" "$checkout"
  status=$?
  set -e

  expect_code 1 "$status" "genuine conflict exits 1"
  assert_contains "$CHECK_OUT" "wake:" "conflict case reports a wake"
  assert_contains "$CHECK_OUT" "would conflict" "conflict case names the conflict"
  assert_contains "$CHECK_OUT" "shared.txt" "conflict case names the conflicting path"

  wq=$(wake_queue_file "$home")
  assert_present "$wq" "conflict case must queue a durable wake"
  wake_line=$(cat "$wq")
  assert_contains "$wake_line" $'\tsignal\t' "conflict wake must be kind=signal"
  assert_contains "$wake_line" "upstream-sync-conflict" "conflict wake must use the conflict key"
  assert_contains "$wake_line" "shared.txt" "conflict wake payload must name the conflicting path"

  [ "$(head_sha "$checkout")" = "$before" ] || fail "conflict case moved local main"
  [ -z "$(git -C "$checkout" status --porcelain)" ] || fail "conflict case left a dirty tree"
  ! git -C "$checkout" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    || fail "conflict case left a merge in progress"
  [ "$(origin_bare_head "$home/gamma-origin.git")" = "$origin_before" ] \
    || fail "conflict case pushed to the fixture origin"
  pass "a genuine conflict makes no working-tree changes and fires the conflict wake"
}

test_dirty_checkout_skips_without_mutation() {
  local home checkout status before wq wake_line
  home=$(new_home)
  checkout=$(build_fixture "$home" delta)
  advance_checkout "$home" delta fork-only.txt fork "fork-only work"
  advance_upstream "$home" delta upstream-only.txt up "upstream-only work"
  before=$(head_sha "$checkout")
  printf 'uncommitted edit\n' >> "$checkout/shared.txt"

  set +e
  run_check "$home" "$checkout"
  status=$?
  set -e

  expect_code 1 "$status" "dirty checkout exits 1"
  assert_contains "$CHECK_OUT" "wake:" "dirty checkout reports a wake"
  assert_contains "$CHECK_OUT" "not clean" "dirty checkout names the dirty state"
  assert_not_contains "$CHECK_OUT" "would conflict" "dirty checkout is not reported as a merge conflict"

  wq=$(wake_queue_file "$home")
  assert_present "$wq" "dirty checkout must queue a durable wake"
  wake_line=$(cat "$wq")
  assert_contains "$wake_line" "upstream-sync-check" "dirty checkout wake must use the generic check key"
  assert_not_contains "$wake_line" "upstream-sync-conflict" "dirty checkout must not use the conflict key"

  [ "$(head_sha "$checkout")" = "$before" ] || fail "dirty checkout case moved local main"
  grep -q "uncommitted edit" "$checkout/shared.txt" || fail "dirty checkout's uncommitted change was discarded"
  pass "a dirty working tree is a preflight refusal, not a conflict, and makes no changes"
}

test_unrelated_histories_wakes_without_mutation() {
  local home checkout status before origin_before wq wake_line orphan_work upstream_abs
  home=$(new_home)
  checkout=$(build_fixture "$home" epsilon)
  before=$(head_sha "$checkout")
  origin_before=$(origin_bare_head "$home/epsilon-origin.git")

  # Force-push an orphan root commit to the bare upstream so upstream/main
  # shares no history at all with the checkout's main, reproducing a fork
  # recreation or upstream history rewrite.
  orphan_work="$home/epsilon-orphan"
  upstream_abs=$(cd "$home/epsilon-upstream.git" && pwd)
  git init -q "$orphan_work"
  git -C "$orphan_work" symbolic-ref HEAD refs/heads/main
  commit_file "$orphan_work" unrelated.txt v0 "unrelated root"
  git -C "$orphan_work" remote add upstream "file://$upstream_abs"
  git -C "$orphan_work" push -q --force upstream main

  set +e
  run_check "$home" "$checkout"
  status=$?
  set -e

  expect_code 1 "$status" "unrelated histories exits 1"
  assert_contains "$CHECK_OUT" "wake:" "unrelated histories case reports a wake"
  assert_contains "$CHECK_OUT" "merge-base" "unrelated histories case names the merge-base failure"

  wq=$(wake_queue_file "$home")
  assert_present "$wq" "unrelated histories case must queue a durable wake"
  wake_line=$(cat "$wq")
  assert_contains "$wake_line" $'\tsignal\t' "unrelated-histories wake must be kind=signal"
  assert_contains "$wake_line" "upstream-sync-check" "unrelated-histories wake must use the generic check key"

  [ "$(head_sha "$checkout")" = "$before" ] || fail "unrelated histories case moved local main"
  [ -z "$(git -C "$checkout" status --porcelain)" ] || fail "unrelated histories case left a dirty tree"
  [ "$(origin_bare_head "$home/epsilon-origin.git")" = "$origin_before" ] \
    || fail "unrelated histories case pushed to the fixture origin"
  pass "unrelated upstream/main history wakes without mutating the checkout"
}

test_no_new_upstream_commits_is_noop
test_clean_divergence_merges_and_pushes
test_genuine_conflict_makes_no_changes_and_wakes
test_dirty_checkout_skips_without_mutation
test_unrelated_histories_wakes_without_mutation
