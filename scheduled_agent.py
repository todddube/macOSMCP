#!/usr/bin/env python3
# mac-bridge — Daily Briefing Agent
# Author: Todd Dube | March 2026

"""
Daily briefing agent — pulls calendar + reminders via MCP, generates an HTML
summary with Ollama (qwen2.5:7b), emails it via Mail.app, and sends an
iMessage nudge.

Run manually:
    uv run --extra agent scheduled_agent.py
    uv run --extra agent scheduled_agent.py --dry-run   # prints HTML, no email/iMessage

Scheduled via launchd (see specs.md for plist).

Required:
    Ollama running locally with qwen2.5:7b pulled
        brew services start ollama
        ollama pull qwen2.5:7b

Optional env vars:
    OLLAMA_HOST         — default http://localhost:11434
    OLLAMA_MODEL        — default qwen2.5:7b
    IMESSAGE_RECIPIENT  — phone (+1XXXXXXXXXX) or Apple ID email for push alert
"""

import argparse
import asyncio
import email.mime.multipart
import email.mime.text
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
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")

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
Today is {today}. You are generating a daily briefing email.

## Calendar Events ({today} to {end})
{events_json}

## Overdue Reminders
{overdue_json}

## Upcoming Reminders (next 7 days)
{upcoming_json}

Produce an HTML email body with:
- **Today's Schedule** — today's events sorted by time
- **This Week** — remaining events grouped by day
- **Overdue Reminders** — sorted by priority (high first)
- **Upcoming Reminders** — grouped by day, sorted by priority

Rules for HTML output:
- Inline CSS only (no <style> tags, no CSS variables, no external resources)
- Email-safe layout: use <table> for grouping/columns — NOT flexbox or CSS grid
- All CSS values must be syntactically valid (e.g. "padding: 12px;" not "padding: 12,")
- Highlight overlapping events. "Nothing scheduled" if a section is empty.
- Return ONLY the HTML body fragment (no <html>/<head>/<body> wrappers, no markdown fences, no explanation)
"""


async def fetch_data() -> tuple[str, str, str]:
    """Fetch calendar events, overdue reminders, and upcoming reminders via MCP."""
    async with Client(MCP_CONFIG) as client:
        events = await client.call_tool("get_calendar_events", {
            "start_date": TODAY.isoformat(),
            "end_date": END.isoformat(),
            "limit": 100,
        })
        overdue = await client.call_tool("get_overdue_reminders", {"limit": 50})
        upcoming = await client.call_tool("get_upcoming_reminders", {
            "days": 7, "limit": 50,
        })
    return str(events), str(overdue), str(upcoming)


def generate_summary(
    events_json: str, overdue_json: str, upcoming_json: str,
) -> str:
    """Send data to local Ollama and get back an HTML briefing."""
    prompt = SUMMARY_PROMPT.format(
        today=TODAY.isoformat(),
        end=END.isoformat(),
        events_json=events_json,
        overdue_json=overdue_json,
        upcoming_json=upcoming_json,
    )
    log.info("Calling Ollama model=%s host=%s", OLLAMA_MODEL, OLLAMA_HOST)
    response = ollama_chat(
        model=OLLAMA_MODEL,
        messages=[{"role": "user", "content": prompt}],
        options={"num_predict": 4096},
    )
    html = response.message.content

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


async def send_imessage_nudge(
    events_json: str, overdue_json: str, upcoming_json: str,
) -> None:
    """Send a short iMessage push alert summarizing the briefing."""
    if not IMESSAGE_RECIPIENT:
        log.info("IMESSAGE_RECIPIENT not set, skipping push alert")
        return

    event_count = events_json.count("'title':") or events_json.count('"title":')
    overdue_count = overdue_json.count("'title':") or overdue_json.count('"title":')
    upcoming_count = upcoming_json.count("'title':") or upcoming_json.count('"title":')

    parts = []
    if event_count:
        parts.append(f"{event_count} events this week")
    if overdue_count:
        parts.append(f"{overdue_count} overdue")
    if upcoming_count:
        parts.append(f"{upcoming_count} upcoming reminders")

    summary = ", ".join(parts) if parts else "Nothing on the schedule"
    message = f"Daily Briefing: {summary}. Check email for details."

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
        events_json, overdue_json, upcoming_json = asyncio.run(fetch_data())
        log.info(
            "Data fetched: events=%d chars, overdue=%d chars, upcoming=%d chars",
            len(events_json), len(overdue_json), len(upcoming_json),
        )

        html = generate_summary(events_json, overdue_json, upcoming_json)
        if not html.strip():
            log.error("Ollama returned empty summary")
            return

        if args.dry_run:
            print(html)
            log.info("Dry run — HTML printed to stdout")
            return

        send_email_via_mail_app(html)
        log.info("Briefing email sent to %s", RECIPIENT_EMAIL)

        asyncio.run(send_imessage_nudge(events_json, overdue_json, upcoming_json))

    except Exception:
        log.exception("Agent failed")
        raise


if __name__ == "__main__":
    main()
