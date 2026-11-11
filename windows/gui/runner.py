"""Engine runner and log parser for the diskinfer Windows workbench.

The workbench does not re-implement inference: it drives the already built
executables (disktui.exe / diskrun.exe / llama-completion.exe), sets the
LLAMA_DISK_* environment the same way the command line wrappers do, and parses
the logs the engines print so the GUI can show arena/io/compute/RSS numbers.

No third-party dependency beyond PySide6 (ctypes is used for the Windows RSS
query, so psutil is not needed).
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wintypes
import json
import os
import re
import shlex
import sys
import uuid
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable, Optional

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from i18n import tr

# --------------------------------------------------------------------------- paths

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# the workbench autodetects a local GGUF for the model field (see
# find_default_model); --model / $DISKINFER_MODEL always win.  DEFAULT_MODEL is
# kept for compatibility only, it is deliberately empty.
DEFAULT_MODEL = Path("")


def _model_search_dirs() -> list[Path]:
    """Directories that may contain GGUF models, in preference order."""
    dirs: list[Path] = []
    env_dirs = os.environ.get("DISKINFER_MODEL_DIRS", "")
    for part in env_dirs.replace(";", os.pathsep).split(os.pathsep):
        part = part.strip()
        if part:
            dirs.append(Path(part))
    dirs += [
        Path.home() / "models",
        PROJECT_ROOT / "models",
        Path.home() / "Downloads" / "models",
        Path(r"D:\LMStudioModel"),  # local model library on the dev machine
    ]
    out: list[Path] = []
    seen = set()
    for d in dirs:
        key = str(d)
        if key not in seen:
            seen.add(key)
            out.append(d)
    return out


def _scan_gguf(root: Path, depth: int = 2) -> list[Path]:
    """*.gguf files under root, depth-limited; skips mmproj/vision projectors."""
    found: list[Path] = []

    def walk(d: Path, left: int) -> None:
        if left < 0:
            return
        try:
            entries = list(os.scandir(d))
        except OSError:
            return
        for entry in entries:
            try:
                if entry.is_file(follow_symlinks=False):
                    low = entry.name.lower()
                    if low.endswith(".gguf") and not low.startswith("mmproj"):
                        p = Path(entry.path)
                        try:
                            if 1_000_000 <= p.stat().st_size <= 4 * 1024 ** 3:
                                found.append(p)
                        except OSError:
                            pass
                elif (entry.is_dir(follow_symlinks=False) and left > 0
                      and not entry.name.startswith(".")):
                    walk(Path(entry.path), left - 1)
            except OSError:
                continue

    walk(root, depth)
    return found


_MODEL_CACHE: list[str] = []


def find_default_model() -> str:
    """Path of a usable local GGUF (``--model`` still wins); "" if none found."""
    if _MODEL_CACHE:
        return _MODEL_CACHE[0]
    env_model = os.environ.get("DISKINFER_MODEL", "").strip()
    if env_model and Path(env_model).exists():
        _MODEL_CACHE.append(env_model)
        return env_model
    candidates: list[Path] = []
    for d in _model_search_dirs():
        if not d.is_dir():
            continue
        candidates = _scan_gguf(d, 2)
        if candidates:
            break
    seen = set()
    uniq: list[Path] = []
    for p in candidates:
        key = str(p)
        if key not in seen:
            seen.add(key)
            uniq.append(p)
    if not uniq:
        _MODEL_CACHE.append("")
        return ""

    def rank(p: Path) -> tuple:
        low = p.name.lower()
        pref = 0 if ("hai-test" in low or "0.8b" in low or "tiny" in low) else 1
        try:
            size = p.stat().st_size
        except OSError:
            size = 4 * 1024 ** 3
        return (pref, size)

    best = sorted(uniq, key=rank)[0]
    _MODEL_CACHE.append(str(best))
    return str(best)

BIN_NAMES = {
    "disktui": "disktui.exe",
    "diskrun": "diskrun.exe",
    "llama-completion": "llama-completion.exe",
}

ENGINE_LABELS = {
    "disktui": "disktui  (TUI 分屏测试)",
    "diskrun": "diskrun  (最小驱动, 打印 token id)",
    "llama-completion": "llama-completion  (标准 llama.cpp 工具)",
}


def candidate_bin_dirs() -> list[Path]:
    """Directories that may contain the built Windows executables."""
    dirs: list[Path] = []
    env = os.environ.get("DISKINFER_BIN_DIR")
    if env:
        dirs.append(Path(env))
    dirs.append(PROJECT_ROOT / "bin")
    dirs.append(PROJECT_ROOT / "build" / "out" / "win-x64")
    dirs.append(PROJECT_ROOT / "build" / "win-x64" / "bin" / "Release")
    return dirs


def find_bin_dir(explicit: Optional[str] = None) -> Optional[Path]:
    if explicit:
        p = Path(explicit)
        if (p / "diskrun.exe").exists():
            return p
    for d in candidate_bin_dirs():
        if (d / "diskrun.exe").exists() or (d / "disktui.exe").exists():
            return d
    return None


CACHE_DIR = PROJECT_ROOT / "gui" / "runs"


# --------------------------------------------------------------------------- rss

class _PMC(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("PageFaultCount", wintypes.DWORD),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


_win: dict = {}


def _win_api():
    if _win:
        return _win
    if os.name != "nt":
        return {}
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)

        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.OpenProcess.restype = ctypes.c_void_p
        k32.CloseHandle.argtypes = (ctypes.c_void_p,)
        k32.CloseHandle.restype = wintypes.BOOL
        psapi.GetProcessMemoryInfo.argtypes = (ctypes.c_void_p, ctypes.POINTER(_PMC), wintypes.DWORD)
        psapi.GetProcessMemoryInfo.restype = wintypes.BOOL

        _win.update(k32=k32, psapi=psapi)
    except Exception:  # pragma: no cover - non windows or hardened env
        _win.clear()
    return _win


PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def process_rss_mb(pid: int) -> Optional[tuple[float, float]]:
    """(current working set MiB, peak working set MiB) of a pid, None if unknown."""
    api = _win_api()
    if not api or pid <= 0:
        return None
    k32, psapi = api["k32"], api["psapi"]
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return None
    try:
        pmc = _PMC()
        pmc.cb = ctypes.sizeof(_PMC)
        if not psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
            return None
        return (pmc.WorkingSetSize / 1048576.0, pmc.PeakWorkingSetSize / 1048576.0)
    finally:
        k32.CloseHandle(h)


# --------------------------------------------------------------------------- config

@dataclass
class RunConfig:
    engine: str = "diskrun"
    model: str = ""
    bin_dir: str = ""
    prompt: str = "The capital of France is"
    raw: bool = True
    sysmsg: str = ""

    n_predict: int = 8
    n_ctx: int = 128
    n_batch: int = 4
    n_ubatch: int = 4
    threads: int = 4
    temp: float = 0.0
    top_k: int = 20
    top_p: float = 0.95
    extra_args: str = ""

    # arena: "auto"  -> LLAMA_DISK_STREAM_MB unset (memory/8, clamped)
    #        "native"-> LLAMA_DISK_STREAM_MB=0 (stock mmap / full load)
    #        "custom"-> LLAMA_DISK_STREAM_MB=<arena_mib>
    arena_mode: str = "auto"
    arena_mib: int = 200

    odirect: bool = True
    mlock: bool = False
    prefetch: bool = False
    lookahead: int = 16
    debug: bool = False
    verbose: bool = False

    # run the same case again with the native path and diff the outputs
    compare_native: bool = False
    save_log: bool = True
    tag: str = ""

    def clone(self, **kw) -> "RunConfig":
        data = asdict(self)
        data.update(kw)
        return RunConfig(**data)

    def native_baseline(self) -> "RunConfig":
        """Same run on the native mmap path, for the greedy token-id comparison.

        The disk-streaming loader disables weight repacking, so the native run
        adds -no-extra-bufts: without it a repacked native run (AVX2 builds)
        can legitimately pick different greedy tokens.
        """
        extra = self.extra_args.strip()
        extra = (extra + " -no-extra-bufts") if extra else "-no-extra-bufts"
        return self.clone(arena_mode="native", compare_native=False, tag="baseline",
                          extra_args=extra)

    def exe_path(self) -> Path:
        base = Path(self.bin_dir) if self.bin_dir else (find_bin_dir() or Path("."))
        return base / BIN_NAMES[self.engine]


# --------------------------------------------------------------------------- metrics

@dataclass
class Metrics:
    # model / arena
    registered_tensors: Optional[int] = None
    registered_mib: Optional[int] = None
    largest_tensor: str = ""
    largest_mib: Optional[int] = None
    arena_requested_mib: Optional[int] = None
    arena_mib: Optional[int] = None
    arena_note: str = ""
    direct_io: Optional[int] = None
    mlock: Optional[int] = None
    prefetch: Optional[int] = None
    lookahead: Optional[int] = None
    virtual_lock_failed: bool = False
    buffered_fallback: bool = False
    read_failed: bool = False

    # timing
    model_load_s: Optional[float] = None
    prompt_tokens: Optional[int] = None
    prefill_s: Optional[float] = None
    prefill_io_s: float = 0.0
    prefill_cmp_s: float = 0.0
    generated_tokens: Optional[int] = None
    s_per_token: Optional[float] = None
    load_time_ms: Optional[float] = None
    prompt_eval_ms: Optional[float] = None
    prompt_eval_tokens: Optional[int] = None
    eval_ms: Optional[float] = None
    eval_runs: Optional[int] = None
    total_ms: Optional[float] = None
    io_total_s: float = 0.0
    cmp_total_s: float = 0.0

    # disk streaming counters (LLAMA_DISK_VERBOSE)
    loads: Optional[int] = None
    prefetch_loads: Optional[int] = None
    prefetch_dropped: Optional[int] = None
    read_mib_total: Optional[int] = None
    evictions: Optional[int] = None
    engine_io_s: Optional[float] = None

    # memory
    rss_peak_mib: Optional[float] = None
    rss_reported_mib: Optional[int] = None

    # text / tokens
    generated_ids: list = field(default_factory=list)
    token_rows: list = field(default_factory=list)
    prefill_rows: list = field(default_factory=list)
    generated_text: str = ""
    answer: str = ""
    model_desc: str = ""
    saved_answer_to: str = ""

    warnings: list = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class RunResult:
    cfg: RunConfig
    exit_code: Optional[int] = None
    wall_s: float = 0.0
    metrics: Metrics = field(default_factory=Metrics)
    log_path: str = ""
    stdout_path: str = ""
    stderr_path: str = ""
    timestamp: str = ""
    run_id: str = ""
    verdict: str = ""
    notes: list = field(default_factory=list)
    compare: Optional[dict] = None

    def to_dict(self) -> dict:
        return {
            "run_id": self.run_id,
            "timestamp": self.timestamp,
            "engine": self.cfg.engine,
            "arena_mode": self.cfg.arena_mode,
            "arena_mib": self.cfg.arena_mib,
            "exit_code": self.exit_code,
            "wall_s": round(self.wall_s, 3),
            "verdict": self.verdict,
            "notes": self.notes,
            "metrics": self.metrics.to_dict(),
            "compare": self.compare,
            "log_path": self.log_path,
        }


# --------------------------------------------------------------------------- parsing

R = {
    "registered": re.compile(
        r"llama-disk: (\d+) tensors registered, (\d+) MiB to stream, largest tensor '([^']*)' (\d+) MiB"),
    "arena_raise": re.compile(
        r"llama-disk: arena (\d+) MiB cannot hold the largest tensor '([^']*)' \((\d+) MiB\), raised to (\d+) MiB"),
    "streaming": re.compile(
        r"llama-disk: streaming weights from disk, arena = (\d+) MiB \(([^)]*)\), "
        r"direct io = (\d), mlock = (\d), prefetch = (\d) \(lookahead (\d+)\)"),
    "vlock_fail": re.compile(r"llama-disk: VirtualLock failed"),
    "buffered_fb": re.compile(r"llama-disk: unbuffered reads unavailable"),
    "read_fail": re.compile(r"llama-disk: read failed"),
    "verbose": re.compile(
        r"llama-disk: loads = (\d+) \(prefetch (\d+), dropped (\d+)\), read = (\d+) MiB, "
        r"evictions = (\d+), io = (\d+)\.(\d+) s, waits = (\d+)"),

    "dr_model_load": re.compile(r"diskrun: model loaded in ([\d.]+) s"),
    "dr_prompt": re.compile(r"diskrun: prompt has (\d+) tokens"),
    "dr_prefill_tok": re.compile(r"diskrun: prefill token (\d+)/(\d+) done, rss = (-?\d+) MiB"),
    "dr_prefill_done": re.compile(r"diskrun: prefill took ([\d.]+) s"),
    "dr_token": re.compile(r"diskrun: token (\d+) id=(-?\d+) sample=([\d.]+) s, rss = (-?\d+) MiB"),
    "dr_rss": re.compile(r"diskrun: rss (.+?)\s+= (-?\d+) MiB"),
    "dr_generated": re.compile(r"diskrun: generated (\d+) tokens in ([\d.]+) s \(([\d.]+) s/token\)"),

    "perf_load": re.compile(r"load time =\s+([\d.]+) ms"),
    "perf_prompt": re.compile(r"prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens"),
    "perf_eval": re.compile(r"eval time =\s+([\d.]+) ms /\s+(\d+) runs"),
    "perf_total": re.compile(r"total time =\s+([\d.]+) ms /\s+(\d+) tokens"),

    "tui_ready": re.compile(r"\[\s*([\d.]+)s\] model ready: (.*)"),
    "tui_prompt_tokens": re.compile(r"prompt = (\d+) tokens"),
    "tui_pp": re.compile(
        r"\[([\d:]+)\] pp (\d+)-(\d+)/(\d+)\s+io ([\d.]+)s\s+cmp ([\d.]+)s\s+'(.*)'"),
    "tui_token": re.compile(
        r"\[([\d:]+)\] t(\d+)\s+io ([\d.]+)s\s+cmp ([\d.]+)s\s+tot ([\d.]+)s\s+(.*)"),
    "tui_gen": re.compile(r"gen (\d+) tok in ([\d.]+)s \(([\d.]+) s/tok\)\s+io ([\d.]+)s"),
    "tui_answer": re.compile(r"answer: (.*)"),
    "tui_saved": re.compile(r"saved to (.*)"),
}

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def parse_line(line: str, m: Metrics) -> None:
    """Update metrics from one log line. Never raises."""
    line = line.rstrip("\r\n")
    if not line:
        return
    try:
        _parse_line(line, m)
    except Exception:  # parsing must never kill a run
        m.warnings.append(tr('解析日志失败: ') + line[:160])


def _parse_line(line: str, m: Metrics) -> None:
    if "llama-disk:" in line:
        mo = R["registered"].search(line)
        if mo:
            m.registered_tensors = int(mo.group(1))
            m.registered_mib = int(mo.group(2))
            m.largest_tensor = mo.group(3)
            m.largest_mib = int(mo.group(4))
            return
        mo = R["arena_raise"].search(line)
        if mo:
            m.arena_requested_mib = int(mo.group(1))
            m.largest_tensor = mo.group(2)
            m.largest_mib = int(mo.group(3))
            m.arena_mib = int(mo.group(4))
            m.arena_note = tr('从 {0} MiB 抬到 {1} MiB (最大张量 {2} MiB)').format(mo.group(1), mo.group(4), mo.group(3))
            return
        mo = R["streaming"].search(line)
        if mo:
            m.arena_mib = int(mo.group(1))
            m.arena_note = mo.group(2)
            m.direct_io = int(mo.group(3))
            m.mlock = int(mo.group(4))
            m.prefetch = int(mo.group(5))
            m.lookahead = int(mo.group(6))
            return
        if R["vlock_fail"].search(line):
            m.virtual_lock_failed = True
            return
        if R["buffered_fb"].search(line):
            m.buffered_fallback = True
            return
        if R["read_fail"].search(line):
            m.read_failed = True
            m.warnings.append(tr('磁盘读取失败: ') + line[:160])
            return
        mo = R["verbose"].search(line)
        if mo:
            m.loads = int(mo.group(1))
            m.prefetch_loads = int(mo.group(2))
            m.prefetch_dropped = int(mo.group(3))
            m.read_mib_total = int(mo.group(4))
            m.evictions = int(mo.group(5))
            m.engine_io_s = int(mo.group(6)) + int(mo.group(7)) / 10.0
            return
        return

    if "diskrun:" in line:
        mo = R["dr_model_load"].search(line)
        if mo:
            m.model_load_s = float(mo.group(1))
            return
        mo = R["dr_prompt"].search(line)
        if mo:
            m.prompt_tokens = int(mo.group(1))
            return
        mo = R["dr_prefill_tok"].search(line)
        if mo:
            m.prefill_rows.append({
                "batch": f"{mo.group(1)}/{mo.group(2)}",
                "rss_mib": int(mo.group(3)),
            })
            return
        mo = R["dr_prefill_done"].search(line)
        if mo:
            m.prefill_s = float(mo.group(1))
            return
        mo = R["dr_token"].search(line)
        if mo:
            m.token_rows.append({
                "n": int(mo.group(1)),
                "id": int(mo.group(2)),
                "io_s": float(mo.group(3)),
                "rss_mib": int(mo.group(4)),
            })
            m.generated_ids.append(int(mo.group(2)))
            return
        mo = R["dr_rss"].search(line)
        if mo and mo.group(2).strip():
            try:
                m.rss_reported_mib = int(mo.group(2))
            except ValueError:
                pass
            return
        mo = R["dr_generated"].search(line)
        if mo:
            m.generated_tokens = int(mo.group(1))
            m.s_per_token = float(mo.group(3))
            return
        return

    if "llama_perf_context_print" in line or "common_perf_print" in line:
        mo = R["perf_load"].search(line)
        if mo:
            m.load_time_ms = float(mo.group(1))
            return
        mo = R["perf_prompt"].search(line)
        if mo:
            m.prompt_eval_ms = float(mo.group(1))
            m.prompt_eval_tokens = int(mo.group(2))
            return
        mo = R["perf_eval"].search(line)
        if mo:
            m.eval_ms = float(mo.group(1))
            m.eval_runs = int(mo.group(2))
            return
        mo = R["perf_total"].search(line)
        if mo:
            m.total_ms = float(mo.group(1))
            return
        return

    # disktui log lines (also arrive through the log file, not only stdout)
    mo = R["tui_ready"].search(line)
    if mo:
        m.model_desc = mo.group(2).strip()
        return
    mo = R["tui_prompt_tokens"].search(line)
    if mo:
        m.prompt_tokens = int(mo.group(1))
        return
    mo = R["tui_pp"].search(line)
    if mo:
        io_s, cmp_s = float(mo.group(5)), float(mo.group(6))
        m.prefill_rows.append({
            "batch": f"{mo.group(2)}-{mo.group(3)}/{mo.group(4)}",
            "io_s": io_s,
            "cmp_s": cmp_s,
            "piece": mo.group(7),
            "elapsed": mo.group(1),
        })
        m.prefill_io_s += io_s
        m.prefill_cmp_s += cmp_s
        return
    mo = R["tui_token"].search(line)
    if mo:
        io_s, cmp_s, tot_s = float(mo.group(3)), float(mo.group(4)), float(mo.group(5))
        piece = mo.group(6).strip()
        if len(piece) >= 2 and piece.startswith("'") and piece.endswith("'"):
            piece = piece[1:-1]
        m.token_rows.append({
            "n": int(mo.group(2)),
            "piece": piece,
            "io_s": io_s,
            "cmp_s": cmp_s,
            "tot_s": tot_s,
            "clock": mo.group(1),
        })
        m.io_total_s += io_s
        m.cmp_total_s += cmp_s
        return
    mo = R["tui_gen"].search(line)
    if mo:
        m.generated_tokens = int(mo.group(1))
        m.s_per_token = float(mo.group(3))
        m.io_total_s = max(m.io_total_s, float(mo.group(4)))
        return
    mo = R["tui_answer"].search(line)
    if mo:
        m.answer = mo.group(1)
        return
    mo = R["tui_saved"].search(line)
    if mo:
        m.saved_answer_to = mo.group(1).strip()
        return


# --------------------------------------------------------------------------- command / env building

def build_command(cfg: RunConfig) -> list[str]:
    args: list[str] = ["-m", cfg.model]
    if cfg.engine == "disktui":
        args += [
            "-c", str(cfg.n_ctx), "-ub", str(cfg.n_ubatch), "-t", str(cfg.threads),
            "-n", str(cfg.n_predict),
            "--temp", f"{cfg.temp:g}", "--top-k", str(cfg.top_k), "--top-p", f"{cfg.top_p:g}",
        ]
        if cfg.raw:
            args += ["--raw"]
        else:
            args += ["--chat"]
            if cfg.sysmsg:
                args += ["--sys", cfg.sysmsg]
        if cfg.prompt:
            args += ["-q", cfg.prompt]
        if cfg.debug:
            args += ["--debug"]
    elif cfg.engine == "diskrun":
        args += [
            "-p", cfg.prompt or "Hello",
            "-n", str(cfg.n_predict), "-c", str(cfg.n_ctx),
            "-b", str(cfg.n_batch), "-ub", str(cfg.n_ubatch), "-t", str(cfg.threads),
        ]
    else:  # llama-completion
        args += [
            "-p", cfg.prompt or "Hello",
            "-n", str(cfg.n_predict), "-c", str(cfg.n_ctx),
            "-b", str(cfg.n_batch), "-ub", str(cfg.n_ubatch), "-t", str(cfg.threads),
            "--temp", f"{cfg.temp:g}", "--top-k", str(cfg.top_k), "--top-p", f"{cfg.top_p:g}",
        ]
        if cfg.raw:
            args += ["-no-cnv"]
        else:
            args += ["-cnv"]
            if cfg.sysmsg:
                args += ["-sys", cfg.sysmsg]
    if cfg.extra_args.strip():
        args += [a for a in shlex.split(cfg.extra_args, posix=False) if a]
    return args



def build_api_probe_command(cfg: RunConfig, port: int) -> list[str]:
    """Command line for the headless ``disktui --api-only`` probe case."""
    return ["-m", cfg.model, "--api-only", "--port", str(port), "-c", str(cfg.n_ctx)]

ENV_KEYS_TO_CLEAR = (
    "LLAMA_DISK_STREAM_MB",
    "LLAMA_DISK_ODIRECT",
    "LLAMA_DISK_MLOCK",
    "LLAMA_DISK_PREFETCH",
    "LLAMA_DISK_LOOKAHEAD",
    "LLAMA_DISK_DEBUG",
    "LLAMA_DISK_VERBOSE",
    "LLAMA_DISK_LOG",
    "LLAMA_DISK_WINDOW",
    "LLAMA_DISK_OUT_CHUNK",
    "GGML_CPU_DISABLE_FUSION",
)


def build_env(cfg, log_path: Optional[Path] = None) -> QProcessEnvironment:
    """Environment for any engine config (RunConfig or ChatConfig)."""
    env = QProcessEnvironment.systemEnvironment()
    for key in ENV_KEYS_TO_CLEAR:
        env.remove(key)
    env.insert("LLAMA_DISK_ODIRECT", "1" if cfg.odirect else "0")
    if cfg.arena_mode == "custom":
        env.insert("LLAMA_DISK_STREAM_MB", str(cfg.arena_mib))
    elif cfg.arena_mode == "native":
        env.insert("LLAMA_DISK_STREAM_MB", "0")
    # "auto": leave LLAMA_DISK_STREAM_MB unset
    if cfg.mlock:
        env.insert("LLAMA_DISK_MLOCK", "1")
    if cfg.prefetch:
        env.insert("LLAMA_DISK_PREFETCH", "1")
    if getattr(cfg, "lookahead", 16) != 16:
        env.insert("LLAMA_DISK_LOOKAHEAD", str(cfg.lookahead))
    if getattr(cfg, "debug", False):
        env.insert("LLAMA_DISK_DEBUG", "1")
    if getattr(cfg, "verbose", False):
        env.insert("LLAMA_DISK_VERBOSE", "1")
    if log_path is not None:
        env.insert("LLAMA_DISK_LOG", str(log_path))
    return env


def env_summary(cfg: RunConfig) -> str:
    bits: list[str] = []
    if cfg.arena_mode == "native":
        bits.append("STREAM_MB=0")
    elif cfg.arena_mode == "custom":
        bits.append(f"STREAM_MB={cfg.arena_mib}")
    else:
        bits.append("STREAM_MB=auto")
    bits.append("ODIRECT=" + ("1" if cfg.odirect else "0"))
    if cfg.mlock:
        bits.append("MLOCK=1")
    if cfg.prefetch:
        bits.append("PREFETCH=1")
    if cfg.debug:
        bits.append("DEBUG=1")
    if cfg.verbose:
        bits.append("VERBOSE=1")
    return " ".join(bits)


def powershell_command(cfg: RunConfig, log_path: Optional[Path]) -> str:
    exe = cfg.exe_path()
    env = build_env(cfg, log_path)
    parts = []
    for key in ENV_KEYS_TO_CLEAR:
        if env.contains(key):
            parts.append(f"$env:{key}='{env.value(key)}'")
        else:
            parts.append(f"Remove-Item Env:{key} -ErrorAction SilentlyContinue")
    parts.append('& "' + str(exe) + '" ' + " ".join(subprocess_quote(a) for a in build_command(cfg)))
    return "; ".join(parts)


def subprocess_quote(arg: str) -> str:
    if not arg or any(c in arg for c in ' \t"'):
        return '"' + arg.replace('"', '\\"') + '"'
    return arg


# --------------------------------------------------------------------------- runner

def _new_run_dir() -> Path:
    stamp = __import__("datetime").datetime.now().strftime("%Y%m%d-%H%M%S")
    d = CACHE_DIR / f"{stamp}-{uuid.uuid4().hex[:6]}"
    d.mkdir(parents=True, exist_ok=True)
    return d


class EngineRunner(QObject):
    """Runs one engine invocation and turns its output into Metrics."""

    started = Signal()
    output = Signal(str, str)        # (channel, chunk) channel: out|err|log
    snapshot = Signal(object)        # Metrics (live)
    finished = Signal(object)        # RunResult
    error = Signal(str)

    def __init__(self, cfg: RunConfig, parent: QObject | None = None):
        super().__init__(parent)
        self.cfg = cfg
        self.metrics = Metrics()
        self.result = RunResult(cfg=cfg)
        self._proc: QProcess | None = None
        self._buf = {"out": "", "err": ""}
        self._log_pos = 0
        self._wall_t0 = 0.0
        self._rss_peak = 0.0
        self._stderr_text = ""
        self._stdout_text = ""
        self._kill_timer: QTimer | None = None

        self._timer = QTimer(self)
        self._timer.setInterval(250)
        self._timer.timeout.connect(self._poll)

    # -- public ------------------------------------------------------------
    def start(self) -> None:
        exe = self.cfg.exe_path()
        if not exe.exists():
            self.error.emit(tr('可执行文件不存在: {0}').format(exe))
            return
        # the model path is deliberately not validated here: the "missing model"
        # case must exercise the engine's own error path (nonzero exit), not ours

        if self.cfg.save_log:
            run_dir = _new_run_dir()
        else:
            # keep the project tree clean: unsaved runs go to the system temp dir
            import tempfile
            run_dir = Path(tempfile.mkdtemp(prefix="diskinfer-workbench-"))
        run_dir.mkdir(parents=True, exist_ok=True)
        self.result.run_id = run_dir.name
        self.result.log_path = str(run_dir / "engine.log")
        self.result.stdout_path = str(run_dir / "stdout.log")
        self.result.stderr_path = str(run_dir / "stderr.log")
        self.result.timestamp = __import__("datetime").datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        cfg_log = Path(self.result.log_path) if self.cfg.engine == "disktui" else None

        proc = QProcess(self)
        proc.setProgram(str(exe))
        proc.setArguments(build_command(self.cfg))
        proc.setWorkingDirectory(str(PROJECT_ROOT))
        proc.setProcessEnvironment(build_env(self.cfg, cfg_log))
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        proc.setStandardInputFile(QProcess.nullDevice())
        proc.readyReadStandardOutput.connect(self._on_stdout)
        proc.readyReadStandardError.connect(self._on_stderr)
        proc.finished.connect(self._on_finished)
        proc.errorOccurred.connect(self._on_error)
        self._proc = proc

        self._wall_t0 = __import__("time").monotonic()
        self._timer.start()
        proc.start()
        self.started.emit()

    def stop(self) -> None:
        if self._proc is None:
            return
        self._proc.terminate()
        if self._kill_timer is None:
            self._kill_timer = QTimer(self)
            self._kill_timer.setSingleShot(True)
            self._kill_timer.setInterval(2000)
            self._kill_timer.timeout.connect(self._force_kill)
            self._kill_timer.start()

    def is_running(self) -> bool:
        return self._proc is not None and self._proc.state() != QProcess.ProcessState.NotRunning

    # -- internals ---------------------------------------------------------
    def _force_kill(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.ProcessState.NotRunning:
            self._proc.kill()

    def _on_stdout(self) -> None:
        if self._proc is None:
            return
        data = bytes(self._proc.readAllStandardOutput()).decode("utf-8", errors="replace")
        self._stdout_text += data
        self._feed("out", data)

    def _on_stderr(self) -> None:
        if self._proc is None:
            return
        data = bytes(self._proc.readAllStandardError()).decode("utf-8", errors="replace")
        self._stderr_text += data
        self._feed("err", data)

    def _feed(self, channel: str, data: str) -> None:
        self._buf[channel] += data
        while "\n" in self._buf[channel]:
            line, self._buf[channel] = self._buf[channel].split("\n", 1)
            self._handle_line(channel, line)

    def _handle_line(self, channel: str, raw: str) -> None:
        line = strip_ansi(raw).rstrip("\r")
        if not line.strip():
            return
        parse_line(line, self.metrics)
        self.output.emit(channel, line)

    def _poll(self) -> None:
        # tail the disktui log file (the TUI paints its stdout, the log is the clean text)
        log_path = Path(self.result.log_path) if self.result.log_path else None
        if log_path is not None and self.cfg.engine == "disktui" and log_path.exists():
            try:
                with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
                    fh.seek(self._log_pos)
                    new = fh.read()
                    self._log_pos = fh.tell()
                for line in new.splitlines():
                    line = strip_ansi(line).rstrip("\r")
                    if not line.strip():
                        continue
                    parse_line(line, self.metrics)
                    self.output.emit("log", line)
            except OSError:
                pass

        if self._proc is not None:
            pid = int(self._proc.processId() or 0)
            rss = process_rss_mb(pid)
            if rss is not None:
                cur, peak = rss
                if peak > self._rss_peak:
                    self._rss_peak = peak
                self.metrics.rss_peak_mib = round(self._rss_peak, 1)
        self.snapshot.emit(self.metrics)

        if self._proc is not None and self._proc.state() == QProcess.ProcessState.NotRunning:
            self._timer.stop()

    def _on_error(self, err: QProcess.ProcessError) -> None:
        if err == QProcess.ProcessError.FailedToStart:
            msg = tr('进程启动失败: {0}').format(self.cfg.exe_path())
            if self._proc is not None:
                msg += f" ({self._proc.errorString()})"
            self.error.emit(msg)

    def _on_finished(self, exit_code: int, _status) -> None:
        self._timer.stop()
        self._force_kill()
        self.result.exit_code = exit_code
        self.result.wall_s = __import__("time").monotonic() - self._wall_t0
        self.result.metrics = self.metrics

        # flush trailing partial lines
        for ch in ("out", "err"):
            if self._buf[ch].strip():
                self._handle_line(ch, self._buf[ch])
                self._buf[ch] = ""

        # finish log tail
        if self.cfg.engine == "disktui":
            self._poll()

        self._derive_text()

        if self.result.stdout_path:
            try:
                Path(self.result.stdout_path).write_text(self._stdout_text, encoding="utf-8", errors="replace")
                Path(self.result.stderr_path).write_text(self._stderr_text, encoding="utf-8", errors="replace")
            except OSError:
                pass

        self.result.verdict, self.result.notes = judge_single(self.result)
        self.finished.emit(self.result)

    def _derive_text(self) -> None:
        m = self.metrics
        if self.cfg.engine == "disktui":
            m.generated_text = m.answer.strip()
            if m.generated_tokens is None and m.token_rows:
                m.generated_tokens = len(m.token_rows)
            return
        text = self._stdout_text
        prompt = self.cfg.prompt or "Hello"
        if text.startswith(prompt):
            text = text[len(prompt):]
        m.generated_text = text.strip()
        # llama-completion has no per-token lines: the first token comes from the
        # prompt-eval logits, every eval run after that produces one more token
        if m.generated_tokens is None and m.eval_runs is not None:
            m.generated_tokens = m.eval_runs + 1
            if m.eval_ms is not None and m.eval_runs > 0:
                m.s_per_token = m.eval_ms / 1000.0 / m.eval_runs


# --------------------------------------------------------------------------- chat

@dataclass
class ChatConfig:
    """Settings for the persistent streaming chat engine (diskc.exe)."""

    model: str = ""
    bin_dir: str = ""
    n_ctx: int = 2048
    n_batch: int = 4
    n_ubatch: int = 4
    threads: int = 4
    n_predict: int = 256
    temp: float = 0.7
    top_k: int = 40
    top_p: float = 0.95
    no_think: bool = True

    # disk streaming options (mirror RunConfig names so build_env can be shared)
    arena_mode: str = "auto"
    arena_mib: int = 2048
    odirect: bool = True
    mlock: bool = False
    prefetch: bool = False
    lookahead: int = 16
    debug: bool = False
    verbose: bool = False

    def exe_path(self) -> Path:
        base = Path(self.bin_dir) if self.bin_dir else (find_bin_dir() or Path("."))
        # the build script copies llama-diskc.exe to diskc.exe; accept both layouts
        for name in ("diskc.exe", "llama-diskc.exe"):
            candidate = base / name
            if candidate.exists():
                return candidate
        return base / "diskc.exe"

    def key(self) -> tuple:
        """Identity of the engine process: a change requires a restart."""
        return (self.model, self.bin_dir, self.n_ctx, self.n_batch, self.n_ubatch, self.threads,
                self.arena_mode, self.arena_mib, self.odirect, self.mlock, self.prefetch,
                self.lookahead)


class ChatSession(QObject):
    """One persistent diskc.exe process speaking JSON lines on stdin/stdout."""

    ready = Signal(object)     # engine metadata
    progress = Signal(object)  # live layer / io / counters
    token = Signal(object)     # one generated token with io/cmp/layer
    done = Signal(object)      # turn finished
    info = Signal(object)      # engine diagnostics (prefix reuse etc.)
    failure = Signal(str)
    log = Signal(str)
    state_changed = Signal(str)

    def __init__(self, cfg: ChatConfig, parent: QObject | None = None):
        super().__init__(parent)
        self.cfg = cfg
        self._proc: QProcess | None = None
        self._dying: list[QProcess] = []
        self._buf = ""
        self._err_buf = ""
        self._state = "idle"       # idle | starting | ready | generating

    # -- lifecycle ---------------------------------------------------------
    def is_running(self) -> bool:
        return self._proc is not None and self._proc.state() != QProcess.ProcessState.NotRunning

    def state(self) -> str:
        return self._state

    def _set_state(self, state: str) -> None:
        if self._state != state:
            self._state = state
            self.state_changed.emit(state)

    def start(self) -> bool:
        model = Path(self.cfg.model)
        if not model.exists():
            self.failure.emit(tr('模型不存在：{0}').format(self.cfg.model))
            return False
        # DISKINFER_CHAT_CMD lets a demo/simulation engine speak the diskc JSON-line
        # protocol instead of the native diskc.exe (used by the Kimi-K3 demo).
        custom = os.environ.get("DISKINFER_CHAT_CMD", "").strip()
        exe = self.cfg.exe_path()
        if not custom and not exe.exists():
            self.failure.emit(tr('找不到对话引擎：{0}\n请先运行 build\\build-windows.ps1（会生成 diskc.exe）').format(exe))
            return False
        self.stop()

        proc = QProcess(self)
        if custom:
            try:
                parts = [p.strip('"') for p in shlex.split(custom, posix=False)]
            except ValueError as exc:
                self.failure.emit(tr('DISKINFER_CHAT_CMD 解析失败: {0}').format(exc))
                return False
            if not parts:
                self.failure.emit(tr('DISKINFER_CHAT_CMD 为空'))
                return False
            proc.setProgram(parts[0])
            proc.setArguments(parts[1:] + [
                "--model", self.cfg.model, "--n-ctx", str(self.cfg.n_ctx),
                "--n-predict", str(self.cfg.n_predict), "--threads", str(self.cfg.threads),
            ])
        else:
            proc.setProgram(str(exe))
            proc.setArguments([
                "-m", self.cfg.model, "-c", str(self.cfg.n_ctx),
                "-b", str(self.cfg.n_batch), "-ub", str(self.cfg.n_ubatch), "-t", str(self.cfg.threads),
                "--temp", f"{self.cfg.temp:g}", "--top-k", str(self.cfg.top_k),
                "--top-p", f"{self.cfg.top_p:g}", "-n", str(self.cfg.n_predict),
            ])
        proc.setWorkingDirectory(str(PROJECT_ROOT))
        proc.setProcessEnvironment(build_env(self.cfg))
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        proc.readyReadStandardOutput.connect(self._on_stdout)
        proc.readyReadStandardError.connect(self._on_stderr)
        proc.finished.connect(self._on_finished)
        proc.errorOccurred.connect(self._on_error)
        self._proc = proc
        self._buf = ""
        self._err_buf = ""
        self._set_state("starting")
        proc.start()
        return True

    def _write(self, req: dict) -> bool:
        if self._proc is None:
            return False
        try:
            self._proc.write((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
            return True
        except Exception as exc:  # broken pipe etc.
            self.failure.emit(tr('写入对话引擎失败: {0}').format(exc))
            return False

    def send(self, messages: list[dict], n_predict: int | None = None, temp: float | None = None,
             top_k: int | None = None, top_p: float | None = None) -> bool:
        if not self.is_running() or self._state != "ready":
            return False
        req = {
            "cmd": "chat",
            "messages": messages,
            "n_predict": int(n_predict if n_predict is not None else self.cfg.n_predict),
            "temp": float(temp if temp is not None else self.cfg.temp),
            "top_k": int(top_k if top_k is not None else self.cfg.top_k),
            "top_p": float(top_p if top_p is not None else self.cfg.top_p),
            "no_think": bool(self.cfg.no_think),
        }
        self._set_state("generating")
        return self._write(req)

    def reset(self) -> None:
        if self.is_running():
            self._write({"cmd": "reset"})

    def cancel(self) -> None:
        if self.is_running():
            self._write({"cmd": "cancel"})

    def stop(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        self._set_state("idle")
        try:
            if proc.state() != QProcess.ProcessState.NotRunning:
                proc.write(b'{"cmd":"quit"}\n')
                proc.closeWriteChannel()
                if not proc.waitForFinished(1200):
                    proc.kill()
                    proc.waitForFinished(800)
        except RuntimeError:
            pass
        proc.deleteLater()

    # -- output ------------------------------------------------------------
    def _on_stdout(self) -> None:
        if self._proc is None:
            return
        self._buf += bytes(self._proc.readAllStandardOutput()).decode("utf-8", "replace")
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                self.log.emit(line)
                continue
            kind = ev.get("ev")
            if kind == "ready":
                self._set_state("ready")
                self.ready.emit(ev)
            elif kind == "progress":
                self.progress.emit(ev)
            elif kind == "token":
                self.token.emit(ev)
            elif kind == "done":
                self._set_state("ready")
                self.done.emit(ev)
            elif kind == "error":
                self._set_state("ready")
                self.failure.emit(str(ev.get("msg", "engine error")))
            elif kind == "info":
                self.info.emit(ev)
            else:
                self.log.emit(line)

    def _on_stderr(self) -> None:
        if self._proc is None:
            return
        self._err_buf += bytes(self._proc.readAllStandardError()).decode("utf-8", "replace")
        while "\n" in self._err_buf:
            line, self._err_buf = self._err_buf.split("\n", 1)
            line = strip_ansi(line).rstrip("\r")
            if not line.strip():
                continue
            # the per-node graph dump is too noisy for the chat diagnostics pane
            if "llama_graph_n_input_tensors" in line or "is used by node" in line:
                continue
            self.log.emit(line)

    def _on_finished(self, exit_code: int, _status) -> None:
        was = self._state
        self._proc = None
        self._set_state("idle")
        if was in ("starting", "ready", "generating") and exit_code != 0:
            self.failure.emit(tr('对话引擎异常退出（退出码 {0}）').format(exit_code))

    def _on_error(self, err) -> None:
        if err == QProcess.ProcessError.FailedToStart:
            msg = tr('对话引擎启动失败: {0}').format(self.cfg.exe_path())
            if self._proc is not None:
                msg += f" ({self._proc.errorString()})"
            self.failure.emit(msg)


# --------------------------------------------------------------------------- verdict

def judge_single(res: RunResult) -> tuple[str, list[str]]:
    """PASS / WARN / FAIL for a single run, plus human notes."""
    notes: list[str] = []
    m = res.metrics
    cfg = res.cfg

    if res.exit_code != 0:
        notes.append(tr('退出码 {0} (非 0)').format(res.exit_code))
        return "FAIL", notes

    tokens = m.generated_tokens
    if tokens is None:
        tokens = len(m.token_rows)
    if tokens is None or tokens <= 0:
        if m.generated_text:
            tokens = 0
        else:
            notes.append(tr('没有生成任何 token'))
            return "FAIL", notes

    if cfg.arena_mode != "native":
        if m.arena_mib is None:
            notes.append(tr('没有看到流式 arena 日志 (可能没有启用磁盘流式)'))
            return "FAIL", notes
        if m.read_failed:
            notes.append(tr('出现磁盘读取失败'))
            return "FAIL", notes
    else:
        if m.arena_mib is not None:
            notes.append(tr('原生模式却出现了流式 arena 日志'))

    if m.buffered_fallback:
        notes.append(tr('卷不支持无缓冲读，已回退 buffered'))
    if m.virtual_lock_failed:
        notes.append(tr('VirtualLock 失败(arena 可能被换出，非致命)'))
    if m.read_failed:
        notes.append(tr('磁盘读取失败'))
        return "FAIL", notes

    return ("WARN" if notes else "PASS"), notes


def compare_runs(a: RunResult, b: RunResult) -> dict:
    """Compare a streaming run against its native baseline."""
    ma, mb = a.metrics, b.metrics
    ids_a = list(ma.generated_ids)
    ids_b = list(mb.generated_ids)
    text_a = (ma.generated_text or "").strip()
    text_b = (mb.generated_text or "").strip()

    compare: dict = {
        "mode": "ids" if (ids_a and ids_b) else "text",
        "ids_a": ids_a,
        "ids_b": ids_b,
        "text_a": text_a,
        "text_b": text_b,
        "same_ids": None,
        "same_text": text_a == text_b,
        "match": False,
        "detail": "",
    }
    if compare["mode"] == "ids":
        same = ids_a == ids_b
        compare["same_ids"] = same
        compare["match"] = bool(same)
        compare["detail"] = tr('token id 序列{0}: {1}').format(
            tr('完全一致') if same else tr('不一致'),
            ','.join(map(str, ids_a)) if same else f'A={ids_a} B={ids_b}',
        )
    else:
        compare["match"] = bool(text_a) and text_a == text_b
        compare["detail"] = (
            tr('生成文本一致') if compare["match"]
            else tr('文本不同: A={0!r} B={1!r}').format(text_a, text_b)
        )
    return compare


def judge_compare(compare: dict) -> tuple[str, list[str]]:
    if compare.get("match"):
        return "PASS", [compare.get("detail", "")]
    return "FAIL", [compare.get("detail", tr('流式与原生结果不一致'))]


# --------------------------------------------------------------------------- suite

@dataclass
class SuiteCase:
    key: str
    name: str
    overrides: dict
    expect_error: bool = False
    require_streaming: bool = True
    compare_native: bool = False
    api_probe: bool = False
    note: str = ""


SUITE_CASES: list[SuiteCase] = [
    SuiteCase("case1", "流式 · 小 arena 200 MiB", {
        "engine": "diskrun", "arena_mode": "custom", "arena_mib": 200,
        "n_predict": 8, "n_ctx": 128, "n_ubatch": 4, "threads": 4, "verbose": True,
    }, compare_native=True,
        note="arena 会被抬到最大张量+24 MiB；与 native+-no-extra-bufts 的贪心 token id 必须一致"),
    SuiteCase("case2", "原生基线 · STREAM_MB=0 · repack off", {
        "engine": "diskrun", "arena_mode": "native", "extra_args": "-no-extra-bufts",
        "n_predict": 8, "n_ctx": 128, "n_ubatch": 4, "threads": 4,
    }, require_streaming=False,
        note="标准 llama.cpp mmap 路径 + -no-extra-bufts（磁盘模式不带 repack，布局一致才可比）"),
    SuiteCase("case3", "自动 arena (内存/8)", {
        "engine": "diskrun", "arena_mode": "auto",
        "n_predict": 8, "n_ctx": 128, "n_ubatch": 4, "threads": 4, "verbose": True,
    }, note="应等于 min(RAM/8, 2048) MiB"),
    SuiteCase("case4", "关闭 O_DIRECT (buffered)", {
        "engine": "diskrun", "arena_mode": "custom", "arena_mib": 200, "odirect": False,
        "n_predict": 8, "n_ctx": 128, "n_ubatch": 4, "threads": 4, "verbose": True,
    }, note="buffered 读取路径，结果必须与直读一致"),
    SuiteCase("case5", "disktui --api-only · /v1/models", {
        "engine": "disktui", "arena_mode": "custom", "arena_mib": 300,
        "n_ctx": 128, "threads": 4, "verbose": True,
    }, api_probe=True, require_streaming=False,
        note="新 TUI 无 pipe 单轮模式：改用 --api-only 起服务，GET /v1/models 必须 200 后退出"),
    SuiteCase("case6", "llama-completion 流式", {
        "engine": "llama-completion", "arena_mode": "custom", "arena_mib": 200,
        "n_predict": 8, "n_ctx": 128, "n_batch": 4, "n_ubatch": 4, "threads": 4,
    }),
    SuiteCase("case7", "错误路径 (模型不存在)", {
        "engine": "diskrun", "arena_mode": "auto",
        "n_predict": 2, "n_ctx": 64, "n_ubatch": 4, "threads": 2,
        "model": r"C:\definitely\missing.gguf",
    }, expect_error=True, require_streaming=False,
        note="必须在 1 秒内以非 0 退出码报错，不能挂起"),
]


def new_run_result(cfg: RunConfig) -> RunResult:
    return RunResult(cfg=cfg)


__all__ = [
    "PROJECT_ROOT", "DEFAULT_MODEL", "BIN_NAMES", "ENGINE_LABELS", "CACHE_DIR",
    "RunConfig", "Metrics", "RunResult", "EngineRunner", "SuiteCase", "SUITE_CASES",
    "find_bin_dir", "candidate_bin_dirs", "find_default_model",
    "build_command", "build_api_probe_command", "build_env", "env_summary",
    "powershell_command", "process_rss_mb", "judge_single", "compare_runs",
    "judge_compare", "strip_ansi", "parse_line",
]

