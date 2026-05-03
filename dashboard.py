#!/usr/bin/env python3
# mac-bridge — Agent Dashboard
# curses TUI — works reliably in any macOS terminal.
#
#   uv run dashboard.py            interactive full-screen TUI
#   uv run dashboard.py --status   print status table and exit

import argparse
import curses
import subprocess
import sys
import threading
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

PROJECT_DIR = Path(__file__).parent
LOG_DIR     = Path.home() / "Library" / "Logs" / "macOSMCP"
UV          = "/opt/homebrew/bin/uv"

# ── Color pair IDs ─────────────────────────────────────────────────────────────
_HEADER  = 1   # white on blue  (header bar)
_GREEN   = 2   # green
_RED     = 3   # red
_YELLOW  = 4   # yellow
_CYAN    = 5   # cyan
_MAGENTA = 6   # magenta
_SEL     = 7   # black on cyan  (confirm highlight)
_BLUE    = 8   # blue

# Per-agent colors indexed by AGENTS position
_AGENT_COLORS = [_CYAN, _GREEN, _YELLOW, _MAGENTA]

def _init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(_HEADER,  curses.COLOR_WHITE,   curses.COLOR_BLUE)
    curses.init_pair(_GREEN,   curses.COLOR_GREEN,   -1)
    curses.init_pair(_RED,     curses.COLOR_RED,     -1)
    curses.init_pair(_YELLOW,  curses.COLOR_YELLOW,  -1)
    curses.init_pair(_CYAN,    curses.COLOR_CYAN,    -1)
    curses.init_pair(_MAGENTA, curses.COLOR_MAGENTA, -1)
    curses.init_pair(_SEL,     curses.COLOR_BLACK,   curses.COLOR_CYAN)
    curses.init_pair(_BLUE,    curses.COLOR_BLUE,    -1)

def _cp(pair_id: int, bold: bool = False) -> int:
    attr = curses.color_pair(pair_id)
    if bold:
        attr |= curses.A_BOLD
    return attr

# ── Agent definitions ──────────────────────────────────────────────────────────

def _next_daily(n: datetime, h: int, m: int) -> datetime:
    t = n.replace(hour=h, minute=m, second=0, microsecond=0)
    return t if n < t else t + timedelta(days=1)

def _next_weekly(n: datetime, wd: int, h: int, m: int) -> datetime:
    t = n.replace(hour=h, minute=m, second=0, microsecond=0)
    d = (wd - n.weekday()) % 7
    if d == 0 and n >= t:
        d = 7
    return t + timedelta(days=d)

def _next_multi(n: datetime, slots: list) -> datetime:
    for h, m in sorted(slots):
        t = n.replace(hour=h, minute=m, second=0, microsecond=0)
        if n < t:
            return t
    h, m = sorted(slots)[0]
    return n.replace(hour=h, minute=m, second=0, microsecond=0) + timedelta(days=1)

def _next_weekdays(n: datetime, h: int, m: int) -> datetime:
    t = n.replace(hour=h, minute=m, second=0, microsecond=0)
    if n.weekday() < 5 and n < t:
        return t
    for d in range(1, 8):
        c = n + timedelta(days=d)
        if c.weekday() < 5:
            return c.replace(hour=h, minute=m, second=0, microsecond=0)
    return t

AGENTS = [
    {
        "key": "1", "name": "Morning Briefing", "tag": "Morning",
        "emoji": ">>", "label": "com.thedubes.morning-briefing",
        "script": "agents/morning_briefing.py", "log": "morning_briefing.log",
        "sched": "7:00 AM  daily", "model": "haiku-4-5",
        "next_fn": lambda n: _next_daily(n, 7, 0),
    },
    {
        "key": "2", "name": "Weekly Review", "tag": "Weekly",
        "emoji": "**", "label": "com.thedubes.weekly-review",
        "script": "agents/weekly_review.py", "log": "weekly_review.log",
        "sched": "5:00 PM  Sunday", "model": "sonnet-4-6",
        "next_fn": lambda n: _next_weekly(n, 6, 17, 0),
    },
    {
        "key": "3", "name": "Priority Alert", "tag": "Priority",
        "emoji": "!!", "label": "com.thedubes.priority-alert",
        "script": "agents/priority_alert.py", "log": "priority_alert.log",
        "sched": "11:30 AM + 4:30 PM", "model": "haiku-4-5",
        "next_fn": lambda n: _next_multi(n, [(11, 30), (16, 30)]),
    },
    {
        "key": "4", "name": "Evening Prep", "tag": "Evening",
        "emoji": "~~", "label": "com.thedubes.evening-prep",
        "script": "agents/evening_prep.py", "log": "evening_prep.log",
        "sched": "6:00 PM  Mon-Fri", "model": "haiku-4-5",
        "next_fn": lambda n: _next_weekdays(n, 18, 0),
    },
]

# ── System status ──────────────────────────────────────────────────────────────

def _loaded_labels() -> set:
    r = subprocess.run(["launchctl", "list"], capture_output=True, text=True)
    return {ln.split()[-1] for ln in r.stdout.splitlines() if "thedubes" in ln}

def _key_ok() -> bool:
    r = subprocess.run(
        ["security", "find-generic-password", "-s", "mac-bridge",
         "-a", "ANTHROPIC_API_KEY", "-w"],
        capture_output=True, text=True,
    )
    return r.returncode == 0 and bool(r.stdout.strip())

def _last_run(log: str) -> Optional[datetime]:
    p = LOG_DIR / log
    if not p.exists():
        return None
    try:
        for line in reversed(p.read_text().splitlines()):
            if "Starting" in line and len(line) > 19:
                try:
                    return datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    pass
    except OSError:
        pass
    return None

def _countdown(dt: datetime) -> str:
    s = (dt - datetime.now()).total_seconds()
    if s < 0:
        return "now"
    if s < 3600:
        return f"{int(s // 60)}m"
    return f"{int(s // 3600)}h {int((s % 3600) // 60)}m"

def _fmt_last(dt: Optional[datetime]) -> str:
    if dt is None:
        return "—"
    now = datetime.now()
    if dt.date() == now.date():
        return f"Today {dt.strftime('%-I:%M %p')}"
    if dt.date() == (now - timedelta(days=1)).date():
        return f"Yesterday {dt.strftime('%-I:%M %p')}"
    return dt.strftime("%b %-d  %-I:%M %p")

# ── Dashboard state ────────────────────────────────────────────────────────────

class _State:
    def __init__(self):
        self.output: deque = deque(maxlen=200)
        self.running       = False
        self.run_name      = ""
        self.run_mode      = ""
        self.mode          = "normal"   # normal | confirm | log
        self.confirm_idx   = None       # int 0-3 or -1 (uninstall)
        self.status_msg    = ""
        self.loaded: set   = set()
        self.key_ok        = False
        self.log_idx       = 0          # which agent log is displayed
        self.log_scroll    = 0          # lines scrolled up from bottom (0 = auto-follow)
        self._lock         = threading.Lock()

    def push(self, line: str):
        with self._lock:
            self.output.append(line)

    def get_output(self) -> list:
        with self._lock:
            return list(self.output)

    def clear_output(self):
        with self._lock:
            self.output.clear()

    def refresh(self):
        self.loaded  = _loaded_labels()
        self.key_ok  = _key_ok()

S = _State()

# ── Subprocess streaming ───────────────────────────────────────────────────────

_SKIP = ("╭","╰","│","▄","▀","FastMCP","gofastmcp","Update available",
         "pip install", "fastmcp.cloud", "🚀", "🖥")

def _stream(cmd: list, label: str):
    S.running = True
    S.clear_output()
    S.push(f">> {label}")
    S.push("=" * 60)
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,   # never read from terminal
            text=True,
            bufsize=1,
        )
        for raw in proc.stdout:
            line = raw.rstrip()
            if any(x in line for x in _SKIP):
                continue
            S.push(line)
        proc.wait()
        S.push("=" * 60)
        if proc.returncode == 0:
            S.push("DONE (ok)  —  press 1-4 to run again or q to quit")
        else:
            S.push(f"FAILED exit={proc.returncode}")
        S.status_msg = f"Finished: {label[:40]}"
    except Exception as e:
        S.push(f"ERROR: {e}")
    finally:
        S.running = False

def _run_agent(agent: dict, dry_run: bool):
    if S.running:
        S.status_msg = "Already running — wait for it to finish"
        return
    S.run_name = agent["name"]
    S.run_mode = "dry-run" if dry_run else "LIVE"
    mode_str   = "dry-run" if dry_run else "LIVE — sends email + iMessage"
    label      = f"{agent['name']}  ({mode_str})"
    cmd        = [UV, "run", "--directory", str(PROJECT_DIR),
                  "--extra", "agent", agent["script"]]
    if dry_run:
        cmd.append("--dry-run")
    threading.Thread(target=_stream, args=(cmd, label), daemon=True).start()

def _run_install(extra: list = []):
    if S.running:
        S.status_msg = "Already running"
        return
    S.run_name = "Installer"
    S.run_mode = " ".join(extra) or "full install"
    cmd = [UV, "run", "--directory", str(PROJECT_DIR),
           "install.py", "--skip-dry-run"] + extra
    threading.Thread(target=_stream, args=(cmd, f"install.py {' '.join(extra)}"), daemon=True).start()

def _run_uninstall():
    if S.running:
        return
    S.run_name = "Uninstall"
    S.run_mode = ""
    cmd = [UV, "run", "--directory", str(PROJECT_DIR), "install.py", "--uninstall"]
    threading.Thread(target=_stream, args=(cmd, "Uninstall all agents"), daemon=True).start()

# (keyboard input handled directly by curses.getch — no separate thread needed)

# ── curses drawing helpers ─────────────────────────────────────────────────────

def _read_log(agent_idx: int) -> list[str]:
    """Return all lines of an agent's log file, newest last."""
    path = LOG_DIR / AGENTS[agent_idx]["log"]
    if not path.exists():
        return [f"  No log file yet: {path}"]
    try:
        return path.read_text(errors="replace").splitlines()
    except OSError as e:
        return [f"  Cannot read log: {e}"]


def _log_line_attr(line: str) -> int:
    """Return curses attribute for a log line based on its content."""
    u = line.upper()
    if "ERROR" in u or "FAILED" in u or "EXCEPTION" in u or "TRACEBACK" in u:
        return _cp(_RED, bold=True)
    if "WARNING" in u or "WARN" in u:
        return _cp(_YELLOW)
    if "DONE" in u or "SENT" in u or "SUCCESS" in u:
        return _cp(_GREEN, bold=True)
    if "STARTING" in u or "LOADED" in u or "CLAUDE CALL" in u:
        return _cp(_CYAN)
    if "TOOL:" in u or "TOOL " in u:
        return _cp(_MAGENTA)
    if "INFO" in line[:30]:
        return 0
    if line.startswith("20"):      # timestamp line
        return curses.A_DIM
    return 0


def _safe_addstr(win, row: int, col: int, text: str, attr: int = 0):
    """addstr that clips to window bounds and never raises."""
    h, w = win.getmaxyx()
    if row < 0 or row >= h or col >= w:
        return
    if col < 0:
        text = text[-col:]
        col  = 0
    text = text[:max(0, w - col - 1)]  # leave 1 col margin
    if text:
        try:
            win.addstr(row, col, text, attr)
        except curses.error:
            pass

def _hline(win, row: int, char: str = "─"):
    _, w = win.getmaxyx()
    _safe_addstr(win, row, 0, char * (w - 1))

# ── Main curses drawing ────────────────────────────────────────────────────────

def _draw(scr):
    scr.erase()
    h, w = scr.getmaxyx()
    now  = datetime.now()

    # ── Row 0: Header ──────────────────────────────────────────────────────────
    header_bg = _cp(_HEADER, bold=True)
    scr.bkgdset(" ", header_bg)
    _safe_addstr(scr, 0, 0, " " * (w - 1), header_bg)
    key_str   = "KEY: ok" if S.key_ok else "KEY: MISSING — press i"
    time_str  = now.strftime("%a %b %-d  %-I:%M:%S %p")
    title     = "  mac-bridge Agent Dashboard"
    mid       = f"{time_str}   {key_str}  "
    _safe_addstr(scr, 0, 0,             title,  header_bg)
    _safe_addstr(scr, 0, w - len(mid),  mid,    header_bg)
    scr.bkgdset(" ", 0)

    # ── Row 1: divider ─────────────────────────────────────────────────────────
    _hline(scr, 1)

    # ── Rows 2-7: Agent table ──────────────────────────────────────────────────
    COL = [0, 4, 26, 47, 62, 75, 98]   # column offsets: #, name, sched, model, status, last, next
    headers = ["#", "Agent", "Schedule", "Model", "Launchd", "Last Run", "Next"]
    header_attr = _cp(_CYAN, bold=True)
    for i, (off, hdr) in enumerate(zip(COL, headers)):
        _safe_addstr(scr, 2, off, hdr, header_attr)
    _hline(scr, 3, "─")

    for idx, a in enumerate(AGENTS):
        row   = 4 + idx
        color = _AGENT_COLORS[idx]
        loaded = a["label"] in S.loaded
        last   = _last_run(a["log"])
        nxt    = a["next_fn"](now)
        is_running = S.running and S.run_name == a["name"]
        is_confirm = S.mode == "confirm" and S.confirm_idx == idx

        row_attr = _cp(_SEL) if is_confirm else (curses.A_REVERSE if is_running else 0)

        # background fill for selected/running rows
        if row_attr:
            _safe_addstr(scr, row, 0, " " * (w - 1), row_attr)

        _safe_addstr(scr, row, COL[0], f" {a['key']}", _cp(color, bold=True) | (curses.A_REVERSE if is_confirm else 0))
        _safe_addstr(scr, row, COL[1], f"{a['tag']: <18}", _cp(color, bold=True))
        _safe_addstr(scr, row, COL[2], f"{a['sched']: <18}", curses.A_DIM)
        _safe_addstr(scr, row, COL[3], f"{a['model']: <12}", _cp(_CYAN))
        if loaded:
            _safe_addstr(scr, row, COL[4], " loaded  ", _cp(_GREEN, bold=True))
        else:
            _safe_addstr(scr, row, COL[4], " UNLOADED", _cp(_RED,   bold=True))
        _safe_addstr(scr, row, COL[5], f"{_fmt_last(last): <22}", _cp(_GREEN) if last and last.date() == now.date() else curses.A_DIM)
        _safe_addstr(scr, row, COL[6], _countdown(nxt), _cp(color, bold=True))

    _hline(scr, 8)

    # ── Row 9: Next fire bar ───────────────────────────────────────────────────
    nexts  = sorted(AGENTS, key=lambda a: a["next_fn"](now))
    soonest = nexts[0]
    nxt_dt  = soonest["next_fn"](now)
    sc      = _AGENT_COLORS[AGENTS.index(soonest)]
    t9 = f"  Next: {soonest['tag']} fires in {_countdown(nxt_dt)}  ({nxt_dt.strftime('%-I:%M %p')})    "
    for a2 in nexts[1:]:
        t9 += f"  {a2['tag']}: {_countdown(a2['next_fn'](now))}"
    _safe_addstr(scr, 9, 0, t9[:w-1], _cp(sc))

    _hline(scr, 10)

    # ── Row 11: Action / confirm / log-mode bar ───────────────────────────────
    if S.mode == "log":
        a      = AGENTS[S.log_idx]
        color  = _AGENT_COLORS[S.log_idx]
        scroll = S.log_scroll
        scroll_str = f"  scroll:{scroll} lines up" if scroll else "  auto-follow"
        bar = f"  Log: {a['name']}{scroll_str}   "
        _safe_addstr(scr, 11, 0, bar[:w//2], _cp(color, bold=True))
        log_keys = [
            ("[1-4]", "switch log"), ("[↑↓]", "scroll"), ("[PgUp/Dn]", "page"),
            ("[b]", "bottom"), ("[ESC]", "back"),
        ]
        col11 = w // 2
        for k, label in log_keys:
            if col11 + len(k) + len(label) + 3 >= w - 1:
                break
            _safe_addstr(scr, 11, col11, k, _cp(_YELLOW, bold=True))
            col11 += len(k)
            _safe_addstr(scr, 11, col11, f" {label}  ", curses.A_DIM)
            col11 += len(label) + 3
    elif S.mode == "confirm" and S.confirm_idx is not None:
        if S.confirm_idx == -1:
            msg = "  Uninstall all agents?  [y] confirm   [ESC] cancel"
        else:
            a   = AGENTS[S.confirm_idx]
            msg = f"  Run {a['name']}?   [d] dry-run (safe)   [r] REAL run (sends email+iMessage)   [l] view log   [ESC] cancel"
        _safe_addstr(scr, 11, 0, msg[:w-1], _cp(_SEL, bold=True))
    else:
        keys = [
            ("[1-4]", "Run agent"), ("[l]", "Logs"), ("[i]", "Install"),
            ("[u]", "Uninstall"), ("[k]", "Refresh key"), ("[s]", "Refresh"), ("[q]", "Quit"),
        ]
        col11 = 2
        for k, label in keys:
            if col11 + len(k) + len(label) + 3 >= w - 1:
                break
            _safe_addstr(scr, 11, col11, k, _cp(_YELLOW, bold=True))
            col11 += len(k)
            _safe_addstr(scr, 11, col11, f" {label}   ", curses.A_DIM)
            col11 += len(label) + 4

    _hline(scr, 12)

    panel_start = 13
    panel_end   = h - 2

    if S.mode == "log":
        # ── Log viewer ────────────────────────────────────────────────────────
        a       = AGENTS[S.log_idx]
        color   = _AGENT_COLORS[S.log_idx]
        lines   = _read_log(S.log_idx)
        total   = len(lines)
        height  = max(0, panel_end - panel_start - 1)  # -1 for title row

        # Clamp scroll
        S.log_scroll = max(0, min(S.log_scroll, max(0, total - height)))

        # Title row
        path_str = str(LOG_DIR / a["log"])
        auto_str = "" if S.log_scroll else "  [auto]"
        title    = f"  {a['name']} log  —  {path_str}{auto_str}  ({total} lines)"
        _safe_addstr(scr, panel_start, 0, title[:w-1], _cp(color, bold=True))

        # Visible slice: from (total - height - scroll) to (total - scroll)
        bottom = total - S.log_scroll
        top    = max(0, bottom - height)
        visible = lines[top:bottom]

        for i, line in enumerate(visible):
            row = panel_start + 1 + i
            if row >= panel_end:
                break
            # Strip log prefix for cleaner display: "2026-05-03 07:45:22,957 INFO     "
            display = line
            attr    = _log_line_attr(line)
            # Dim the timestamp prefix (first 24 chars if it looks like a timestamp)
            if len(line) > 24 and line[:4].isdigit() and "-" in line[4:7]:
                _safe_addstr(scr, row, 2, line[:23], curses.A_DIM)
                _safe_addstr(scr, row, 25, line[23:w-3], attr)
            else:
                _safe_addstr(scr, row, 2, display[:w-3], attr)

        # Scroll indicator (bottom-right)
        if total > height:
            pct = int(100 * bottom / total) if total else 100
            ind = f" {pct}% ({bottom}/{total}) "
            _safe_addstr(scr, panel_end - 1, w - len(ind) - 1, ind, curses.A_DIM)

    else:
        # ── Run output panel ──────────────────────────────────────────────────
        if S.running:
            out_title = f"  >> Running: {S.run_name}  [{S.run_mode}] ..."
            _safe_addstr(scr, panel_start, 0, out_title[:w-1], _cp(_CYAN, bold=True))
        elif S.run_name:
            out_title = f"  Last: {S.run_name}  [{S.run_mode}]  — press [l] to view full log"
            _safe_addstr(scr, panel_start, 0, out_title[:w-1], curses.A_DIM)
        else:
            _safe_addstr(scr, panel_start, 0,
                         "  Output — press [1-4] to run an agent  |  [l] view logs",
                         curses.A_DIM)

        out_start  = panel_start + 1
        out_height = max(0, panel_end - out_start)
        lines      = S.get_output()
        visible    = lines[-out_height:] if out_height else []

        for i, line in enumerate(visible):
            row = out_start + i
            if row >= panel_end:
                break
            if "==" in line or ">>" in line:
                attr = _cp(_CYAN, bold=True)
            elif "DONE" in line:
                attr = _cp(_GREEN, bold=True)
            elif "FAILED" in line or "ERROR" in line or "error" in line.lower():
                attr = _cp(_RED, bold=True)
            elif "WARNING" in line.upper():
                attr = _cp(_YELLOW)
            elif "PREVIEW" in line:
                attr = _cp(_MAGENTA, bold=True)
            elif line.startswith("  "):
                attr = curses.A_DIM
            else:
                attr = 0
            _safe_addstr(scr, row, 2, line[:w-3], attr)

    # ── Bottom status bar (h-1) ────────────────────────────────────────────────
    _hline(scr, h - 2)
    if S.status_msg:
        status_text = f"  {S.status_msg}"
        S.status_msg = ""
    else:
        status_text = (
            f"  mac-bridge v0.6.0   "
            f"logs: ~/Library/Logs/macOSMCP/   "
            f"state: ~/.mac-bridge/agent_state.json"
        )
    _safe_addstr(scr, h - 1, 0, status_text[:w-1], curses.A_DIM)

    scr.refresh()

# ── Key handler ────────────────────────────────────────────────────────────────

# Map curses key codes → single-char strings the handler understands
_KEY_MAP = {
    ord("q"): "q",  ord("Q"): "q",
    ord("1"): "1",  ord("2"): "2",  ord("3"): "3",  ord("4"): "4",
    ord("d"): "d",  ord("D"): "d",
    ord("r"): "r",  ord("R"): "r",
    ord("i"): "i",  ord("I"): "i",
    ord("u"): "u",  ord("U"): "u",
    ord("k"): "k",  ord("K"): "k",
    ord("l"): "l",  ord("L"): "l",
    ord("b"): "b",  ord("B"): "b",   # jump to bottom in log view
    ord("s"): "s",  ord("S"): "s",
    ord("y"): "y",  ord("Y"): "y",
    ord("n"): "n",  ord("N"): "n",
    3:              "q",   # Ctrl-C
    27:             "ESC",
    curses.KEY_UP:    "UP",
    curses.KEY_DOWN:  "DOWN",
    curses.KEY_PPAGE: "PGUP",   # Page Up
    curses.KEY_NPAGE: "PGDN",   # Page Down
    curses.KEY_HOME:  "HOME",
    curses.KEY_END:   "END",
}


def _handle(ch: str, scr_height: int = 24) -> bool:
    """Process a key. Returns True to quit."""
    if S.running and ch not in ("q",):
        return False

    # ── Log viewer mode ────────────────────────────────────────────────────────
    if S.mode == "log":
        page = max(1, scr_height - 16)   # visible lines in the log panel
        if ch in ("ESC", "q"):
            S.mode = "normal"
        elif ch in "1234":
            S.log_idx    = int(ch) - 1
            S.log_scroll = 0              # reset to auto-follow on switch
        elif ch == "UP":
            S.log_scroll += 1
        elif ch == "DOWN":
            S.log_scroll = max(0, S.log_scroll - 1)
        elif ch == "PGUP":
            S.log_scroll += page
        elif ch == "PGDN":
            S.log_scroll = max(0, S.log_scroll - page)
        elif ch in ("b", "END"):
            S.log_scroll = 0              # jump to bottom / auto-follow
        elif ch == "HOME":
            lines = _read_log(S.log_idx)
            S.log_scroll = max(0, len(lines) - page)
        return False

    # ── Normal mode ────────────────────────────────────────────────────────────
    if S.mode == "normal":
        if ch == "q":
            return True
        elif ch in "1234":
            S.confirm_idx = int(ch) - 1
            S.mode = "confirm"
        elif ch == "l":
            # Open log viewer for the most recently run agent, or agent 0
            if S.run_name:
                names = [a["name"] for a in AGENTS]
                S.log_idx = names.index(S.run_name) if S.run_name in names else 0
            S.log_scroll = 0
            S.mode = "log"
        elif ch == "i":
            _run_install()
        elif ch == "u":
            S.confirm_idx = -1
            S.mode = "confirm"
        elif ch == "k":
            _run_install(["--refresh-key"])
        elif ch == "s":
            S.refresh()
            S.status_msg = "Status refreshed"

    # ── Confirm mode ───────────────────────────────────────────────────────────
    elif S.mode == "confirm":
        if ch == "ESC":
            S.mode = "normal"
            S.confirm_idx = None
            S.status_msg = ""
        elif S.confirm_idx == -1:
            if ch == "y":
                _run_uninstall()
            else:
                S.status_msg = "Uninstall cancelled"
            S.mode = "normal"
        elif ch == "d":
            _run_agent(AGENTS[S.confirm_idx], dry_run=True)
            S.mode = "normal"
        elif ch == "r":
            _run_agent(AGENTS[S.confirm_idx], dry_run=False)
            S.mode = "normal"
        elif ch == "l":
            S.log_idx    = S.confirm_idx
            S.log_scroll = 0
            S.mode       = "log"
        elif ch in "1234":
            S.confirm_idx = int(ch) - 1

    return False


# ── Interactive entry point ────────────────────────────────────────────────────

def run_interactive():
    S.refresh()

    def _main(scr):
        _init_colors()
        curses.curs_set(0)
        last_sys = datetime.now()

        while True:
            _draw(scr)

            # Block up to 200ms waiting for a key (acts as our frame timer).
            # Faster refresh while agent is streaming output.
            scr.timeout(100 if S.running else 200)
            c = scr.getch()

            h, _ = scr.getmaxyx()
            ch = _KEY_MAP.get(c)
            if ch and _handle(ch, scr_height=h):
                break

            # KEY_RESIZE: just redraw (no action needed)

            now = datetime.now()
            if (now - last_sys).total_seconds() >= 10:
                S.refresh()
                last_sys = now

    curses.wrapper(_main)

# ── Static status mode ─────────────────────────────────────────────────────────

def run_status():
    """Print a plain-text status table (no curses, no TTY needed)."""
    try:
        from rich import box
        from rich.console import Console
        from rich.table import Table
        from rich.text import Text

        con = Console()
        S.refresh()
        now = datetime.now()

        tbl = Table(title="[bold cyan]mac-bridge Agent Status[/]",
                    box=box.ROUNDED, border_style="blue",
                    header_style="bold cyan", padding=(0, 1))
        tbl.add_column("#",        width=3,  justify="center")
        tbl.add_column("Agent",    min_width=22)
        tbl.add_column("Schedule", min_width=20)
        tbl.add_column("Launchd",  min_width=11, justify="center")
        tbl.add_column("Last Run", min_width=20)
        tbl.add_column("Next",     min_width=10, justify="right")

        colors = ["cyan", "green", "yellow", "magenta"]
        for idx, a in enumerate(AGENTS):
            c      = colors[idx]
            loaded = a["label"] in S.loaded
            last   = _last_run(a["log"])
            nxt    = a["next_fn"](now)
            tbl.add_row(
                Text(f" {a['key']}", style=f"bold {c}"),
                Text(f"{a['name']}",  style=f"bold {c}"),
                Text(f"  {a['sched']}", style="dim"),
                Text("  loaded",   style="green") if loaded else Text("  UNLOADED", style="bold red"),
                Text(_fmt_last(last), style="green" if last and last.date() == now.date() else "dim"),
                Text(_countdown(nxt), style=f"bold {c}"),
            )

        con.print()
        con.print(tbl)
        key_str = "[bold green]  API key in Keychain[/]" if S.key_ok else "[bold red]  No API key — run: uv run install.py[/]"
        con.print(key_str)
        con.print(f"  [dim]Logs:  {LOG_DIR}[/]\n")

    except ImportError:
        # Fallback plain text
        S.refresh()
        now = datetime.now()
        print("\nmac-bridge Agent Status")
        print("-" * 60)
        for a in AGENTS:
            loaded = "loaded" if a["label"] in S.loaded else "UNLOADED"
            print(f"  [{a['key']}] {a['name']:<22} {a['sched']:<20} {loaded:<10} next:{_countdown(a['next_fn'](now))}")
        print(f"\n  Key: {'ok' if S.key_ok else 'MISSING'}")
        print()

# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="mac-bridge Agent Dashboard")
    p.add_argument("--status", action="store_true", help="Print status and exit")
    args = p.parse_args()

    if args.status or not sys.stdout.isatty():
        run_status()
    else:
        run_interactive()

if __name__ == "__main__":
    main()
