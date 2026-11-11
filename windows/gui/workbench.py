"""diskinfer Windows 测试工作台 (PySide6)

一个图形化测试台，用来驱动已经编译好的 diskinfer Windows 可执行文件：

    disktui.exe            TUI 分屏测试（能看到逐 token 的 io / cmp 计时）
    diskrun.exe            最小驱动（会打印每个生成 token 的 id，最适合做正确性对比）
    llama-completion.exe   标准 llama.cpp 工具

功能：
  * 「对话」模式：普通聊天界面（消息正常渲染、Markdown 回复），右侧实时显示生成过程——
    当前在算第几层（L12/24）、每个 token 的读盘 io / 计算 cmp 耗时、tok/s、读盘量/换出次数
  * 选择模型 / 引擎 / arena 策略（自动、原生 mmap、自定义 MiB）和其它 LLAMA_DISK_* 选项
  * 实时显示引擎输出（diskrun/llama-completion 的 stdout+stderr，disktui 的干净日志）
  * 解析并展示指标：arena、直读、mlock、张量注册、读盘量、换出、io/cmp 计时、RSS 峰值
  * “同时跑原生基线并对比”：同一 prompt 再用 LLAMA_DISK_STREAM_MB=0 跑一遍，比较贪心 token id
  * 一键测试套件：7 个端到端用例（流式/原生/自动/关 O_DIRECT/TUI/llama-completion/错误路径）
  * 运行历史（可双击查看详情）与 Markdown/JSON 导出

用法：
    python gui/workbench.py                 # 打开工作台（默认「对话」页）
    python gui/workbench.py --demo          # 打开并填入演示数据（用于截图）
    python gui/workbench.py --selftest      # 无界面自检：跑完整套件并输出 JSON
    python gui/workbench.py --chat-selftest # 无界面自检：对话模式（层/速度事件）
    python gui/workbench.py --screenshot out.png [--demo --tab N]

仅依赖 PySide6（见 gui/requirements.txt）。对话模式需要 diskc.exe（build-windows.ps1 会一起编译）。
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

try:
    from PySide6.QtCore import QProcess, Qt, QTimer
    from PySide6.QtGui import QColor, QFont, QGuiApplication, QKeySequence, QPalette, QShortcut
    from PySide6.QtWidgets import (
        QAbstractItemView,
        QApplication,
        QCheckBox,
        QComboBox,
        QDialog,
        QDialogButtonBox,
        QDoubleSpinBox,
        QFileDialog,
        QFormLayout,
        QGridLayout,
        QGroupBox,
        QHBoxLayout,
        QHeaderView,
        QLabel,
        QLineEdit,
        QMainWindow,
        QMessageBox,
        QPlainTextEdit,
        QProgressBar,
        QPushButton,
        QScrollArea,
        QSpinBox,
        QSplitter,
        QTableWidget,
        QTableWidgetItem,
        QTabWidget,
        QVBoxLayout,
        QWidget,
    )
except ImportError as exc:  # pragma: no cover - user environment problem
    import i18n as _i18n

    _i18n.set_lang(_i18n.detect())
    sys.stderr.write(_i18n.tr(
        "PySide6 未安装，无法启动 GUI 工作台。\n"
        "请先安装依赖：\n"
        "    python -m pip install -r gui\\requirements.txt\n"
        "\n原始错误: {0}\n").format(exc))
    raise SystemExit(2)

sys.path.insert(0, str(Path(__file__).resolve().parent))

import runner as R  # noqa: E402
import theme as T  # noqa: E402
from i18n import tr, detect as detect_lang, set_lang, normalize_tag, current as current_lang  # noqa: E402
from chatpanel import ChatPanel  # noqa: E402

APP_TITLE = "diskinfer Windows 测试工作台"
ENGINE_KEYS = ["diskrun", "disktui", "llama-completion"]

PRESETS = [
    ("快速冒烟 · 自动 arena, diskrun 8 token", {
        "engine": "diskrun", "arena_mode": "auto", "n_predict": 8, "n_ctx": 128,
        "n_ubatch": 4, "threads": 4, "compare_native": True, "raw": True,
    }),
    ("小 arena 流式 · 200 MiB, diskrun", {
        "engine": "diskrun", "arena_mode": "custom", "arena_mib": 200,
        "n_predict": 8, "n_ctx": 128, "n_ubatch": 4, "threads": 4,
        "compare_native": True, "raw": True,
    }),
    ("原生基线 · LLAMA_DISK_STREAM_MB=0", {
        "engine": "diskrun", "arena_mode": "native", "n_predict": 8, "n_ctx": 128,
        "n_ubatch": 4, "threads": 4, "compare_native": False, "raw": True,
    }),
    ("TUI 单轮 · disktui, 300 MiB, 逐 token io/cmp", {
        "engine": "disktui", "arena_mode": "custom", "arena_mib": 300,
        "n_predict": 8, "n_ctx": 256, "n_ubatch": 4, "threads": 4,
        "compare_native": False, "raw": True,
    }),
    ("llama-completion 流式 · 200 MiB", {
        "engine": "llama-completion", "arena_mode": "custom", "arena_mib": 200,
        "n_predict": 8, "n_ctx": 256, "n_batch": 4, "n_ubatch": 4, "threads": 4,
        "compare_native": False, "raw": True,
    }),
    ("自定义", {}),
]

MONO_FAMILIES = ["Cascadia Mono", "Consolas", "Courier New", "monospace"]


def mono_font(size: int = 9) -> QFont:
    f = QFont()
    f.setFamilies(MONO_FAMILIES)
    f.setStyleHint(QFont.StyleHint.Monospace)
    f.setPointSize(size)
    return f


def fmt_seconds(v: float | None) -> str:
    if v is None:
        return "—"
    if v >= 60:
        return f"{v / 60:.1f} min"
    return f"{v:.2f} s"


def fmt_ms(v: float | None) -> str:
    if v is None:
        return "—"
    return f"{v:.1f} ms" if v < 1000 else f"{v / 1000:.2f} s"


# --------------------------------------------------------------------------- detail dialog

class TextDialog(QDialog):
    def __init__(self, title: str, text: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(820, 600)
        lay = QVBoxLayout(self)
        edit = QPlainTextEdit()
        edit.setReadOnly(True)
        edit.setFont(mono_font(9))
        edit.setPlainText(text)
        lay.addWidget(edit)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self.accept)
        lay.addWidget(buttons)


# --------------------------------------------------------------------------- main window

class MainWindow(QMainWindow):
    def __init__(self, bin_dir: str | None = None, model: str | None = None):
        super().__init__()
        self.setWindowTitle(tr(APP_TITLE))
        self.resize(1400, 900)
        # follow the Windows light/dark scheme (Qt already themes the standard widgets,
        # every hard-coded color below is taken from this theme object)
        self.t = T.current()

        self.runner: R.EngineRunner | None = None
        self._baseline_pending = False
        self._main_result: R.RunResult | None = None
        self._baseline_result: R.RunResult | None = None
        self._current_compare: dict | None = None
        self.last_result: R.RunResult | None = None
        self.history: list[R.RunResult] = []
        self._run_t0 = 0.0
        self.session_verdict = ""
        self.suite_finished = False

        # suite state
        self._suite_active = False
        self._suite_cancel = False
        self._suite_cancelled = False
        self._suite_cases: list[R.SuiteCase] = []
        self._suite_idx = 0
        self._suite_results: list[dict] = []
        self._suite_case: R.SuiteCase | None = None
        self._suite_main: R.RunResult | None = None
        self._suite_phase = "main"
        self._suite_api: dict | None = None

        self._build_ui(bin_dir, model)
        self._apply_preset(0)
        if not self.w["model"].text().strip():
            self.status_state.setText(tr('未找到 .gguf 模型：请用 --model 指定'))

    # -- ui construction ---------------------------------------------------
    def _build_ui(self, bin_dir: str | None, model: str | None) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        splitter = QSplitter(Qt.Orientation.Horizontal)
        root.addWidget(splitter)

        splitter.addWidget(self._build_left_panel(bin_dir, model))
        splitter.addWidget(self._build_right_panel())
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([400, 1000])

        # status bar
        self.status_state = QLabel(tr('就绪'))
        self.status_elapsed = QLabel("—")
        self.status_rss = QLabel("RSS —")
        self.status_exe = QLabel("")
        for w in (self.status_state, self.status_elapsed, self.status_rss):
            self.statusBar().addWidget(w)
            self.statusBar().addPermanentWidget(QLabel("  "))
        self.statusBar().addPermanentWidget(self.status_exe)
        self.statusBar().addPermanentWidget(QLabel(tr('语言: {0}').format(current_lang())))

        # shortcuts
        sc_run = QShortcut(QKeySequence("F5"), self)
        sc_run.activated.connect(self._run)
        sc_stop = QShortcut(QKeySequence("Shift+F5"), self)
        sc_stop.activated.connect(self._stop)

    def _build_left_panel(self, bin_dir: str | None, model: str | None) -> QWidget:
        # the parameter groups scroll, but the run controls stay pinned at the bottom so the
        # primary action is always reachable on small screens
        panel = QWidget()
        panel.setMinimumWidth(380)
        panel.setMaximumWidth(560)
        outer = QVBoxLayout(panel)
        outer.setContentsMargins(8, 8, 8, 8)
        outer.setSpacing(6)

        self.w: dict[str, QWidget] = {}
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)

        # ---- model / engine
        gb = QGroupBox(tr('模型与引擎'))
        form = QFormLayout(gb)

        row = QHBoxLayout()
        initial_model = model or R.find_default_model()
        self.w["model"] = QLineEdit(initial_model)
        self.w["model"].setPlaceholderText(tr('未找到 .gguf 模型：请用 --model 指定'))
        browse = QPushButton("…")
        browse.setFixedWidth(28)
        browse.clicked.connect(self._browse_model)
        row.addWidget(self.w["model"], 1)
        row.addWidget(browse)
        form.addRow(tr('模型 (.gguf)'), row)

        row2 = QHBoxLayout()
        self.w["bin_dir"] = QLineEdit(bin_dir or "")
        browse2 = QPushButton("…")
        browse2.setFixedWidth(28)
        browse2.clicked.connect(self._browse_bin_dir)
        row2.addWidget(self.w["bin_dir"], 1)
        row2.addWidget(browse2)
        form.addRow(tr('可执行文件目录'), row2)

        self.w["engine"] = QComboBox()
        for key in ENGINE_KEYS:
            self.w["engine"].addItem(tr(R.ENGINE_LABELS[key]), key)
        form.addRow(tr('引擎'), self.w["engine"])

        self.w["preset"] = QComboBox()
        for name, _ in PRESETS:
            self.w["preset"].addItem(tr(name))
        self.w["preset"].currentIndexChanged.connect(self._apply_preset)
        form.addRow(tr('预设'), self.w["preset"])
        lay.addWidget(gb)

        # ---- prompt
        gb = QGroupBox("Prompt")
        form = QFormLayout(gb)
        self.w["prompt"] = QLineEdit("The capital of France is")
        form.addRow("prompt", self.w["prompt"])
        self.w["mode"] = QComboBox()
        self.w["mode"].addItem(tr('raw 裸补全'), True)
        self.w["mode"].addItem(tr('chat 模板'), False)
        form.addRow(tr('模式'), self.w["mode"])
        self.w["sysmsg"] = QLineEdit()
        self.w["sysmsg"].setPlaceholderText(tr('仅 chat 模式使用'))
        form.addRow("system", self.w["sysmsg"])
        lay.addWidget(gb)

        # ---- generation params
        gb = QGroupBox(tr('生成参数'))
        grid = QGridLayout(gb)
        specs = [
            ("n_predict", "n_predict", 1, 4096, 8),
            ("n_ctx", "n_ctx", 16, 32768, 128),
            ("n_batch", "n_batch", 1, 512, 4),
            ("n_ubatch", "n_ubatch", 1, 512, 4),
            ("threads", "threads", 1, 64, 4),
        ]
        for i, (key, label, lo, hi, val) in enumerate(specs):
            sb = QSpinBox()
            sb.setRange(lo, hi)
            sb.setValue(val)
            self.w[key] = sb
            grid.addWidget(QLabel(label), i // 2, (i % 2) * 2)
            grid.addWidget(sb, i // 2, (i % 2) * 2 + 1)
        self.w["temp"] = QDoubleSpinBox()
        self.w["temp"].setRange(0.0, 4.0)
        self.w["temp"].setDecimals(2)
        self.w["temp"].setSingleStep(0.05)
        self.w["temp"].setValue(0.0)
        self.w["top_k"] = QSpinBox()
        self.w["top_k"].setRange(0, 500)
        self.w["top_k"].setValue(20)
        self.w["top_p"] = QDoubleSpinBox()
        self.w["top_p"].setRange(0.0, 1.0)
        self.w["top_p"].setDecimals(2)
        self.w["top_p"].setSingleStep(0.05)
        self.w["top_p"].setValue(0.95)
        r = (len(specs) + 1) // 2
        grid.addWidget(QLabel("temp"), r, 0)
        grid.addWidget(self.w["temp"], r, 1)
        grid.addWidget(QLabel("top_k"), r, 2)
        grid.addWidget(self.w["top_k"], r, 3)
        r += 1
        grid.addWidget(QLabel("top_p"), r, 0)
        grid.addWidget(self.w["top_p"], r, 1)
        lay.addWidget(gb)

        # ---- disk engine options
        gb = QGroupBox(tr('磁盘流式选项'))
        form = QFormLayout(gb)
        self.w["arena_mode"] = QComboBox()
        self.w["arena_mode"].addItem(tr('自动 (内存/8, 至少 176 MiB)'), "auto")
        self.w["arena_mode"].addItem(tr('原生 (LLAMA_DISK_STREAM_MB=0)'), "native")
        self.w["arena_mode"].addItem(tr('自定义 MiB'), "custom")
        self.w["arena_mode"].currentIndexChanged.connect(lambda _i: self._arena_mode_changed())
        form.addRow("arena", self.w["arena_mode"])
        self.w["arena_mib"] = QSpinBox()
        self.w["arena_mib"].setRange(32, 16384)
        self.w["arena_mib"].setValue(200)
        self.w["arena_mib"].setSuffix(" MiB")
        form.addRow(tr('自定义大小'), self.w["arena_mib"])
        self.w["odirect"] = QCheckBox(tr('O_DIRECT / 无缓冲读'))
        self.w["odirect"].setChecked(True)
        form.addRow("", self.w["odirect"])
        self.w["mlock"] = QCheckBox("mlock / VirtualLock")
        form.addRow("", self.w["mlock"])
        self.w["prefetch"] = QCheckBox(tr('预读线程 (PREFETCH)'))
        form.addRow("", self.w["prefetch"])
        self.w["lookahead"] = QSpinBox()
        self.w["lookahead"].setRange(1, 256)
        self.w["lookahead"].setValue(16)
        form.addRow("lookahead", self.w["lookahead"])
        self.w["debug"] = QCheckBox(tr('DEBUG 看门狗'))
        form.addRow("", self.w["debug"])
        self.w["verbose"] = QCheckBox(tr('VERBOSE 计数'))
        form.addRow("", self.w["verbose"])
        self.w["extra_args"] = QLineEdit()
        self.w["extra_args"].setPlaceholderText(tr('附加命令行参数 (原样传给引擎)'))
        form.addRow(tr('附加参数'), self.w["extra_args"])
        lay.addWidget(gb)

        # ---- run (pinned footer, built by _build_run_group)
        lay.addStretch(1)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(w)
        outer.addWidget(scroll, 1)
        outer.addWidget(self._build_run_group())

        info = QLabel(
            tr('提示：正确性对比用 diskrun（打印 token id）；逐 token io/cmp 用 disktui；停止 = terminate，2 秒后强杀'))
        info.setWordWrap(True)
        info.setStyleSheet(f"color: {self.t.muted};")
        outer.addWidget(info)
        return panel

    def _build_run_group(self) -> QGroupBox:
        gb = QGroupBox(tr('运行'))
        v = QVBoxLayout(gb)
        self.w["compare_native"] = QCheckBox(tr('同时跑原生基线并对比 (native + -no-extra-bufts, 贪心 token id)'))
        self.w["compare_native"].setChecked(True)
        v.addWidget(self.w["compare_native"])
        self.w["save_log"] = QCheckBox(tr('保存每次运行的日志 (gui/runs/)'))
        self.w["save_log"].setChecked(True)
        v.addWidget(self.w["save_log"])

        row = QHBoxLayout()
        self.btn_run = QPushButton(tr('▶  运行 (F5)'))
        self.btn_run.setMinimumHeight(34)
        self.btn_run.clicked.connect(self._run)
        self.btn_stop = QPushButton(tr('■ 停止'))
        self.btn_stop.setMinimumHeight(34)
        self.btn_stop.setEnabled(False)
        self.btn_stop.clicked.connect(self._stop)
        row.addWidget(self.btn_run, 2)
        row.addWidget(self.btn_stop, 1)
        v.addLayout(row)

        row = QHBoxLayout()
        btn_cmd = QPushButton(tr('复制命令'))
        btn_cmd.clicked.connect(self._copy_command)
        btn_logs = QPushButton(tr('打开日志目录'))
        btn_logs.clicked.connect(self._open_logs)
        btn_clean = QPushButton(tr('清理日志'))
        btn_clean.clicked.connect(self._clean_runs)
        row.addWidget(btn_cmd)
        row.addWidget(btn_logs)
        row.addWidget(btn_clean)
        v.addLayout(row)
        return gb

    def _build_right_panel(self) -> QWidget:
        tabs = QTabWidget()
        self.tabs = tabs
        # 对话 is the everyday mode: normal chat rendering + live engine details
        self.chat_panel = ChatPanel(self._collect_cfg)
        tabs.addTab(self.chat_panel, tr('对话'))
        tabs.addTab(self._build_log_tab(), tr('实时输出'))
        self.metrics_tab = self._build_metrics_tab()
        tabs.addTab(self.metrics_tab, tr('指标 / 结果'))
        self.suite_tab = self._build_suite_tab()
        tabs.addTab(self.suite_tab, tr('测试套件'))
        tabs.addTab(self._build_history_tab(), tr('运行历史'))
        return tabs

    # -- tab: log ----------------------------------------------------------
    def _build_log_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(6, 6, 6, 6)

        row = QHBoxLayout()
        self.log_autoscroll = QCheckBox(tr('自动滚动'))
        self.log_autoscroll.setChecked(True)
        self.log_show_raw = QCheckBox(tr('显示 disktui 原始 stdout (ANSI)'))
        btn_clear = QPushButton(tr('清空'))
        btn_clear.clicked.connect(lambda: self.log.clear())
        self.log_count = QLabel(tr('0 行'))
        row.addWidget(self.log_autoscroll)
        row.addWidget(self.log_show_raw)
        row.addStretch(1)
        row.addWidget(self.log_count)
        row.addWidget(btn_clear)
        lay.addLayout(row)

        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(mono_font(9))
        self.log.setMaximumBlockCount(20000)
        self.log.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        lay.addWidget(self.log, 1)
        return w

    # -- tab: metrics ------------------------------------------------------
    def _build_metrics_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(6, 6, 6, 6)

        self.verdict_label = QLabel(tr('尚未运行'))
        self.verdict_label.setStyleSheet(
            "font-size: 15px; font-weight: bold; padding: 6px; border-radius: 4px;"
            f"background: {self.t.neutral_bg}; color: {self.t.neutral_fg};")
        lay.addWidget(self.verdict_label)

        splitter = QSplitter(Qt.Orientation.Vertical)

        self.summary = QTableWidget(0, 2)
        self.summary.setHorizontalHeaderLabels([tr('指标'), tr('值')])
        self.summary.verticalHeader().setVisible(False)
        self.summary.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.summary.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.summary.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.summary.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        splitter.addWidget(self.summary)

        self.token_table = QTableWidget(0, 0)
        self.token_table.verticalHeader().setVisible(False)
        self.token_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.token_table.setAlternatingRowColors(True)
        splitter.addWidget(self.token_table)

        self.compare_view = QPlainTextEdit()
        self.compare_view.setReadOnly(True)
        self.compare_view.setFont(mono_font(9))
        self.compare_view.setMaximumHeight(160)
        self.compare_view.setPlaceholderText(tr('勾选“同时跑原生基线并对比”后，这里会显示流式 vs native + -no-extra-bufts 的逐 token 对比'))
        splitter.addWidget(self.compare_view)

        splitter.setSizes([300, 260, 140])
        lay.addWidget(splitter, 1)
        return w

    # -- tab: suite --------------------------------------------------------
    def _build_suite_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(6, 6, 6, 6)

        hint = QLabel(
            tr('一键跑 7 个端到端用例（使用左侧的模型 / prompt；arena 等参数按用例固定）：\n流式小 arena → 原生基线 → 自动 arena → 关 O_DIRECT → disktui 单轮 → llama-completion → 错误路径。\ncase1 会自动再跑一次原生基线并逐 token 对比，不一致判 FAIL。'))
        hint.setWordWrap(True)
        hint.setStyleSheet(f"color: {self.t.muted};")
        lay.addWidget(hint)

        row = QHBoxLayout()
        self.btn_suite = QPushButton(tr('▶  开始测试套件'))
        self.btn_suite.setMinimumHeight(32)
        self.btn_suite.clicked.connect(self._start_suite)
        self.btn_suite_stop = QPushButton(tr('■ 停止'))
        self.btn_suite_stop.setEnabled(False)
        self.btn_suite_stop.clicked.connect(self._stop_suite)
        btn_md = QPushButton(tr('导出 Markdown'))
        btn_md.clicked.connect(self._export_suite_markdown)
        btn_json = QPushButton(tr('导出 JSON'))
        btn_json.clicked.connect(self._export_suite_json)
        row.addWidget(self.btn_suite, 2)
        row.addWidget(self.btn_suite_stop, 1)
        row.addStretch(1)
        row.addWidget(btn_md)
        row.addWidget(btn_json)
        lay.addLayout(row)

        self.suite_progress = QProgressBar()
        self.suite_progress.setFormat("%v / %m")
        self.suite_progress.setValue(0)
        lay.addWidget(self.suite_progress)

        self.suite_table = QTableWidget(0, 9)
        self.suite_table.setHorizontalHeaderLabels(
            ["#", tr('用例'), tr('引擎'), tr('环境'), tr('退出码'), "tokens", "s/token", "RSS MiB", tr('判定')])
        self.suite_table.verticalHeader().setVisible(False)
        self.suite_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.suite_table.setAlternatingRowColors(True)
        self.suite_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        for c in (0, 2, 3, 4, 5, 6, 7, 8):
            self.suite_table.horizontalHeader().setSectionResizeMode(
                c, QHeaderView.ResizeMode.ResizeToContents)
        lay.addWidget(self.suite_table, 1)

        self.suite_notes = QPlainTextEdit()
        self.suite_notes.setReadOnly(True)
        self.suite_notes.setFont(mono_font(9))
        self.suite_notes.setMaximumHeight(150)
        lay.addWidget(self.suite_notes)
        return w

    # -- tab: history ------------------------------------------------------
    def _build_history_tab(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(6, 6, 6, 6)

        row = QHBoxLayout()
        btn_clear = QPushButton(tr('清空历史'))
        btn_clear.clicked.connect(self._clear_history)
        btn_export = QPushButton(tr('导出 JSON'))
        btn_export.clicked.connect(self._export_history)
        btn_detail = QPushButton(tr('查看详情'))
        btn_detail.clicked.connect(self._show_history_detail)
        row.addWidget(btn_detail)
        row.addWidget(btn_export)
        row.addStretch(1)
        row.addWidget(btn_clear)
        lay.addLayout(row)

        self.history_table = QTableWidget(0, 9)
        self.history_table.setHorizontalHeaderLabels(
            [tr('时间'), tr('引擎'), "arena", tr('退出码'), "tokens", "s/token", "RSS MiB", tr('耗时'), tr('判定')])
        self.history_table.verticalHeader().setVisible(False)
        self.history_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.history_table.setAlternatingRowColors(True)
        self.history_table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.history_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeMode.Stretch)
        for c in range(1, 9):
            self.history_table.horizontalHeader().setSectionResizeMode(
                c, QHeaderView.ResizeMode.ResizeToContents)
        self.history_table.doubleClicked.connect(lambda _i: self._show_history_detail())
        lay.addWidget(self.history_table, 1)

        self.history_info = QLabel("")
        self.history_info.setStyleSheet(f"color: {self.t.muted};")
        lay.addWidget(self.history_info)
        return w

    # -- helpers -----------------------------------------------------------
    def _set_verdict(self, verdict: str, detail: str = "") -> None:
        colors = {
            "PASS": (self.t.pass_bg, self.t.pass_fg),
            "WARN": (self.t.warn_bg, self.t.warn_fg),
            "FAIL": (self.t.fail_bg, self.t.fail_fg),
            "RUN": (self.t.run_bg, self.t.run_fg),
            tr('就绪'): (self.t.neutral_bg, self.t.neutral_fg),
        }
        bg, fg = colors.get(verdict, colors[tr('就绪')])
        self.verdict_label.setText(f"{verdict}   {detail}".strip())
        self.verdict_label.setStyleSheet(
            f"font-size: 15px; font-weight: bold; padding: 6px; border-radius: 4px;"
            f"background: {bg}; color: {fg};")

    def _verdict_item(self, text: str, verdict: str) -> QTableWidgetItem:
        """Table cell with theme-aware verdict colors (readable in light and dark mode)."""
        item = QTableWidgetItem(text)
        bg, fg = T.verdict_colors(self.t, verdict)
        item.setBackground(QColor(bg))
        item.setForeground(QColor(fg))
        return item

    def _append_log(self, channel: str, text: str) -> None:
        if channel == "out" and self._cfg_engine() == "disktui" and not self.log_show_raw.isChecked():
            return
        self.log.appendPlainText(text)
        n = self.log.blockCount()
        self.log_count.setText(tr('{0} 行').format(n))
        if self.log_autoscroll.isChecked():
            self.log.verticalScrollBar().setValue(self.log.verticalScrollBar().maximum())

    def _cfg_engine(self) -> str:
        return self.w["engine"].currentData()

    def _browse_model(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, tr('选择 GGUF 模型'), str(Path(self.w["model"].text()).parent),
                                             tr('GGUF 模型 (*.gguf);;所有文件 (*)'))
        if path:
            self.w["model"].setText(path)

    def _browse_bin_dir(self) -> None:
        path = QFileDialog.getExistingDirectory(self, tr('选择可执行文件目录'), self.w["bin_dir"].text() or str(R.PROJECT_ROOT))
        if path:
            self.w["bin_dir"].setText(path)

    def _arena_mode_changed(self) -> None:
        mode = self.w["arena_mode"].currentData()
        self.w["arena_mib"].setEnabled(mode == "custom")

    def _apply_preset(self, idx: int) -> None:
        name, overrides = PRESETS[idx] if 0 <= idx < len(PRESETS) else PRESETS[-1]
        if not overrides:
            self._arena_mode_changed()
            return
        if "engine" in overrides:
            i = self.w["engine"].findData(overrides["engine"])
            if i >= 0:
                self.w["engine"].setCurrentIndex(i)
        mapping = {
            "arena_mode": ("arena_mode", "data"),
            "arena_mib": ("arena_mib", "value"),
            "n_predict": ("n_predict", "value"),
            "n_ctx": ("n_ctx", "value"),
            "n_batch": ("n_batch", "value"),
            "n_ubatch": ("n_ubatch", "value"),
            "threads": ("threads", "value"),
            "temp": ("temp", "value"),
            "top_k": ("top_k", "value"),
            "top_p": ("top_p", "value"),
            "compare_native": ("compare_native", "checked"),
            "raw": ("mode", "raw"),
        }
        for key, val in overrides.items():
            if key not in mapping:
                continue
            widget_key, kind = mapping[key]
            widget = self.w[widget_key]
            if kind == "data":
                i = widget.findData(val)
                if i >= 0:
                    widget.setCurrentIndex(i)
            elif kind == "value":
                widget.setValue(val)
            elif kind == "checked":
                widget.setChecked(bool(val))
            elif kind == "raw":
                widget.setCurrentIndex(0 if val else 1)
        self._arena_mode_changed()

    def _collect_cfg(self) -> R.RunConfig:
        bin_dir = self.w["bin_dir"].text().strip() or (str(R.find_bin_dir() or ""))
        model = self.w["model"].text().strip()
        return R.RunConfig(
            engine=self._cfg_engine(),
            model=model,
            bin_dir=bin_dir,
            prompt=self.w["prompt"].text(),
            raw=bool(self.w["mode"].currentData()),
            sysmsg=self.w["sysmsg"].text(),
            n_predict=self.w["n_predict"].value(),
            n_ctx=self.w["n_ctx"].value(),
            n_batch=self.w["n_batch"].value(),
            n_ubatch=self.w["n_ubatch"].value(),
            threads=self.w["threads"].value(),
            temp=self.w["temp"].value(),
            top_k=self.w["top_k"].value(),
            top_p=self.w["top_p"].value(),
            extra_args=self.w["extra_args"].text(),
            arena_mode=self.w["arena_mode"].currentData(),
            arena_mib=self.w["arena_mib"].value(),
            odirect=self.w["odirect"].isChecked(),
            mlock=self.w["mlock"].isChecked(),
            prefetch=self.w["prefetch"].isChecked(),
            lookahead=self.w["lookahead"].value(),
            debug=self.w["debug"].isChecked(),
            verbose=self.w["verbose"].isChecked(),
            compare_native=self.w["compare_native"].isChecked(),
            save_log=self.w["save_log"].isChecked(),
        )

    # -- run control -------------------------------------------------------
    def _set_busy(self, busy: bool) -> None:
        self.btn_run.setEnabled(not busy)
        self.btn_stop.setEnabled(busy)
        self.btn_suite.setEnabled(not busy)

    def _run(self) -> None:
        if self.runner is not None and self.runner.is_running():
            return
        cfg = self._collect_cfg()
        if not cfg.model:
            self.status_state.setText(tr('未找到 .gguf 模型：请用 --model 指定'))
            self._append_log("err", tr('未找到 .gguf 模型：请用 --model 指定'))
            return
        if not cfg.bin_dir or not Path(cfg.bin_dir).exists():
            QMessageBox.warning(self, tr(APP_TITLE),
                                tr('找不到可执行文件目录：{0}\n\n请先运行 build\\build-windows.ps1').format(cfg.bin_dir))
            return
        exe = cfg.exe_path()
        if not exe.exists():
            QMessageBox.warning(self, tr(APP_TITLE), tr('引擎不存在：{0}').format(exe))
            return
        if not Path(cfg.model).exists():
            QMessageBox.warning(self, tr(APP_TITLE), tr('模型不存在：{0}').format(cfg.model))
            return

        self.log.clear()
        self.compare_view.clear()
        self._main_result = None
        self._baseline_result = None
        self._current_compare = None
        self.token_table.setRowCount(0)
        self._set_verdict("RUN", tr('运行中…'))
        self._set_busy(True)
        self.status_state.setText(tr('运行中'))
        self.status_exe.setText(f"{cfg.engine}  |  {exe.name}  |  {R.env_summary(cfg)}")
        self._append_log("log", f"$ {exe.name} {R.build_command(cfg)}")
        self._append_log("log", f"# env: {R.env_summary(cfg)}")

        self._start_engine(cfg, self._on_main_finished)

    def _start_engine(self, cfg: R.RunConfig, on_finished) -> None:
        runner = R.EngineRunner(cfg, self)
        runner.output.connect(self._append_log)
        runner.snapshot.connect(self._on_snapshot)
        runner.error.connect(self._on_engine_error)
        runner.finished.connect(on_finished)
        self.runner = self._last_runner = runner
        self._run_t0 = time.monotonic()
        runner.start()

    def _on_snapshot(self, metrics: R.Metrics) -> None:
        # cheap live summary refresh
        if self.runner is None:
            return
        elapsed = (time.monotonic() - self._run_t0) if self._run_t0 else 0.0
        rss = metrics.rss_peak_mib
        self.status_elapsed.setText(tr('耗时 {0:.1f} s').format(elapsed))
        self.status_rss.setText(tr('RSS 峰值 {0:.0f} MiB').format(rss) if rss else "RSS —")
        self._fill_summary(metrics, live=True)

    def _on_engine_error(self, msg: str) -> None:
        self._append_log("err", msg)
        self._set_verdict("FAIL", msg)
        self._set_busy(False)
        self.status_state.setText(tr('失败'))
        QMessageBox.warning(self, tr(APP_TITLE), msg)

    def _on_main_finished(self, result: R.RunResult) -> None:
        self._main_result = result
        self.last_result = result
        self._append_log("log", tr('# 退出码 {0}，耗时 {1:.2f} s，判定 {2}').format(result.exit_code, result.wall_s, result.verdict))
        for note in result.notes:
            self._append_log("log", f"# {note}")

        cfg = result.cfg
        need_compare = cfg.compare_native and cfg.arena_mode != "native"
        if need_compare and result.exit_code == 0:
            base_cfg = cfg.native_baseline()
            self._append_log("log", tr('# 开始原生基线对比运行 (LLAMA_DISK_STREAM_MB=0 + -no-extra-bufts) …'))
            self.status_state.setText(tr('运行原生基线…'))
            self._start_engine(base_cfg, self._on_baseline_finished)
            return

        self._finish_run(result, None)

    def _on_baseline_finished(self, base: R.RunResult) -> None:
        self._baseline_result = base
        comparison = R.compare_runs(self._main_result, base) if self._main_result else None
        self._current_compare = comparison
        self._finish_run(self._main_result, comparison)

    def _finish_run(self, result: R.RunResult, comparison: dict | None) -> None:
        result.compare = comparison
        verdict = result.verdict
        notes = list(result.notes)
        if comparison is not None:
            cverdict, cnotes = R.judge_compare(comparison)
            notes += cnotes
            if cverdict == "FAIL":
                verdict = "FAIL"
            elif verdict == "PASS" and cverdict == "PASS":
                verdict = "PASS"
            elif verdict == "PASS":
                verdict = "WARN"

        self._set_verdict(verdict, tr('退出码 {0}，{1:.1f} s').format(result.exit_code, result.wall_s))
        self.session_verdict = verdict
        self._fill_metrics_tab(result, comparison)
        self._add_history(result, verdict, comparison)
        self._set_busy(False)
        self.status_state.setText(tr('完成'))
        self._append_log("log", tr('# 完成：{0}').format(verdict))

    def _stop(self) -> None:
        if self.runner is not None:
            self.runner.stop()
            self._append_log("log", tr('# 已请求停止 (terminate，2 秒后强制结束)'))

    # -- metrics tab fill --------------------------------------------------
    SUMMARY_ROWS = [
        ("判定", "verdict"),
        ("退出码", "exit"),
        ("总耗时", "wall"),
        ("模型加载", "load"),
        ("arena", "arena"),
        ("direct io / mlock / prefetch", "ioflags"),
        ("张量注册", "registered"),
        ("流式读取", "read"),
        ("换出次数", "evictions"),
        ("prompt tokens", "prompt"),
        ("prefill", "prefill"),
        ("生成 tokens", "tokens"),
        ("平均 s/token", "spt"),
        ("io 合计 / cmp 合计", "iocmp"),
        ("RSS 峰值", "rss"),
        ("生成文本", "text"),
    ]

    def _summary_row(self, key: str) -> int:
        return [k for _label, k in self.SUMMARY_ROWS].index(key)

    def _ensure_summary_rows(self) -> None:
        if self.summary.rowCount() == len(self.SUMMARY_ROWS):
            return
        self.summary.setRowCount(len(self.SUMMARY_ROWS))
        for i, (label, _key) in enumerate(self.SUMMARY_ROWS):
            item = QTableWidgetItem(tr(label))
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            self.summary.setItem(i, 0, item)
            self.summary.setItem(i, 1, QTableWidgetItem("—"))

    def _fill_summary(self, m: R.Metrics, live: bool = False) -> None:
        self._ensure_summary_rows()
        elapsed = (time.monotonic() - self._run_t0) if (live and self._run_t0) else 0.0
        values = {
            "verdict": tr('运行中…') if live else self._summary_verdict(),
            "exit": tr('运行中…') if live else "—",
            "wall": f"{elapsed:.1f} s" if live else "—",
            "load": fmt_ms(m.load_time_ms) if m.load_time_ms is not None else fmt_seconds(m.model_load_s),
            "arena": f"{m.arena_mib} MiB ({m.arena_note})" if m.arena_mib is not None else "—",
            "ioflags": ("—" if m.direct_io is None else
                        f"direct={m.direct_io} mlock={m.mlock} prefetch={m.prefetch}"),
            "registered": (tr('{0} 个 / {1} MiB，最大 {2} {3} MiB').format(m.registered_tensors, m.registered_mib, m.largest_tensor, m.largest_mib)) if m.registered_tensors is not None else "—",
            "read": (tr('{0} MiB，{1} 次加载').format(m.read_mib_total, m.loads)
                     if m.read_mib_total is not None else "—"),
            "evictions": f"{m.evictions}" if m.evictions is not None else "—",
            "prompt": f"{m.prompt_tokens}" if m.prompt_tokens is not None else "—",
            "prefill": self._fmt_prefill(m),
            "tokens": f"{m.generated_tokens}" if m.generated_tokens is not None else "—",
            "spt": f"{m.s_per_token:.3f} s" if m.s_per_token is not None else "—",
            "iocmp": (f"{m.io_total_s:.2f} s / {m.cmp_total_s:.2f} s"
                      if (m.io_total_s or m.cmp_total_s) else "—"),
            "rss": (f"{m.rss_peak_mib:.0f} MiB" if m.rss_peak_mib else
                    (tr('{0} MiB (引擎报告)').format(m.rss_reported_mib) if m.rss_reported_mib is not None else "—")),
            "text": (m.generated_text[:120] if m.generated_text else "—"),
        }
        for i, (_label, key) in enumerate(self.SUMMARY_ROWS):
            self.summary.setItem(i, 1, QTableWidgetItem(values.get(key, "—")))
        self.summary.resizeRowsToContents()

    def _summary_verdict(self) -> str:
        return getattr(self, "session_verdict", "—")

    @staticmethod
    def _fmt_prefill(m: R.Metrics) -> str:
        if m.prefill_s is not None:
            return fmt_seconds(m.prefill_s)
        if m.prefill_io_s or m.prefill_cmp_s:
            return f"{m.prefill_io_s:.2f} s io + {m.prefill_cmp_s:.2f} s cmp"
        if m.prompt_eval_ms is not None:
            return fmt_ms(m.prompt_eval_ms)
        return "—"

    def _fill_metrics_tab(self, result: R.RunResult, comparison: dict | None) -> None:
        m = result.metrics
        self._fill_summary(m, live=False)
        # verdict row shows the final one
        self.summary.setItem(self._summary_row("verdict"), 1,
                             QTableWidgetItem(getattr(self, "session_verdict", result.verdict)))
        self.summary.setItem(self._summary_row("exit"), 1,
                             QTableWidgetItem(str(result.exit_code)))
        self.summary.setItem(self._summary_row("wall"), 1,
                             QTableWidgetItem(fmt_seconds(result.wall_s)))
        self._fill_token_table(m)
        if comparison is not None:
            def fmt_t(text: str) -> str:
                return (text or "").replace("\r", "").replace("\n", " ↵ ")

            lines = [
                tr('对比模式: {0}').format(comparison['mode']),
                tr('流式:  {0!r}').format(fmt_t(comparison.get('text_a'))),
                tr('原生:  {0!r}').format(fmt_t(comparison.get('text_b'))),
            ]
            if comparison.get("ids_a"):
                lines.append(f"id A: {comparison['ids_a']}")
                lines.append(f"id B: {comparison['ids_b']}")
                lines.append(tr('id 一致: {0}').format(tr('是 ✅') if comparison.get('same_ids') else tr('否 ❌')))
            lines.append(tr('文本一致: {0}').format(tr('是 ✅') if comparison.get('same_text') else tr('否 ❌')))
            lines.append(tr('判定: {0}').format(tr('一致 ✅') if comparison.get('match') else tr('不一致 ❌')))
            self.compare_view.setPlainText("\n".join(lines))
        elif result.cfg.compare_native:
            self.compare_view.setPlainText(tr('对比未执行（主运行失败或无原生基线）'))

    def _fill_token_table(self, m: R.Metrics) -> None:
        rows = m.token_rows
        if not rows:
            self.token_table.setRowCount(0)
            self.token_table.setColumnCount(0)
            return
        keys = [k for k in rows[0].keys()]
        tui_style = "cmp_s" in keys
        headers = {
            "n": "#", "id": "token id", "piece": "token", "io_s": "io s" if tui_style else "s/token",
            "cmp_s": "cmp s", "tot_s": "tot s", "rss_mib": "RSS MiB", "clock": tr('时刻'),
            "batch": "batch", "elapsed": tr('时刻'),
        }
        self.token_table.setColumnCount(len(keys))
        self.token_table.setHorizontalHeaderLabels([headers.get(k, k) for k in keys])
        self.token_table.setRowCount(len(rows))
        for r, row in enumerate(rows):
            for c, k in enumerate(keys):
                val = row.get(k)
                item = QTableWidgetItem("—" if val is None else str(val))
                if k in ("io_s", "cmp_s"):
                    item.setBackground(QColor(self.t.table_hl))
                    item.setForeground(self.token_table.palette().color(QPalette.ColorRole.Text))
                self.token_table.setItem(r, c, item)
        self.token_table.resizeColumnsToContents()
        self.token_table.horizontalHeader().setStretchLastSection(True)

    # -- history -----------------------------------------------------------
    def _add_history(self, result: R.RunResult, verdict: str, comparison: dict | None) -> None:
        self.history.append(result)
        row = self.history_table.rowCount()
        self.history_table.insertRow(row)
        m = result.metrics
        arena = ("native" if result.cfg.arena_mode == "native"
                 else ("auto" if result.cfg.arena_mode == "auto" else f"{result.cfg.arena_mib}"))
        cells = [
            __import__("datetime").datetime.now().strftime("%H:%M:%S"),
            result.cfg.engine,
            arena,
            str(result.exit_code),
            str(m.generated_tokens if m.generated_tokens is not None else "—"),
            f"{m.s_per_token:.3f}" if m.s_per_token is not None else "—",
            f"{m.rss_peak_mib:.0f}" if m.rss_peak_mib else "—",
            f"{result.wall_s:.1f}",
            verdict,
        ]
        for c, text in enumerate(cells):
            if c == 8:
                self.history_table.setItem(row, c, self._verdict_item(text, verdict))
            else:
                self.history_table.setItem(row, c, QTableWidgetItem(text))
        self.history_info.setText(tr('共 {0} 次运行；双击行查看详情，或导出 JSON。').format(len(self.history)))
        self.history_table.scrollToBottom()

    def _selected_history(self) -> R.RunResult | None:
        rows = self.history_table.selectionModel().selectedRows() if self.history_table.selectionModel() else []
        if not rows:
            return None
        idx = rows[0].row()
        return self.history[idx] if 0 <= idx < len(self.history) else None

    def _show_history_detail(self) -> None:
        res = self._selected_history()
        if res is None:
            QMessageBox.information(self, tr(APP_TITLE), tr('先在列表里选中一次运行。'))
            return
        TextDialog(tr('运行详情'), json.dumps(res.to_dict(), ensure_ascii=False, indent=2), self).exec()

    def _clear_history(self) -> None:
        self.history.clear()
        self.history_table.setRowCount(0)
        self.history_info.setText("")

    def _export_history(self) -> None:
        if not self.history:
            return
        path, _ = QFileDialog.getSaveFileName(self, tr('导出运行历史'), str(R.PROJECT_ROOT / "gui" / "history.json"),
                                              "JSON (*.json)")
        if not path:
            return
        Path(path).write_text(json.dumps([r.to_dict() for r in self.history], ensure_ascii=False, indent=2),
                              encoding="utf-8")
        QMessageBox.information(self, tr(APP_TITLE), tr('已导出 {0} 条记录到\n{1}').format(len(self.history), path))

    # -- suite -------------------------------------------------------------
    def _start_suite(self) -> None:
        if self._suite_active:
            return
        cfg = self._collect_cfg()
        if not cfg.bin_dir or not Path(cfg.bin_dir).exists() or not cfg.exe_path().exists():
            QMessageBox.warning(self, tr(APP_TITLE), tr('找不到引擎可执行文件，请先编译或指定可执行文件目录。'))
            return
        self._suite_active = True
        self._suite_cancel = False
        self._suite_cancelled = False
        self._suite_idx = 0
        self._suite_results = []
        self._suite_api = None
        self._suite_cases = list(R.SUITE_CASES)
        self.suite_table.setRowCount(0)
        self.suite_notes.clear()
        self.suite_progress.setMaximum(len(self._suite_cases))
        self.suite_progress.setValue(0)
        self.btn_suite.setEnabled(False)
        self.btn_suite_stop.setEnabled(True)
        self._set_busy(True)
        self.btn_run.setEnabled(False)
        self.tabs.setCurrentWidget(self.suite_tab)
        self._append_log("log", tr('# 测试套件开始：{0} 个用例').format(len(self._suite_cases)))
        self._suite_next()

    def _suite_base_cfg(self) -> R.RunConfig:
        cfg = self._collect_cfg()
        cfg.compare_native = False
        return cfg

    def _suite_next(self) -> None:
        if self._suite_cancel or self._suite_idx >= len(self._suite_cases):
            self._suite_finish()
            return
        case = self._suite_cases[self._suite_idx]
        self._suite_case = case
        self._suite_main = None
        self._suite_phase = "main"
        cfg = self._suite_base_cfg()
        overrides = dict(case.overrides)
        model = overrides.pop("model", None) if "model" in overrides else None
        cfg = cfg.clone(**overrides) if overrides else cfg
        if model is not None:
            cfg = cfg.clone(model=model)
        self.suite_progress.setValue(self._suite_idx)
        self.status_state.setText(tr('套件 {0}/{1}: {2}').format(self._suite_idx + 1, len(self._suite_cases), tr(case.name)))
        self._append_log("log", f"# [{self._suite_idx + 1}/{len(self._suite_cases)}] {tr(case.name)}  ({R.env_summary(cfg)})")

        if case.api_probe:
            self._suite_run_api_probe(case, cfg)
            return

        runner = R.EngineRunner(cfg, self)
        runner.output.connect(lambda ch, txt: None)  # suite output is summarised, keep UI light
        runner.error.connect(self._suite_on_error)
        runner.finished.connect(self._suite_on_main_finished)
        self.runner = runner
        runner.start()

    # -- suite case 5: `disktui --api-only` + HTTP probe -------------------
    # the v0.9.0 TUI is interactive only: without a TTY it exits with code 2
    # and points at --api-only, so this case validates the headless
    # `/v1/models` endpoint instead of a piped single turn.
    def _suite_api_free_port(self) -> int:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])
        finally:
            sock.close()

    def _suite_run_api_probe(self, case, cfg) -> None:
        port = self._suite_api_free_port()
        args = R.build_api_probe_command(cfg, port)
        proc = QProcess(self)
        proc.setProgram(str(cfg.exe_path()))
        proc.setArguments(args)
        proc.setProcessEnvironment(R.build_env(cfg))
        proc.setWorkingDirectory(str(R.PROJECT_ROOT))
        self.runner = None
        self._suite_api = {"proc": proc, "port": port, "tries": 0,
                           "t0": time.monotonic(), "case": case, "timer": None}
        self._suite_phase = "api"
        self._append_log("log", f"$ {cfg.exe_path().name} {' '.join(args)}")
        self._append_log("log", tr('API 探针：等待 /v1/models …'))
        proc.start()
        timer = QTimer(self)
        timer.setInterval(300)
        timer.timeout.connect(self._suite_api_poll)
        timer.start()
        self._suite_api["timer"] = timer

    def _suite_api_poll(self) -> None:
        state = self._suite_api
        if state is None:
            return
        if self._suite_cancel:
            self._suite_api_abort()
            return
        state["tries"] += 1
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(f"http://127.0.0.1:{state['port']}/v1/models", timeout=0.8) as resp:
                body = resp.read()
                code = int(getattr(resp, "status", 200) or 200)
            if code == 200:
                try:
                    payload = json.loads(body.decode("utf-8", "replace"))
                    n_models = len(payload.get("data") or [])
                    self._suite_api_finish(
                        True, tr('API 探针：GET /v1/models 200，{0} 个模型').format(n_models), code)
                except Exception:
                    self._suite_api_finish(
                        False, tr('API 探针失败：{0}').format("response is not JSON"), code)
                return
        except Exception as exc:
            if state["tries"] >= 60:
                self._suite_api_finish(
                    False, tr('API 探针失败：{0}').format(str(exc)[:160]))
                return
        proc = state["proc"]
        if proc is not None and proc.state() == QProcess.ProcessState.NotRunning and state["tries"] >= 3:
            self._suite_api_finish(
                False, tr('API 探针：进程提前退出（退出码 {0}）').format(proc.exitCode()))

    def _suite_api_finish(self, ok: bool, note: str, http_code=None) -> None:
        state = self._suite_api
        if state is None:
            return
        self._suite_api = None
        timer = state.get("timer")
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        proc = state.get("proc")
        if proc is not None:
            try:
                if proc.state() != QProcess.ProcessState.NotRunning:
                    proc.terminate()
                    if not proc.waitForFinished(2000):
                        proc.kill()
                        proc.waitForFinished(1000)
            except Exception:
                pass
        wall = time.monotonic() - float(state.get("t0", time.monotonic()))
        self._suite_record_custom(state["case"], ok, [note], tr('disktui --api-only'),
                                  f"API :{state['port']}", wall, http_code)
        self._suite_idx += 1
        QTimer.singleShot(0, self._suite_next)

    def _suite_api_abort(self) -> None:
        state = self._suite_api
        if state is None:
            return
        self._suite_api = None
        timer = state.get("timer")
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        proc = state.get("proc")
        if proc is not None:
            try:
                if proc.state() != QProcess.ProcessState.NotRunning:
                    proc.kill()
                    proc.waitForFinished(1000)
            except Exception:
                pass

    def _suite_record_custom(self, case, ok: bool, notes, engine: str,
                             envtxt: str, wall_s: float, http_code=None) -> None:
        verdict = "PASS" if ok else "FAIL"
        row = self.suite_table.rowCount()
        self.suite_table.insertRow(row)
        cells = [str(self._suite_idx + 1), tr(case.name), engine, envtxt,
                 str(http_code) if http_code is not None else "—",
                 "—", "—", "—", verdict]
        for c, text in enumerate(cells):
            if c == 8:
                self.suite_table.setItem(row, c, self._verdict_item(text, verdict))
            else:
                self.suite_table.setItem(row, c, QTableWidgetItem(text))
        self.suite_table.scrollToBottom()
        self._suite_results.append({
            "index": self._suite_idx + 1, "key": case.key, "name": tr(case.name),
            "engine": engine, "env": envtxt, "arena": "—",
            "exit_code": http_code, "tokens": None, "s_per_token": None,
            "rss_peak_mib": None, "wall_s": wall_s, "verdict": verdict,
            "notes": list(notes), "generated_text": "", "ids": [],
            "arena_mib": None, "direct_io": None, "read_mib": None,
            "evictions": None, "loads": None, "prefetch_loads": None,
            "engine_io_s": None, "compare": None, "log_dir": "",
        })
        self.suite_notes.appendPlainText(
            f"{verdict}  {tr(case.name)}  ({envtxt})  HTTP={cells[4]}")
        for n in notes:
            self.suite_notes.appendPlainText(f"      · {n}")
        self.status_state.setText(
            tr('套件完成 {0}/{1}').format(self._suite_idx + 1, len(self._suite_cases)))

    def _suite_on_error(self, msg: str) -> None:
        if not self._suite_active or self._suite_cancel:
            return
        self._append_log("err", msg)
        self._suite_record_fail(msg)
        self._suite_idx += 1
        QTimer.singleShot(0, self._suite_next)

    def _suite_on_main_finished(self, result: R.RunResult) -> None:
        if not self._suite_active or self._suite_cancel:
            return
        case = self._suite_case
        assert case is not None
        self._suite_main = result
        if (case.compare_native and not case.expect_error and result.exit_code == 0
                and not self._suite_cancel):
            base = result.cfg.native_baseline()
            self._suite_phase = "baseline"
            runner = R.EngineRunner(base, self)
            runner.output.connect(lambda ch, txt: None)
            runner.error.connect(self._suite_on_error)
            runner.finished.connect(self._suite_on_baseline_finished)
            self.runner = runner
            runner.start()
            return
        self._suite_record(case, result, None)
        self._suite_idx += 1
        QTimer.singleShot(0, self._suite_next)

    def _suite_on_baseline_finished(self, base: R.RunResult) -> None:
        if not self._suite_active or self._suite_cancel:
            return
        case = self._suite_case
        main = self._suite_main
        comparison = R.compare_runs(main, base) if main else None
        self._suite_record(case, main, comparison)
        self._suite_idx += 1
        QTimer.singleShot(0, self._suite_next)

    def _suite_record_fail(self, msg: str) -> None:
        row = self.suite_table.rowCount()
        self.suite_table.insertRow(row)
        vals = [str(self._suite_idx + 1), tr(self._suite_case.name) if self._suite_case else "?", "—",
                "—", "—", "—", "—", "—", "FAIL"]
        for c, text in enumerate(vals):
            self.suite_table.setItem(row, c, QTableWidgetItem(text))
        self._suite_results.append({"name": vals[1], "verdict": "FAIL", "notes": [msg]})
        self.suite_notes.appendPlainText(f"FAIL {vals[1]}: {msg}")

    def _suite_record(self, case: R.SuiteCase, main: R.RunResult | None, comparison: dict | None) -> None:
        verdict = "FAIL"
        notes: list[str] = []
        if main is None:
            notes.append(tr('主运行没有结果'))
        else:
            if case.expect_error:
                if main.exit_code not in (0, None) and main.wall_s < 30:
                    verdict = "PASS"
                    notes.append(tr('按预期非 0 退出 ({0})，耗时 {1:.2f} s').format(main.exit_code, main.wall_s))
                else:
                    notes.append(tr('错误路径不符合预期：退出码 {0}').format(main.exit_code))
            else:
                verdict, notes = R.judge_single(main)
                if case.require_streaming and main.metrics.arena_mib is None:
                    verdict = "FAIL"
                    notes.append(tr('缺少流式 arena 日志'))
                if comparison is not None:
                    cv, cn = R.judge_compare(comparison)
                    notes += cn
                    if cv == "FAIL":
                        verdict = "FAIL"
                    elif verdict == "PASS" and cv != "PASS":
                        verdict = "WARN"
        m = main.metrics if main else R.Metrics()
        spt = m.s_per_token if main else None
        row = self.suite_table.rowCount()
        self.suite_table.insertRow(row)
        arena = "—"
        envtxt = "—"
        if main:
            arena = ("native" if main.cfg.arena_mode == "native"
                     else ("auto" if main.cfg.arena_mode == "auto" else f"{main.cfg.arena_mib}"))
            envtxt = R.env_summary(main.cfg)
        cells = [
            str(self._suite_idx + 1), tr(case.name), main.cfg.engine if main else "—", envtxt,
            str(main.exit_code) if main else "—",
            str(m.generated_tokens if m.generated_tokens is not None else "—"),
            f"{spt:.3f}" if spt is not None else "—",
            f"{m.rss_peak_mib:.0f}" if m.rss_peak_mib else "—",
            verdict,
        ]
        for c, text in enumerate(cells):
            if c == 8:
                self.suite_table.setItem(row, c, self._verdict_item(text, verdict))
            else:
                self.suite_table.setItem(row, c, QTableWidgetItem(text))
        self.suite_table.scrollToBottom()
        self._suite_results.append({
            "index": self._suite_idx + 1, "key": case.key, "name": tr(case.name),
            "engine": main.cfg.engine if main else "",
            "env": envtxt, "arena": arena,
            "exit_code": main.exit_code if main else None,
            "tokens": m.generated_tokens, "s_per_token": spt, "rss_peak_mib": m.rss_peak_mib,
            "wall_s": main.wall_s if main else None,
            "verdict": verdict, "notes": notes,
            "generated_text": m.generated_text,
            "ids": m.generated_ids,
            "arena_mib": m.arena_mib, "direct_io": m.direct_io,
            "read_mib": m.read_mib_total, "evictions": m.evictions,
            "loads": m.loads, "prefetch_loads": m.prefetch_loads,
            "engine_io_s": m.engine_io_s,
            "compare": comparison,
            "log_dir": str(Path(main.log_path).parent) if main and main.log_path else "",
        })
        self.suite_notes.appendPlainText(
            f"{verdict}  {tr(case.name)}  ({envtxt})  tokens={cells[5]}  s/tok={cells[6]}  "
            f"RSS={cells[7]} MiB")
        for n in notes:
            self.suite_notes.appendPlainText(f"      · {n}")
        self.status_state.setText(tr('套件完成 {0}/{1}').format(self._suite_idx + 1, len(self._suite_cases)))

    def _suite_finish(self) -> None:
        if not self._suite_active:
            return
        self._suite_active = False
        self._suite_cancel = False
        self.btn_suite.setEnabled(True)
        self.btn_suite_stop.setEnabled(False)
        self._set_busy(False)
        self.btn_run.setEnabled(True)
        self.suite_progress.setValue(len(self._suite_cases))
        total = len(self._suite_results)
        passed = sum(1 for r in self._suite_results if r.get("verdict") == "PASS")
        failed = sum(1 for r in self._suite_results if r.get("verdict") == "FAIL")
        if self._suite_cancelled:
            overall = "WARN"
            summary = tr('已停止 ({0}/{1} PASS)').format(passed, total)
        elif total and failed == 0:
            overall = "PASS"
            summary = tr('测试套件 {0}/{1} PASS').format(passed, total)
        else:
            overall = "FAIL"
            summary = tr('测试套件 {0}/{1} PASS, {2} FAIL').format(passed, total, failed)
        self._append_log("log", tr('# 测试套件结束：{0}/{1} PASS，{2} FAIL').format(passed, total, failed))
        self.suite_notes.appendPlainText(tr('\n=== 套件结束：{0}/{1} PASS，{2} FAIL ===').format(passed, total, failed))
        self._set_verdict(overall, summary)
        self.status_state.setText(tr('套件完成'))
        self.status_exe.setText("")
        self.suite_finished = True

    def _stop_suite(self) -> None:
        if not self._suite_active:
            return
        self._suite_cancel = True
        self._suite_cancelled = True
        self._suite_api_abort()
        if self.runner is not None:
            self.runner.stop()
        self._append_log("log", tr('# 已请求停止测试套件'))
        self._suite_finish()

    def _export_suite_markdown(self) -> None:
        if not self._suite_results:
            QMessageBox.information(self, tr(APP_TITLE), tr('还没有测试结果。'))
            return
        path, _ = QFileDialog.getSaveFileName(
            self, tr('导出套件结果'), str(R.PROJECT_ROOT / "gui" / "suite-report.md"), "Markdown (*.md)")
        if not path:
            return
        lines = [tr('# diskinfer Windows 工作台 · 测试套件结果'), "",
                 tr('- 模型: `{0}`').format(self._collect_cfg().model),
                 tr('- 时间: {0:%Y-%m-%d %H:%M:%S}').format(__import__('datetime').datetime.now()),
                 tr('- 主机: {0}').format(os.environ.get('COMPUTERNAME', '')), "",
                 tr('| # | 用例 | 引擎 | 环境 | 退出码 | tokens | s/token | RSS MiB | 判定 |'),
                 "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for r in self._suite_results:
            lines.append(
                f"| {r.get('index', '')} | {r.get('name', '')} | {r.get('engine', '')} | "
                f"`{r.get('env', '')}` | {r.get('exit_code', '')} | {r.get('tokens', '')} | "
                f"{('%.3f' % r['s_per_token']) if r.get('s_per_token') else '—'} | "
                f"{('%.0f' % r['rss_peak_mib']) if r.get('rss_peak_mib') else '—'} | "
                f"**{r.get('verdict', '')}** |")
        passed = sum(1 for r in self._suite_results if r.get("verdict") == "PASS")
        lines += ["", tr('汇总：{0}/{1} PASS。').format(passed, len(self._suite_results)), ""]
        for r in self._suite_results:
            if r.get("notes"):
                lines.append(f"- {r.get('name')}: " + "；".join(r["notes"]))
        Path(path).write_text("\n".join(lines), encoding="utf-8")
        QMessageBox.information(self, tr(APP_TITLE), tr('已导出到\n{0}').format(path))

    def _export_suite_json(self) -> None:
        if not self._suite_results:
            QMessageBox.information(self, tr(APP_TITLE), tr('还没有测试结果。'))
            return
        path, _ = QFileDialog.getSaveFileName(
            self, tr('导出套件结果'), str(R.PROJECT_ROOT / "gui" / "suite-report.json"), "JSON (*.json)")
        if not path:
            return
        payload = {
            "model": self._collect_cfg().model,
            "generated": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
            "cases": self._suite_results,
        }
        Path(path).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        QMessageBox.information(self, tr(APP_TITLE), tr('已导出到\n{0}').format(path))

    # -- misc --------------------------------------------------------------
    def _copy_command(self) -> None:
        cfg = self._collect_cfg()
        # unsaved runs go to the system temp dir, so point the copied command there too
        log_path = (Path(tempfile.gettempdir()) / "diskinfer-workbench" / "engine.log"
                    if cfg.engine == "disktui" else None)
        text = R.powershell_command(cfg, log_path)
        QGuiApplication.clipboard().setText(text)
        self.statusBar().showMessage(tr('PowerShell 命令已复制到剪贴板'), 3000)

    def _open_logs(self) -> None:
        R.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        if os.name == "nt":
            os.startfile(str(R.CACHE_DIR))  # noqa: S606
        else:
            self.statusBar().showMessage(str(R.CACHE_DIR), 3000)

    def _clean_runs(self) -> None:
        """Delete the per-run log directories under gui/runs (they grow over time)."""
        if not R.CACHE_DIR.exists():
            self.statusBar().showMessage(tr('还没有运行日志'), 3000)
            return
        dirs = [d for d in R.CACHE_DIR.iterdir() if d.is_dir()]
        if not dirs:
            self.statusBar().showMessage(tr('还没有运行日志'), 3000)
            return
        answer = QMessageBox.question(
            self, tr(APP_TITLE),
            tr('删除 gui/runs/ 下的 {0} 个运行日志目录？\n\n测试结果表格和已导出的文件不受影响。').format(len(dirs)),
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No)
        if answer != QMessageBox.StandardButton.Yes:
            return
        removed = 0
        for d in dirs:
            try:
                shutil.rmtree(d)
                removed += 1
            except OSError:
                pass
        self.statusBar().showMessage(tr('已清理 {0} 个运行日志目录').format(removed), 5000)

    # -- demo / selftest helpers ------------------------------------------
    def load_demo(self) -> None:
        """Fill the UI with a believable sample so screenshots show a populated window."""
        self.log.clear()
        demo_lines = [
            "$ diskrun.exe -m Qwen3.5-0.8B-Q6_K.gguf -p 'The capital of France is' -n 8 -c 128 -b 4 -ub 4 -t 4",
            "# env: STREAM_MB=200 ODIRECT=1",
            "llama-disk: 320 tensors registered, 590 MiB to stream, largest tensor 'token_embd.weight' 198 MiB",
            "llama-disk: arena 200 MiB cannot hold the largest tensor 'token_embd.weight' (198 MiB), raised to 222 MiB",
            "llama-disk: streaming weights from disk, arena = 222 MiB (raised to fit the largest tensor), direct io = 1, mlock = 0, prefetch = 0 (lookahead 16)",
            "diskrun: model loaded in 0.300 s",
            "diskrun: prompt has 5 tokens: 760 6511 314 9338 369",
            "diskrun: prefill token 1/5 done, rss = 340 MiB",
            "diskrun: prefill took 1.7 s",
            "diskrun: token 1 id=11751 sample=0.334 s, rss = 347 MiB",
            "diskrun: token 2 id=13 sample=0.331 s, rss = 347 MiB",
            "diskrun: token 3 id=198 sample=0.333 s, rss = 347 MiB",
            "diskrun: generated 8 tokens in 2.34 s (0.334 s/token)",
            tr('# 退出码 0，耗时 4.77 s，判定 PASS'),
            tr('# 完成：PASS'),
        ]
        for line in demo_lines:
            self._append_log("log", line)
        self.status_state.setText(tr('完成'))
        self.status_elapsed.setText(tr('耗时 4.77 s'))
        self.status_rss.setText(tr('RSS 峰值 348 MiB'))
        self.status_exe.setText("diskrun  |  diskrun.exe  |  STREAM_MB=200 ODIRECT=1")

        m = R.Metrics(
            registered_tensors=320, registered_mib=590, largest_tensor="token_embd.weight",
            largest_mib=198, arena_requested_mib=200, arena_mib=222,
            arena_note="raised to fit the largest tensor", direct_io=1, mlock=0, prefetch=0,
            lookahead=16, model_load_s=0.3, prompt_tokens=5, prefill_s=1.7,
            generated_tokens=8, s_per_token=0.334, loads=320, read_mib_total=7898,
            evictions=0, rss_peak_mib=348.0, answer=" Paris.",
            generated_text=" Paris. The capital of France is Paris, a city on the Seine.",
            token_rows=[
                {"n": i + 1, "id": iid, "io_s": 0.334, "rss_mib": 347}
                for i, iid in enumerate([11751, 13, 198, 760, 6511, 314, 9338, 369])
            ],
            generated_ids=[11751, 13, 198, 760, 6511, 314, 9338, 369],
        )
        self.session_verdict = "PASS"
        self._set_verdict("PASS", tr('退出码 0，4.8 s'))
        self._fill_summary(m, live=True)
        self._fill_metrics_tab(R.RunResult(cfg=self._collect_cfg(), exit_code=0, wall_s=4.77, metrics=m),
                               {"mode": "ids",
                                "ids_a": [11751, 13, 198, 760, 6511, 314, 9338, 369],
                                "ids_b": [11751, 13, 198, 760, 6511, 314, 9338, 369],
                                "text_a": " Paris.", "text_b": " Paris.", "same_ids": True,
                                "same_text": True, "match": True,
                                "detail": tr('token id 序列完全一致')})
        # (the comparison panel is filled by _fill_metrics_tab above, keep it consistent)

        # demo suite rows
        self.suite_table.setRowCount(0)
        demo_cases = [
            ("1", tr('流式 · 小 arena 200 MiB'), "diskrun", "STREAM_MB=200 ODIRECT=1", "0", "8", "0.334", "348", "PASS"),
            ("2", tr('原生基线 · LLAMA_DISK_STREAM_MB=0'), "diskrun", "STREAM_MB=0", "0", "8", "0.041", "715", "PASS"),
            ("3", tr('自动 arena (内存/8)'), "diskrun", "STREAM_MB=auto", "0", "8", "0.045", "717", "PASS"),
            ("4", tr('关闭 O_DIRECT (buffered)'), "diskrun", "STREAM_MB=200 ODIRECT=0", "0", "8", "0.227", "347", "PASS"),
            ("5", tr('disktui 单轮 (TUI)'), "disktui", "STREAM_MB=300", "0", "4", "0.310", "2173", "PASS"),
            ("6", tr('llama-completion 流式'), "llama-completion", "STREAM_MB=200", "0", "8", "0.335", "342", "PASS"),
            ("7", tr('错误路径 (模型不存在)'), "diskrun", "STREAM_MB=auto", "1", "—", "—", "6", "PASS"),
        ]
        for row in demo_cases:
            r = self.suite_table.rowCount()
            self.suite_table.insertRow(r)
            for c, text in enumerate(row):
                if c == 8:
                    self.suite_table.setItem(r, c, self._verdict_item(text, "PASS"))
                else:
                    self.suite_table.setItem(r, c, QTableWidgetItem(text))
        self.suite_notes.setPlainText(
            tr('PASS  流式 · 小 arena 200 MiB  tokens=8  s/tok=0.334  RSS=348 MiB\n      · token id 序列完全一致: 11751,13,198,760,6511,314,9338,369\nPASS  原生基线 · LLAMA_DISK_STREAM_MB=0  tokens=8  s/tok=0.041  RSS=715 MiB\nPASS  自动 arena (内存/8)  tokens=8  s/tok=0.045  RSS=717 MiB\nPASS  关闭 O_DIRECT (buffered)  tokens=8  s/tok=0.227  RSS=347 MiB\nPASS  disktui 单轮 (TUI)  tokens=4  s/tok=0.310  RSS=2173 MiB\nPASS  llama-completion 流式  tokens=8  s/tok=0.335  RSS=342 MiB\nPASS  错误路径 (模型不存在)  按预期非 0 退出 (1)，耗时 0.03 s\n\n=== 套件结束：7/7 PASS，0 FAIL ==='))
        self.suite_progress.setMaximum(7)
        self.suite_progress.setValue(7)

        # demo history
        self.history_table.setRowCount(0)
        for i in range(3):
            row = self.history_table.rowCount()
            self.history_table.insertRow(row)
            cells = [f"23:{24 + i}:0{i}", "diskrun", "200" if i else "auto", "0",
                     "8", "0.334" if i == 0 else "0.045", "348" if i == 0 else "717", "4.8", "PASS"]
            for c, text in enumerate(cells):
                if c == 8:
                    self.history_table.setItem(row, c, self._verdict_item(text, "PASS"))
                else:
                    self.history_table.setItem(row, c, QTableWidgetItem(text))
        self.history_info.setText(tr('共 3 次运行；双击行查看详情，或导出 JSON。'))
        self.chat_panel.load_demo()
        self.tabs.setCurrentWidget(self.metrics_tab)

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        """Stop every child engine before the window goes away."""
        try:
            self._suite_api_abort()
            if self._suite_active:
                self._stop_suite()
            if self.runner is not None:
                self.runner.stop()
            if self.chat_panel is not None:
                self.chat_panel.shutdown()
        except Exception:
            pass
        super().closeEvent(event)


# --------------------------------------------------------------------------- app entry

def make_app(argv: list[str]) -> QApplication:
    app = QApplication.instance() or QApplication(argv)
    app.setApplicationName(APP_TITLE)
    # no-op in auto mode (Qt follows the Windows scheme); builds a palette when the
    # theme was forced via --theme dark/light
    T.apply_palette(app)
    return app


def run_selftest(bin_dir: str | None, model: str | None, timeout_s: int = 900) -> int:
    """Headless: run the whole suite through the same code path as the GUI."""
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = make_app([sys.argv[0]])
    win = MainWindow(bin_dir=bin_dir, model=model)
    win._suite_active = False
    win.suite_finished = False
    win._start_suite()

    state = {"rc": 3}

    def watchdog() -> None:
        app.quit()

    def check_done() -> None:
        if getattr(win, "suite_finished", False):
            state["rc"] = 0 if all(r.get("verdict") == "PASS" for r in win._suite_results) else 1
            print(json.dumps({
                "cases": win._suite_results,
                "passed": sum(1 for r in win._suite_results if r.get("verdict") == "PASS"),
                "total": len(win._suite_results),
            }, ensure_ascii=False))
            app.quit()

    timer = QTimer()
    timer.setInterval(500)
    timer.timeout.connect(check_done)
    timer.start()
    QTimer.singleShot(timeout_s * 1000, watchdog)
    app.exec()
    return state["rc"]


def run_chat_selftest(bin_dir: str | None, model: str | None, timeout_s: int = 300) -> int:
    """Headless smoke test of the chat mode: send one message through diskc.exe."""
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ.setdefault("QT_QPA_FONTDIR", r"C:\Windows\Fonts")
    app = make_app([sys.argv[0]])
    win = MainWindow(bin_dir=bin_dir, model=model)
    panel = win.chat_panel
    if model:
        win.w["model"].setText(model)
    panel.sp_n_ctx.setValue(512)
    panel.sp_n_predict.setValue(8)
    panel.sp_temp.setValue(0.0)

    collected = {"layers": set(), "progress": 0, "tokens": []}

    panel.input.setPlainText("The capital of France is")
    panel.send_message()
    if panel.session is None:
        print(json.dumps({"ok": False, "error": tr('对话引擎没有启动'), "rc": 1}, ensure_ascii=False))
        return 1

    def on_progress(ev: dict) -> None:
        collected["progress"] += 1
        layer = int(ev.get("layer", -1) or -1)
        if layer >= 0:
            collected["layers"].add(layer)

    def on_token(ev: dict) -> None:
        collected["tokens"].append({"id": ev.get("id"), "piece": ev.get("piece"),
                                    "io_s": ev.get("io_s"), "cmp_s": ev.get("cmp_s"),
                                    "layer": ev.get("layer"), "tok_s": ev.get("tok_s")})

    panel.session.progress.connect(on_progress)
    panel.session.token.connect(on_token)

    result: dict = {"rc": 3}
    state = {"phase": 1, "turn1": ""}

    def finish(ok: bool, extra: dict | None = None) -> None:
        result.update({
            "ok": ok,
            "turn1": state["turn1"],
            "turn2": panel.messages[-1].get("content", "") if len(panel.messages) >= 4 else "",
            "messages": len(panel.messages),
            "tokens_turn2": len(collected["tokens"]),
            "layers_seen": sorted(collected["layers"]),
            "progress_events": collected["progress"],
            "first_tokens": collected["tokens"][:3],
            "ready": panel.ready_info,
            "avg_tok_s": panel.lbl_avg_s.text(),
            "cur_layer_label": panel.lbl_layer.text(),
            "layer_bar": panel.bar_layer.value(),
            "rc": 0 if ok else 1,
        })
        if extra:
            result.update(extra)
        print(json.dumps(result, ensure_ascii=False))
        panel.shutdown()
        app.quit()

    def check() -> None:
        if panel.busy:
            return
        if state["phase"] == 1:
            if len(panel.messages) < 2:
                return
            last = panel.messages[-1]
            if last.get("role") != "assistant":
                finish(False, {"error": last.get("content", tr('对话失败'))})
                return
            state["turn1"] = last.get("content", "")
            state["phase"] = 2
            # keep the union of layer samples (a warm cache in turn 2 may only show the
            # last layer), reset the per-turn counters
            state["layers_turn1"] = len(collected["layers"])
            collected["tokens"].clear()
            collected["progress"] = 0
            panel.input.setPlainText("And the capital of Germany is")
            panel.send_message()
            return
        # phase 2: second turn must also succeed (exercises KV prefix handling)
        if len(panel.messages) < 4:
            return
        last = panel.messages[-1]
        ok = (last.get("role") == "assistant" and bool(last.get("content", "").strip())
              and len(collected["layers"]) > 1 and collected["progress"] > 0)
        finish(ok)

    timer = QTimer()
    timer.setInterval(150)
    timer.timeout.connect(check)
    timer.start()

    def watchdog() -> None:
        if result.get("rc") == 3:
            finish(False, {"timeout": True, "phase": state["phase"]})
        else:
            app.quit()

    QTimer.singleShot(timeout_s * 1000, watchdog)
    app.exec()
    return int(result.get("rc", 3))


def run_screenshot(path: str, demo: bool, bin_dir: str | None, model: str | None,
                   tab: int | None = None) -> int:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = make_app([sys.argv[0]])
    win = MainWindow(bin_dir=bin_dir, model=model)
    win.resize(1400, 900)
    win.show()
    if demo:
        win.load_demo()
    if tab is not None:
        win.tabs.setCurrentIndex(tab)
    app.processEvents()

    def grab() -> None:
        out = win.grab()
        ok = out.save(path)
        print(f"screenshot: {path} ({out.width()}x{out.height()}) saved={ok}")
        app.quit()

    QTimer.singleShot(700, grab)
    app.exec()
    return 0


def main(argv: list[str]) -> int:
    import argparse

    # language: CLI --lang > DISKINFER_LANG/LC_ALL/LANG > Qt locale > en
    lang_arg = None
    for i, arg in enumerate(argv):
        if arg == "--lang" and i + 1 < len(argv):
            lang_arg = argv[i + 1]
        elif arg.startswith("--lang="):
            lang_arg = arg.split("=", 1)[1]
    set_lang(lang_arg if lang_arg is not None else detect_lang())

    parser = argparse.ArgumentParser(description=tr(APP_TITLE))
    parser.add_argument("--lang", default=None,
                        choices=["auto", "en", "zh", "zh-Hans", "zh-Hant", "zh-CN", "zh-TW"],
                        help=tr('界面语言：auto 跟随系统（默认），或 en / zh-Hans / zh-Hant'))
    parser.add_argument("--bin-dir", default=None, help=tr('可执行文件目录 (默认自动查找 build/out/win-x64)'))
    parser.add_argument("--model", default=None, help=tr('GGUF 模型路径'))
    parser.add_argument("--selftest", action="store_true", help=tr('无界面跑完整测试套件并输出 JSON'))
    parser.add_argument("--chat-selftest", action="store_true",
                        help=tr('无界面测试对话模式（diskc.exe 流式生成 + 层/速度事件）'))
    parser.add_argument("--screenshot", default=None, help=tr('无界面渲染窗口到 PNG 后退出'))
    parser.add_argument("--tab", type=int, default=None,
                        help=tr('截图时显示的标签页 0=对话 1=输出 2=指标 3=套件 4=历史'))
    parser.add_argument("--theme", choices=["auto", "light", "dark"], default="auto",
                        help=tr('界面主题：auto 跟随 Windows 深色模式（默认），light/dark 强制'))
    parser.add_argument("--demo", action="store_true", help=tr('填入演示数据 (配合 --screenshot)'))
    parser.add_argument("--chat-send", default=None,
                        help=tr('启动后自动在「对话」页发送一条消息（演示用）'))
    args = parser.parse_args(argv)
    set_lang(args.lang if args.lang else detect_lang())

    if args.theme != "auto":
        os.environ["DISKINFER_THEME"] = args.theme
    T.set_override(None if args.theme == "auto" else args.theme)

    if args.selftest:
        return run_selftest(args.bin_dir, args.model)
    if args.chat_selftest:
        return run_chat_selftest(args.bin_dir, args.model)
    if args.screenshot:
        return run_screenshot(args.screenshot, args.demo, args.bin_dir, args.model, args.tab)

    app = make_app([sys.argv[0]])
    win = MainWindow(bin_dir=args.bin_dir, model=args.model)
    win.show()
    if args.demo:
        win.load_demo()
    if args.chat_send:
        def _auto_send() -> None:
            win.tabs.setCurrentWidget(win.chat_panel)
            win.chat_panel.input.setPlainText(args.chat_send)
            win.chat_panel.send_message()
        _delay = int(os.environ.get("DISKINFER_AUTOSEND_DELAY_MS", "3500"))
        QTimer.singleShot(_delay, _auto_send)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))


