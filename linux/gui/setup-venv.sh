#!/usr/bin/env bash
# Create the Python venv for the diskinfer PySide6 GUI and install PySide6.
#
# Linux counterpart of the Windows `python -m pip install -r gui/requirements.txt`.
# The venv is created with the system python3 (`ensurepip` is used by default,
# so no system pip / get-pip.py is required) and PySide6 is installed from the
# Tsinghua mirror by default (override with DISKINFER_PIP_INDEX).
#
# Usage:
#   gui/setup-venv.sh                      # venv at <repo>/.venv
#   gui/setup-venv.sh --venv-dir ~/venvs/diskinfer
#   DISKINFER_PIP_INDEX=https://pypi.org/simple gui/setup-venv.sh
#
# After setup run the GUI with:
#   .venv/bin/python gui/workbench.py
#   gui/run-workbench.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

VENV_DIR="${DISKINFER_VENV:-$REPO_ROOT/.venv}"
PIP_INDEX="${DISKINFER_PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PYTHON="${PYTHON:-python3}"
REQUIREMENTS="$SCRIPT_DIR/requirements.txt"
UPGRADE=0

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --venv-dir DIR   venv location (default: <repo>/.venv)
  --upgrade        reinstall/upgrade PySide6
  --no-index-url   use pip's default index instead of the Tsinghua mirror
  -h, --help       show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --venv-dir)   [ $# -ge 2 ] || { echo "option needs a value: $1" >&2; exit 2; }; VENV_DIR="$2"; shift 2 ;;
        --upgrade)    UPGRADE=1; shift ;;
        --no-index-url) PIP_INDEX=""; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

command -v "$PYTHON" >/dev/null 2>&1 || { echo "ERROR: $PYTHON not found in PATH" >&2; exit 1; }

version_ok=0
py_version="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0.0)"
case "$py_version" in
    3.1[0-9]) version_ok=1 ;;
    *)        version_ok=0 ;;
esac
if [ "$version_ok" = "0" ]; then
    echo "ERROR: Python 3.10+ is required for PySide6 (found $py_version: $("$PYTHON" --version 2>&1))" >&2
    exit 1
fi

echo "==> GUI venv: $VENV_DIR"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    "$PYTHON" -m venv "$VENV_DIR" || {
        cat >&2 <<EOF
ERROR: python3 -m venv failed. On Debian/Ubuntu install the venv module first:
  sudo apt-get install python3-venv
EOF
        exit 1
    }
else
    echo "  reusing existing venv"
fi

VENV_PY="$VENV_DIR/bin/python"
if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
    echo "  bootstrapping pip with ensurepip"
    "$VENV_PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
fi
"$VENV_PY" -m pip --version >/dev/null 2>&1 || {
    echo "ERROR: the venv has no pip. Create it again with: $PYTHON -m venv --clear $VENV_DIR" >&2
    exit 1
}

pip_args=(install --disable-pip-version-check)
[ "$UPGRADE" = "1" ] && pip_args+=(--upgrade)
[ -n "$PIP_INDEX" ] && pip_args+=(-i "$PIP_INDEX")

echo "==> installing PySide6 (index: ${PIP_INDEX:-default pypi})"
"$VENV_PY" -m pip "${pip_args[@]}" -r "$REQUIREMENTS"

echo
echo "==> checking the Qt platform plugin can be loaded (offscreen)"
QT_QPA_PLATFORM=offscreen "$VENV_PY" - <<'PY'
import sys
try:
    from PySide6 import QtCore, QtWidgets
except Exception as exc:  # pragma: no cover
    print("ERROR: PySide6 import failed:", exc, file=sys.stderr)
    raise SystemExit(1)
print("PySide6", QtCore.__version__)
app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
w = QtWidgets.QLabel("diskinfer GUI ok")
w.resize(240, 60)
img = w.grab()
print("offscreen render ok:", img.width(), "x", img.height())
PY

echo
echo "done. run the GUI with:"
echo "  $VENV_DIR/bin/python $SCRIPT_DIR/workbench.py"
echo "  $SCRIPT_DIR/run-workbench.sh"
