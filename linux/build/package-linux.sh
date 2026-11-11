#!/usr/bin/env bash
# Package the built diskinfer Linux x64 binaries into a release tarball.
#
# Linux counterpart of the Windows dist/ package. Produces:
#
#   dist/diskinfer-linux-1.1-preview-x64.tar.gz
#   dist/SHA256SUMS.txt
#
# Tarball layout (top-level directory diskinfer-linux-<version>-x64/):
#
#   bin/                 disktui / diskrun / diskc / llama-completion (stripped)
#   device/              Linux launcher (diskinfer)
#   gui/                 PySide6 workbench (sources, screenshots, setup script)
#   test/                end-to-end regression script + tools
#   src/llama.cpp-fork/  complete llama.cpp fork (optional, --no-src to skip)
#   README.md / LICENSE / install.sh / SHA256SUMS.txt
#
# Usage:
#   build/package-linux.sh                     # from build/out/linux-x64
#   build/package-linux.sh --version 1.0-preview
#   build/package-linux.sh --no-src            # smaller tarball, no C++ sources
#   build/package-linux.sh --bin-dir /path/to/bin --dist-dir /path/to/dist

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shared source tree: standalone checkout has src/ next to build/, the desktop repo has it
# one level up (linux/ is the Linux-specific subtree)
SRC_ROOT="$REPO_ROOT/src"
if [ ! -d "$SRC_ROOT/llama.cpp-fork" ] && [ -d "$REPO_ROOT/../src/llama.cpp-fork" ]; then
    SRC_ROOT="$(cd -- "$REPO_ROOT/.." && pwd)/src"
fi

VERSION="1.1-preview"
ARCH="x64"
BIN_DIR="$REPO_ROOT/build/out/linux-x64"
DIST_DIR="$REPO_ROOT/dist"
INCLUDE_SRC=1
KEEP_STAGE=0

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
      --version VER    release version string (default: 1.0-preview)
      --bin-dir DIR    directory with the built binaries (default: <repo>/build/out/linux-x64)
      --dist-dir DIR   output directory for the tarball (default: <repo>/dist)
      --no-src         do not include src/llama.cpp-fork in the tarball
      --keep-stage     keep the staging directory (build/package/...) for inspection
  -h, --help           show this help
EOF
}

log()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   [ $# -ge 2 ] || die "$1 needs a value"; VERSION="$2"; shift 2 ;;
        --bin-dir)   [ $# -ge 2 ] || die "$1 needs a value"; BIN_DIR="$2"; shift 2 ;;
        --dist-dir)  [ $# -ge 2 ] || die "$1 needs a value"; DIST_DIR="$2"; shift 2 ;;
        --no-src)    INCLUDE_SRC=0; shift ;;
        --keep-stage) KEEP_STAGE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

NAME="diskinfer-linux-${VERSION}-${ARCH}"
STAGE_ROOT="${DISKINFER_STAGE_DIR:-${TMPDIR:-/tmp}/diskinfer-package}"
STAGE="$STAGE_ROOT/$NAME"
TARBALL="$DIST_DIR/$NAME.tar.gz"

[ -d "$BIN_DIR" ] || die "bin dir not found: $BIN_DIR (run build/build-linux.sh first)"
for exe in disktui diskrun diskc llama-completion; do
    [ -x "$BIN_DIR/$exe" ] || die "missing executable: $BIN_DIR/$exe (run build/build-linux.sh first)"
done

step "staging $NAME"
rm -rf -- "$STAGE"
mkdir -p "$STAGE"/{bin,device,gui,test/tools}

# --- binaries --------------------------------------------------------------
for exe in disktui diskrun diskc llama-completion; do
    cp -f -- "$BIN_DIR/$exe" "$STAGE/bin/$exe"
    chmod 755 -- "$STAGE/bin/$exe"
done
log "  bin: $(ls "$STAGE/bin" | tr '\n' ' ')"

# --- launcher --------------------------------------------------------------
cp -f -- "$REPO_ROOT/device/diskinfer" "$STAGE/device/diskinfer"
chmod 755 -- "$STAGE/device/diskinfer"
log "  device: diskinfer"

# --- GUI -------------------------------------------------------------------
for f in workbench.py runner.py chatpanel.py theme.py i18n.py requirements.txt README.md \
         run-workbench.sh setup-venv.sh; do
    if [ -f "$REPO_ROOT/gui/$f" ]; then
        cp -f -- "$REPO_ROOT/gui/$f" "$STAGE/gui/$f"
    else
        die "missing GUI file: gui/$f"
    fi
done
chmod 755 -- "$STAGE/gui/run-workbench.sh" "$STAGE/gui/setup-venv.sh"
for png in "$REPO_ROOT"/gui/screenshot-*.png; do
    [ -f "$png" ] && cp -f -- "$png" "$STAGE/gui/"
done
log "  gui: $(ls "$STAGE/gui" | tr '\n' ' ')"

# --- tests -----------------------------------------------------------------
cp -f -- "$REPO_ROOT/test/run-tests.sh" "$STAGE/test/run-tests.sh"
chmod 755 -- "$STAGE/test/run-tests.sh"
[ -f "$REPO_ROOT/test/tools/gguf-info.py" ] && cp -f -- "$REPO_ROOT/test/tools/gguf-info.py" "$STAGE/test/tools/"
[ -f "$REPO_ROOT/test/REPORT.md" ] && cp -f -- "$REPO_ROOT/test/REPORT.md" "$STAGE/test/"
[ -f "$REPO_ROOT/test/REPORT-moe.md" ] && cp -f -- "$REPO_ROOT/test/REPORT-moe.md" "$STAGE/test/"
[ -f "$REPO_ROOT/test/GUI-VERIFY.md" ] && cp -f -- "$REPO_ROOT/test/GUI-VERIFY.md" "$STAGE/test/"
if [ -d "$REPO_ROOT/test/i18n" ]; then
    mkdir -p "$STAGE/test/i18n"
    cp -f -- "$REPO_ROOT"/test/i18n/*.txt "$STAGE/test/i18n/" 2>/dev/null || true
    cp -f -- "$REPO_ROOT"/test/i18n/*.raw.log "$STAGE/test/i18n/" 2>/dev/null || true
fi
log "  test: $(find "$STAGE/test" -type f | sed "s#^$STAGE/test/##" | sort | tr '\n' ' ')"

# --- docs / install --------------------------------------------------------
cp -f -- "$REPO_ROOT/README.md" "$STAGE/README.md"
if [ -f "$REPO_ROOT/LICENSE" ]; then
    cp -f -- "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"
elif [ -f "$SRC_ROOT/llama.cpp-fork/LICENSE" ]; then
    cp -f -- "$SRC_ROOT/llama.cpp-fork/LICENSE" "$STAGE/LICENSE"
fi
cp -f -- "$REPO_ROOT/install.sh" "$STAGE/install.sh" 2>/dev/null && chmod 755 "$STAGE/install.sh" || true

# --- optional: full fork sources ------------------------------------------
if [ "$INCLUDE_SRC" = "1" ]; then
    step "copying src/llama.cpp-fork (large, use --no-src to skip)"
    mkdir -p "$STAGE/src"
    # keep the tree useful but drop obvious local/build junk
    tar -C "$SRC_ROOT" -cf - \
        --exclude='llama.cpp-fork/.git' \
        --exclude='llama.cpp-fork/build' \
        --exclude='llama.cpp-fork/build-*' \
        --exclude='__pycache__' \
        llama.cpp-fork 2>/dev/null | tar -C "$STAGE/src" -xf -
    log "  src: $(du -sh "$STAGE/src/llama.cpp-fork" | cut -f1)"
    for f in UPSTREAM.txt PATCHES.md; do
        [ -f "$SRC_ROOT/$f" ] && cp -f -- "$REPO_ROOT/src/$f" "$STAGE/src/$f"
    done
    if [ -d "$REPO_ROOT/patch" ]; then
        mkdir -p "$STAGE/patch"
        cp -f -- "$REPO_ROOT"/patch/* "$STAGE/patch/" 2>/dev/null || true
    fi
else
    log "  src: skipped (--no-src)"
fi

# --- inner checksum file ---------------------------------------------------
step "writing SHA256SUMS.txt"
(
    cd "$STAGE"
    find . -type f ! -name SHA256SUMS.txt -print0 \
        | sort -z \
        | xargs -0 sha256sum > SHA256SUMS.txt
    log "  $(wc -l < SHA256SUMS.txt) files"
)

# --- tarball ---------------------------------------------------------------
step "creating $TARBALL"
mkdir -p "$DIST_DIR"
rm -f -- "$TARBALL"
tar -C "$STAGE_ROOT" -czf "$TARBALL" "$NAME"

# --- outer checksums -------------------------------------------------------
step "writing $DIST_DIR/SHA256SUMS.txt"
(
    cd "$DIST_DIR"
    : > SHA256SUMS.txt
    # keep checksums for every release tarball currently present
    for f in *.tar.gz *.zip; do
        [ -f "$f" ] && sha256sum "$f" >> SHA256SUMS.txt
    done
    sort -o SHA256SUMS.txt SHA256SUMS.txt
)

[ "$KEEP_STAGE" = "1" ] || rm -rf -- "$STAGE"

log ''
log '=== done ==='
log "  tarball : $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
log "  sum     : $(cd "$DIST_DIR" && sha256sum "$NAME.tar.gz" | cut -d' ' -f1)"
log "  sha file: $DIST_DIR/SHA256SUMS.txt"
log ''
log "verify: cd $DIST_DIR && sha256sum -c SHA256SUMS.txt"
log "install: tar -xzf $TARBALL && cd $NAME && ./install.sh --gui"
