# AI Agent Automation — Scheduled Daily Briefing

## Goal

A headless Python agent that runs daily on macOS, connects to the mac-bridge MCP server, pulls the next 7 days of calendar events and reminders, asks Claude to generate a summary, and emails it to `todd@thedubes.com`.

---

## Architecture

```
launchd (daily @ 7:00 AM)
    |
    v
scheduled_agent.py
    |
    +-- FastMCP Client (stdio transport)
    |       |
    |       +-- get_calendar_events  (next 7 days)
    |       +-- get_overdue_reminders
    |       +-- get_upcoming_reminders (7 days)
    |       |
    |       v
    |   Structured JSON data
    |
    +-- Anthropic Python SDK
    |       |
    |       v
    |   Claude generates HTML summary
    |
    +-- smtplib / Mail.app --> todd@thedubes.com
```

---

## Approach Comparison

| | Option A: Hybrid (Recommended) | Option B: Anthropic SDK + Manual Tools | Option C: No-LLM Direct |
|---|---|---|---|
| Data fetching | FastMCP Client (direct MCP calls) | Manual tool loop via `messages.create()` | FastMCP Client |
| Summarization | Single `messages.create()` call | Built into the tool loop | Python template (no LLM) |
| MCP lifecycle | `async with Client(config)` | Manual subprocess spawn | `async with Client(config)` |
| API calls | 1 (summary only) | 3-4 (tool calls + summary) | 0 |
| Cost per run | ~$0.01 | ~$0.02 | $0 |
| Conflict detection | Yes (Claude analyzes) | Yes | No |
| Lines of code | ~80 | ~120 | ~60 |
| Dependencies | `anthropic`, `fastmcp` | `anthropic` | `fastmcp` |

**Recommended: Option A (Hybrid)** — Use FastMCP Client to fetch data directly (fast, reliable, no tool-loop overhead), then a single Claude API call to generate the summary. Best cost/quality tradeoff.

---

## Implementation Plan

### Option A: Hybrid (Recommended)

#### File: `scheduled_agent.py`

Location: `/Users/todddube/Documents/Github/macOSMCP/scheduled_agent.py`

```python
#!/usr/bin/env python3
"""Daily briefing agent — pulls calendar + reminders via MCP, emails summary."""

import asyncio
import smtplib
import os
import logging
from datetime import date, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import anthropic
from fastmcp import Client

# --- Config ---
RECIPIENT = "todd@thedubes.com"
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER")          # email address
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD")   # app password
FROM_ADDR = os.environ.get("FROM_ADDR", SMTP_USER)

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.expanduser("~/Library/Logs/macOSMCP")

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "scheduled_agent.log"),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


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

Here is the raw data from macOS Calendar and Reminders:

## Calendar Events ({today} to {end})
{events_json}

## Overdue Reminders
{overdue_json}

## Upcoming Reminders (next 7 days)
{upcoming_json}

Produce an HTML email body with these sections:
- **Today's Schedule** — today's events, sorted by time
- **This Week** — remaining events grouped by day
- **Overdue Reminders** — sorted by priority (high first)
- **Upcoming Reminders** — grouped by day, sorted by priority

Use clean, minimal HTML. Inline CSS only (email-safe). No external resources.
Use a professional but friendly tone. Highlight conflicts (overlapping events).
If any section is empty, say "Nothing scheduled" instead of omitting it.

Return ONLY the HTML body (no markdown fences, no explanation).
"""


async def fetch_data() -> tuple[str, str, str]:
    """Fetch calendar + reminder data via FastMCP Client."""
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


def generate_summary(events_json: str, overdue_json: str, upcoming_json: str) -> str:
    """Send data to Claude for HTML summary generation."""
    client = anthropic.Anthropic()
    prompt = SUMMARY_PROMPT.format(
        today=TODAY.isoformat(),
        end=END.isoformat(),
        events_json=events_json,
        overdue_json=overdue_json,
        upcoming_json=upcoming_json,
    )
    message = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    )
    return message.content[0].text


def send_email(html_body: str) -> None:
    """Send the briefing email via SMTP."""
    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"Daily Briefing — {TODAY.strftime('%A, %B %-d')}"
    msg["From"] = FROM_ADDR
    msg["To"] = RECIPIENT

    plain = "Your daily briefing is available in HTML format."
    msg.attach(MIMEText(plain, "plain"))
    msg.attach(MIMEText(html_body, "html"))

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
        server.starttls()
        server.login(SMTP_USER, SMTP_PASSWORD)
        server.sendmail(FROM_ADDR, RECIPIENT, msg.as_string())


def main():
    os.makedirs(LOG_DIR, exist_ok=True)

    log.info("Starting daily briefing agent")
    try:
        events_json, overdue_json, upcoming_json = asyncio.run(fetch_data())
        log.info("Data fetched: events=%d chars, overdue=%d chars, upcoming=%d chars",
                 len(events_json), len(overdue_json), len(upcoming_json))

        html = generate_summary(events_json, overdue_json, upcoming_json)
        if not html.strip():
            log.error("Claude returned empty summary")
            return

        send_email(html)
        log.info("Briefing email sent to %s", RECIPIENT)
    except Exception:
        log.exception("Agent failed")
        raise


if __name__ == "__main__":
    main()
```

---

## Email Delivery Options

### Option A: Gmail App Password (simplest)

1. Enable 2FA on your Google account
2. Generate an App Password at https://myaccount.google.com/apppasswords
3. Set environment variables:
   ```
   SMTP_HOST=smtp.gmail.com
   SMTP_PORT=587
   SMTP_USER=your-gmail@gmail.com
   SMTP_PASSWORD=xxxx-xxxx-xxxx-xxxx
   FROM_ADDR=your-gmail@gmail.com
   ```

### Option B: iCloud Mail App Password

1. Generate at https://appleid.apple.com -> Sign-In and Security -> App-Specific Passwords
2. Set:
   ```
   SMTP_HOST=smtp.mail.me.com
   SMTP_PORT=587
   SMTP_USER=your-icloud@icloud.com
   SMTP_PASSWORD=xxxx-xxxx-xxxx-xxxx
   ```

### Option C: macOS Mail.app via AppleScript (no SMTP credentials)

Skip `smtplib` entirely. Use AppleScript to create and send via Mail.app:
```python
import subprocess

def send_via_mail_app(html_body: str, subject: str, recipient: str):
    script = f'''
    tell application "Mail"
        set newMessage to make new outgoing message with properties {{
            subject:"{subject}", ¬
            content:"{html_body}", ¬
            visible:false
        }}
        tell newMessage
            make new to recipient at end of to recipients with properties {{
                address:"{recipient}"
            }}
        end tell
        send newMessage
    end tell
    '''
    subprocess.run(["osascript", "-e", script], check=True, timeout=30)
```
**Pros:** No credentials to store, uses your default Mail.app account.
**Cons:** Requires Mail.app to be configured and running. Needs Automation permission.

---

## Scheduling with launchd

### Plist File

`~/Library/LaunchAgents/com.thedubes.daily-briefing.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.thedubes.daily-briefing</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/todddube/.local/bin/uv</string>
        <string>run</string>
        <string>--directory</string>
        <string>/Users/todddube/Documents/Github/macOSMCP</string>
        <string>scheduled_agent.py</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>7</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_API_KEY</key>
        <string>sk-ant-REPLACE-ME</string>
        <key>SMTP_HOST</key>
        <string>smtp.gmail.com</string>
        <key>SMTP_PORT</key>
        <string>587</string>
        <key>SMTP_USER</key>
        <string>REPLACE-ME</string>
        <key>SMTP_PASSWORD</key>
        <string>REPLACE-ME</string>
        <key>FROM_ADDR</key>
        <string>REPLACE-ME</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/todddube/Library/Logs/macOSMCP/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/todddube/Library/Logs/macOSMCP/launchd-stderr.log</string>
</dict>
</plist>
```

### launchd Commands

```bash
# Install
launchctl load ~/Library/LaunchAgents/com.thedubes.daily-briefing.plist

# Test run now
launchctl start com.thedubes.daily-briefing

# Check status
launchctl list | grep daily-briefing

# View logs
tail -f ~/Library/Logs/macOSMCP/scheduled_agent.log

# Uninstall
launchctl unload ~/Library/LaunchAgents/com.thedubes.daily-briefing.plist
```

---

## Dependencies

Add to `pyproject.toml`:
```toml
[project.optional-dependencies]
agent = ["anthropic>=0.42.0", "fastmcp>=2.0"]
```

Install: `uv sync --extra agent`

The `smtplib` and `email` modules are Python stdlib — no extra deps for email.

---

## Security Considerations

| Concern | Mitigation |
|---|---|
| ANTHROPIC_API_KEY in plist | Store in macOS Keychain and read at runtime (see enhancement below) |
| SMTP credentials in plist | Same — Keychain or a `.env` file with `chmod 600` |
| Claude sees calendar/reminder data | Data sent to Anthropic API — same trust model as using Claude Desktop |
| Runaway API costs | Single `messages.create()` call with `max_tokens=4096`; no tool loop |

### Keychain Enhancement (recommended)

```python
import subprocess

def get_keychain_password(service: str, account: str) -> str:
    """Read a password from macOS Keychain."""
    result = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()

# Store once:  security add-generic-password -s "daily-briefing" -a "anthropic" -w "sk-ant-..."
# Then read:   ANTHROPIC_API_KEY = get_keychain_password("daily-briefing", "anthropic")
```

---

## Estimated Cost Per Run

| Component | Tokens | Cost (Sonnet) |
|---|---|---|
| Prompt + raw data | ~2,000 input | ~$0.006 |
| HTML summary generation | ~1,500 output | ~$0.015 |
| **Total per run** | | **~$0.02** |
| **Monthly (30 days)** | | **~$0.60** |

Uses `claude-sonnet-4-6` for cost efficiency. Calendar/reminder data is structured — Sonnet handles summarization well.

---

## Implementation Steps

### Phase 1: Core Agent (MVP)
1. [ ] Add `anthropic` and `fastmcp` as optional deps: `uv add --optional agent anthropic fastmcp`
2. [ ] Create `scheduled_agent.py` with the code above
3. [ ] Create `~/Library/Logs/macOSMCP/` directory
4. [ ] Choose email delivery method (Gmail App Password is simplest)
5. [ ] Set environment variables and test manually: `uv run scheduled_agent.py`
6. [ ] Verify email arrives with correct formatting

### Phase 2: Schedule
7. [ ] Create launchd plist at `~/Library/LaunchAgents/com.thedubes.daily-briefing.plist`
8. [ ] Load with `launchctl load`
9. [ ] Test with `launchctl start com.thedubes.daily-briefing`
10. [ ] Verify logs at `~/Library/Logs/macOSMCP/`

### Phase 3: Harden
11. [ ] Move secrets to macOS Keychain
12. [ ] Add retry logic (1 retry on network failure)
13. [ ] Add a "last successful run" timestamp file for monitoring
14. [ ] Consider adding a `--dry-run` flag that prints HTML to stdout instead of emailing

---

## Alternative: No-Claude Direct Approach (Option C)

If you want to skip the API cost entirely, call the MCP tools directly via FastMCP Client and use a Python template:

```python
from fastmcp import Client
from datetime import date, timedelta

PROJECT_DIR = "/Users/todddube/Documents/Github/macOSMCP"

async def get_briefing_data():
    config = {"mcpServers": {"mac-bridge": {
        "command": "uv",
        "args": ["--directory", PROJECT_DIR, "run", "server.py"],
    }}}
    async with Client(config) as client:
        events = await client.call_tool("get_calendar_events", {
            "start_date": date.today().isoformat(),
            "end_date": (date.today() + timedelta(days=7)).isoformat(),
            "limit": 100,
        })
        overdue = await client.call_tool("get_overdue_reminders", {"limit": 50})
        upcoming = await client.call_tool("get_upcoming_reminders", {
            "days": 7, "limit": 50,
        })
    return events, overdue, upcoming
```

**Pros:** Zero API cost, faster execution, no API key needed.
**Cons:** No intelligent summarization, conflict detection, or prioritization. Just raw data in a template.

---

## Prerequisites (already complete)

The mac-bridge MCP server that this agent depends on is fully built and tested:

- 10 read-only tools (6 Reminders + 4 Calendar) -- all working
- Swift/EventKit helper for fast calendar queries (<1s vs ~45s with AppleScript)
- 81 pytest tests passing
- Structured JSON output with TypedDict return types
- AppleScript input sanitization for security
- Project version: v0.5.0

See `macOSMCP_specs.md` for full technical details on the MCP server.
