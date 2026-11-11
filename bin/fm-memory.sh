#!/usr/bin/env bash
# fm-memory.sh - front door for the Fleet Memory librarian (tools/fleet-memory).
#
# Usage: fm-memory.sh <init|build|refresh|rebuild|query|stats|start|stop|status|registry|eval> [args...]
#   build is an alias for rebuild. Everything else is passed to `python -m fmem`;
#   tools/fleet-memory/README.md owns the subcommand contract and the --json output.
#
# Interpreter, first match wins:
#   $FM_MEMORY_PYTHON, <memory home>/venv/bin/python, ~/fleet-memory-poc/venv/bin/python.
# The memory home is $FM_MEMORY_HOME, else $FM_HOME/data/fleet-memory, else <code root>/data/fleet-memory.
# The tool never downloads models and never writes outside the memory home.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SELF_DIR/.." && pwd)
TOOL_DIR="$ROOT/tools/fleet-memory"

MEM_HOME=${FM_MEMORY_HOME:-${FM_HOME:-$ROOT}/data/fleet-memory}

pick_python() {
  local c
  for c in "${FM_MEMORY_PYTHON:-}" "$MEM_HOME/venv/bin/python" "$HOME/fleet-memory-poc/venv/bin/python"; do
    if [ -n "$c" ] && [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

if ! PY=$(pick_python); then
  echo "fm-memory: no Python with the librarian dependencies found." >&2
  echo "fm-memory: set FM_MEMORY_PYTHON, or create $MEM_HOME/venv and install $TOOL_DIR/requirements.txt." >&2
  exit 2
fi

cmd=$1
shift
[ "$cmd" = "build" ] && cmd=rebuild

export PYTHONPATH="$TOOL_DIR${PYTHONPATH:+:$PYTHONPATH}"
export FM_MEMORY_HOME="$MEM_HOME"
export PYTHONDONTWRITEBYTECODE=1
exec "$PY" -m fmem "$cmd" "$@"
