#!/usr/bin/env python3
# mac-bridge — Daily Briefing Agent
# Author: Todd Dube | March 2026

"""
Daily briefing agent — pulls calendar, reminders, and unread mail via MCP,
generates a professional HTML summary with Ollama (qwen2.5:7b), emails it
via Mail.app, and sends a detailed iMessage nudge.

Run manually:
    uv run --extra agent scheduled_agent.py
    uv run --extra agent scheduled_agent.py --dry-run   # prints HTML + iMessage preview, no send

Scheduled via launchd (see specs.md for plist).

Required:
    Ollama running locally with qwen2.5:7b pulled
        brew services start ollama
        ollama pull qwen2.5:7b

Optional env vars:
    OLLAMA_HOST         — default http://localhost:11434
    OLLAMA_MODEL        — default qwen2.5:7b
    IMESSAGE_RECIPIENT  — phone (+1XXXXXXXXXX) or Apple ID email for push alert
    MAIL_COUNT          — unread emails to include in briefing (default: 20, set 0 to disable)
    MAIL_MAILBOX        — mailbox to read (default: all inbox-type mailboxes)
"""

import argparse
import asyncio
import email.mime.multipart
import email.mime.text
import json
import logging
import os
import re
import subprocess
import tempfile
from datetime import date, timedelta

from ollama import chat as ollama_chat
from fastmcp import Client

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.expanduser("~/Library/Logs/macOSMCP")

RECIPIENT_EMAIL = "todd@thedubes.com"
IMESSAGE_RECIPIENT = os.environ.get("IMESSAGE_RECIPIENT", "+18044328850")

# ---------------------------------------------------------------------------
# Ollama configuration (local LLM — zero cost, fully private)
#
# OLLAMA_MODEL env var selects the model. Options (best to fastest):
#   qwen2.5:7b       — default; best structured HTML output (~4.7 GB)
#   qwen3-fast:latest — faster; thinking model — <think> tags stripped below
#   llama3.1:8b      — good general purpose (~4.9 GB)
#   llama3.2:3b      — fastest; acceptable quality (~2 GB)
#
# OLLAMA_HOST env var sets the server URL (default: http://localhost:11434).
# Set in launchd plist EnvironmentVariables when running under launchd so
# the daemon can locate the Ollama server started by `brew services start ollama`.
# ---------------------------------------------------------------------------
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")

# ---------------------------------------------------------------------------
# Mail configuration
#
# MAIL_COUNT: number of unread emails to include in the briefing (default 20).
# Set to 0 to disable mail entirely (e.g. if Mail.app permission not granted).
# MAIL_MAILBOX: restrict to a specific mailbox name (e.g. "INBOX").
#               Omit to query all inbox-type mailboxes across all accounts.
# ---------------------------------------------------------------------------
MAIL_COUNT = int(os.environ.get("MAIL_COUNT", "20"))
MAIL_MAILBOX = os.environ.get("MAIL_MAILBOX", "")  # empty = all inboxes

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "scheduled_agent.log"),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

# Also log to stderr so dry-run output is visible
_console = logging.StreamHandler()
_console.setLevel(logging.INFO)
log.addHandler(_console)

MCP_CONFIG = {
    "mcpServers": {
        "mac-bridge": {
            "command": "uv",
            "args": ["--directory", PROJECT_DIR, "run", "server.py"],
        }
    }
}

TODAY = date.today()
END = TODAY + timedelta(days=7)

SUMMARY_PROMPT = """\
Today is {today}. Generate a professional daily briefing HTML email.

## Data

### Calendar Events ({today} → {end})
{events_json}

### Overdue Reminders
{overdue_json}

### Upcoming Reminders (next 7 days)
{upcoming_json}

### Unread / Follow-up Emails
{mail_json}

## HTML Design Specification

Produce a complete HTML email body fragment using ONLY inline CSS (no <style> tags, no external resources).
Use <table> for layout — NOT flexbox or grid (email client compatibility).

### Color palette (use these exact hex values):
- Background: #f4f6f9
- Card background: #ffffff
- Header gradient: background-color #1a3a5c (dark navy)
- Today section accent: #1a73e8 (blue)
- This Week accent: #0f5132 border, #d1e7dd background
- Overdue accent: #842029 border, #f8d7da background
- Upcoming accent: #664d03 border, #fff3cd background
- Divider: #dee2e6
- Body text: #212529
- Muted text: #6c757d
- Priority HIGH badge: background #dc3545, color white
- Priority MEDIUM badge: background #fd7e14, color white
- Priority LOW badge: background #ffc107, color #212529
- Conflict highlight: background #fff3cd, left border 4px solid #ffc107
- Email Follow-up accent: #4a1d96 border, #ede9fe background, badge background #7c3aed

### Structure:

**1. Header** — full-width dark navy bar:
<table width="100%" cellpadding="0" cellspacing="0"><tr><td style="background-color:#1a3a5c;padding:24px 32px;">
  <h1 style="color:#ffffff;margin:0;font-size:22px;font-family:Arial,sans-serif;">Daily Briefing</h1>
  <p style="color:#93b8d8;margin:4px 0 0;font-size:14px;font-family:Arial,sans-serif;">{today_long}</p>
</td></tr></table>

**2. Wrapper** — light grey background, max-width 640px centered:
<table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f6f9;">
  <tr><td style="padding:24px 16px;">

**3. Today's Schedule card** (blue left border, 4px):
- Section heading: "Today's Schedule" in #1a73e8
- Table with columns: TIME | EVENT | CALENDAR
  - Time column width: 90px, bold, #1a73e8
  - All-day events: show "All Day" in grey
  - Overlapping events: wrap row in conflict highlight style
- If empty: "Nothing scheduled today" in muted text

**4. This Week card** (green accent):
- Section heading: "This Week"
- Group events by day. Each day: bold date header row (#0f5132), then event rows
- Same TIME | EVENT | CALENDAR column structure
- If empty: "No upcoming events this week"

**5. Overdue Reminders card** (red accent):
- Section heading: "Overdue" with count badge (red circle)
- Each reminder row: priority badge | title | list name | days overdue (muted)
- Sort: high → medium → low → none
- If empty: green checkmark "All caught up — nothing overdue"

**6. Upcoming Reminders card** (yellow/amber accent):
- Section heading: "Due This Week" with count badge
- Group by due date. Each reminder: priority badge | title | list name
- If empty: "No reminders due this week"

**7. Email Follow-up card** (purple accent: #4a1d96 border, #ede9fe background):
- Section heading: "Email Follow-up" with unread count badge (purple)
- Each row: sender (bold, truncated to 24 chars) | subject | time received (muted)
- Flag time-sensitive items: if subject contains words like "urgent", "action required",
  "deadline", "invoice", "payment", "reminder" → add a small red "!" badge before subject
- If mail data is empty or disabled: omit this section entirely (do not show placeholder)

**8. Footer** — muted, centered:
Generated by mac-bridge · {today}

### Rules:
- All font-family values: Arial, Helvetica, sans-serif
- Card style: border-radius:8px; border:1px solid #dee2e6; margin-bottom:20px; overflow:hidden
- Card header row: padding:12px 16px; font-weight:bold; font-size:15px
- Data rows: padding:10px 16px; border-top:1px solid #dee2e6
- Priority badges: display:inline-block; padding:2px 8px; border-radius:12px; font-size:11px; font-weight:bold
- Show "Nothing scheduled" / "Nothing overdue" / "Nothing due" placeholders — never omit a section
- Return ONLY the HTML body fragment — no <html>/<head>/<body> wrappers, no markdown fences
"""


async def fetch_data() -> tuple[dict, dict, dict, dict]:
    """Fetch calendar, reminders, and unread mail via MCP.

    Returns four structured dicts via CallToolResult.structured_content.
    Mail fetch is skipped (returns {}) when MAIL_COUNT=0.
    """
    async with Client(MCP_CONFIG) as client:
        events_result = await client.call_tool("get_calendar_events", {
            "start_date": TODAY.isoformat(),
            "end_date": END.isoformat(),
            "limit": 100,
        })
        overdue_result = await client.call_tool("get_overdue_reminders", {"limit": 50})
        upcoming_result = await client.call_tool("get_upcoming_reminders", {
            "days": 7, "limit": 50,
        })

        # Mail: controlled by MAIL_COUNT env var (set to 0 to disable)
        if MAIL_COUNT > 0:
            mail_args: dict = {"count": MAIL_COUNT}
            if MAIL_MAILBOX:
                mail_args["mailbox"] = MAIL_MAILBOX
            mail_result = await client.call_tool("get_unread_emails", mail_args)
            mail = mail_result.structured_content or {}
        else:
            mail = {}

    events = events_result.structured_content or {}
    overdue = overdue_result.structured_content or {}
    upcoming = upcoming_result.structured_content or {}
    return events, overdue, upcoming, mail


def generate_summary(events: dict, overdue: dict, upcoming: dict, mail: dict) -> str:
    """Send structured data to local Ollama and get back an HTML briefing.

    Converts dicts to indented JSON for the prompt so Ollama sees clean,
    readable input rather than a Python repr string.
    Mail section is omitted from the prompt when mail dict is empty (disabled).
    """
    today_long = TODAY.strftime("%A, %B %-d, %Y")  # e.g. "Saturday, April 5, 2026"
    # Pass an explicit note when mail is disabled so the model skips that section
    mail_json = json.dumps(mail, indent=2) if mail else '{"note": "mail disabled — omit Email Follow-up section"}'
    prompt = SUMMARY_PROMPT.format(
        today=TODAY.isoformat(),
        today_long=today_long,
        end=END.isoformat(),
        events_json=json.dumps(events, indent=2),
        overdue_json=json.dumps(overdue, indent=2),
        upcoming_json=json.dumps(upcoming, indent=2),
        mail_json=mail_json,
    )
    log.info("Calling Ollama model=%s host=%s", OLLAMA_MODEL, OLLAMA_HOST)
    response = ollama_chat(
        model=OLLAMA_MODEL,
        messages=[{"role": "user", "content": prompt}],
        # Larger token budget for detailed HTML output
        options={"num_predict": 8192},
    )
    html = response.message.content

    # Strip <think>...</think> blocks (qwen3 thinking models emit these)
    html = re.sub(r"<think>.*?</think>", "", html, flags=re.DOTALL).strip()
    # Strip markdown code fences if model wrapped output anyway
    html = re.sub(r"^```[a-z]*\n?", "", html).rstrip("```").strip()

    return html


def send_email_via_mail_app(html_body: str) -> None:
    """Send the briefing email as HTML via Mail.app.

    Builds a proper multipart/alternative MIME message so the HTML is
    rendered rather than displayed as raw text (Mail.app's AppleScript
    `content` property only creates plain-text messages).
    """
    subject = f"Daily Briefing — {TODAY.strftime('%A, %B %-d')}"

    msg = email.mime.multipart.MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = RECIPIENT_EMAIL
    msg["To"] = RECIPIENT_EMAIL
    msg.attach(email.mime.text.MIMEText(
        "Please view this email in an HTML-capable client.", "plain", "utf-8"
    ))
    msg.attach(email.mime.text.MIMEText(html_body, "html", "utf-8"))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".eml", delete=False, prefix="daily_briefing_"
    ) as f:
        f.write(msg.as_string())
        eml_path = f.name

    try:
        safe_path = eml_path.replace("\\", "\\\\").replace('"', '\\"')
        script = f'''
tell application "Mail"
    set eml to (POSIX file "{safe_path}") as alias
    open eml
    delay 2
    repeat with m in (every outgoing message)
        if subject of m contains "Daily Briefing" then
            send m
            exit repeat
        end if
    end repeat
end tell
'''
        subprocess.run(["osascript", "-e", script], check=True, timeout=30)
    finally:
        try:
            os.unlink(eml_path)
        except OSError:
            pass


def _format_event_time(start_str: str) -> str:
    """Extract a short time string from an event start date string.

    Input: "Saturday, April 5, 2026 at 9:00:00 AM"
    Output: "9:00 AM"
    """
    if " at " in start_str:
        time_part = start_str.split(" at ", 1)[1]          # "9:00:00 AM"
        parts = time_part.split(":")
        if len(parts) >= 2:
            hour = parts[0].lstrip("0") or "12"
            minute = parts[1]
            ampm = parts[2].strip().split(" ")[-1] if len(parts) > 2 else ""
            return f"{hour}:{minute} {ampm}".strip()
    return start_str


def _build_imessage_text(events: dict, overdue: dict, upcoming: dict, mail: dict) -> str:
    """Build a detailed iMessage nudge from structured tool data.

    Lists today's events by time, then summarises overdue, upcoming, and
    unread mail counts. Kept concise so it reads well as a notification.
    """
    today_str = TODAY.strftime("%B %-d, %Y")   # "April 5, 2026"
    header = f"Daily Briefing — {TODAY.strftime('%A, %b %-d')}\n"

    # ---- Today's events ----
    all_events = events.get("events", [])
    today_events = [
        e for e in all_events
        if today_str in e.get("start", "") and not e.get("allday")
    ]
    today_allday = [
        e for e in all_events
        if today_str in e.get("start", "") and e.get("allday")
    ]

    if today_events or today_allday:
        schedule_lines = ["\nToday:"]
        for e in today_allday:
            schedule_lines.append(f"  All Day — {e.get('title', '?')}")
        for e in sorted(today_events, key=lambda x: x.get("start", "")):
            t = _format_event_time(e.get("start", ""))
            schedule_lines.append(f"  {t} — {e.get('title', '?')}")
        schedule = "\n".join(schedule_lines)
    else:
        schedule = "\nToday: Nothing scheduled"

    # ---- Overdue / upcoming / mail counts ----
    overdue_count = overdue.get("count", 0)
    upcoming_count = upcoming.get("count", 0)
    mail_count = mail.get("count", 0)

    tail_parts = []
    if overdue_count:
        tail_parts.append(f"⚠️ {overdue_count} overdue reminder{'s' if overdue_count != 1 else ''}")
    if upcoming_count:
        tail_parts.append(f"📋 {upcoming_count} due this week")
    if mail_count:
        tail_parts.append(f"✉️ {mail_count} unread email{'s' if mail_count != 1 else ''}")
    tail = ("\n\n" + "\n".join(tail_parts)) if tail_parts else ""

    footer = "\n\nFull details in email."
    return header + schedule + tail + footer


async def send_imessage_nudge(events: dict, overdue: dict, upcoming: dict, mail: dict) -> None:
    """Send a detailed iMessage push alert with today's events, task counts, and unread mail."""
    if not IMESSAGE_RECIPIENT:
        log.info("IMESSAGE_RECIPIENT not set, skipping push alert")
        return

    message = _build_imessage_text(events, overdue, upcoming, mail)
    async with Client(MCP_CONFIG) as client:
        await client.call_tool("send_imessage", {
            "recipient": IMESSAGE_RECIPIENT,
            "message": message,
        })
    log.info("iMessage nudge sent to %s", IMESSAGE_RECIPIENT)


def main():
    parser = argparse.ArgumentParser(description="Daily briefing agent")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print HTML to stdout instead of emailing",
    )
    args = parser.parse_args()

    os.makedirs(LOG_DIR, exist_ok=True)
    log.info("Starting daily briefing agent (model=%s)", OLLAMA_MODEL)

    try:
        events, overdue, upcoming, mail = asyncio.run(fetch_data())
        log.info(
            "Data fetched: events=%d, overdue=%d, upcoming=%d, mail=%d",
            events.get("count", 0), overdue.get("count", 0),
            upcoming.get("count", 0), mail.get("count", 0),
        )

        html = generate_summary(events, overdue, upcoming, mail)
        if not html.strip():
            log.error("Ollama returned empty summary")
            return

        if args.dry_run:
            print(html)
            print("\n--- iMessage preview ---")
            print(_build_imessage_text(events, overdue, upcoming, mail))
            log.info("Dry run — HTML and iMessage preview printed to stdout")
            return

        send_email_via_mail_app(html)
        log.info("Briefing email sent to %s", RECIPIENT_EMAIL)

        asyncio.run(send_imessage_nudge(events, overdue, upcoming, mail))

    except Exception:
        log.exception("Agent failed")
        raise


if __name__ == "__main__":
    main()
