#!/usr/bin/env bash
# diskinfer Linux x64 end-to-end regression tests.
#
# Linux port of test/run-tests.ps1 (Windows): 11 cases, incl. the v0.9.0 TUI
# (scripted pty keys, i18n screenshots, --api-only HTTP probe)
# against the compiled binaries and also validates the diskc JSON-line protocol
# and (optionally) the PySide6 GUI offscreen.
#
#   case1  streaming-200       streaming weights with a 200 MiB arena (diskrun)
#   case2  native-baseline     native llama.cpp path (LLAMA_DISK_STREAM_MB=0 + -no-extra-bufts:
#   case3  auto-arena          arena auto-sized to min(RAM/8, 2048) MiB
#   case4  odirect-off         streaming with LLAMA_DISK_ODIRECT=0
#   case5  disktui-oneshot     v0.9.0 TUI one-shot: scripted keys (s start, q quit)
#                              inside a pseudo terminal (`script -q -e -c`)
#   case6  error-missing-model missing model -> clean nonzero exit, no hang
#   case7  tiny-arena-32       32 MiB arena gets raised to largest tensor + 24 MiB
#   case8  diskc-json          persistent engine JSON lines (ready/token/done)
#   case9  gui-offscreen       PySide6 workbench renders offscreen (skipped when
#                              PySide6 is not installed)
#   case10 tui-i18n            TUI language coverage: en / zh-Hans / zh-Hant via
#                              --lang and DISKINFER_LANG; screen captures in test/i18n/
#   case11 tui-api             disktui --api-only: /v1/models + /v1/chat/completions
#                              over HTTP, clean SIGTERM shutdown
#
# Extra cross-case checks:
#   * greedy token ids of the streaming runs must be identical to the native run
#     (native + -no-extra-bufts, i.e. same weight layout as the disk path)
#   * streaming runs must actually read the model from disk (/proc/<pid>/io)
#   * streaming peak RSS must stay below the model size when the arena is small
#
# Usage:
#   test/run-tests.sh                                  # auto-detect binaries + model
#   test/run-tests.sh --model ~/models/qwen.gguf       # explicit model
#   test/run-tests.sh --bin-dir build/out/linux-x64
#   test/run-tests.sh --cases 1,2,5                    # subset (ids or names)
#   test/run-tests.sh --list                           # list the cases
#   test/run-tests.sh --gui-full                       # also run workbench --selftest
#
# Logs: test/logs/caseN-*.log ; report: test/REPORT.md ; exit code 0 = all pass.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BIN_DIR=""
MODEL=""
LOG_DIR="$SCRIPT_DIR/logs"
REPORT="$SCRIPT_DIR/REPORT.md"
TIMEOUT_SEC=600
CASES_FILTER=()
GUI_FULL=0
LIST_ONLY=0
ALLOW_DIVERGENCE=0
REPORT_OVERRIDE=""
PROMPT_TEXT="The capital of France is"

usage() {
    sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
      --bin-dir DIR    directory with the compiled binaries
                       (default: <repo>/build/out/linux-x64, then build/build-linux/bin)
      --model PATH     GGUF model to test (default: auto-detect, or $DISKINFER_MODEL)
      --log-dir DIR    where raw logs are written (default: test/logs)
      --timeout SEC    per-case timeout in seconds (default: 600)
      --cases LIST     comma separated case ids/names (default: all)
      --gui-full       also run the GUI --selftest suite (slow, needs PySide6)
      --allow-divergence  demote native-vs-streamed token-id mismatches to WARN
                          (use for MoE/hybrid models where parity is not expected)
      --report PATH    markdown report path (default: test/REPORT.md)
      --list           list the test cases and exit
  -h, --help           show this help

Environment:
  DISKINFER_BIN_DIR   same as --bin-dir
  DISKINFER_MODEL     same as --model
  DISKINFER_MODEL_DIRS  extra model search dirs (colon separated)

Options for models where streaming/native parity is not expected (e.g. MoE):
      --allow-divergence  demote native-vs-streamed token-id mismatches to WARN
      --report PATH       write the markdown report here (default test/REPORT.md)
EOF
}

log()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir)  [ $# -ge 2 ] || die "$1 needs a value"; BIN_DIR="$2"; shift 2 ;;
        --model)    [ $# -ge 2 ] || die "$1 needs a value"; MODEL="$2"; shift 2 ;;
        --log-dir)  [ $# -ge 2 ] || die "$1 needs a value"; LOG_DIR="$2"; shift 2 ;;
        --timeout)  [ $# -ge 2 ] || die "$1 needs a value"; TIMEOUT_SEC="$2"; shift 2 ;;
        --cases)    [ $# -ge 2 ] || die "$1 needs a value"
                    IFS=',' read -r -a CASES_FILTER <<< "$2"; shift 2 ;;
        --gui-full) GUI_FULL=1; shift ;;
        --allow-divergence) ALLOW_DIVERGENCE=1; shift ;;
        --report)   [ $# -ge 2 ] || die "$1 needs a value"; REPORT_OVERRIDE="$2"; shift 2 ;;
        --list)     LIST_ONLY=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done
[ -n "${DISKINFER_BIN_DIR:-}" ] && [ -z "$BIN_DIR" ] && BIN_DIR="$DISKINFER_BIN_DIR"
[ -n "${DISKINFER_MODEL:-}" ] && [ -z "$MODEL" ] && MODEL="$DISKINFER_MODEL"
if [ -n "$REPORT_OVERRIDE" ]; then REPORT="$REPORT_OVERRIDE"; fi
if [ -z "$BIN_DIR" ]; then
    for cand in "$REPO_ROOT/build/out/linux-x64" "$REPO_ROOT/build/build-linux/bin" "$REPO_ROOT/bin"; do
        [ -x "$cand/diskrun" ] && BIN_DIR="$cand" && break
    done
fi
[ -n "$BIN_DIR" ] || die "no built binaries found; run build/build-linux.sh first (or pass --bin-dir)"
BIN_DIR="$(cd -- "$BIN_DIR" && pwd)"
LOG_DIR="${LOG_DIR/#\~/$HOME}"
mkdir -p "$LOG_DIR"
I18N_DIR="$REPO_ROOT/test/i18n"
mkdir -p "$I18N_DIR"

CASES_ALL=(preflight case1 case2 case3 case4 case5 case6 case7 case8 case9 case10 case11 compare)
CASE_NAMES=(preflight streaming-200 native-baseline auto-arena odirect-off disktui-oneshot
            error-missing-model tiny-arena-32 diskc-json gui-offscreen tui-i18n tui-api compare)
case_name_for() {
    case "$1" in
        preflight) echo preflight ;;
        case1) echo streaming-200 ;;
        case2) echo native-baseline ;;
        case3) echo auto-arena ;;
        case4) echo odirect-off ;;
        case5) echo disktui-oneshot ;;
        case6) echo error-missing-model ;;
        case7) echo tiny-arena-32 ;;
        case8) echo diskc-json ;;
        case9) echo gui-offscreen ;;
        case10) echo tui-i18n ;;
        case11) echo tui-api ;;
        compare) echo cross-case-compare ;;
        *) echo "$1" ;;
    esac
}
case_enabled() {
    [ "${#CASES_FILTER[@]}" -eq 0 ] && return 0
    local want bare
    for want in "${CASES_FILTER[@]}"; do
        want="${want// /}"
        [ -z "$want" ] && continue
        bare="${1#case}"
        if [ "$want" = "$1" ] || [ "$want" = "$(case_name_for "$1")" ] || [ "$want" = "$bare" ]; then
            return 0
        fi
    done
    return 1
}

if [ "$LIST_ONLY" = "1" ]; then
    for c in "${CASES_ALL[@]}"; do
        printf '%-10s %s\n' "$c" "$(case_name_for "$c")"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# dependency checks
# ---------------------------------------------------------------------------
command -v timeout >/dev/null 2>&1 || die "'timeout' not found (coreutils)"
command -v awk >/dev/null 2>&1 || die "'awk' not found"
command -v sed >/dev/null 2>&1 || die "'sed' not found"
for exe in disktui diskrun diskc llama-completion; do
    [ -x "$BIN_DIR/$exe" ] || die "missing executable: $BIN_DIR/$exe (run build/build-linux.sh first)"
done

# ---------------------------------------------------------------------------
# model selection
# ---------------------------------------------------------------------------
model_dirs() {
    if [ -n "${DISKINFER_MODEL_DIRS:-}" ]; then
        local IFS=':'
        for d in $DISKINFER_MODEL_DIRS; do printf '%s\n' "${d/#\~/$HOME}"; done
    fi
    printf '%s\n' "$HOME/models" "$(pwd)/models" "$HOME/Downloads/models"
}
find_models() {
    local d
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f -name '*.gguf' -print 2>/dev/null
    done < <(model_dirs)
}

if [ -z "$MODEL" ]; then
    mapfile -t _models < <(find_models | LC_ALL=C sort -u)
    if [ "${#_models[@]}" -eq 0 ]; then
        die "no .gguf model found. Put one in ~/models or pass --model PATH"
    fi
    # prefer the smallest model: the regression is about correctness, and small
    # models keep the whole suite fast
    MODEL="$(for m in "${_models[@]}"; do stat -c '%s %n' "$m" 2>/dev/null; done | sort -n | head -1 | cut -d' ' -f2-)"
fi
[ -f "$MODEL" ] || die "model not found: $MODEL"
MODEL="$(cd -- "$(dirname -- "$MODEL")" && pwd)/$(basename -- "$MODEL")"
MODEL_BYTES=$(stat -c '%s' "$MODEL")
MODEL_MIB=$(( MODEL_BYTES / 1048576 ))

MEM_TOTAL_MIB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024; exit }' /proc/meminfo 2>/dev/null)
MEM_TOTAL_MIB=${MEM_TOTAL_MIB:-0}
AUTO_ARENA_MIB=$(( MEM_TOTAL_MIB / 8 ))
[ "$AUTO_ARENA_MIB" -lt 128 ] && AUTO_ARENA_MIB=128
[ "$AUTO_ARENA_MIB" -gt 2048 ] && AUTO_ARENA_MIB=2048

# ---------------------------------------------------------------------------
# result bookkeeping
# ---------------------------------------------------------------------------
declare -A CASE_CHECKS CASE_FAILS CASE_WARNS
CHECK_TOTAL=0
FAIL_TOTAL=0
WARN_TOTAL=0
SKIP_TOTAL=0

check() { # case name status detail
    local c="$1" n="$2" s="$3" detail="${4:-}"
    CHECK_TOTAL=$((CHECK_TOTAL+1))
    CASE_CHECKS[$c]=$(( ${CASE_CHECKS[$c]:-0} + 1 ))
    case "$s" in
        PASS) printf '  PASS %-24s %s\n' "$n" "$detail" ;;
        FAIL) printf '  FAIL %-24s %s\n' "$n" "$detail"
              FAIL_TOTAL=$((FAIL_TOTAL+1)); CASE_FAILS[$c]=$(( ${CASE_FAILS[$c]:-0} + 1 )) ;;
        WARN) printf '  WARN %-24s %s\n' "$n" "$detail"
              WARN_TOTAL=$((WARN_TOTAL+1)); CASE_WARNS[$c]=$(( ${CASE_WARNS[$c]:-0} + 1 )) ;;
        SKIP) printf '  SKIP %-24s %s\n' "$n" "$detail"; SKIP_TOTAL=$((SKIP_TOTAL+1)) ;;
        *)    printf '  INFO %-24s %s\n' "$n" "$detail" ;;
    esac
}

case_status() { # echoes PASS/FAIL/SKIP for a case
    local c="$1"
    if [ "${CASE_FAILS[$c]:-0}" -gt 0 ]; then echo FAIL
    elif [ "${CASE_CHECKS[$c]:-0}" -eq 0 ]; then echo SKIP
    else echo PASS; fi
}

strip_ansi() {
    # perl handles the full CSI/OSC range correctly; the sed fallback drops the
    # ESC byte first so the remaining "[...X" sequences can be matched plainly
    if command -v perl >/dev/null 2>&1; then
        perl -pe 's/\e\][^\x07]*\x07//g; s/\e\[[0-9;?]*[a-zA-Z]//g; s/\e.//g; s/\r//g'
    else
        tr -d '\033' | sed -E 's/\r//g; s/\[[0-9;?]*[A-Za-z]//g'
    fi
}

flatten_tui() {
    # The disktui screen is repainted with cursor-position sequences instead of
    # newlines: turn each row move into a real line break, then strip the rest.
    if command -v perl >/dev/null 2>&1; then
        perl -pe 's/\e\[[0-9]+;[0-9]+H/\n/g; s/\e\][^\x07]*\x07//g; s/\e\[[0-9;?]*[a-zA-Z]//g; s/\e.//g; s/\r//g'
    else
        tr -d '\033' | sed -E $'s/\r//g; s/\\[[0-9]+;[0-9]+H/\\n/g; s/\\[[0-9;?]*[A-Za-z]//g'
    fi
}

# ---------------------------------------------------------------------------
# TUI driver: run the v0.9.0 full-screen TUI in a pseudo terminal and feed it
# keys. The new TUI is a real interactive application (settings page + run page,
# 's' start / 'c' cancel / 'q' quit) and hangs forever on stdin EOF, so it has to
# be driven with scripted keystrokes instead of being run headless.
# ---------------------------------------------------------------------------
TUI_EXTRA_ENV=()
tui_pty_run() { # $1 = log file, $2 = mode (quit|oneshot), $3 = timeout, rest = TUI args
    local lf="$1" mode="$2" tmo="$3"; shift 3
    local inner a
    inner="$(printf '%q' "$BIN_DIR/disktui") -m $(printf '%q' "$MODEL")"
    for a in "$@"; do inner+=" $(printf '%q' "$a")"; done
    (
        sleep 2
        printf 's'
        if [ "$mode" = "oneshot" ]; then
            local i=0
            while [ "$i" -lt 480 ]; do
                grep -aqE 'generate +[0-9]+ tok .*finish ' "$lf" 2>/dev/null && break
                sleep 0.5
                i=$((i+1))
            done
        fi
        sleep 0.5
        printf 'q'
    ) | ( TERM=xterm-256color env "${CLEAR_ENV[@]:1}" "${TUI_EXTRA_ENV[@]}" \
            LLAMA_DISK_STREAM_MB=200 timeout "$tmo" \
            script -q -e -c "$inner" /dev/null ) >"$lf" 2>&1
    RUN_RC=$?
    return 0
}

# ---------------------------------------------------------------------------
# process runner with RSS + disk-read sampling
# ---------------------------------------------------------------------------
# SR_LOG      log file
# SR_TMO      timeout seconds
# SR_ENV      array prefix (e.g. env -u LLAMA_DISK_STREAM_MB K=V)
# SR_CMD      array command
# sets: SR_RC SR_SECS SR_PEAK_RSS_MIB SR_READ_BYTES SR_TIMEOUT
SR_LOG=""; SR_TMO=0; SR_ENV=(); SR_CMD=()
SR_RC=0; SR_SECS=0; SR_PEAK_RSS_MIB=0; SR_READ_BYTES=0; SR_TIMEOUT=0

sampled_run() {
    : > "$SR_LOG"
    local start=$SECONDS deadline=$((SECONDS+SR_TMO))
    SR_PEAK_RSS_MIB=0; SR_READ_BYTES=0; SR_TIMEOUT=0
    "${SR_ENV[@]}" "${SR_CMD[@]}" >"$SR_LOG" 2>&1 &
    local pid=$!
    local rb rss
    while kill -0 "$pid" 2>/dev/null; do
        if [ -r "/proc/$pid/io" ]; then
            rb=$(awk '/^read_bytes:/ { print $2; exit }' "/proc/$pid/io" 2>/dev/null)
            [ -n "${rb:-}" ] && [ "$rb" -gt "$SR_READ_BYTES" ] 2>/dev/null && SR_READ_BYTES="$rb"
        fi
        if [ -r "/proc/$pid/status" ]; then
            rss=$(awk '/^VmHWM:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)
            if [ -n "${rss:-}" ]; then
                rss=$(( rss / 1024 ))
                [ "$rss" -gt "$SR_PEAK_RSS_MIB" ] && SR_PEAK_RSS_MIB="$rss"
            fi
        fi
        if [ "$SECONDS" -gt "$deadline" ]; then
            SR_TIMEOUT=1
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.05
    done
    wait "$pid" 2>/dev/null
    SR_RC=$?
    SR_SECS=$((SECONDS-start))
    [ "$SR_TIMEOUT" = "1" ] && SR_RC=124
    # tiny models finish before the first /proc sample: fall back to the RSS
    # numbers the engine itself prints into its log
    if [ "$SR_PEAK_RSS_MIB" -eq 0 ] && [ -s "$SR_LOG" ]; then
        SR_PEAK_RSS_MIB=$(grep -aoE 'rss[^=]*= [0-9]+ MiB' "$SR_LOG" 2>/dev/null \
            | grep -oE '[0-9]+' | sort -n | tail -1)
        SR_PEAK_RSS_MIB=${SR_PEAK_RSS_MIB:-0}
    fi
    return 0
}

run_simple() { # log timeout command...  (no sampling; for TUI/error/GUI)
    local lf="$1" tmo="$2"; shift 2
    local start=$SECONDS
    timeout "$tmo" "$@" >"$lf" 2>&1
    RUN_RC=$?
    RUN_SECS=$((SECONDS-start))
    return 0
}
RUN_RC=0; RUN_SECS=0

# ---------------------------------------------------------------------------
# log parsers
# ---------------------------------------------------------------------------
# arena line:
# llama-disk: streaming weights from disk, arena = N MiB (why), direct io = D, mlock = M, prefetch = P (lookahead L)
ARENA_MIB=""; ARENA_WHY=""; ARENA_DIO=""; ARENA_MLOCK=""; ARENA_PREF=""
parse_arena() {
    local f="$1" line
    line=$(grep -a 'streaming weights from disk, arena = ' "$f" 2>/dev/null | tail -1)
    ARENA_MIB=""; ARENA_WHY=""; ARENA_DIO=""; ARENA_MLOCK=""; ARENA_PREF=""
    [ -z "$line" ] && return 1
    ARENA_MIB=$(printf '%s' "$line" | sed -nE 's/.*arena = ([0-9]+) MiB.*/\1/p')
    ARENA_WHY=$(printf '%s' "$line" | sed -nE 's/.*MiB \(([^)]*)\),*.*/\1/p')
    ARENA_DIO=$(printf '%s' "$line" | sed -nE 's/.*direct io = ([0-9]+).*/\1/p')
    ARENA_MLOCK=$(printf '%s' "$line" | sed -nE 's/.*mlock = ([0-9]+).*/\1/p')
    ARENA_PREF=$(printf '%s' "$line" | sed -nE 's/.*prefetch = ([0-9]+).*/\1/p')
    [ -n "$ARENA_MIB" ]
}

TENSOR_COUNT=""; TENSOR_MIB=""; TENSOR_LARGEST=""; TENSOR_LARGEST_MIB=""
parse_tensors() {
    local f="$1" line
    line=$(grep -a 'tensors registered, ' "$f" 2>/dev/null | tail -1)
    TENSOR_COUNT=""; TENSOR_MIB=""; TENSOR_LARGEST=""; TENSOR_LARGEST_MIB=""
    [ -z "$line" ] && return 1
    TENSOR_COUNT=$(printf '%s' "$line" | sed -nE 's/.*: ([0-9]+) tensors registered.*/\1/p')
    TENSOR_MIB=$(printf '%s' "$line" | sed -nE 's/.*, ([0-9]+) MiB to stream.*/\1/p')
    TENSOR_LARGEST=$(printf '%s' "$line" | sed -nE "s/.*largest tensor '([^']*)' ([0-9]+) MiB.*/\1/p")
    TENSOR_LARGEST_MIB=$(printf '%s' "$line" | sed -nE "s/.*largest tensor '[^']*' ([0-9]+) MiB.*/\1/p")
    [ -n "$TENSOR_COUNT" ]
}

RAISE_FROM=""; RAISE_TO=""
parse_raise() {
    local f="$1" line
    line=$(grep -a 'cannot hold the largest tensor' "$f" 2>/dev/null | tail -1)
    RAISE_FROM=""; RAISE_TO=""
    [ -z "$line" ] && return 1
    RAISE_FROM=$(printf '%s' "$line" | sed -nE 's/.*arena ([0-9]+) MiB cannot hold.*/\1/p')
    RAISE_TO=$(printf '%s' "$line" | sed -nE 's/.*raised to ([0-9]+) MiB.*/\1/p')
    [ -n "$RAISE_TO" ]
}

token_ids() { # file -> "id id id ..."
    grep -a -oE 'diskrun: token [0-9]+ id=[0-9]+' "$1" 2>/dev/null \
        | sed -E 's/.*id=([0-9]+)/\1/' | tr '\n' ' ' | sed -E 's/ +$//'
}
token_count() { # file
    grep -a -cE 'diskrun: token [0-9]+ id=' "$1" 2>/dev/null || true
}
generated_count() { # file
    local n
    n=$(grep -a -oE 'generated [0-9]+ tokens' "$1" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
    printf '%s' "${n:-0}"
}
rss_after_prefill() { # file
    grep -a -oE 'rss after prefill += [0-9]+ MiB' "$1" 2>/dev/null | tail -1 | grep -oE '[0-9]+'
}

now_human() { date '+%Y-%m-%d %H:%M:%S'; }

# ---------------------------------------------------------------------------
# shared command line pieces
# ---------------------------------------------------------------------------
GEN_ARGS=(-p "$PROMPT_TEXT" -n 8 -c 128 -b 4 -ub 4 -t 4)
CLEAR_ENV=(env
    -u LLAMA_DISK_STREAM_MB -u LLAMA_DISK_ODIRECT -u LLAMA_DISK_MLOCK
    -u LLAMA_DISK_PREFETCH -u LLAMA_DISK_LOOKAHEAD -u LLAMA_DISK_VERBOSE
    -u LLAMA_DISK_DEBUG -u LLAMA_DISK_WINDOW -u LLAMA_DISK_OUT_CHUNK
    -u LLAMA_DISK_LOG -u GGML_CPU_DISABLE_FUSION)

LOG_WRITTEN_FILE="$LOG_DIR/.logs-written"
: > "$LOG_WRITTEN_FILE"
new_log() { # case label -> path (records the path for the report; command
            # substitution runs in a subshell, so the list lives in a file)
    local path="$LOG_DIR/$1.log"
    printf '%s''\n' "$path" >> "$LOG_WRITTEN_FILE"
    printf '%s' "$path"
}

need_streaming_marker() { # case log label
    local c="$1" f="$2"
    if parse_arena "$f"; then
        check "$c" streaming_marker PASS "arena = $ARENA_MIB MiB ($ARENA_WHY), direct io = $ARENA_DIO, mlock = $ARENA_MLOCK, prefetch = $ARENA_PREF"
        return 0
    fi
    check "$c" streaming_marker FAIL "no 'streaming weights from disk' line found"
    return 1
}

expect_arena() { # case requested(auto=0) label
    local c="$1" requested="$2"
    local largest="${TENSOR_LARGEST_MIB:-1}"
    local need=$(( largest + 24 ))
    local auto_base="$AUTO_ARENA_MIB"
    local exp=""
    if parse_raise "$3"; then
        # the engine had to grow the arena to fit the largest tensor
        if [ "$ARENA_WHY" = "raised to fit the largest tensor" ]; then
            if [ "$ARENA_MIB" -ge "$need" ] && [ "$ARENA_MIB" -le $((need+2)) ]; then
                check "$c" arena_expected PASS "requested $([ "$requested" = 0 ] && echo auto || echo "$requested") MiB -> $ARENA_MIB MiB = largest $largest + 24 MiB"
            else
                check "$c" arena_expected FAIL "raised arena $ARENA_MIB MiB, expected ~$need MiB (largest $largest + 24)"
            fi
            check "$c" arena_raise_log PASS "raised from $RAISE_FROM to $RAISE_TO MiB (largest tensor does not fit)"
            if [ "$requested" != "0" ] && [ "${RAISE_FROM:-0}" != "$requested" ]; then
                check "$c" arena_raise_from WARN "raise log says requested $RAISE_FROM MiB, case requested $requested MiB"
            fi
            return 0
        fi
        check "$c" arena_expected FAIL "raise log present but arena reason is '$ARENA_WHY'"
        return 0
    fi
    # no raise: check the reason chain
    case "$ARENA_WHY" in
        "requested")
            if [ "$ARENA_MIB" = "$requested" ]; then
                check "$c" arena_expected PASS "arena = requested $requested MiB (largest tensor $largest MiB fits)"
            else
                check "$c" arena_expected FAIL "requested $requested MiB, engine used $ARENA_MIB MiB"
            fi ;;
        "auto, 1/8 of ram")
            if [ "$ARENA_MIB" = "$auto_base" ]; then
                check "$c" arena_expected PASS "auto arena = $ARENA_MIB MiB = MemTotal/8 (min 128, max 2048)"
            else
                check "$c" arena_expected FAIL "auto arena = $ARENA_MIB MiB, expected $auto_base MiB = MemTotal($MEM_TOTAL_MIB MiB)/8"
            fi ;;
        "128 MiB floor")
            if [ "$ARENA_MIB" = "128" ]; then
                check "$c" arena_expected PASS "arena fell back to the 128 MiB floor (requested $requested, largest+24 = $need MiB)"
            else
                check "$c" arena_expected FAIL "128 MiB floor reason but arena = $ARENA_MIB MiB"
            fi ;;
        "2048 MiB cap")
            if [ "$ARENA_MIB" = "2048" ]; then
                check "$c" arena_expected PASS "arena capped at 2048 MiB"
            else
                check "$c" arena_expected FAIL "2048 MiB cap reason but arena = $ARENA_MIB MiB"
            fi ;;
        "clamped to what is free")
            if [ "$ARENA_MIB" -ge "$need" ] && [ "$ARENA_MIB" -le $((auto_base+2)) ]; then
                check "$c" arena_expected PASS "arena clamped to $ARENA_MIB MiB because only limited RAM is free (>= need $need MiB)"
            else
                check "$c" arena_expected FAIL "clamped arena $ARENA_MIB MiB, expected between $need and $auto_base MiB"
            fi ;;
        *)
            check "$c" arena_expected WARN "unrecognised arena reason '$ARENA_WHY' (arena $ARENA_MIB MiB)" ;;
    esac
    if [ -n "$RAISE_FROM" ] || [ -n "$RAISE_TO" ]; then
        check "$c" arena_raise_log FAIL "raise log present but the arena reason was '$ARENA_WHY'"
    fi
    return 0
}

expect_tokens() { # case log min max
    local c="$1" f="$2" nmin="$3" nmax="$4"
    local ids n gen
    ids=$(token_ids "$f")
    n=$(token_count "$f")
    gen=$(generated_count "$f")
    TOKEN_IDS_CASE[$c]="$ids"
    TOKEN_COUNT_CASE[$c]="$n"
    if [ "${n:-0}" -lt "$nmin" ]; then
        check "$c" tokens FAIL "only ${n:-0} token(s) generated, expected >= $nmin"
        return 1
    fi
    if [ -n "$nmax" ] && [ "$n" -gt "$nmax" ]; then
        check "$c" tokens FAIL "$n tokens generated, expected <= $nmax"
        return 1
    fi
    check "$c" tokens PASS "$n token(s): $ids"
    if [ "$gen" != "$n" ] && [ "$gen" -gt 0 ]; then
        check "$c" generated_count WARN "'generated $gen tokens' but $n token lines (EOG handling?)"
    else
        check "$c" generated_count PASS "engine reports $gen generated token(s)"
    fi
    local rss
    rss=$(rss_after_prefill "$f")
    if [ -n "$rss" ]; then
        check "$c" rss_after_prefill PASS "rss = $rss MiB (sampled peak $SR_PEAK_RSS_MIB MiB)"
        if [ -n "${MAX_RSS_MIB:-}" ] && [ "$rss" -gt "$MAX_RSS_MIB" ]; then
            check "$c" rss_limit FAIL "rss $rss MiB > limit ${MAX_RSS_MIB} MiB"
        fi
    fi
    return 0
}

declare -A TOKEN_IDS_CASE TOKEN_COUNT_CASE
declare -A CASE_RC CASE_SECS CASE_RSS CASE_READ_MIB CASE_ARENA CASE_WHY CASE_DIO

record_metrics() { # case rc secs
    CASE_RC[$1]="$2"
    CASE_SECS[$1]="$3"
    CASE_RSS[$1]="${SR_PEAK_RSS_MIB:-0}"
    CASE_READ_MIB[$1]=$(( ${SR_READ_BYTES:-0} / 1048576 ))
    if parse_arena "${CASE_LOG[$1]:-}" 2>/dev/null; then
        CASE_ARENA[$1]="$ARENA_MIB"
        CASE_WHY[$1]="$ARENA_WHY"
        CASE_DIO[$1]="$ARENA_DIO"
    fi
}
declare -A CASE_LOG

# ---------------------------------------------------------------------------
# machine info snapshot
# ---------------------------------------------------------------------------
OS_PRETTY="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
KERNEL="$(uname -r)"
CPU_NAME=$(awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
CPU_NAME=${CPU_NAME:-unknown}
NPROC=$(nproc 2>/dev/null || echo '?')
GLIBC="$(ldd --version 2>/dev/null | head -1 | sed -E 's/.* ([0-9]+\.[0-9]+)$/\1/')"
GLIBC=${GLIBC:-unknown}
GCC_VER=$(gcc --version 2>/dev/null | head -1)
CMAKE_VER=$(cmake --version 2>/dev/null | head -1)
MODEL_SHA=$(sha256sum "$MODEL" 2>/dev/null | cut -c1-16)

START_TIME="$(now_human)"
START_EPOCH=$SECONDS
log "diskinfer Linux x64 regression tests"
log "  when      : $START_TIME"
log "  os        : $OS_PRETTY  ($KERNEL)"
log "  cpu       : $CPU_NAME  ($NPROC logical cores)"
log "  memory    : $MEM_TOTAL_MIB MiB total"
log "  glibc     : $GLIBC"
log "  bin dir   : $BIN_DIR"
log "  model     : $MODEL  ($MODEL_MIB MiB, sha256:$MODEL_SHA)"
log "  auto arena: expected $AUTO_ARENA_MIB MiB (MemTotal/8, clamped 128..2048)"
log "  cases     : $([ "${#CASES_FILTER[@]}" -eq 0 ] && echo all || echo "${CASES_FILTER[*]}")"

# ---------------------------------------------------------------------------
# global watchdog: never let a stuck engine hang the whole regression
# ---------------------------------------------------------------------------
OVERALL_LIMIT="${DISKINFER_TEST_WATCHDOG:-$(( TIMEOUT_SEC * 12 ))}"
# the watchdog must not inherit our stdout/stderr: a long `sleep` would keep the
# caller's pipe open after the script finished (this bit the first v0.9.0 run)
( sleep "$OVERALL_LIMIT"
  echo "watchdog: tests exceeded ${OVERALL_LIMIT}s, aborting (pid $$)" >> "$LOG_DIR/watchdog.log"
  kill -TERM $$ 2>/dev/null
) >/dev/null 2>&1 &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null || true' EXIT INT TERM

# ===========================================================================
# preflight
# ===========================================================================
if case_enabled preflight; then
    step "preflight: binaries"
    for exe in disktui diskrun diskc llama-completion; do
        p="$BIN_DIR/$exe"
        if [ -x "$p" ]; then
            check preflight "binary_$exe" PASS "$(stat -c '%s' "$p") bytes, $(file -b "$p" 2>/dev/null | cut -c1-40)"
        else
            check preflight "binary_$exe" FAIL "missing or not executable: $p"
        fi
    done
    if [ -x "$BIN_DIR/llama-completion" ]; then
        vout="$("$BIN_DIR/llama-completion" --version 2>&1 | head -1)"
        ENGINE_VERSION="$vout"
        if [ -n "$vout" ]; then
            check preflight version PASS "$vout"
        else
            check preflight version FAIL "'llama-completion --version' printed nothing"
        fi
    fi
    if [ -x "$BIN_DIR/disktui" ]; then
        # the v0.9.0 TUI localises --help, so force English for the assertion and
        # add a second check that the zh-Hans help really is translated
        hout="$(timeout 30 "$BIN_DIR/disktui" --lang en -h 2>&1 | head -5)"
        if printf '%s' "$hout" | grep -qiE 'usage'; then
            check preflight disktui_help PASS "$(printf '%s' "$hout" | head -1)"
        else
            check preflight disktui_help FAIL "disktui --lang en -h did not print an English usage line"
        fi
        hzh="$(DISKINFER_LANG=zh-Hans timeout 30 "$BIN_DIR/disktui" -h 2>&1 | head -5)"
        if printf '%s' "$hzh" | grep -q '用法'; then
            check preflight disktui_help_i18n PASS "zh-Hans --help localised ('用法')"
        else
            check preflight disktui_help_i18n WARN "zh-Hans --help is not localised"
        fi
    fi
    case "$(case_status preflight)" in FAIL) PREFLIGHT_FAILED=1 ;; *) PREFLIGHT_FAILED=0 ;; esac
else
    PREFLIGHT_FAILED=0
fi

# ===========================================================================
# case1: streaming-200 (diskrun)
# ===========================================================================
if case_enabled case1 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case1 streaming-200 (diskrun, LLAMA_DISK_STREAM_MB=200)"
    logf=$(new_log case1-streaming-200); CASE_LOG[case1]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    SR_ENV=("${CLEAR_ENV[@]}" LLAMA_DISK_STREAM_MB=200)
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}")
    sampled_run
    check case1 exit_code "$([ "$SR_RC" = 0 ] && echo PASS || echo FAIL)" "exit $SR_RC (expect 0), ${SR_SECS}s, peak rss ${SR_PEAK_RSS_MIB} MiB, disk read $((SR_READ_BYTES/1048576)) MiB"
    record_metrics case1 "$SR_RC" "$SR_SECS"
    if [ "$SR_RC" = 0 ] && need_streaming_marker case1 "$logf"; then
        parse_tensors "$logf" >/dev/null && \
            check case1 tensors PASS "$TENSOR_COUNT tensors, $TENSOR_MIB MiB to stream, largest '$TENSOR_LARGEST' $TENSOR_LARGEST_MIB MiB"
        MAX_RSS_MIB=1024
        expect_arena case1 200 "$logf"
        expect_tokens case1 "$logf" 1 8
        if [ -n "$TENSOR_LARGEST_MIB" ]; then
            if [ "$ARENA_DIO" = "1" ]; then
                check case1 direct_io PASS "direct io = 1 (O_DIRECT)"
            else
                check case1 direct_io FAIL "direct io = $ARENA_DIO, expected 1"
            fi
            # direct I/O must really touch the disk; the model is much larger than the page cache
            # for the models used here, so a real read is provable from /proc/<pid>/io
            if [ "$MODEL_MIB" -gt 300 ]; then
                if [ "$SR_READ_BYTES" -ge $(( MODEL_BYTES / 2 )) ]; then
                    check case1 disk_read PASS "read_bytes = $((SR_READ_BYTES/1048576)) MiB >= half the model ($((MODEL_BYTES/2/1048576)) MiB)"
                else
                    check case1 disk_read FAIL "read_bytes = $((SR_READ_BYTES/1048576)) MiB, expected >= $((MODEL_BYTES/2/1048576)) MiB"
                fi
                if [ "$SR_PEAK_RSS_MIB" -lt "$MODEL_MIB" ]; then
                    check case1 rss_vs_model PASS "peak rss ${SR_PEAK_RSS_MIB} MiB < model $MODEL_MIB MiB (weights are streamed, not resident)"
                else
                    check case1 rss_vs_model FAIL "peak rss ${SR_PEAK_RSS_MIB} MiB >= model $MODEL_MIB MiB, weights may not be streamed"
                fi
            fi
        fi
    else
        check case1 streaming_marker SKIP "run failed, no markers to check"
    fi
    unset MAX_RSS_MIB
elif case_enabled case1; then
    step "case1 streaming-200"; check case1 run SKIP "preflight failed"
fi

# ===========================================================================
# case2: native baseline
# ===========================================================================
if case_enabled case2 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case2 native-baseline (diskrun, LLAMA_DISK_STREAM_MB=0 -no-extra-bufts)"
    logf=$(new_log case2-native-baseline); CASE_LOG[case2]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    # The disk-streaming loader disables the extra buffer types (weight
    # repacking). Run the native mmap path with the same layout so the greedy
    # token comparison is apples-to-apples; without this flag a repacked native
    # run can legitimately pick different tokens on AVX2/ARM-dotprod builds.
    SR_ENV=("${CLEAR_ENV[@]}" LLAMA_DISK_STREAM_MB=0)
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}" -no-extra-bufts)
    sampled_run
    check case2 exit_code "$([ "$SR_RC" = 0 ] && echo PASS || echo FAIL)" "exit $SR_RC (expect 0), ${SR_SECS}s, peak rss ${SR_PEAK_RSS_MIB} MiB"
    record_metrics case2 "$SR_RC" "$SR_SECS"
    if [ "$SR_RC" = 0 ]; then
        if grep -aq 'streaming weights from disk' "$logf"; then
            check case2 streaming_marker FAIL "native run (STREAM_MB=0) printed a disk-streaming arena line"
        else
            check case2 streaming_marker PASS "no disk-streaming arena line (native mmap path)"
        fi
        if grep -aq 'repack active = 0' "$logf"; then
            check case2 repack_off PASS "native baseline runs with repack disabled (same weight layout as the disk path)"
        elif grep -aq 'repack active = ' "$logf"; then
            check case2 repack_off WARN "diskrun does not report 'repack active = 0' (old binary?)"
        fi
        expect_tokens case2 "$logf" 1 8
    fi
elif case_enabled case2; then
    step "case2 native-baseline"; check case2 run SKIP "preflight failed"
fi

# ===========================================================================
# case3: auto arena
# ===========================================================================
if case_enabled case3 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case3 auto-arena (diskrun, LLAMA_DISK_STREAM_MB unset)"
    logf=$(new_log case3-auto-arena); CASE_LOG[case3]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    SR_ENV=("${CLEAR_ENV[@]}")
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}")
    sampled_run
    check case3 exit_code "$([ "$SR_RC" = 0 ] && echo PASS || echo FAIL)" "exit $SR_RC (expect 0), ${SR_SECS}s, peak rss ${SR_PEAK_RSS_MIB} MiB"
    record_metrics case3 "$SR_RC" "$SR_SECS"
    if [ "$SR_RC" = 0 ] && need_streaming_marker case3 "$logf"; then
        parse_tensors "$logf" >/dev/null && true
        expect_arena case3 0 "$logf"
        expect_tokens case3 "$logf" 1 8
    else
        check case3 streaming_marker SKIP "run failed, no markers to check"
    fi
elif case_enabled case3; then
    step "case3 auto-arena"; check case3 run SKIP "preflight failed"
fi

# ===========================================================================
# case4: O_DIRECT off
# ===========================================================================
if case_enabled case4 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case4 odirect-off (diskrun, LLAMA_DISK_STREAM_MB=200 LLAMA_DISK_ODIRECT=0)"
    logf=$(new_log case4-odirect-off); CASE_LOG[case4]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    SR_ENV=("${CLEAR_ENV[@]}" LLAMA_DISK_STREAM_MB=200 LLAMA_DISK_ODIRECT=0)
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}")
    sampled_run
    check case4 exit_code "$([ "$SR_RC" = 0 ] && echo PASS || echo FAIL)" "exit $SR_RC (expect 0), ${SR_SECS}s, peak rss ${SR_PEAK_RSS_MIB} MiB"
    record_metrics case4 "$SR_RC" "$SR_SECS"
    if [ "$SR_RC" = 0 ] && need_streaming_marker case4 "$logf"; then
        parse_tensors "$logf" >/dev/null && true
        expect_arena case4 200 "$logf"
        expect_tokens case4 "$logf" 1 8
        if [ "$ARENA_DIO" = "0" ]; then
            check case4 direct_io PASS "direct io = 0 (buffered reads)"
        else
            check case4 direct_io FAIL "direct io = $ARENA_DIO, expected 0"
        fi
        check case4 buffered_read INFO "buffered path may be served from the page cache; read_bytes is not asserted here"
    else
        check case4 streaming_marker SKIP "run failed, no markers to check"
    fi
elif case_enabled case4; then
    step "case4 odirect-off"; check case4 run SKIP "preflight failed"
fi

# ===========================================================================
# case5: disktui one-shot in a pseudo terminal
# ===========================================================================
if case_enabled case5 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case5 disktui-oneshot (v0.9.0 TUI, scripted keys in a pseudo terminal)"
    logf=$(new_log case5-disktui-oneshot); CASE_LOG[case5]="$logf"
    if ! command -v script >/dev/null 2>&1; then
        check case5 pty SKIP "'script' (util-linux) not installed; cannot allocate a pseudo terminal"
    else
        CASE_RC[case5]=0
        TUI_EXTRA_ENV=()
        tui_pty_run "$logf" oneshot "$TIMEOUT_SEC" \
            -n 4 -c 64 --temp 0 --top-k 1 --lang en -q "$PROMPT_TEXT"
        CASE_RC[case5]="$RUN_RC"; CASE_LOG[case5]="$logf"
        clean="$LOG_DIR/case5-disktui-clean.log"
        flatten_tui < "$logf" > "$clean"
        check case5 exit_code "$([ "$RUN_RC" = 0 ] && echo PASS || echo FAIL)" "exit $RUN_RC (expect 0), scripted s/q keys"
        banner=$(grep -aoE 'diskinfer [0-9][0-9A-Za-z._-]*' "$clean" | head -1)
        if [ -n "$banner" ]; then
            check case5 tui_banner PASS "TUI banner rendered: $banner"
        else
            check case5 tui_banner FAIL "no 'diskinfer <version>' banner in the TUI output"
        fi
        if grep -aq -- 'Settings' "$clean"; then
            check case5 settings_page PASS "settings page rendered (en)"
        else
            check case5 settings_page FAIL "settings page not found in the TUI output"
        fi
        prefill_line=$(grep -aE 'prefill +[0-9]+ tok in ' "$clean" | tail -1 | sed -E 's/^ +//')
        if [ -n "$prefill_line" ]; then
            check case5 prefill_done PASS "$prefill_line"
        else
            check case5 prefill_done FAIL "no completed prefill line ('prefill N tok in T s')"
        fi
        gen_line=$(grep -aE 'generate +[0-9]+ tok .*finish ' "$clean" | tail -1 | sed -E 's/^ +//')
        if [ -n "$gen_line" ]; then
            check case5 generate_done PASS "$gen_line"
        else
            check case5 generate_done FAIL "no completed generate line ('generate N tok ... finish ...')"
        fi
        if grep -aqE -- '-- Answer --|Answer' "$clean"; then
            check case5 answer_section PASS "answer section present on the run page"
        else
            check case5 answer_section WARN "answer section header not found"
        fi
        if grep -aqE 'no interactive terminal|未检测到交互式终端' "$clean"; then
            check case5 tty PASS "x" >/dev/null
            check case5 tty_required FAIL "TUI reported 'no interactive terminal' although a pty was allocated"
        else
            check case5 tty_required PASS "TUI accepted the pty and stayed interactive (no fallback message)"
        fi
        CASE_SECS[case5]="$RUN_SECS"
    fi
elif case_enabled case5; then
    step "case5 disktui-oneshot"; check case5 run SKIP "preflight failed"
fi

# ===========================================================================
# case6: missing model must fail cleanly
# ===========================================================================
if case_enabled case6 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case6 error-missing-model"
    logf=$(new_log case6-error-missing-model); CASE_LOG[case6]="$logf"
    missing="/definitely/missing/diskinfer-model.gguf"
    run_simple "$logf" 180 env "${CLEAR_ENV[@]:1}" "$BIN_DIR/diskrun" \
        -m "$missing" -n 4 -c 64 -b 4 -ub 4 -t 4
    rc=$RUN_RC
    if [ "$rc" != "0" ]; then
        check case6 exit_code PASS "exit $rc (nonzero), ${RUN_SECS}s, no hang"
    else
        check case6 exit_code FAIL "exit 0 for a missing model, expected nonzero"
    fi
    if [ "$rc" != "124" ]; then
        check case6 no_timeout PASS "process ended on its own (${RUN_SECS}s < 180s)"
    else
        check case6 no_timeout FAIL "process hung until the timeout"
    fi
    if grep -aqiE 'error|failed|not found|cannot|no such|unable to' "$logf"; then
        check case6 error_message PASS "$(strip_ansi < "$logf" | grep -aiE 'error|failed|not found|cannot|no such|unable to' | head -2 | tr '\n' '|')"
    else
        check case6 error_message FAIL "no error message on stdout/stderr"
    fi
    if grep -aq 'streaming weights from disk' "$logf"; then
        check case6 no_streaming PASS "no arena was allocated (model load failed before streaming)"
    fi
elif case_enabled case6; then
    step "case6 error-missing-model"; check case6 run SKIP "preflight failed"
fi

# ===========================================================================
# case7: tiny 32 MiB arena
# ===========================================================================
if case_enabled case7 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case7 tiny-arena-32 (diskrun, LLAMA_DISK_STREAM_MB=32)"
    logf=$(new_log case7-tiny-arena-32); CASE_LOG[case7]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    SR_ENV=("${CLEAR_ENV[@]}" LLAMA_DISK_STREAM_MB=32)
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}")
    sampled_run
    check case7 exit_code "$([ "$SR_RC" = 0 ] && echo PASS || echo FAIL)" "exit $SR_RC (expect 0), ${SR_SECS}s, peak rss ${SR_PEAK_RSS_MIB} MiB"
    record_metrics case7 "$SR_RC" "$SR_SECS"
    if [ "$SR_RC" = 0 ] && need_streaming_marker case7 "$logf"; then
        parse_tensors "$logf" >/dev/null && \
            check case7 tensors PASS "$TENSOR_COUNT tensors, largest '$TENSOR_LARGEST' $TENSOR_LARGEST_MIB MiB"
        expect_arena case7 32 "$logf"
        expect_tokens case7 "$logf" 1 8
        if [ "$MODEL_MIB" -gt 300 ] && [ "$SR_READ_BYTES" -ge $(( MODEL_BYTES / 2 )) ]; then
            check case7 disk_read PASS "read_bytes = $((SR_READ_BYTES/1048576)) MiB proves streaming from disk"
        fi
    else
        check case7 streaming_marker SKIP "run failed, no markers to check"
    fi
elif case_enabled case7; then
    step "case7 tiny-arena-32"; check case7 run SKIP "preflight failed"
fi

# ===========================================================================
# case8: diskc JSON-line protocol
# ===========================================================================
if case_enabled case8 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case8 diskc-json (persistent engine, JSON lines on stdin/stdout)"
    logf=$(new_log case8-diskc-json); CASE_LOG[case8]="$logf"
    errf="$LOG_DIR/case8-diskc-json.stderr.log"
    rm -f "$logf" "$errf"
    chat_req='{"cmd":"chat","messages":[{"role":"user","content":"The capital of France is"}],"max_tokens":4,"temperature":0}'
    ready=0; tokens=0; done_ev=0; first_token=""
    coproc DISKC_PROC { timeout "$TIMEOUT_SEC" env "${CLEAR_ENV[@]:1}" LLAMA_DISK_STREAM_MB=200 \
        "$BIN_DIR/diskc" -m "$MODEL" -c 128 -b 4 -ub 4 -t 4 -n 4 2>"$errf"; }
    # bash unsets NAME_PID when the coprocess exits, so remember the pid now
    diskc_pid="$DISKC_PROC_PID"
    exec 3>&"${DISKC_PROC[1]}" 4<&"${DISKC_PROC[0]}"
    printf '%s\n' "$chat_req" >&3
    deadline=$((SECONDS+TIMEOUT_SEC))
    while IFS= read -r line <&4; do
        printf '%s\n' "$line" >>"$logf"
        case "$line" in
            *'"ev":"ready"'*|*'"ev": "ready"'*) ready=1 ;;
            *'"ev":"token"'*|*'"ev": "token"'*)
                tokens=$((tokens+1))
                [ -z "$first_token" ] && first_token=$(printf '%s' "$line" | sed -nE 's/.*"id": ?(-?[0-9]+).*/\1/p') ;;
            *'"ev":"done"'*|*'"ev": "done"'*) done_ev=1; break ;;
        esac
        [ "$SECONDS" -gt "$deadline" ] && break
    done
    # the engine exits only after it sees EOF on stdin (its reader thread blocks
    # on getline), so send quit and close both write ends of the pipe
    printf '{"cmd":"quit"}\n' >&3 2>/dev/null || true
    eval "exec ${DISKC_PROC[1]}>&-" 2>/dev/null || true
    exec 3>&- 4<&-
    quit_deadline=$((SECONDS+15))
    while kill -0 "$diskc_pid" 2>/dev/null && [ "$SECONDS" -le "$quit_deadline" ]; do sleep 0.1; done
    if kill -0 "$diskc_pid" 2>/dev/null; then
        kill -9 "$diskc_pid" 2>/dev/null || true
        check case8 clean_exit WARN "engine had to be killed after quit (stdin EOF not honoured?)"
    fi
    wait "$diskc_pid" 2>/dev/null
    diskc_rc=$?
    check case8 ready_event "$([ "$ready" = 1 ] && echo PASS || echo FAIL)" "engine sent the ready event"
    if [ "$tokens" -ge 1 ]; then
        check case8 token_events PASS "$tokens token event(s), first id=${first_token:-?}"
    else
        check case8 token_events FAIL "no token events received"
    fi
    check case8 done_event "$([ "$done_ev" = 1 ] && echo PASS || echo FAIL)" "engine sent the done event"
    if [ -s "$errf" ] && grep -aq 'streaming weights from disk' "$errf"; then
        check case8 streaming_marker PASS "engine stderr contains the streaming marker"
    else
        check case8 streaming_marker WARN "no streaming marker on stderr (buffered/cached run?)"
    fi
    if [ "${diskc_rc:-1}" = "0" ]; then
        check case8 quit PASS "quit command honoured, engine exited cleanly (rc 0)"
    else
        check case8 quit WARN "engine exit code ${diskc_rc:-?} after quit"
    fi

    # a second request on the same process would need the process alive; this
    # run validates the documented single-turn protocol, which is what the GUI
    # chat session uses per message.
elif case_enabled case8; then
    step "case8 diskc-json"; check case8 run SKIP "preflight failed"
fi

# ===========================================================================
# case9: GUI offscreen render (+ optional full suite)
# ===========================================================================
GUI_PY=""
for cand in "$REPO_ROOT/.venv/bin/python" "$HOME/diskinfer-build/venv/bin/python"; do
    [ -x "$cand" ] && "$cand" -c 'import PySide6' >/dev/null 2>&1 && GUI_PY="$cand" && break
done
if [ -z "$GUI_PY" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import PySide6' >/dev/null 2>&1 && GUI_PY="$(command -v python3)"
fi

if case_enabled case9 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case9 gui-offscreen (PySide6 workbench, QT_QPA_PLATFORM=offscreen)"
    if [ -z "$GUI_PY" ]; then
        check case9 pyside6 SKIP "PySide6 is not installed (run gui/setup-venv.sh); python compilation is covered by preflight"
    else
        logf=$(new_log case9-gui-offscreen); CASE_LOG[case9]="$logf"
        png="$LOG_DIR/case9-gui.png"
        rm -f "$png"
        run_simple "$logf" 180 env QT_QPA_PLATFORM=offscreen "$GUI_PY" \
            "$REPO_ROOT/gui/workbench.py" --screenshot "$png" --demo --theme dark --bin-dir "$BIN_DIR" --model "$MODEL"
        check case9 exit_code "$([ "$RUN_RC" = 0 ] && echo PASS || echo FAIL)" "exit $RUN_RC (expect 0), ${RUN_SECS}s"
        if [ -s "$png" ]; then
            check case9 screenshot PASS "rendered $(stat -c '%s' "$png") byte PNG: $png"
        else
            check case9 screenshot FAIL "no PNG produced"
        fi
        if grep -aq 'screenshot:' "$logf"; then
            check case9 render_log PASS "$(grep -a 'screenshot:' "$logf" | tail -1)"
        fi
        # also prove py_compile passes for every GUI module
        if "$GUI_PY" -m py_compile "$REPO_ROOT"/gui/*.py 2>"$LOG_DIR/case9-pycompile.err"; then
            check case9 py_compile PASS "all gui/*.py modules compile"
        else
            check case9 py_compile FAIL "$(head -3 "$LOG_DIR/case9-pycompile.err" | tr '\n' '|')"
        fi
    fi

    if [ "$GUI_FULL" = "1" ] && [ -n "$GUI_PY" ]; then
        step "case9b gui-selftest (workbench --selftest, 7 cases through the GUI runner)"
        logf=$(new_log case9b-gui-selftest)
        run_simple "$logf" $((TIMEOUT_SEC*3)) env QT_QPA_PLATFORM=offscreen "$GUI_PY" \
            "$REPO_ROOT/gui/workbench.py" --selftest --bin-dir "$BIN_DIR" --model "$MODEL"
        if [ "$RUN_RC" = 0 ]; then
            check case9b selftest PASS "exit 0 (all GUI suite cases passed), ${RUN_SECS}s"
        else
            check case9b selftest FAIL "exit $RUN_RC, ${RUN_SECS}s (see $logf)"
        fi
        if grep -aq '"passed"' "$logf"; then
            check case9b summary PASS "$(grep -a '"passed"' "$logf" | tail -1 | cut -c1-160)"
        fi
    fi
elif case_enabled case9; then
    step "case9 gui-offscreen"; check case9 run SKIP "preflight failed"
fi

# ===========================================================================
# case10: TUI i18n (en / zh-Hans / zh-Hant, --lang and DISKINFER_LANG)
# ===========================================================================
if case_enabled case10 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case10 tui-i18n (en / zh-Hans / zh-Hant screen captures)"
    if ! command -v script >/dev/null 2>&1; then
        check case10 pty SKIP "'script' not installed; cannot capture the TUI screen"
    else
        CASE_RC[case10]=0
        declare -A LANG_EXPECT LANG_NAME
        LANG_EXPECT[en]="Settings|Temperature"
        LANG_EXPECT[zh-Hans]="设置|温度"
        LANG_EXPECT[zh-Hant]="設定|溫度"
        LANG_NAME[en]=en; LANG_NAME[zh-Hans]=zh-Hans; LANG_NAME[zh-Hant]=zh-Hant
        for lg in en zh-Hans zh-Hant; do
            cap="$I18N_DIR/tui-$lg"
            logf=$(new_log "case10-tui-$lg")
            TUI_EXTRA_ENV=()
            tui_pty_run "$logf" quit 180 --lang "$lg"
            flatten_tui < "$logf" > "$cap.txt"
            cp -f "$logf" "$cap.raw.log" 2>/dev/null || true
            CASE_LOG[case10]="$logf"
            want1="${LANG_EXPECT[$lg]%%|*}"
            want2="${LANG_EXPECT[$lg]##*|}"
            if [ -s "$cap.txt" ] && grep -aq -- "$want1" "$cap.txt" && grep -aq -- "$want2" "$cap.txt"; then
                check case10 "lang_${LANG_NAME[$lg]}" PASS "--lang $lg: '\''$want1'\'' + '\''$want2'\'' captured"
            else
                check case10 "lang_${LANG_NAME[$lg]}" FAIL "--lang $lg: expected '\''$want1'\'' and '\''$want2'\'' in the screen capture"
            fi
        done
        # environment selection (no --lang): DISKINFER_LANG must win over the locale
        logf=$(new_log case10-tui-env); CASE_LOG[case10]="$logf"
        TUI_EXTRA_ENV=(DISKINFER_LANG=zh-Hant)
        tui_pty_run "$logf" quit 180
        TUI_EXTRA_ENV=()
        cap="$I18N_DIR/tui-env-zh-Hant"
        flatten_tui < "$logf" > "$cap.txt"
        cp -f "$logf" "$cap.raw.log" 2>/dev/null || true
        if [ -s "$cap.txt" ] && grep -aq -- '設定' "$cap.txt" && grep -aq -- '溫度' "$cap.txt"; then
            check case10 lang_env PASS "DISKINFER_LANG=zh-Hant selects zh-Hant without --lang"
        else
            check case10 lang_env FAIL "DISKINFER_LANG=zh-Hant did not produce a zh-Hant screen"
        fi
        echo "  i18n captures: $I18N_DIR/tui-{en,zh-Hans,zh-Hant}.txt + tui-env-zh-Hant.txt"
    fi
elif case_enabled case10; then
    step "case10 tui-i18n"; check case10 run SKIP "preflight failed"
fi

# ===========================================================================
# case11: disktui --api-only (OpenAI-compatible HTTP API, no TTY required)
# ===========================================================================
if case_enabled case11 && [ "$PREFLIGHT_FAILED" = "0" ]; then
    step "case11 tui-api (disktui --api-only, OpenAI-compatible)"
    logf=$(new_log case11-tui-api); CASE_LOG[case11]="$logf"
    api_port="${DISKINFER_TEST_API_PORT:-4011}"
    models_json="$LOG_DIR/case11-models.json"
    chat_json="$LOG_DIR/case11-chat.json"
    rm -f "$models_json" "$chat_json"
    CASE_RC[case11]=0
    # truncate before the child opens it: otherwise a stale "listening" line from
    # a previous run can satisfy the ready poll before the new server binds
    : > "$logf"
    ( env "${CLEAR_ENV[@]:1}" LLAMA_DISK_STREAM_MB=200 \
          "$BIN_DIR/disktui" -m "$MODEL" --api-only --port "$api_port" -c 128 -n 8 \
          --lang en ) >"$logf" 2>&1 &
    api_pid=$!
    ready=0
    deadline=$((SECONDS+180))
    while [ "$SECONDS" -le "$deadline" ]; do
        if grep -aq "listening on http://0.0.0.0:$api_port/v1" "$logf" 2>/dev/null; then ready=1; break; fi
        kill -0 "$api_pid" 2>/dev/null || break
        sleep 0.3
    done
    [ "$ready" = "1" ] && sleep 0.3   # let the accept loop settle before the first curl
    if [ "$ready" = "1" ]; then
        check case11 ready PASS "api-only server listening on :$api_port"
        curl -s -m 30 "http://127.0.0.1:$api_port/v1/models" -o "$models_json" 2>/dev/null
        rc_models=$?
        if [ "$rc_models" = 0 ] && grep -aq '"object": *"list"' "$models_json" && grep -aq "$(basename -- "$MODEL")" "$models_json"; then
            check case11 models PASS "GET /v1/models: $(head -c 120 "$models_json" | tr '\n' ' ')"
        else
            check case11 models FAIL "GET /v1/models failed (curl rc $rc_models): $(head -c 200 "$models_json" 2>/dev/null)"
        fi
        req='{"messages":[{"role":"user","content":"The capital of France is"}],"max_tokens":4,"temperature":0}'
        curl -s -m 300 -X POST "http://127.0.0.1:$api_port/v1/chat/completions" \
            -H 'Content-Type: application/json' -d "$req" -o "$chat_json" 2>/dev/null
        rc_chat=$?
        if [ "$rc_chat" = 0 ] && grep -aq '"object": *"chat.completion"' "$chat_json"; then
            if python3 - "$chat_json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ch = d.get("choices") or []
assert ch, "no choices"
msg = ch[0].get("message") or {}
assert msg.get("role") == "assistant", "role"
content = (msg.get("content") or "").strip()
assert content, "empty content"
assert d.get("usage", {}).get("completion_tokens", 0) > 0, "usage"
print(f"content={content!r} finish={ch[0].get('finish_reason')}")
PYEOF
            then
                check case11 chat_completion PASS "POST /v1/chat/completions: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(repr(d["choices"][0]["message"]["content"]))' "$chat_json" 2>/dev/null)"
            else
                check case11 chat_completion FAIL "chat completion response invalid: $(head -c 300 "$chat_json" 2>/dev/null)"
            fi
        else
            check case11 chat_completion FAIL "POST /v1/chat/completions failed (curl rc $rc_chat): $(head -c 300 "$chat_json" 2>/dev/null)"
        fi
        curl -s -m 10 "http://127.0.0.1:$api_port/health" -o /dev/null 2>/dev/null
        check case11 health "$([ "$?" = 0 ] && echo PASS || echo WARN)" "GET /health reachable"
        kill -TERM "$api_pid" 2>/dev/null || true
        api_deadline=$((SECONDS+20))
        while kill -0 "$api_pid" 2>/dev/null && [ "$SECONDS" -le "$api_deadline" ]; do sleep 0.2; done
        kill -9 "$api_pid" 2>/dev/null || true
        wait "$api_pid" 2>/dev/null
        api_rc=$?
        CASE_RC[case11]="$api_rc"
        if grep -aqE 'bye|再见|再見' "$logf"; then
            check case11 shutdown PASS "SIGTERM handled cleanly (engine printed bye), exit $api_rc"
        elif [ "$api_rc" = "0" ]; then
            check case11 shutdown PASS "SIGTERM shutdown, exit 0"
        else
            check case11 shutdown WARN "engine exit code $api_rc after SIGTERM"
        fi
    else
        kill -TERM "$api_pid" 2>/dev/null || true
        kill -9 "$api_pid" 2>/dev/null || true
        wait "$api_pid" 2>/dev/null
        check case11 ready FAIL "api-only server did not start listening on :$api_port (see $logf)"
    fi
elif case_enabled case11; then
    step "case11 tui-api"; check case11 run SKIP "preflight failed"
fi

# ===========================================================================
# cross-case comparisons
# ============================================================================
step "cross-case: greedy token ids must match the native baseline"
REFERENCE_CASE=""

# case2b diagnostic: plain native mmap path (weight repacking enabled), used when
# native baseline differs (fusion changes the summation order, so a hybrid/MoE
# model can legitimately pick a different greedy token; the disk path forces
# fusion off, so the fair reference is native + GGML_CPU_DISABLE_FUSION=1)
run_case2b() {
    # Diagnostic: plain native mmap run (weight repacking enabled). The disk path
    # always disables repacking, so a streamed-vs-native difference on a repacked
    # quant is a float-accumulation-order artifact, not a streaming bug.
    local logf
    logf=$(new_log case2b-native-repack-on); CASE_LOG[case2b]="$logf"
    SR_LOG="$logf"; SR_TMO=$TIMEOUT_SEC
    SR_ENV=("${CLEAR_ENV[@]}" LLAMA_DISK_STREAM_MB=0)
    SR_CMD=("$BIN_DIR/diskrun" -m "$MODEL" "${GEN_ARGS[@]}")
    sampled_run
    local ids n
    ids=$(token_ids "$logf")
    n=$(token_count "$logf")
    TOKEN_IDS_CASE[case2b]="$ids"
    TOKEN_COUNT_CASE[case2b]="$n"
    CASE_LOG[case2b]="$logf"
    if [ "$SR_RC" = 0 ] && [ -n "$ids" ]; then
        check compare case2b INFO "plain native (repack on) diagnostic: $n token(s): $ids"
    else
        check compare case2b WARN "diagnostic native (repack on) run failed (exit $SR_RC)"
    fi
}

compare_ids() { # a b label -> 0 when identical
    local a="$1" b="$2" label="$3"
    local ida idb ca cb
    ida="${TOKEN_IDS_CASE[$a]:-}"; idb="${TOKEN_IDS_CASE[$b]:-}"
    ca="${TOKEN_COUNT_CASE[$a]:-0}"; cb="${TOKEN_COUNT_CASE[$b]:-0}"
    if [ -z "$ida" ] || [ -z "$idb" ]; then
        check compare "$label" SKIP "one of the runs produced no token ids"
        return 1
    fi
    if [ "$ida" = "$idb" ] && [ "$ca" = "$cb" ]; then
        check compare "$label" PASS "$ca tokens identical: $ida"
        return 0
    fi
    if [ "$ALLOW_DIVERGENCE" = "1" ]; then
        check compare "$label" WARN "[$ca: $ida] != [$cb: $idb] (mismatch allowed with --allow-divergence)"
    else
        check compare "$label" FAIL "[$ca: $ida] != [$cb: $idb]"
    fi
    return 1
}

if [ "$PREFLIGHT_FAILED" = "0" ]; then
    ref="${TOKEN_IDS_CASE[case2]:-}"
    if [ -z "$ref" ]; then
        check compare native_reference SKIP "the native baseline (case2) produced no token ids"
    else
        # case2 is the native mmap path with repacking disabled (-no-extra-bufts):
        # exactly the weight layout the disk-streaming loader forces, so its greedy
        # token ids MUST match the streamed run.
        if [ "${TOKEN_IDS_CASE[case1]:-}" = "${TOKEN_IDS_CASE[case2]:-}" ]; then
            REFERENCE_CASE=case2
            check compare native_reference PASS "native with repack disabled (same weight layout as the disk path) matches the streamed ids: $ref"
        else
            step "case2/case1 differ even with the same weight layout; running case2b (plain native, repack on) to classify"
            run_case2b
            if [ "${TOKEN_IDS_CASE[case1]:-}" = "${TOKEN_IDS_CASE[case2b]:-}" ]; then
                REFERENCE_CASE=case2b
                check compare native_reference WARN "native -no-extra-bufts differs but plain native (repack on) matches the streamed ids: this points at the repack layout, not the engine"
            else
                REFERENCE_CASE=case2
                if [ "$ALLOW_DIVERGENCE" = "1" ]; then
                    check compare native_reference WARN "streamed ids ${TOKEN_IDS_CASE[case1]} differ from native-repack-off ${ref} and plain native ${TOKEN_IDS_CASE[case2b]:-}; allowed with --allow-divergence"
                else
                    check compare native_reference FAIL "streamed ids ${TOKEN_IDS_CASE[case1]} differ from native-repack-off ${ref} (same weight layout) and from plain native ${TOKEN_IDS_CASE[case2b]:-}"
                fi
            fi
        fi
    fi

    if [ -n "$REFERENCE_CASE" ]; then
        compare_ids case1 "$REFERENCE_CASE" "case1-vs-$REFERENCE_CASE" >/dev/null
        # on a model where the native path legitimately diverges (MoE/hybrid with
        # --allow-divergence), the meaningful parity check is streamed -> streamed:
        # every arena/O_DIRECT/auto variant must agree with the 200 MiB streaming run
        variant_ref="$REFERENCE_CASE"
        if [ "$ALLOW_DIVERGENCE" = "1" ] && [ "${TOKEN_IDS_CASE[case1]:-}" != "${TOKEN_IDS_CASE[$REFERENCE_CASE]:-}" ]; then
            variant_ref=case1
            check compare variant_reference WARN "native path diverges on this model; streamed variants are compared against case1 instead"
        fi
        ncmp=1
        for c in case3 case4 case7; do
            if [ -n "${TOKEN_IDS_CASE[$c]:-}" ]; then
                compare_ids "$c" "$variant_ref" "$c-vs-$variant_ref" >/dev/null
                ncmp=$((ncmp+1))
            fi
        done
        if [ "${CASE_FAILS[compare]:-0}" -gt 0 ]; then
            if [ "$ALLOW_DIVERGENCE" = "1" ]; then
                check compare all_identical WARN "streamed variants vs $variant_ref: see per-pair checks (divergence allowed)"
            else
                check compare all_identical FAIL "streamed variants do not all agree with $variant_ref (see the per-pair checks above)"
            fi
        else
            check compare all_identical PASS "$ncmp streamed/arena variant(s) produced identical greedy token ids (reference: $variant_ref)"
        fi
    fi
fi

# ===========================================================================
# summary + report
# ===========================================================================
END_TIME="$(now_human)"
TOTAL_SECS=$((SECONDS-START_EPOCH))

step 'summary'
printf '  %-18s %-6s %s\n' CASE STATUS CHECKS
for c in "${CASES_ALL[@]}"; do
    if [ "${CASE_CHECKS[$c]:-0}" -eq 0 ]; then continue; fi
    printf '  %-18s %-6s %s' "$c" "$(case_status "$c")" "${CASE_CHECKS[$c]}"
    if [ "${CASE_FAILS[$c]:-0}" -gt 0 ]; then printf ' (%d FAIL)' "${CASE_FAILS[$c]}"; fi
    if [ "${CASE_WARNS[$c]:-0}" -gt 0 ]; then printf ' (%d WARN)' "${CASE_WARNS[$c]}"; fi
    printf '\n'
done

CASE_TOTAL=0; CASE_PASS=0; CASE_FAIL=0; CASE_SKIP=0
for c in "${CASES_ALL[@]}"; do
    [ "${CASE_CHECKS[$c]:-0}" -eq 0 ] && continue
    CASE_TOTAL=$((CASE_TOTAL+1))
    case "$(case_status "$c")" in
        PASS) CASE_PASS=$((CASE_PASS+1)) ;;
        FAIL) CASE_FAIL=$((CASE_FAIL+1)) ;;
        SKIP) CASE_SKIP=$((CASE_SKIP+1)) ;;
    esac
done

if [ "$FAIL_TOTAL" -eq 0 ]; then
    log ''
    log "RESULT: PASS  (${CASE_PASS}/${CASE_TOTAL} cases, $CHECK_TOTAL checks, $WARN_TOTAL warn, $SKIP_TOTAL skip, ${TOTAL_SECS}s)"
else
    log ''
    log "RESULT: FAIL  (${CASE_FAIL} failed case(s), $FAIL_TOTAL failed check(s), $CHECK_TOTAL checks, ${TOTAL_SECS}s)"
fi
log "logs  : $LOG_DIR"
log "report: $REPORT"

# --- write the markdown report --------------------------------------------
{
    echo '# diskinfer Linux x64 test report'
    echo
    echo "Generated: $END_TIME (duration ${TOTAL_SECS}s)"
    echo
    echo '## Environment'
    echo
    echo '| Item | Value |'
    echo '|---|---|'
    echo "| OS | $OS_PRETTY |"
    echo "| Kernel | $KERNEL |"
    echo "| CPU | $CPU_NAME ($NPROC logical cores) |"
    echo "| Memory | $MEM_TOTAL_MIB MiB |"
    echo "| glibc | $GLIBC |"
    echo "| gcc | ${GCC_VER//|/\\|} |"
    echo "| cmake | ${CMAKE_VER//|/\\|} |"
    echo "| Binaries | \`$BIN_DIR\` |"
    echo "| Model | \`$MODEL\` ($MODEL_MIB MiB, sha256:${MODEL_SHA}…) |"
    echo "| Source baseline | ${ENGINE_VERSION:-unknown} (llama.cpp fork v0.9.0) |"
    echo "| Auto arena expectation | $AUTO_ARENA_MIB MiB = MemTotal/8 (clamped 128..2048) |"
    echo
    echo '## Cases'
    echo
    echo '| Case | Name | Status | Checks | Notes |'
    echo '|---|---|---|---|---|'
    for c in "${CASES_ALL[@]}"; do
        [ "${CASE_CHECKS[$c]:-0}" -eq 0 ] && continue
        notes=""
        [ "${CASE_FAILS[$c]:-0}" -gt 0 ] && notes="$notes ${CASE_FAILS[$c]} FAIL"
        [ "${CASE_WARNS[$c]:-0}" -gt 0 ] && notes="$notes ${CASE_WARNS[$c]} WARN"
        echo "| $c | $(case_name_for "$c") | $(case_status "$c") | ${CASE_CHECKS[$c]} |${notes} |"
    done
    echo
    echo '## Weight repacking (repack) note'
    echo
    echo 'The disk-streaming load path disables the extra buffer types'
    echo '(`params.use_extra_bufts && !disk_stream` in `src/llama-model.cpp`), so quantized'
    echo 'tensors are not repacked into the platform-specific 8x4/16x1 layout while streaming.'
    echo 'Native mmap runs on AVX2 / ARM-dotprod builds do repack by default, which changes the'
    echo 'float accumulation order and can flip greedy tokens when logits are close.'
    echo 'case2 therefore runs native with `-no-extra-bufts` (same layout as streaming), which'
    echo 'is the correct apples-to-apples baseline; the `case2b` plain-native diagnostic is'
    echo 'only run when a mismatch needs to be classified.'
    echo
    echo '## Key metrics'
    echo
    echo '| Case | exit | runtime | arena | direct io | peak RSS | disk read | tokens | token ids |'
    echo '|---|---|---|---|---|---|---|---|---|'
    for c in case1 case2 case3 case4 case7; do
        [ "${CASE_CHECKS[$c]:-0}" -eq 0 ] && continue
        echo "| $c | ${CASE_RC[$c]:-–} | ${CASE_SECS[$c]:-–}s | ${CASE_ARENA[$c]:-–} MiB (${CASE_WHY[$c]:-–}) | ${CASE_DIO[$c]:-–} | ${CASE_RSS[$c]:-–} MiB | ${CASE_READ_MIB[$c]:-–} MiB | ${TOKEN_COUNT_CASE[$c]:-–} | \`${TOKEN_IDS_CASE[$c]:-–}\` |"
    done
    echo
    echo '## Greedy token-id comparison'
    echo
    if [ -n "${REFERENCE_CASE:-}" ] && [ -n "${TOKEN_IDS_CASE[$REFERENCE_CASE]:-}" ]; then
        echo "Reference: \`$REFERENCE_CASE\` — \`${TOKEN_IDS_CASE[$REFERENCE_CASE]}\`"
        if [ "${TOKEN_IDS_CASE[case2]:-}" != "${TOKEN_IDS_CASE[$REFERENCE_CASE]:-}" ]; then
            echo
            echo '> Note: the plain native baseline (operator fusion on) produced different greedy'
            echo '> tokens; the disk-streaming path forces fusion off, so `case2b` (native +'
            echo '> `GGML_CPU_DISABLE_FUSION=1`) is the fair reference. This is expected for'
            echo '> hybrid/MoE models whose numerics are sensitive to the fusion order.'
        fi
        echo
        echo '| Variant | Token ids | vs reference |'
        echo '|---|---|---|'
        for c in case1 case2 case2b case3 case4 case7; do
            [ -z "${TOKEN_IDS_CASE[$c]:-}" ] && continue
            if [ "${TOKEN_IDS_CASE[$c]}" = "${TOKEN_IDS_CASE[$REFERENCE_CASE]}" ]; then r="identical"; else r="different"; fi
            echo "| $c | \`${TOKEN_IDS_CASE[$c]}\` | $r |"
        done
    else
        echo '| – | – | no token ids captured |'
    fi
    echo
    echo '## TUI i18n captures'
    echo
    for f in "$I18N_DIR"/tui-*.txt; do
        [ -f "$f" ] && echo "- \`${f#$REPO_ROOT/}\`"
    done
    echo
    echo '## Raw logs'
    echo
    while IFS= read -r lf; do
        [ -n "$lf" ] && [ -f "$lf" ] && echo "- `${lf#$REPO_ROOT/}`"
    done < "$LOG_WRITTEN_FILE"
    echo
    echo '## Commands'
    echo
    echo '```'
    echo "test/run-tests.sh --bin-dir $BIN_DIR --model $MODEL"
    echo '```'
} > "$REPORT" 2>/dev/null || log "warning: could not write $REPORT"

[ "$FAIL_TOTAL" -eq 0 ] && exit 0
exit 1
