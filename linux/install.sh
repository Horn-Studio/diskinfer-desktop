#!/usr/bin/env bash
# Install the diskinfer Linux x64 build for the current user (no root needed).
#
# Installs the engine binaries + launcher into a prefix (default ~/.local):
#
#   <prefix>/bin/disktui / diskrun / diskc / llama-completion
#   <prefix>/bin/diskinfer            (launcher; finds a model and runs disktui)
#   <prefix>/share/diskinfer/gui/...  (PySide6 workbench sources, with --gui)
#
# Works both inside the source repo and inside an extracted release tarball
# (binaries under build/out/linux-x64 or bin/).
#
# Usage:
#   ./install.sh                 # binaries + launcher into ~/.local/bin
#   ./install.sh --gui           # also install the GUI and create its venv
#   ./install.sh --prefix /usr/local --gui
#   ./install.sh --uninstall
#
# Requirements: bash, a glibc-based x86_64 Linux. PySide6 (GUI only) is
# installed into a private venv under <prefix>/share/diskinfer/venv.
#
# messages: en / zh-Hans / zh-Hant, auto-detected (contract v5 §1.3):
#   --lang CLI > DISKINFER_LANG > $LC_ALL > $LC_MESSAGES > $LANG > /etc/default/locale > en

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink -f -- "$SELF")"; done
HERE="$(cd -- "$(dirname -- "$SELF")" && pwd)"

PREFIX="${PREFIX:-$HOME/.local}"
WITH_GUI=0
UNINSTALL=0
PIP_INDEX="${DISKINFER_PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
lang_from_tag() {
    local tag
    tag="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$tag" in
        *hant*|*tw*|*hk*|*mo*) printf '%s' zh-hant ;;
        zh*)                   printf '%s' zh-hans ;;
        *)                     printf '%s' en ;;
    esac
}

probe_system_lang() {
    local probe
    probe="${LC_ALL:-}"
    [ -z "$probe" ] && probe="${LC_MESSAGES:-}"
    [ -z "$probe" ] && probe="${LANG:-}"
    if [ -z "$probe" ] && [ -r /etc/default/locale ]; then
        probe="$(grep '^LANG=' /etc/default/locale 2>/dev/null | head -1 | sed 's/^LANG=//; s/^"//; s/"$//' || true)"
    fi
    printf '%s' "$probe"
}

detect_lang() {
    local explicit="${1:-}"
    if [ -z "$explicit" ] && [ -n "${DISKINFER_LANG:-}" ]; then
        explicit="$DISKINFER_LANG"
    fi
    if [ -z "$explicit" ]; then
        explicit="$(probe_system_lang)"
    fi
    lang_from_tag "$explicit"
}

# t <en> <zh-Hans> <zh-Hant>
t() {
    case "$L10N" in
        zh-hans) printf '%s' "$2" ;;
        zh-hant) printf '%s' "$3" ;;
        *)       printf '%s' "$1" ;;
    esac
}

scan_lang_arg() {
    local prev="" a
    for a in "$@"; do
        case "$prev" in
            --lang) printf '%s' "$a"; return 0 ;;
        esac
        case "$a" in
            --lang=*) printf '%s' "${a#*=}"; return 0 ;;
        esac
        prev="$a"
    done
    return 1
}

usage() {
    case "$L10N" in
        zh-hans)
            cat <<'EOF'
安装 diskinfer Linux x64 版到当前用户（不需要 root）。

用法:
  ./install.sh                 # 二进制 + 启动器装进 ~/.local/bin
  ./install.sh --gui           # 同时安装 GUI（并创建其 venv）
  ./install.sh --prefix /usr/local --gui
  ./install.sh --uninstall

选项:
      --prefix DIR   安装前缀（默认: $PREFIX 或 ~/.local）
      --gui          同时安装 PySide6 工作台 + 其 venv
      --uninstall    删除已安装的文件
      --lang TAG     界面语言: auto / en / zh-Hans / zh-Hant（默认按系统；
                     也可用环境变量 DISKINFER_LANG 覆盖）
      --no-index-url 使用 pip 默认源（不用清华镜像）
  -h, --help         显示本帮助
EOF
            ;;
        zh-hant)
            cat <<'EOF'
安裝 diskinfer Linux x64 版到目前使用者（不需要 root）。

用法:
  ./install.sh                 # 二進位 + 啟動器裝進 ~/.local/bin
  ./install.sh --gui           # 同時安裝 GUI（並建立其 venv）
  ./install.sh --prefix /usr/local --gui
  ./install.sh --uninstall

選項:
      --prefix DIR   安裝前綴（預設: $PREFIX 或 ~/.local）
      --gui          同時安裝 PySide6 工作台 + 其 venv
      --uninstall    刪除已安裝的檔案
      --lang TAG     介面語言: auto / en / zh-Hans / zh-Hant（預設依系統；
                     也可用環境變數 DISKINFER_LANG 覆蓋）
      --no-index-url 使用 pip 預設來源（不用清華鏡像）
  -h, --help         顯示本說明
EOF
            ;;
        *)
            cat <<'EOF'
Install the diskinfer Linux x64 build for the current user (no root needed).

Usage:
  ./install.sh                 # binaries + launcher into ~/.local/bin
  ./install.sh --gui           # also install the GUI and create its venv
  ./install.sh --prefix /usr/local --gui
  ./install.sh --uninstall

Options:
      --prefix DIR   install prefix (default: $PREFIX or ~/.local)
      --gui          also install the PySide6 workbench + its venv
      --uninstall    remove the installed files
      --lang TAG     UI language: auto / en / zh-Hans / zh-Hant (default: system;
                     the DISKINFER_LANG environment variable works too)
      --no-index-url use pip's default index instead of the Tsinghua mirror
  -h, --help         show this help
EOF
            ;;
    esac
}

log()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '%s %s\n' "$(t 'warning:' '警告:' '警告:')" "$*" >&2; }
die()  { printf '%s %s\n' "$(t 'ERROR:' '错误:' '錯誤:')" "$*" >&2; exit 1; }

LANG_CLI=""
LANG_CLI="$(scan_lang_arg "$@" || true)"
L10N="$(detect_lang "$LANG_CLI")"
export DISKINFER_LANG="$L10N"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)  [ $# -ge 2 ] || die "$1 $(t 'needs a value' '需要一个值' '需要一個值')"; PREFIX="$2"; shift 2 ;;
        --gui)     WITH_GUI=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --no-index-url) PIP_INDEX=""; shift ;;
        --lang)    [ $# -ge 2 ] || die "$1 $(t 'needs a value' '需要一个值' '需要一個值')"; shift 2 ;;
        --lang=*)  shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "$(t "unknown argument: $1 (try --help)" "未知参数: $1（试试 --help）" "未知參數: $1（試試 --help）")" ;;
    esac
done

# locate the payload: source repo layout or extracted release layout
if [ -d "$HERE/build/out/linux-x64" ]; then
    BIN_SRC="$HERE/build/out/linux-x64"
elif [ -d "$HERE/bin" ]; then
    BIN_SRC="$HERE/bin"
else
    die "$(t "cannot find the binaries (looked for $HERE/bin and $HERE/build/out/linux-x64)" "找不到二进制（找过 $HERE/bin 和 $HERE/build/out/linux-x64）" "找不到二進位（找過 $HERE/bin 和 $HERE/build/out/linux-x64）")"
fi

BIN_DST="$PREFIX/bin"
APP_DST="$PREFIX/share/diskinfer"

if [ "$UNINSTALL" = "1" ]; then
    step "$(t "removing diskinfer from $PREFIX" "从 $PREFIX 卸载 diskinfer" "從 $PREFIX 解除安裝 diskinfer")"
    rm -f -- "$BIN_DST/disktui" "$BIN_DST/diskrun" "$BIN_DST/diskc" \
             "$BIN_DST/llama-completion" "$BIN_DST/diskinfer"
    rm -rf -- "$APP_DST"
    log "$(t 'done. (models in ~/models were not touched)' '完成。（~/models 里的模型没有动）' '完成。（~/models 裡的模型沒有動）')"
    exit 0
fi

command -v uname >/dev/null 2>&1 || die "$(t 'uname not found' '找不到 uname' '找不到 uname')"
[ "$(uname -s)" = "Linux" ] || die "$(t "this installer is for Linux only (found $(uname -s))" "本安装器只支持 Linux（当前系统: $(uname -s)）" "本安裝器只支援 Linux（目前系統: $(uname -s)）")"
[ "$(uname -m)" = "x86_64" ] || warn "$(t "binaries are x86_64; current machine is $(uname -m)" "二进制是 x86_64 的；当前机器是 $(uname -m)" "二進位是 x86_64 的；目前機器是 $(uname -m)")"

step "$(t "installing binaries to $BIN_DST" "安装二进制到 $BIN_DST" "安裝二進位到 $BIN_DST")"
mkdir -p "$BIN_DST"
for exe in disktui diskrun diskc llama-completion; do
    [ -x "$BIN_SRC/$exe" ] || die "$(t "missing binary: $BIN_SRC/$exe" "缺少二进制: $BIN_SRC/$exe" "缺少二進位: $BIN_SRC/$exe")"
    install -m 755 -- "$BIN_SRC/$exe" "$BIN_DST/$exe"
    log "  $BIN_DST/$exe"
done

LAUNCHER_SRC=""
for candidate in "$HERE/device/diskinfer" "$HERE/diskinfer"; do
    [ -f "$candidate" ] && LAUNCHER_SRC="$candidate" && break
done
[ -n "$LAUNCHER_SRC" ] || die "$(t 'launcher (device/diskinfer) not found next to install.sh' 'install.sh 旁边找不到启动器（device/diskinfer）' 'install.sh 旁邊找不到啟動器（device/diskinfer）')"
install -m 755 -- "$LAUNCHER_SRC" "$BIN_DST/diskinfer"
log "  $BIN_DST/diskinfer"

if [ "$WITH_GUI" = "1" ]; then
    GUI_SRC=""
    for candidate in "$HERE/gui" "$HERE/src/../gui"; do
        [ -f "$candidate/workbench.py" ] && GUI_SRC="$candidate" && break
    done
    [ -n "$GUI_SRC" ] || die "$(t 'GUI sources (gui/workbench.py) not found next to install.sh' 'install.sh 旁边找不到 GUI 源码（gui/workbench.py）' 'install.sh 旁邊找不到 GUI 原始碼（gui/workbench.py）')"
    step "$(t "installing the PySide6 workbench to $APP_DST" "安装 PySide6 工作台到 $APP_DST" "安裝 PySide6 工作台到 $APP_DST")"
    mkdir -p "$APP_DST"
    rm -rf -- "$APP_DST/gui"
    cp -a -- "$GUI_SRC" "$APP_DST/gui"
    chmod 755 "$APP_DST/gui/run-workbench.sh" "$APP_DST/gui/setup-venv.sh" 2>/dev/null || true
    # create the private venv + install PySide6
    if [ -x "$APP_DST/gui/setup-venv.sh" ]; then
        DISKINFER_PIP_INDEX="$PIP_INDEX" bash "$APP_DST/gui/setup-venv.sh" --venv-dir "$APP_DST/venv" \
            || warn "$(t "PySide6 setup failed; retry later with: DISKINFER_PIP_INDEX=$PIP_INDEX $APP_DST/gui/setup-venv.sh --venv-dir $APP_DST/venv" "PySide6 安装失败；稍后可用这条命令重试: DISKINFER_PIP_INDEX=$PIP_INDEX $APP_DST/gui/setup-venv.sh --venv-dir $APP_DST/venv" "PySide6 安裝失敗；稍後可用這條指令重試: DISKINFER_PIP_INDEX=$PIP_INDEX $APP_DST/gui/setup-venv.sh --venv-dir $APP_DST/venv")"
    fi
    # small wrapper so the GUI can be started from PATH
    cat > "$BIN_DST/diskinfer-gui" <<EOF
#!/usr/bin/env bash
exec "$APP_DST/venv/bin/python" "$APP_DST/gui/workbench.py" "\$@"
EOF
    chmod 755 "$BIN_DST/diskinfer-gui"
    log "  $BIN_DST/diskinfer-gui"
fi

step "$(t 'checking the installation' '检查安装' '檢查安裝')"
if [ -x "$BIN_DST/llama-completion" ]; then
    "$BIN_DST/llama-completion" --version 2>&1 | head -1 || warn "$(t 'llama-completion did not run' 'llama-completion 没能运行' 'llama-completion 沒能執行')"
fi
if [ -x "$BIN_DST/diskinfer" ]; then
    "$BIN_DST/diskinfer" -l 2>&1 | head -3 || true
fi

log ''
log "$(t 'done.' '完成。' '完成。')"
log "$(t "  TUI      : $BIN_DST/diskinfer            (put a .gguf in ~/models or pass -m)" "  TUI      : $BIN_DST/diskinfer            （把 .gguf 放进 ~/models，或用 -m 指定）" "  TUI      : $BIN_DST/diskinfer            （把 .gguf 放進 ~/models，或用 -m 指定）")"
log "$(t "  raw      : $BIN_DST/diskrun -m model.gguf -p 'hello' -n 16" "  raw      : $BIN_DST/diskrun -m model.gguf -p 'hello' -n 16" "  raw      : $BIN_DST/diskrun -m model.gguf -p 'hello' -n 16")"
[ "$WITH_GUI" = "1" ] && log "$(t "  GUI      : $BIN_DST/diskinfer-gui" "  GUI      : $BIN_DST/diskinfer-gui" "  GUI      : $BIN_DST/diskinfer-gui")"
if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DST:"; then
    log ''
    log "$(t "note: $BIN_DST is not in PATH. Add it with:" "注意: $BIN_DST 不在 PATH 里。用这条命令加上:" "注意: $BIN_DST 不在 PATH 裡。用這條指令加上:")"
    log "  export PATH=\"$BIN_DST:\$PATH\""
fi
