#!/usr/bin/env bash
# Behavior tests for bin/fm-memory.sh, the Fleet Memory librarian front door:
# interpreter selection and refusal, the customer-registry commands that need
# only the standard library, and the tool's own Python unit tests when an
# interpreter with the librarian dependencies is present on the host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory)
MEM="$TMP_ROOT/home"
mkdir -p "$MEM"
cat > "$MEM/customers.toml" <<'TOML'
[[customer]]
id = "fdic"
name = "FDIC"
aliases = ["Federal Deposit Insurance"]
mishearings = ["FGIC"]
TOML

# A Python that can run the registry commands: standard library only.
STD_PY=$(command -v python3 || true)

run_memory() {
  FM_MEMORY_HOME=$MEM FM_MEMORY_PYTHON=$STD_PY "$ROOT/bin/fm-memory.sh" "$@"
}

test_help_lists_subcommands_without_an_interpreter() {
  local out
  out=$(HOME="$TMP_ROOT/nohome" FM_MEMORY_HOME="$MEM" "$ROOT/bin/fm-memory.sh" --help) ||
    fail "help should exit 0 with no interpreter"
  case $out in *refresh*query*) ;; *) fail "help does not name the subcommands: $out" ;; esac
  pass "help works with no interpreter"
}

test_missing_interpreter_is_refused_with_the_remedy() {
  local out rc=0
  out=$(HOME="$TMP_ROOT/nohome" FM_MEMORY_HOME="$MEM" FM_MEMORY_PYTHON='' "$ROOT/bin/fm-memory.sh" stats 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "expected exit 2 with no interpreter, got $rc: $out"
  case $out in *FM_MEMORY_PYTHON*requirements.txt*) ;; *) fail "refusal does not name the remedy: $out" ;; esac
  pass "missing interpreter is refused with the remedy"
}

test_registry_resolves_a_speech_recognition_mishearing() {
  [ -n "$STD_PY" ] || { pass "registry mishearing (skipped: no python3)"; return 0; }
  local out
  out=$(run_memory registry query "what did we show FGIC") || fail "registry query failed"
  case $out in *fdic*) ;; *) fail "FGIC did not resolve to fdic: $out" ;; esac
  pass "registry resolves a mishearing to its customer"
}

test_registry_query_without_a_customer_finds_none() {
  [ -n "$STD_PY" ] || { pass "registry no-match (skipped: no python3)"; return 0; }
  local out
  out=$(run_memory registry query "online chess cheating") || fail "registry query failed"
  [ "$out" = "([], [])" ] || fail "expected no customers and no expansion, got: $out"
  pass "registry query with no customer expands nothing"
}

test_rebuild_alias_reaches_the_tool() {
  [ -n "$STD_PY" ] || { pass "build alias (skipped: no python3)"; return 0; }
  local out rc=0
  # Dry-run needs no models or index; with no sources file the shipped defaults are crawled read-only.
  out=$(run_memory build --dry-run 2>&1) || rc=$?
  case $out in *"crawl:"*) ;; *"No module named"*) pass "build alias (skipped: stdlib python lacks deps)"; return 0 ;; *) fail "build --dry-run did not crawl (rc=$rc): $out" ;; esac
  [ ! -e "$MEM/lancedb" ] || fail "dry-run wrote an index"
  pass "build is an alias for rebuild and --dry-run writes nothing"
}

test_tool_unit_tests_pass_when_dependencies_are_present() {
  local py="${FM_MEMORY_PYTHON:-}"
  [ -n "$py" ] || py="$HOME/fleet-memory-poc/venv/bin/python"
  if [ ! -x "$py" ] || ! "$py" -c 'import lancedb, numpy, pyarrow, yaml' 2>/dev/null; then
    pass "tool unit tests (skipped: no interpreter with the librarian dependencies)"
    return 0
  fi
  local out
  out=$(cd "$ROOT/tools/fleet-memory" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. "$py" -W ignore -m unittest discover -s tests -p 'test_*.py' 2>&1) ||
    fail "tool unit tests failed: $out"
  pass "tool unit tests pass"
}

fm_test_run \
  test_help_lists_subcommands_without_an_interpreter \
  test_missing_interpreter_is_refused_with_the_remedy \
  test_registry_resolves_a_speech_recognition_mishearing \
  test_registry_query_without_a_customer_finds_none \
  test_rebuild_alias_reaches_the_tool \
  test_tool_unit_tests_pass_when_dependencies_are_present
