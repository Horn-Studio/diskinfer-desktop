#!/usr/bin/env bash
# diskinfer Linux x64 build script.
#
# Linux counterpart of build/build-windows.ps1. Builds the diskinfer llama.cpp
# fork with GCC + make (tested on Ubuntu 24.04 / WSL2, cmake 3.28, gcc 13) and
# collects stripped, self-contained executables in build/out/linux-x64/:
#
#   disktui           (built from target llama-diskui)
#   diskrun           (built from target llama-diskrun)
#   diskc             (built from target llama-diskc: streaming chat engine used
#                      by the PySide6 workbench chat mode, JSON lines on stdio)
#   llama-completion  (built from target llama-completion)
#
# Everything is static (BUILD_SHARED_LIBS=OFF) so the binaries have no
# libllama/libggml .so dependencies; only glibc/gcc runtime is required.
#
# WSL note: /mnt/f and /mnt/c are slow. When the source tree lives on a Windows
# drive (drvfs, path starts with /mnt/), this script mirrors it to a local work
# dir (~/.cache/diskinfer-linux by default) and builds there, then copies the
# results back. Pass --no-local-copy to compile directly from the repo.
#
# Usage:
#   build/build-linux.sh                       # full build (all 4 targets)
#   build/build-linux.sh -j 6                  # explicit parallelism (<= 6)
#   build/build-linux.sh -T llama-diskui       # incremental single target
#   build/build-linux.sh --clean               # remove the work/build dirs first
#   build/build-linux.sh --with-gui            # also create .venv + pip install PySide6
#   build/build-linux.sh --help
#
# Then: build/package-linux.sh  -> dist/diskinfer-linux-1.0-preview-x64.tar.gz

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# the desktop repo keeps one shared src/ at its root and the Linux tree under linux/;
# a standalone Linux checkout keeps src/ next to build/
SRC_ROOT="$REPO_ROOT/src"
if [ ! -d "$SRC_ROOT/llama.cpp-fork" ] && [ -d "$REPO_ROOT/../src/llama.cpp-fork" ]; then
    SRC_ROOT="$(cd -- "$REPO_ROOT/.." && pwd)/src"
fi

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
SOURCE="$SRC_ROOT/llama.cpp-fork"
OUT_DIR="$REPO_ROOT/build/out/linux-x64"
BUILD_DIR=""
JOBS=0
TARGET_LIST=()
HAVE_TARGET_ARG=0
CLEAN=0
LOCAL_COPY=auto
WITH_GUI=0
VENV_DIR="${DISKINFER_VENV:-$REPO_ROOT/.venv}"
WORK_DIR="${DISKINFER_BUILD_HOME:-$HOME/.cache/diskinfer-linux}"
PIP_INDEX="${DISKINFER_PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
SHARED_LIBS=0
OPENMP=0
VERBOSE=0
NO_STRIP=0

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -s, --source DIR        llama.cpp fork source tree (default: <repo>/src/llama.cpp-fork)
  -B, --build-dir DIR     cmake build tree (default: local work dir, or <repo>/build/build-linux)
  -o, --out-dir DIR       output dir for the stripped binaries (default: <repo>/build/out/linux-x64)
  -j, --jobs N            parallel jobs (default: min(nproc, 6))
  -T, --target NAME       build only this cmake target (repeatable). Aliases: disktui->llama-diskui,
                          diskrun->llama-diskrun, diskc->llama-diskc, completion->llama-completion
      --clean             remove the build tree first (and stale outputs)
      --shared-libs       build with shared libs instead of static binaries
      --openmp            enable OpenMP (GGML_OPENMP=ON)
      --no-local-copy     compile directly in the source tree (use when source is on a fast local disk)
      --local-copy        force mirroring the source to the local work dir (default when under /mnt/)
      --work-dir DIR      local work dir used for the source mirror/build tree
      --with-gui          create the Python venv and install PySide6 (Tsinghua mirror)
      --venv-dir DIR      venv used by --with-gui (default: <repo>/.venv)
      --no-strip          keep the un-stripped binaries
  -v, --verbose           echo the cmake/make commands
  -h, --help              show this help

Environment:
  DISKINFER_BUILD_HOME   local work dir (default ~/.cache/diskinfer-linux)
  DISKINFER_VENV         GUI venv dir (same as --venv-dir)
  DISKINFER_PIP_INDEX    pip index URL for PySide6 (default Tsinghua mirror)
  DISKINFER_SRC          source tree when --source is not given
  JOBS                   default parallelism

Examples:
  build/build-linux.sh
  build/build-linux.sh -j 6 -T llama-diskui
  wsl -e bash build/build-linux.sh --with-gui
EOF
}

log()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--source)     [ $# -ge 2 ] || die "$1 needs a value"; SOURCE="$2"; shift 2 ;;
        -B|--build-dir)  [ $# -ge 2 ] || die "$1 needs a value"; BUILD_DIR="$2"; shift 2 ;;
        -o|--out-dir)    [ $# -ge 2 ] || die "$1 needs a value"; OUT_DIR="$2"; shift 2 ;;
        -j|--jobs)       [ $# -ge 2 ] || die "$1 needs a value"; JOBS="$2"; shift 2 ;;
        -T|--target)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$2" in
                disktui|diskui|llama-diskui)      TARGET_LIST+=(llama-diskui) ;;
                diskrun|llama-diskrun)            TARGET_LIST+=(llama-diskrun) ;;
                diskc|llama-diskc)                TARGET_LIST+=(llama-diskc) ;;
                completion|llama-completion)      TARGET_LIST+=(llama-completion) ;;
                *) die "unknown target: $2 (llama-diskui|llama-diskrun|llama-diskc|llama-completion)" ;;
            esac
            HAVE_TARGET_ARG=1
            shift 2 ;;
        --clean)         CLEAN=1; shift ;;
        --shared-libs)   SHARED_LIBS=1; shift ;;
        --openmp)        OPENMP=1; shift ;;
        --no-local-copy) LOCAL_COPY=0; shift ;;
        --local-copy)    LOCAL_COPY=1; shift ;;
        --work-dir)      [ $# -ge 2 ] || die "$1 needs a value"; WORK_DIR="$2"; shift 2 ;;
        --with-gui)      WITH_GUI=1; shift ;;
        --venv-dir)      [ $# -ge 2 ] || die "$1 needs a value"; VENV_DIR="$2"; shift 2 ;;
        --no-strip)      NO_STRIP=1; shift ;;
        -v|--verbose)    VERBOSE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

if [ -n "${DISKINFER_SRC:-}" ] && [ "$SOURCE" = "$SRC_ROOT/llama.cpp-fork" ]; then
    SOURCE="$DISKINFER_SRC"
fi

# default targets when -T was not given
if [ "$HAVE_TARGET_ARG" -eq 0 ]; then
    TARGET_LIST=(llama-diskui llama-diskrun llama-diskc llama-completion)
fi

# ---------------------------------------------------------------------------
# resolve paths / parallelism
# ---------------------------------------------------------------------------
resolve_path() { # resolve relative to the caller's cwd, keep non-existing paths usable
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$(pwd)" "$1" ;;
    esac
}
SOURCE="$(resolve_path "$SOURCE")"
OUT_DIR="$(resolve_path "$OUT_DIR")"
[ -n "$BUILD_DIR" ] && BUILD_DIR="$(resolve_path "$BUILD_DIR")"

[ -d "$SOURCE" ] || die "source tree not found: $SOURCE"
[ -f "$SOURCE/src/llama-disk.cpp" ] || die "not a diskinfer llama.cpp fork (missing src/llama-disk.cpp): $SOURCE"
[ -f "$SOURCE/examples/diskui/diskui.cpp" ] || die "fork is missing examples/diskui: $SOURCE"

if [ "$JOBS" -le 0 ]; then
    if [ -n "${JOBS_ENV:-}" ]; then
        JOBS="$JOBS_ENV"
    else
        JOBS="$(nproc 2>/dev/null || echo 4)"
        [ "$JOBS" -gt 6 ] && JOBS=6
    fi
fi
[ "$JOBS" -ge 1 ] || die "invalid job count: $JOBS"
NPROC="$(nproc 2>/dev/null || echo 4)"
[ "$JOBS" -gt "$NPROC" ] && JOBS="$NPROC"

IS_WSL=0
if grep -qi 'microsoft' /proc/version 2>/dev/null; then IS_WSL=1; fi

case "$SOURCE" in
    /mnt/*) SOURCE_IS_SLOW=1 ;;
    *)      SOURCE_IS_SLOW=0 ;;
esac
if [ "$LOCAL_COPY" = "auto" ]; then
    if [ "$SOURCE_IS_SLOW" = "1" ] && command -v rsync >/dev/null 2>&1; then
        LOCAL_COPY=1
    else
        LOCAL_COPY=0
    fi
fi

if [ "$LOCAL_COPY" = "1" ]; then
    mkdir -p "$WORK_DIR"
    LOCAL_SRC="$WORK_DIR/src"
    if [ -z "$BUILD_DIR" ]; then BUILD_DIR="$WORK_DIR/build"; fi
    BUILD_SRC="$LOCAL_SRC"
else
    if [ -z "$BUILD_DIR" ]; then BUILD_DIR="$REPO_ROOT/build/build-linux"; fi
    BUILD_SRC="$SOURCE"
fi

CMAKE="$(command -v cmake || true)"
[ -n "$CMAKE" ] || die "cmake not found in PATH (need >= 3.20)"
CC_BIN="$(command -v gcc || true)"
CXX_BIN="$(command -v g++ || true)"
[ -n "$CC_BIN" ] && [ -n "$CXX_BIN" ] || die "gcc/g++ not found in PATH"
[ -n "$(command -v make || true)" ] || die "make not found in PATH"

CMAKE_VERSION="$("$CMAKE" --version | head -1)"
GCC_VERSION="$("$CC_BIN" --version | head -1)"

log 'diskinfer Linux build'
log "  repo       : $REPO_ROOT"
log "  source     : $SOURCE"
log "  build src  : $BUILD_SRC"
log "  build dir  : $BUILD_DIR"
log "  out dir    : $OUT_DIR"
log "  targets    : ${TARGET_LIST[*]}"
log "  jobs       : $JOBS (nproc $NPROC)"
log "  libraries  : $([ "$SHARED_LIBS" = 1 ] && echo 'shared' || echo 'static (single-file executables)')"
log "  wsl        : $IS_WSL   local source copy: $LOCAL_COPY"
log "  cmake      : $CMAKE_VERSION"
log "  gcc        : $GCC_VERSION"

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
if [ "$CLEAN" = "1" ]; then
    case "$BUILD_DIR" in
        ""|"/"|"$HOME"|"$REPO_ROOT"|"$REPO_ROOT/src"|"$SOURCE") die "refusing to remove unsafe build dir: $BUILD_DIR" ;;
    esac
    if [ -d "$BUILD_DIR" ]; then
        step "removing build dir: $BUILD_DIR"
        rm -rf -- "$BUILD_DIR"
    fi
    if [ "$LOCAL_COPY" = "1" ] && [ -d "$LOCAL_SRC" ]; then
        step "refreshing local source mirror"
        rm -rf -- "$LOCAL_SRC"
    fi
    if [ -d "$OUT_DIR" ]; then
        step "removing stale outputs from: $OUT_DIR"
        rm -f -- "$OUT_DIR/disktui" "$OUT_DIR/diskrun" "$OUT_DIR/diskc" \
                 "$OUT_DIR/llama-completion" "$OUT_DIR"/*.so* 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# mirror source when it lives on a slow drvfs mount
# ---------------------------------------------------------------------------
LOG_DIR="$REPO_ROOT/build"
mkdir -p "$LOG_DIR"
BUILD_LOG="$LOG_DIR/build-linux.log"

run_logged() { # run a command, stream output, keep a log copy
    if [ "$VERBOSE" = "1" ]; then log "+ $*"; fi
    "$@" 2>&1 | tee -a "$BUILD_LOG"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}

: > "$BUILD_LOG"

if [ "$LOCAL_COPY" = "1" ]; then
    step "mirroring source to $BUILD_SRC (drvfs is slow, compiling locally)"
    mkdir -p "$(dirname -- "$LOCAL_SRC")"
    if [ "$VERBOSE" = "1" ]; then log "+ rsync -a --delete --exclude .git $SOURCE/ $LOCAL_SRC/"; fi
    rsync -a --delete --exclude .git --exclude '__pycache__' "$SOURCE/" "$LOCAL_SRC/" \
        || die "rsync of the source tree failed"
fi

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
step 'configuring'
CMAKE_ARGS=(
    -S "$BUILD_SRC"
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=ON
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_CURL=OFF
    -DGGML_NATIVE=OFF
    -DGGML_LLAMAFILE=OFF
    -DDISKINFER_UI_VERSION=1.1-preview
)
if [ "$SHARED_LIBS" = "1" ]; then
    CMAKE_ARGS+=(-DBUILD_SHARED_LIBS=ON)
else
    CMAKE_ARGS+=(-DBUILD_SHARED_LIBS=OFF)
fi
if [ "$OPENMP" = "1" ]; then
    CMAKE_ARGS+=(-DGGML_OPENMP=ON)
else
    CMAKE_ARGS+=(-DGGML_OPENMP=OFF)
fi
if [ "$VERBOSE" = "1" ]; then log "+ $CMAKE ${CMAKE_ARGS[*]}"; fi
if ! run_logged "$CMAKE" "${CMAKE_ARGS[@]}"; then
    die "cmake configure failed (see $BUILD_LOG). If this tree was configured with other options, rerun with --clean."
fi

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
step "building targets: ${TARGET_LIST[*]}"
if ! run_logged make -C "$BUILD_DIR" -j"$JOBS" "${TARGET_LIST[@]}"; then
    die "build failed (see $BUILD_LOG). Rerun with --clean after changing configure options."
fi

BIN_DIR="$BUILD_DIR/bin"
[ -d "$BIN_DIR" ] || die "build output dir not found: $BIN_DIR"

# ---------------------------------------------------------------------------
# collect + strip
# ---------------------------------------------------------------------------
step 'collecting outputs'
copy_out() { # from-name to-name
    local from="$BIN_DIR/$1" to="$OUT_DIR/$2"
    [ -f "$from" ] || die "expected build output not found: $from"
    cp -f -- "$from" "$to"
    chmod 755 -- "$to"
    if [ "$NO_STRIP" != "1" ]; then
        strip --strip-all -- "$to" 2>/dev/null || warn "strip failed for $to (binary still usable)"
    fi
    log "  $(printf '%-18s' "$1") -> $to"
}
copy_out llama-diskui      disktui
copy_out llama-diskrun     diskrun
copy_out llama-diskc       diskc
copy_out llama-completion  llama-completion

if [ "$SHARED_LIBS" = "1" ]; then
    shopt -s nullglob
    sos=("$BIN_DIR"/*.so*)
    if [ "${#sos[@]}" -gt 0 ]; then
        cp -f -- "${sos[@]}" "$OUT_DIR/"
        log "  copied ${#sos[@]} shared library file(s)"
    fi
    shopt -u nullglob
fi

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
step 'verifying outputs'
failed=0
for name in disktui diskrun diskc llama-completion; do
    path="$OUT_DIR/$name"
    [ -f "$path" ] || { warn "missing expected output: $path"; failed=1; continue; }
    bytes=$(stat -c '%s' "$path" 2>/dev/null || echo 0)
    [ "$bytes" -gt 0 ] || { warn "zero-length output: $path"; failed=1; continue; }
    log "  ok $(printf '%-18s' "$name") $(( bytes / 1024 / 1024 )) MiB"
done
[ "$failed" = "0" ] || die "some outputs are missing; see $BUILD_LOG"

if [ -x "$OUT_DIR/llama-completion" ]; then
    version_out="$("$OUT_DIR/llama-completion" --version 2>&1 | head -3 || true)"
    if [ -n "$version_out" ]; then
        log "  ok llama-completion --version: $(printf '%s' "$version_out" | head -1)"
    else
        warn "llama-completion --version printed nothing (dynamic loader problem?)"
    fi
fi

# ---------------------------------------------------------------------------
# optional: Python GUI environment
# ---------------------------------------------------------------------------
if [ "$WITH_GUI" = "1" ]; then
    step "setting up the PySide6 GUI venv: $VENV_DIR"
    if [ -f "$REPO_ROOT/gui/setup-venv.sh" ]; then
        DISKINFER_PIP_INDEX="$PIP_INDEX" bash "$REPO_ROOT/gui/setup-venv.sh" --venv-dir "$VENV_DIR" \
            || die "GUI venv setup failed (network?). The C++ build above is complete; retry just the GUI with: gui/setup-venv.sh"
    else
        warn "gui/setup-venv.sh not found, skipping GUI venv setup"
    fi
else
    log ''
    log "note: the PySide6 GUI is optional. Set it up with:"
    log "  build/build-linux.sh --with-gui        (or: gui/setup-venv.sh)"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
total=0
for name in disktui diskrun diskc llama-completion; do
    total=$(( total + $(stat -c '%s' "$OUT_DIR/$name" 2>/dev/null || echo 0) ))
done
step 'done'
log "  out dir   : $OUT_DIR"
log "  total     : $(( total / 1024 / 1024 )) MiB (stripped)"
log "  build log : $BUILD_LOG"
log ''
log "next:"
log "  $OUT_DIR/diskrun -m model.gguf -p 'The capital of France is' -n 8"
log "  $OUT_DIR/disktui -m model.gguf            (TUI; needs a VT terminal)"
log "  device/diskinfer                          (launcher: finds a model + arena)"
log "  test/run-tests.sh                         (end-to-end regression)"
log "  build/package-linux.sh                    (dist tarball)"
