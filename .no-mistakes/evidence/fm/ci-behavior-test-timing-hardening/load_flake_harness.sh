#!/usr/bin/env bash
# Reproduce the fleet-wide watcher-arm behavior-test flake under CPU load.
# Spawns 2x-core CPU hogs, then runs a given test file N times, recording the
# per-run exit code and the FIRST failing shard name (the file exits at the
# first fail() via exit 1). Prints a fail/total tally.
set -u

TEST_FILE=$1
RUNS=${2:-10}
HOGS=${3:-28}
LABEL=${4:-run}

pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# Spin up CPU hogs (busy loops) to saturate a loaded-runner scenario.
for _ in $(seq 1 "$HOGS"); do
  ( while : ; do : ; done ) &
  pids+=("$!")
done

fails=0
echo "=== $LABEL: $RUNS runs of $(basename "$TEST_FILE") under $HOGS CPU hogs (cores=$(sysctl -n hw.logicalcpu)) ==="
for i in $(seq 1 "$RUNS"); do
  start=$(date +%s)
  out=$(bash "$TEST_FILE" 2>&1)
  code=$?
  end=$(date +%s)
  if [ "$code" -ne 0 ]; then
    fails=$((fails + 1))
    firstfail=$(printf '%s\n' "$out" | grep -m1 'not ok' | sed 's/^not ok - //')
    echo "run $i: FAIL (exit=$code, ${dur:=$((end-start))}s) -> ${firstfail:-<no not-ok line; likely timeout/exit>}"
  else
    echo "run $i: pass (exit=0, $((end-start))s)"
  fi
done
echo "=== $LABEL RESULT: $fails/$RUNS runs failed ==="
