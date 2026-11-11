#!/usr/bin/env bash
# Launcher for the diskinfer Linux PySide6 workbench (GUI).
#
# Same entry-point scheme as device/diskinfer: all arguments are forwarded.
# Uses the private venv created by gui/setup-venv.sh when present, otherwise
# falls back to python3 (which then must be able to `import PySide6`).
#
#   gui/run-workbench.sh                    # open the workbench
#   gui/run-workbench.sh --theme dark
#   gui/run-workbench.sh --selftest         # headless: run the 7-case suite
#   gui/run-workbench.sh --chat-selftest    # headless: two-turn chat through diskc
#   gui/run-workbench.sh --screenshot out.png --demo

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink -f -- "$SELF")"; done
GUI_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
REPO_ROOT="$(cd -- "$GUI_DIR/.." && pwd)"

PY=""
for candidate in "${DISKINFER_PYTHON:-}" "$REPO_ROOT/.venv/bin/python" "$HOME/.local/share/diskinfer/venv/bin/python"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import PySide6' >/dev/null 2>&1; then
        PY="$(command -v python3)"
    else
        cat >&2 <<EOF
error: PySide6 is not available for this Python.
Set up the GUI environment first:

  $REPO_ROOT/gui/setup-venv.sh          # creates $REPO_ROOT/.venv and installs PySide6

or point DISKINFER_PYTHON at a Python that has PySide6.
EOF
        exit 1
    fi
fi

cd -- "$REPO_ROOT"
exec "$PY" "$GUI_DIR/workbench.py" "$@"
