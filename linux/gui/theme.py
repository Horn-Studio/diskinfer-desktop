"""Light/dark theme for the diskinfer workbench.

The GUI must look right on a Linux dark-mode desktop. Qt already applies a dark
palette to the standard widgets, but every color we hard-coded for the light theme
(chat pane background, bubbles, verdict cells, muted labels, ...) has to follow the
system scheme as well, otherwise we get white text on a white background.

Detection order:
  1. explicit override (`--theme dark|light` -> set_override)
  2. DISKINFER_THEME environment variable
  3. Qt 6.5+ QStyleHints.colorScheme()
  4. palette window lightness fallback (also for platforms that report Unknown)
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QGuiApplication, QPalette

_override: str | None = None


def set_override(name: str | None) -> None:
    """Force 'dark' / 'light' (None = automatic). Call before creating widgets."""
    global _override
    _override = name if name in ("dark", "light") else None


def is_dark() -> bool:
    override = _override or os.environ.get("DISKINFER_THEME", "").strip().lower()
    if override in ("dark", "light"):
        return override == "dark"
    try:
        scheme = QGuiApplication.styleHints().colorScheme()
        if scheme == Qt.ColorScheme.Dark:
            return True
        if scheme == Qt.ColorScheme.Light:
            return False
    except Exception:
        pass
    try:
        return QGuiApplication.palette().window().color().lightness() < 128
    except Exception:
        return False


@dataclass(frozen=True)
class Theme:
    dark: bool

    # chat pane
    chat_bg: str
    chat_text: str
    chat_border: str
    user_bg: str
    user_fg: str
    assistant_label: str
    system_text: str
    placeholder: str

    # generic
    muted: str
    accent: str
    table_hl: str

    # verdict colors (used by the status label and the result tables)
    pass_bg: str
    pass_fg: str
    warn_bg: str
    warn_fg: str
    fail_bg: str
    fail_fg: str
    run_bg: str
    run_fg: str
    neutral_bg: str
    neutral_fg: str


LIGHT = Theme(
    dark=False,
    chat_bg="#ffffff",
    chat_text="#1f2328",
    chat_border="#d6dae0",
    user_bg="#dbeafe",
    user_fg="#10233f",
    assistant_label="#1a3f8f",
    system_text="#8a6d00",
    placeholder="#8a8a8a",
    muted="#666666",
    accent="#1a3f8f",
    table_hl="#f2f7fb",
    pass_bg="#e6f7e6", pass_fg="#1b6e1b",
    warn_bg="#fff8e1", warn_fg="#8a6d00",
    fail_bg="#fdecea", fail_fg="#a61b1b",
    run_bg="#e8f0fe", run_fg="#1a3f8f",
    neutral_bg="#eeeeee", neutral_fg="#333333",
)

DARK = Theme(
    dark=True,
    chat_bg="#1e1f22",
    chat_text="#dcdcdc",
    chat_border="#3a3d42",
    user_bg="#2d4a6b",
    user_fg="#eaf2ff",
    assistant_label="#8ab4f8",
    system_text="#e0b04a",
    placeholder="#9aa0a6",
    muted="#a0a4a8",
    accent="#8ab4f8",
    table_hl="#2b2f36",
    pass_bg="#17351f", pass_fg="#7ee08a",
    warn_bg="#3a3117", warn_fg="#f0d060",
    fail_bg="#3d1d1c", fail_fg="#ff8a80",
    run_bg="#1e2b45", run_fg="#8ab4f8",
    neutral_bg="#2b2f36", neutral_fg="#d0d0d0",
)


def current() -> Theme:
    return DARK if is_dark() else LIGHT


def apply_palette(app) -> None:
    """Apply the palette to the whole application.

    In automatic mode Qt already themes the standard widgets from the system setting
    and this is a no-op. When the user forces --theme dark/light (also used for the
    documentation screenshots) the standard widgets have to follow along, otherwise
    a dark window would still contain light tables/edit boxes.
    """
    forced = (_override is not None
              or os.environ.get("DISKINFER_THEME", "").strip().lower() in ("dark", "light"))
    if not forced:
        return
    try:
        app.setStyle("Fusion")
    except Exception:
        pass
    if not is_dark():
        try:
            app.setPalette(app.style().standardPalette())
        except Exception:
            pass
        return

    c = lambda hexname: QColor(hexname)
    pal = QPalette()
    window = c("#2b2b2b")
    base = c("#1e1f22")
    text = c("#e6e6e6")
    dis = c("#7f7f7f")
    pal.setColor(QPalette.ColorRole.Window, window)
    pal.setColor(QPalette.ColorRole.WindowText, text)
    pal.setColor(QPalette.ColorRole.Base, base)
    pal.setColor(QPalette.ColorRole.AlternateBase, c("#262626"))
    pal.setColor(QPalette.ColorRole.ToolTipBase, c("#2b2b2b"))
    pal.setColor(QPalette.ColorRole.ToolTipText, text)
    pal.setColor(QPalette.ColorRole.Text, text)
    pal.setColor(QPalette.ColorRole.PlaceholderText, c("#9aa0a6"))
    pal.setColor(QPalette.ColorRole.Button, window)
    pal.setColor(QPalette.ColorRole.ButtonText, text)
    pal.setColor(QPalette.ColorRole.BrightText, c("#ff6b6b"))
    pal.setColor(QPalette.ColorRole.Light, c("#3a3d42"))
    pal.setColor(QPalette.ColorRole.Midlight, c("#33363b"))
    pal.setColor(QPalette.ColorRole.Mid, c("#2a2d31"))
    pal.setColor(QPalette.ColorRole.Dark, c("#1a1c1f"))
    pal.setColor(QPalette.ColorRole.Shadow, c("#101214"))
    pal.setColor(QPalette.ColorRole.Highlight, c("#2f6fbf"))
    pal.setColor(QPalette.ColorRole.HighlightedText, c("#ffffff"))
    pal.setColor(QPalette.ColorRole.Link, c("#8ab4f8"))
    for role in (QPalette.ColorRole.Text, QPalette.ColorRole.WindowText,
                 QPalette.ColorRole.ButtonText):
        pal.setColor(QPalette.ColorGroup.Disabled, role, dis)
    app.setPalette(pal)


def verdict_colors(theme: Theme, verdict: str) -> tuple[str, str]:
    """(background, foreground) for a PASS/WARN/FAIL/RUN/就绪 cell or label."""
    table = {
        "PASS": (theme.pass_bg, theme.pass_fg),
        "WARN": (theme.warn_bg, theme.warn_fg),
        "FAIL": (theme.fail_bg, theme.fail_fg),
        "ERROR": (theme.fail_bg, theme.fail_fg),
        "RUN": (theme.run_bg, theme.run_fg),
        "就绪": (theme.neutral_bg, theme.neutral_fg),
    }
    return table.get(verdict, (theme.neutral_bg, theme.neutral_fg))
