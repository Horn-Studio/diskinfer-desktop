"""对话模式面板 (PySide6)

普通聊天界面：消息正常渲染（用户/助手气泡，助手回复按 Markdown 渲染），
同时在右侧实时显示「生成过程」的细节：

  * 当前正在计算/换入哪一层（L12 / 24 进度条）——来自引擎的 progress 事件
  * 每个 token 的 io（读盘）/ cmp（计算）/ tot 秒数与速度（tok/s）
  * 阶段（预填 prompt / 生成）、回复进度、累计读盘量、换出次数
  * 逐 token 明细表与引擎日志

引擎是 examples/diskc（diskc），一个常驻进程：GUI 通过 stdin/stdout 的 JSON 行
协议与它通信，KV 前缀能复用就复用（hybrid 模型如 qwen35 会自动回退成整段重算）。
"""

from __future__ import annotations

import html
import re
import time
from pathlib import Path
from typing import Callable

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPalette, QTextCursor, QTextDocument
from PySide6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QDoubleSpinBox,
    QFormLayout,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QSpinBox,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

import runner as R
import theme as T
from i18n import tr

MONO_FAMILIES = ["Cascadia Mono", "Consolas", "Courier New", "monospace"]


def fmt_speed(tok_s: float) -> str:
    """Slow disk-streaming speeds (e.g. 0.0008 tok/s ≈ 20 min/token) need 4 decimals."""
    try:
        v = float(tok_s)
    except (TypeError, ValueError):
        return "—"
    if v <= 0:
        return "—"
    return f"{v:.4f} tok/s" if v < 0.01 else f"{v:.2f} tok/s"


def mono_font(size: int = 9) -> QFont:
    f = QFont()
    f.setFamilies(MONO_FAMILIES)
    f.setStyleHint(QFont.StyleHint.Monospace)
    f.setPointSize(size)
    return f


def md_fragment(text: str) -> str:
    """Render Markdown to an HTML fragment usable inside QTextBrowser.setHtml()."""
    if not text:
        return ""
    doc = QTextDocument()
    doc.setMarkdown(text)
    out = doc.toHtml()
    m = re.search(r"<body[^>]*>(.*)</body>", out, re.S)
    if m:
        return m.group(1)
    return html.escape(text).replace("\n", "<br>")


class ChatInput(QPlainTextEdit):
    """Enter sends, Shift+Enter inserts a newline."""

    send_requested = Signal()

    def keyPressEvent(self, event) -> None:  # noqa: N802 (Qt naming)
        if (event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter)
                and not (event.modifiers() & Qt.KeyboardModifier.ShiftModifier)):
            self.send_requested.emit()
            return
        super().keyPressEvent(event)


class ChatPanel(QWidget):
    """A normal chat view plus a live 'what is the engine doing' detail panel."""

    def __init__(self, get_run_cfg: Callable[[], R.RunConfig], parent: QWidget | None = None):
        super().__init__(parent)
        self.t = T.current()
        self.get_run_cfg = get_run_cfg
        self.session: R.ChatSession | None = None
        self.session_key: tuple | None = None
        self.messages: list[dict] = []
        self.pending_messages: list[dict] | None = None
        self.stream_text = ""
        self.busy = False
        self.ready_info: dict | None = None
        self.last_progress: dict = {}
        self.io_total = 0.0
        self.cmp_total = 0.0
        self.gen_count = 0

        self._build_ui()
        # show the welcome text right away (empty pane otherwise, especially in dark mode
        # where a blank area looks like a rendering bug)
        self._render_conversation()

    # ------------------------------------------------------------------ ui
    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(6, 6, 6, 6)

        # header
        head = QHBoxLayout()
        title = QLabel(tr('对话模式'))
        title.setStyleSheet("font-size: 15px; font-weight: bold;")
        self.engine_label = QLabel(tr('引擎: diskc（磁盘流式 · 常驻会话）'))
        self.engine_label.setStyleSheet(f"color: {self.t.muted};")
        self.status_label = QLabel(tr('未启动'))
        self.status_label.setStyleSheet(f"color: {self.t.accent}; font-weight: bold;")
        btn_new = QPushButton(tr('新对话'))
        btn_new.clicked.connect(self.new_conversation)
        btn_clear = QPushButton(tr('清空显示'))
        btn_clear.clicked.connect(self.clear_display)
        head.addWidget(title)
        head.addWidget(self.engine_label)
        head.addStretch(1)
        head.addWidget(self.status_label)
        head.addSpacing(12)
        head.addWidget(btn_clear)
        head.addWidget(btn_new)
        root.addLayout(head)

        splitter = QSplitter(Qt.Orientation.Horizontal)

        # ---- left: conversation + input
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.setSpacing(6)

        self.chat_view = QTextBrowser()
        self.chat_view.setOpenExternalLinks(False)
        # dark mode: the pane must follow the theme, otherwise the system's white text
        # would end up on a hard-coded white background
        self.chat_view.setStyleSheet(
            f"QTextBrowser {{ background-color: {self.t.chat_bg}; color: {self.t.chat_text};"
            f" border: 1px solid {self.t.chat_border}; border-radius: 4px; }}")
        pal = self.chat_view.palette()
        pal.setColor(QPalette.ColorRole.Base, QColor(self.t.chat_bg))
        pal.setColor(QPalette.ColorRole.Text, QColor(self.t.chat_text))
        self.chat_view.setPalette(pal)
        lv.addWidget(self.chat_view, 1)

        # chat options
        opt_row = QHBoxLayout()
        self.sp_n_ctx = QSpinBox()
        self.sp_n_ctx.setRange(256, 32768)
        self.sp_n_ctx.setSingleStep(256)
        self.sp_n_ctx.setValue(2048)
        self.sp_n_predict = QSpinBox()
        self.sp_n_predict.setRange(16, 4096)
        self.sp_n_predict.setSingleStep(16)
        self.sp_n_predict.setValue(256)
        self.sp_temp = QDoubleSpinBox()
        self.sp_temp.setRange(0.0, 2.0)
        self.sp_temp.setSingleStep(0.05)
        self.sp_temp.setDecimals(2)
        self.sp_temp.setValue(0.70)
        self.chk_no_think = QCheckBox(tr('关闭思考'))
        self.chk_no_think.setChecked(True)
        self.chk_no_think.setToolTip(tr('Qwen3 风格模板：在 assistant 起始后补 <think></think> 空思考块，直接回答'))
        opt_row.addWidget(QLabel(tr('上下文')))
        opt_row.addWidget(self.sp_n_ctx)
        opt_row.addWidget(QLabel(tr('最大回复')))
        opt_row.addWidget(self.sp_n_predict)
        opt_row.addWidget(QLabel("temp"))
        opt_row.addWidget(self.sp_temp)
        opt_row.addWidget(self.chk_no_think)
        opt_row.addStretch(1)
        hint = QLabel(tr('Enter 发送 · Shift+Enter 换行 · 磁盘/arena 沿用左侧面板'))
        hint.setStyleSheet(f"color: {self.t.muted};")
        opt_row.addWidget(hint)
        lv.addLayout(opt_row)

        input_row = QHBoxLayout()
        self.input = ChatInput()
        self.input.setPlaceholderText(tr('输入消息…'))
        self.input.setFixedHeight(74)
        self.input.send_requested.connect(self.send_message)
        input_row.addWidget(self.input, 1)

        btn_col = QVBoxLayout()
        self.btn_send = QPushButton(tr('发送'))
        self.btn_send.setMinimumHeight(34)
        self.btn_send.clicked.connect(self.send_message)
        self.btn_stop = QPushButton(tr('停止生成'))
        self.btn_stop.setMinimumHeight(34)
        self.btn_stop.setEnabled(False)
        self.btn_stop.clicked.connect(self.stop_generation)
        btn_col.addWidget(self.btn_send)
        btn_col.addWidget(self.btn_stop)
        input_row.addLayout(btn_col)
        lv.addLayout(input_row)
        splitter.addWidget(left)

        # ---- right: details
        splitter.addWidget(self._build_detail_panel())
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 0)
        splitter.setSizes([900, 360])
        root.addWidget(splitter, 1)

    def _build_detail_panel(self) -> QWidget:
        panel = QWidget()
        panel.setMinimumWidth(340)
        panel.setMaximumWidth(460)
        v = QVBoxLayout(panel)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(6)

        # generation progress
        gb = QGroupBox(tr('生成过程'))
        g = QVBoxLayout(gb)
        self.lbl_phase = QLabel(tr('阶段: 等待输入'))
        self.lbl_phase.setStyleSheet("font-weight: bold;")
        g.addWidget(self.lbl_phase)

        self.lbl_layer = QLabel(tr('当前层: —'))
        self.lbl_layer.setStyleSheet(f"font-size: 14px; font-weight: bold; color: {self.t.accent};")
        g.addWidget(self.lbl_layer)
        self.bar_layer = QProgressBar()
        self.bar_layer.setRange(0, 24)
        self.bar_layer.setValue(0)
        self.bar_layer.setFormat("L%v / %m")
        g.addWidget(self.bar_layer)

        self.lbl_progress = QLabel(tr('进度: —'))
        g.addWidget(self.lbl_progress)
        self.bar_turn = QProgressBar()
        self.bar_turn.setRange(0, 1)
        self.bar_turn.setValue(0)
        self.bar_turn.setFormat("%v / %m")
        g.addWidget(self.bar_turn)
        v.addWidget(gb)

        # speed / per token
        gb = QGroupBox(tr('速度与本次 token'))
        grid = QGridLayout(gb)
        self.lbl_tok_s = QLabel("—")
        self.lbl_avg_s = QLabel("—")
        self.lbl_io = QLabel("—")
        self.lbl_cmp = QLabel("—")
        self.lbl_tot = QLabel("—")
        self.lbl_prefill_speed = QLabel("—")
        for i, (label, widget) in enumerate([
            (tr('当前速度'), self.lbl_tok_s), (tr('平均速度'), self.lbl_avg_s),
            (tr('预填速度'), self.lbl_prefill_speed),
            (tr('本 token io'), self.lbl_io), (tr('本 token cmp'), self.lbl_cmp),
            (tr('本 token 总耗时'), self.lbl_tot),
        ]):
            grid.addWidget(QLabel(label), i // 2, (i % 2) * 2)
            grid.addWidget(widget, i // 2, (i % 2) * 2 + 1)
        v.addWidget(gb)

        # resources
        gb = QGroupBox(tr('引擎状态'))
        grid = QGridLayout(gb)
        self.lbl_arena = QLabel("—")
        self.lbl_io_mode = QLabel("—")
        self.lbl_read = QLabel("—")
        self.lbl_loads = QLabel("—")
        self.lbl_evict = QLabel("—")
        self.lbl_ctx = QLabel("—")
        for i, (label, widget) in enumerate([
            ("arena", self.lbl_arena), (tr('读取模式'), self.lbl_io_mode),
            (tr('已读盘'), self.lbl_read), (tr('加载次数'), self.lbl_loads),
            (tr('换出次数'), self.lbl_evict), (tr('上下文'), self.lbl_ctx),
        ]):
            grid.addWidget(QLabel(label), i // 2, (i % 2) * 2)
            grid.addWidget(widget, i // 2, (i % 2) * 2 + 1)
        v.addWidget(gb)

        # per token table
        self.tok_table = QTableWidget(0, 7)
        self.tok_table.setHorizontalHeaderLabels(["#", "token", "io s", "cmp s", "tot s", tr('层'), "tok/s"])
        self.tok_table.verticalHeader().setVisible(False)
        self.tok_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.tok_table.setAlternatingRowColors(True)
        self.tok_table.setMaximumHeight(230)
        self.tok_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        for c in (0, 2, 3, 4, 5, 6):
            self.tok_table.horizontalHeader().setSectionResizeMode(
                c, QHeaderView.ResizeMode.ResizeToContents)
        v.addWidget(self.tok_table)

        # engine log
        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setFont(mono_font(8))
        self.log_view.setMaximumBlockCount(500)
        self.log_view.setMaximumHeight(110)
        self.log_view.setPlaceholderText(tr('引擎日志（stderr）'))
        v.addWidget(self.log_view)
        v.addStretch(1)
        return panel

    # ------------------------------------------------------------- config
    def _chat_cfg(self) -> R.ChatConfig:
        rc = self.get_run_cfg()
        return R.ChatConfig(
            model=rc.model,
            bin_dir=rc.bin_dir,
            n_ctx=self.sp_n_ctx.value(),
            n_batch=rc.n_batch,
            n_ubatch=rc.n_ubatch,
            threads=rc.threads,
            n_predict=self.sp_n_predict.value(),
            temp=self.sp_temp.value(),
            top_k=rc.top_k,
            top_p=rc.top_p,
            no_think=self.chk_no_think.isChecked(),
            arena_mode=rc.arena_mode,
            arena_mib=rc.arena_mib,
            odirect=rc.odirect,
            mlock=rc.mlock,
            prefetch=rc.prefetch,
            lookahead=rc.lookahead,
            debug=rc.debug,
            verbose=rc.verbose,
        )

    # ------------------------------------------------------------- rendering
    def _render_conversation(self) -> None:
        t = self.t
        parts = ['<div style="font-family:\'Microsoft YaHei UI\',\'Segoe UI\',sans-serif; '
                 f'font-size:10pt; color:{t.chat_text};">']
        if not self.messages:
            parts.append(
                tr('<div style="color:{0}; margin:16px 0;">在下面输入消息开始对话。引擎会在第一次发送时启动（加载模型），右侧会实时显示它正在算哪一层、读盘和计算各花了多久。</div>').format(t.placeholder))
        for msg in self.messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                parts.append(
                    '<div style="margin:10px 0; text-align:right;">'
                    f'<span style="background:{t.user_bg}; color:{t.user_fg}; padding:6px 10px;">'
                    f'{html.escape(content)}</span></div>')
            elif role == "assistant":
                parts.append(
                    tr('<div style="margin:10px 0;"><div style="color:{0}; font-weight:bold; margin-bottom:2px;">助手</div><div>{1}</div></div>').format(t.assistant_label, md_fragment(content)))
            else:
                parts.append(
                    f'<div style="margin:6px 0; color:{t.system_text};">{html.escape(content)}</div>')
        parts.append("</div>")
        self.chat_view.setHtml("".join(parts))
        self._scroll_to_bottom()

    def _append_stream_bubble(self) -> None:
        self._render_conversation()
        cursor = QTextCursor(self.chat_view.document())
        cursor.movePosition(QTextCursor.MoveOperation.End)
        cursor.insertBlock()
        cursor.insertHtml(tr('<b style="color:{0};">助手</b>').format(self.t.assistant_label))
        cursor.insertBlock()
        self.chat_view.setTextCursor(cursor)
        self._scroll_to_bottom()

    def _append_stream_text(self, piece: str) -> None:
        if not piece:
            return
        cursor = QTextCursor(self.chat_view.document())
        cursor.movePosition(QTextCursor.MoveOperation.End)
        cursor.insertText(piece)
        self.chat_view.setTextCursor(cursor)
        self._scroll_to_bottom()

    def _scroll_to_bottom(self) -> None:
        bar = self.chat_view.verticalScrollBar()
        bar.setValue(bar.maximum())

    # ------------------------------------------------------------- actions
    def send_message(self) -> None:
        if self.busy:
            return
        text = self.input.toPlainText().strip()
        if not text:
            return
        self.input.clear()
        self.messages.append({"role": "user", "content": text})
        self._render_conversation()
        self._append_stream_bubble()
        self.stream_text = ""
        self.io_total = 0.0
        self.cmp_total = 0.0
        self.gen_count = 0
        self.tok_table.setRowCount(0)
        self.busy = True
        self.btn_send.setEnabled(False)
        self.btn_stop.setEnabled(True)
        self.lbl_phase.setText(tr('阶段: 准备引擎'))

        cfg = self._chat_cfg()
        assert isinstance(cfg, R.ChatConfig)
        if (self.session is None or self.session_key != cfg.key()
                or not self.session.is_running()):
            if self.session is not None:
                self.session.stop()
            self.session = R.ChatSession(cfg, self)
            self.session_key = cfg.key()
            self.session.ready.connect(self._on_ready)
            self.session.progress.connect(self._on_progress)
            self.session.token.connect(self._on_token)
            self.session.done.connect(self._on_done)
            self.session.info.connect(self._on_info)
            self.session.failure.connect(self._on_failure)
            self.session.log.connect(self._on_log)
            self.session.state_changed.connect(self._on_state)
            self.pending_messages = list(self.messages)
            self._set_status(tr('加载模型…'))
            if not self.session.start():
                self.busy = False
                self.btn_send.setEnabled(True)
                self.btn_stop.setEnabled(False)
            return

        self.pending_messages = None
        if not self.session.send(self.messages):
            self._on_failure(tr('对话引擎没有就绪，请稍后重试。'))

    def stop_generation(self) -> None:
        if not self.busy or self.session is None:
            return
        self._set_status(tr('正在停止…'))
        self.session.cancel()
        QTimer.singleShot(5000, self._force_stop_if_busy)

    def _force_stop_if_busy(self) -> None:
        if self.busy and self.session is not None:
            self.session.stop()
            self.session = None
            self.session_key = None
            self.busy = False
            self.btn_send.setEnabled(True)
            self.btn_stop.setEnabled(False)
            self._set_status(tr('已停止（引擎已重启）'))
            self._on_failure(tr('生成超时未停止，已强制结束引擎进程。'))

    def new_conversation(self) -> None:
        if self.session is not None:
            self.session.reset()
        self.messages.clear()
        self.stream_text = ""
        self.tok_table.setRowCount(0)
        self.io_total = 0.0
        self.cmp_total = 0.0
        self._render_conversation()
        self._set_status(tr('就绪') if self.session and self.session.is_running() else tr('未启动'))
        self.lbl_phase.setText(tr('阶段: 等待输入'))
        self.lbl_layer.setText(tr('当前层: —'))
        self.bar_layer.setValue(0)
        self.bar_turn.setRange(0, 1)
        self.bar_turn.setValue(0)
        self.lbl_progress.setText(tr('进度: —'))

    def clear_display(self) -> None:
        self.messages.clear()
        self.stream_text = ""
        self.tok_table.setRowCount(0)
        self._render_conversation()

    def shutdown(self) -> None:
        if self.session is not None:
            self.session.stop()
            self.session = None
            self.session_key = None

    # ------------------------------------------------------------- session events
    def _set_status(self, text: str) -> None:
        self.status_label.setText(text)

    def _on_state(self, state: str) -> None:
        if state == "starting":
            self._set_status(tr('加载模型…'))
            self.lbl_phase.setText(tr('阶段: 加载模型（磁盘流式，只读元数据）'))
        elif state == "ready":
            self._set_status(tr('就绪'))
        elif state == "generating":
            self._set_status(tr('生成中…'))
        else:
            self._set_status(tr('未启动'))

    def _on_ready(self, ev: dict) -> None:
        self.ready_info = ev
        n_layer = int(ev.get("n_layer", 24))
        self.bar_layer.setRange(0, max(1, n_layer))
        self.lbl_arena.setText(f"{ev.get('arena_mib', '?')} MiB")
        self.lbl_io_mode.setText(
            f"direct={ev.get('direct_io')} mlock={ev.get('mlock')} prefetch={ev.get('prefetch')}")
        self._append_engine_note(
            tr('模型 {0} · {1} 层 · arena {2} MiB · {3} 个张量 / {4} MiB · ctx {5}').format(ev.get('model'), ev.get('n_layer'), ev.get('arena_mib'), ev.get('tensors'), ev.get('registered_mib'), ev.get('n_ctx')))
        if self.pending_messages is not None and self.session is not None:
            msgs = self.pending_messages
            self.pending_messages = None
            if not self.session.send(msgs):
                self._on_failure(tr('发送失败：引擎未就绪。'))
            else:
                self._set_status(tr('生成中…'))

    def _on_progress(self, ev: dict) -> None:
        self.last_progress = ev
        phase = ev.get("phase", "gen")
        n_layer = int(ev.get("n_layer", 0) or 0)
        layer = int(ev.get("layer", -1) or -1)
        done = int(ev.get("done", 0) or 0)
        total = int(ev.get("total", 0) or 0)
        elapsed = float(ev.get("elapsed_s", 0) or 0)
        if n_layer > 0:
            self.bar_layer.setRange(0, n_layer)
            if layer >= 0:
                self.lbl_layer.setText(tr('当前层: L{0} / {1}').format(layer + 1, n_layer))
                self.bar_layer.setValue(layer + 1)
        if phase == "prefill":
            self.lbl_phase.setText(tr('阶段: 预填 prompt（逐批读盘 + 计算）'))
            self.lbl_progress.setText(tr('预填: {0} / {1} tokens').format(done, total))
            self.bar_turn.setRange(0, max(1, total))
            self.bar_turn.setValue(done)
            if elapsed > 0.05 and done > 0:
                self.lbl_prefill_speed.setText(fmt_speed(done / elapsed))
        else:
            self.lbl_phase.setText(tr('阶段: 生成（每 token 顺序读一遍模型）'))
            self.lbl_progress.setText(tr('回复: {0} / {1} tokens').format(done, total))
            self.bar_turn.setRange(0, max(1, total))
            self.bar_turn.setValue(done)
        self.lbl_read.setText(f"{ev.get('read_mib', 0)} MiB")
        self.lbl_loads.setText(str(ev.get("loads", "—")))
        self.lbl_evict.setText(str(ev.get("evictions", "—")))

    def _on_token(self, ev: dict) -> None:
        piece = ev.get("piece", "")
        self.stream_text += piece
        self._append_stream_text(piece)
        self.gen_count += 1
        io_s = float(ev.get("io_s", 0) or 0)
        cmp_s = float(ev.get("cmp_s", 0) or 0)
        tot_s = float(ev.get("tot_s", 0) or 0)
        tok_s = float(ev.get("tok_s", 0) or 0)
        self.io_total += io_s
        self.cmp_total += cmp_s
        self.lbl_tok_s.setText(fmt_speed(tok_s))
        self.lbl_io.setText(f"{io_s:.3f} s")
        self.lbl_cmp.setText(f"{cmp_s:.3f} s")
        self.lbl_tot.setText(f"{tot_s:.3f} s")
        n_layer = int(ev.get("n_layer", 0) or 0)
        layer = int(ev.get("layer", -1) or -1)
        if n_layer > 0:
            self.bar_layer.setRange(0, n_layer)
            if layer >= 0:
                self.bar_layer.setValue(layer + 1)
                self.lbl_layer.setText(tr('当前层: L{0} / {1}（本 token 结束）').format(layer + 1, n_layer))
        self._add_token_row(ev)

    def _on_done(self, ev: dict) -> None:
        text = ev.get("text") or self.stream_text
        stop = ev.get("stop", "length")
        if stop == "cancelled" and text:
            text = text + tr('\n\n（已停止）')
        if text:
            self.messages.append({"role": "assistant", "content": text})
        # re-render with markdown now that the reply is complete
        self._render_conversation()
        self.stream_text = ""
        self.busy = False
        self.btn_send.setEnabled(True)
        self.btn_stop.setEnabled(False)
        self._set_status(tr('就绪'))
        n_gen = int(ev.get("tokens", 0) or 0)
        tot = float(ev.get("tot_s", 0) or 0)
        avg = float(ev.get("tok_s", 0) or 0)
        self.lbl_avg_s.setText(fmt_speed(avg))
        self.lbl_phase.setText(tr('阶段: 完成（{0} tokens，{1:.2f} s，stop={2}）').format(n_gen, tot, stop))
        self.bar_turn.setRange(0, max(1, n_gen))
        self.bar_turn.setValue(n_gen)
        self.lbl_ctx.setText(f"{ev.get('n_past', '?')} / {ev.get('n_ctx', '?')}")
        io_s = float(ev.get("io_s", 0) or 0)
        cmp_s = float(ev.get("cmp_s", 0) or 0)
        self._append_engine_note(
            tr('本轮: {0} tokens / {1:.2f} s（io {2:.2f} s + cmp {3:.2f} s，{4}）').format(n_gen, tot, io_s, cmp_s, fmt_speed(avg)))

    def _on_info(self, ev: dict) -> None:
        if ev.get("msg") == "prefix":
            self._append_engine_note(
                tr('前缀复用: common={0} prev={1} new={2} reused={3}（hybrid 模型不支持部分回收时会自动整段重算）').format(ev.get('common'), ev.get('prev'), ev.get('new'), ev.get('reused')))

    def _on_failure(self, msg: str) -> None:
        self.busy = False
        self.btn_send.setEnabled(True)
        self.btn_stop.setEnabled(False)
        self._set_status(tr('错误'))
        self.messages.append({"role": "system", "content": msg})
        self._render_conversation()
        self.pending_messages = None

    def _on_log(self, line: str) -> None:
        self.log_view.appendPlainText(line)

    # ------------------------------------------------------------- demo
    def load_demo(self) -> None:
        self.messages = [
            {"role": "user", "content": tr('用一句话介绍磁盘流式推理，并说明速度由什么决定。')},
            {"role": "assistant", "content":
                tr('**磁盘流式推理**把模型权重留在硬盘上，推理时按计算图节点把需要的张量读进一块固定大小的 RAM arena，用完按 LRU 换出，因此显存/内存装不下的模型也能跑。\n\n速度由磁盘带宽决定：每个 token 都要把模型读一遍，所以 `t/s ≈ 磁盘顺序读带宽 / 模型大小`；当 arena 能装下整个模型时，第一个 token 之后就和普通 llama.cpp 一样快。')},
        ]
        self._render_conversation()
        self.ready_info = {"model": "qwen35 0.8B Q6_K", "n_layer": 24, "n_ctx": 2048,
                           "arena_mib": 300, "direct_io": 1, "mlock": 0, "prefetch": 0,
                           "tensors": 320, "registered_mib": 590}
        self.bar_layer.setRange(0, 24)
        self.bar_layer.setValue(18)
        self.lbl_layer.setText(tr('当前层: L18 / 24'))
        self.lbl_phase.setText(tr('阶段: 生成（每 token 顺序读一遍模型）'))
        self.lbl_progress.setText(tr('回复: 42 / 256 tokens'))
        self.bar_turn.setRange(0, 256)
        self.bar_turn.setValue(42)
        self.lbl_tok_s.setText("2.95 tok/s")
        self.lbl_avg_s.setText("2.84 tok/s")
        self.lbl_prefill_speed.setText("6.21 tok/s")
        self.lbl_io.setText("0.298 s")
        self.lbl_cmp.setText("0.041 s")
        self.lbl_tot.setText("0.339 s")
        self.lbl_arena.setText("300 MiB")
        self.lbl_io_mode.setText("direct=1 mlock=0 prefetch=0")
        self.lbl_read.setText("15421 MiB")
        self.lbl_loads.setText("1138")
        self.lbl_evict.setText("842")
        self.lbl_ctx.setText("42 / 2048")
        self._set_status(tr('生成中…'))
        self.tok_table.setRowCount(0)
        demo_tokens = [
            (1, "The", 0.301, 0.038, 0.339, 23),
            (2, " capital", 0.296, 0.042, 0.338, 23),
            (3, " of", 0.299, 0.039, 0.338, 23),
            (4, " France", 0.303, 0.040, 0.343, 23),
            (5, " is", 0.297, 0.041, 0.338, 23),
            (6, " Paris", 0.300, 0.039, 0.339, 23),
        ]
        for n, piece, io_s, cmp_s, tot_s, layer in demo_tokens:
            self._add_token_row({"n": n, "piece": piece, "io_s": io_s, "cmp_s": cmp_s,
                                 "tot_s": tot_s, "layer": layer, "n_layer": 24,
                                 "tok_s": 1.0 / tot_s})
        self.log_view.setPlainText(
            tr('llama-disk: streaming weights from disk, arena = 300 MiB (requested), direct io = 1, mlock = 0, prefetch = 0 (lookahead 16)\n[对话] 预览数据（截图用）'))

    # ------------------------------------------------------------- token table
    def _add_token_row(self, ev: dict) -> None:
        row = self.tok_table.rowCount()
        if row >= 300:
            self.tok_table.removeRow(0)
            row = self.tok_table.rowCount()
        self.tok_table.insertRow(row)
        piece = str(ev.get("piece", ""))
        piece = piece.replace("\n", "⏎").replace("\r", "")
        speed = float(ev.get("tok_s", 0) or 0)
        speed_text = f"{speed:.4f}" if 0 < speed < 0.01 else f"{speed:.2f}"
        vals = [
            str(ev.get("n", row + 1)),
            piece if piece else " ",
            f"{float(ev.get('io_s', 0) or 0):.3f}",
            f"{float(ev.get('cmp_s', 0) or 0):.3f}",
            f"{float(ev.get('tot_s', 0) or 0):.3f}",
            str(ev.get("layer", "—")),
            speed_text,
        ]
        for c, text in enumerate(vals):
            item = QTableWidgetItem(text)
            if c in (2, 3):
                # highlighted io/cmp cells must keep the table's text color, otherwise
                # dark-on-dark (or white-on-white) happens in the other theme
                item.setBackground(QColor(self.t.table_hl))
                item.setForeground(self.tok_table.palette().color(QPalette.ColorRole.Text))
            self.tok_table.setItem(row, c, item)
        self.tok_table.scrollToBottom()

    def _append_engine_note(self, note: str) -> None:
        self.log_view.appendPlainText(note)

