# macOS MCP — Project Specs, Roadmap & Automation

## Current State (v0.5.1)

### What's Built

| Module | Tools | Status |
|---|---|---|
| Reminders | 6 tools (list, get, detail, search, overdue, upcoming) | Working, read-only |
| Calendar | 4 tools (list, get_events, today, search) | Working, read-only |
| Messaging | 1 tool (send_imessage) | Working, write |
| Tests | 90 pytest tests (parsing, sanitization, registration, mocked integration) | Passing |
| Mail | — | Not started |

### Architecture

```
Claude Code / Claude Desktop
        |
        |  MCP (stdio transport, JSON-RPC 2.0)
        v
  server.py              (FastMCP 3.0.2 entry point, on_duplicate="error")
        |
  macos_mcp/
    applescript.py       (osascript subprocess + timeout + TTL cache + sanitization)
    models.py            (TypedDict return types → FastMCP outputSchema)
    reminders.py         (6 tools — per-item AppleScript iteration, ToolError on failure)
    calendar.py          (4 tools — Swift/EventKit for events, AppleScript for list)
    messaging.py         (1 tool — send_imessage via Messages.app AppleScript)
        |
        ├── subprocess -> swift/calendar_helper (EventKit, indexed queries, <1s)
        └── subprocess -> osascript (Reminders + list_calendars + send_imessage)
        v
  macOS Reminders.app / Calendar.app / Messages.app

  swift/
    calendar_helper.swift  (EventKit CLI — fast date-range event queries)
    build.sh               (compile: swiftc → swift/calendar_helper)

  tests/
    test_applescript.py        (sanitization, cache, run_applescript)
    test_parsing.py            (reminders + calendar TSV parsing)
    test_tool_registration.py  (11 tools, readOnlyHint, timeouts, schemas)
    test_tools_mocked.py       (full tool flows with mocked subprocess)
    test_server.py             (server config verification)
```

---

## Roadmap

### P0 — Completed (Ship-Blocking)

- [x] **AppleScript input sanitization** — `sanitize_for_applescript(s)` in `applescript.py`; escapes `\`, `"`, strips control characters; applied to all user-supplied strings
- [x] **`readOnlyHint` annotations** — all 10 read-only tools annotated; reduces confirmation prompts in MCP clients
- [x] **Per-tool timeouts** — 60s for bounded tools (`list_reminders`, `list_calendars`, `get_reminder_detail`), 90s for cross-list reminder tools, 30s for Swift-backed calendar event tools
- [x] **Typed return values** — TypedDicts in `models.py`; FastMCP auto-generates `outputSchema` and `structuredContent`; removed `json.dumps()` from all tools
- [x] **TTL cache** — `list_reminders` and `list_calendars` use 30s cache via `cached_result()`/`set_cached_result()`
- [x] **`ToolError` error handling** — all tools `raise ToolError(...)`, no `return {"error": ...}`; FastMCP sets `isError: true` on MCP responses
- [x] **`on_duplicate="error"`** — added to `FastMCP()` constructor to catch duplicate tool registrations at startup
- [x] **Test suite (90 tests)** — `uv run pytest tests/ -v`
- [x] **Swift/EventKit helper** — O(log N) indexed calendar queries (<1s vs ~45s AppleScript); `build.sh` compiles `swift/calendar_helper`
- [x] **README updated** — reflects current tool set, exclusions, setup paths
- [x] **`send_imessage` tool** — write operation via Messages.app AppleScript; returns `SendMessageResult`

### P1 — In Progress / Up Next

- [ ] **Scheduled daily briefing agent** (`scheduled_agent.py` via launchd)
  - Fetches calendar + reminders via FastMCP Client
  - Single Claude API call for HTML summary generation
  - Emails HTML briefing to `todd@thedubes.com`
  - iPhone push nudge alongside email
  - Full implementation plan in [Daily Briefing Agent](#daily-briefing-agent) section

### P2 — New Features

- [ ] **Mail integration (read-only)**
  - `list_mailboxes()` — all accounts/mailboxes
  - `get_unread_emails(mailbox?, account?, count?)` — recent unread
  - `search_emails(query, mailbox?, count?)` — subject/sender search
  - `get_email_detail(message_id)` — full body + headers
  - Uses same batch AppleScript pattern; Mail.app supports batch property fetching

- [ ] **Write operations for Reminders**
  - `create_reminder(title, list_name, due_date?, note?)` — `destructiveHint: False`
  - `complete_reminder(title, list_name)` — `destructiveHint: False`
  - `delete_reminder(title, list_name)` — `destructiveHint: True`
  - Gate behind config flag (default off) to keep server read-only unless opted in

- [ ] **MCP Prompts** — structured workflow templates (not tools)
  - `daily_planner` — "What's on my calendar today + overdue/upcoming reminders?"
  - `weekly_review` — "Show me this week's events and any overdue items"
  - See [MCP Prompts spec](https://modelcontextprotocol.io/specification/2025-06-18/server/prompts)

### P3 — Polish & Scale

- [ ] **Async AppleScript execution** — replace `subprocess.run()` with `asyncio.create_subprocess_exec()` so blocking calls don't stall FastMCP event loop
- [ ] **Progress reporting** — use `Context.report_progress()` for slow cross-list queries
- [ ] **File-based logging** — move to `~/Library/Logs/macOSMCP/`; stdout interferes with stdio transport
- [ ] **`search_tools` meta-tool** — when tool count exceeds ~15, lets LLM discover tools on-demand (Anthropic-recommended pattern for scale)

---

## Daily Briefing Agent

**File:** `scheduled_agent.py` → `/Users/todddube/Documents/Github/macOSMCP/scheduled_agent.py`

### Architecture

```
launchd (daily @ 7:00 AM)
    |
    v
scheduled_agent.py
    |
    +-- FastMCP Client (stdio transport)
    |       +-- get_calendar_events  (next 7 days)
    |       +-- get_overdue_reminders
    |       +-- get_upcoming_reminders (7 days)
    |       v
    |   Structured JSON data
    |
    +-- Anthropic Python SDK
    |       v
    |   Claude generates HTML summary
    |
    +-- Email (smtplib / Mail.app)  -->  todd@thedubes.com
    +-- iPhone alert (pick option below)  -->  iPhone
```

### Approach Comparison

| | Option A: Hybrid (Recommended) | Option B: SDK + Manual Tools | Option C: No-LLM |
|---|---|---|---|
| Data fetching | FastMCP Client | Manual tool loop | FastMCP Client |
| Summarization | Single `messages.create()` | Built into tool loop | Python template |
| API calls | 1 | 3-4 | 0 |
| Cost per run | ~$0.01 | ~$0.02 | $0 |
| Conflict detection | Yes | Yes | No |
| Lines of code | ~80 | ~120 | ~60 |

**Recommendation: Option A (Hybrid)** — FastMCP Client for data, single Claude call for summary.

### Implementation Code (Option A)

```python
#!/usr/bin/env python3
"""Daily briefing agent — pulls calendar + reminders via MCP, emails summary."""

import asyncio, smtplib, os, logging
from datetime import date, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import anthropic
from fastmcp import Client

RECIPIENT = "todd@thedubes.com"
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD")
FROM_ADDR = os.environ.get("FROM_ADDR", SMTP_USER)

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.expanduser("~/Library/Logs/macOSMCP")

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "scheduled_agent.log"),
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
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

Inline CSS only. Highlight overlapping events. "Nothing scheduled" if empty.
Return ONLY the HTML body (no markdown fences).
"""


async def fetch_data() -> tuple[str, str, str]:
    async with Client(MCP_CONFIG) as client:
        events = await client.call_tool("get_calendar_events", {
            "start_date": TODAY.isoformat(), "end_date": END.isoformat(), "limit": 100,
        })
        overdue = await client.call_tool("get_overdue_reminders", {"limit": 50})
        upcoming = await client.call_tool("get_upcoming_reminders", {"days": 7, "limit": 50})
    return str(events), str(overdue), str(upcoming)


def generate_summary(events_json: str, overdue_json: str, upcoming_json: str) -> str:
    client = anthropic.Anthropic()
    prompt = SUMMARY_PROMPT.format(
        today=TODAY.isoformat(), end=END.isoformat(),
        events_json=events_json, overdue_json=overdue_json, upcoming_json=upcoming_json,
    )
    msg = client.messages.create(
        model="claude-sonnet-4-6", max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    )
    return msg.content[0].text


def send_email(html_body: str) -> None:
    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"Daily Briefing — {TODAY.strftime('%A, %B %-d')}"
    msg["From"] = FROM_ADDR
    msg["To"] = RECIPIENT
    msg.attach(MIMEText("Your daily briefing is available in HTML format.", "plain"))
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

### Email Delivery Options

**Decision needed — pick one before implementing:**

| | Option | Cost | Effort | Notes |
|---|---|---|---|---|
| **A** | Gmail App Password (SMTP) | Free | Low | Enable 2FA → generate at myaccount.google.com/apppasswords |
| **B** | iCloud App Password (SMTP) | Free | Low | Generate at appleid.apple.com → App-Specific Passwords |
| **C** | Mail.app via AppleScript | Free | Low | No credentials needed; uses default Mail.app account; Automation permission required |

**Option C** is simplest — no credentials to store:

```python
import subprocess

def send_via_mail_app(html_body: str, subject: str, recipient: str):
    script = f'''tell application "Mail"
        set m to make new outgoing message with properties {{subject:"{subject}", content:"{html_body}", visible:false}}
        tell m
            make new to recipient at end of to recipients with properties {{address:"{recipient}"}}
        end tell
        send m
    end tell'''
    subprocess.run(["osascript", "-e", script], check=True, timeout=30)
```

### Scheduling with launchd

**Plist:** `~/Library/LaunchAgents/com.thedubes.daily-briefing.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.thedubes.daily-briefing</string>
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
        <key>Hour</key><integer>7</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_API_KEY</key><string>sk-ant-REPLACE-ME</string>
        <key>SMTP_HOST</key><string>smtp.gmail.com</string>
        <key>SMTP_PORT</key><string>587</string>
        <key>SMTP_USER</key><string>REPLACE-ME</string>
        <key>SMTP_PASSWORD</key><string>REPLACE-ME</string>
        <key>FROM_ADDR</key><string>REPLACE-ME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/todddube/Library/Logs/macOSMCP/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/todddube/Library/Logs/macOSMCP/launchd-stderr.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.thedubes.daily-briefing.plist
launchctl start com.thedubes.daily-briefing   # test run now
launchctl list | grep daily-briefing
tail -f ~/Library/Logs/macOSMCP/scheduled_agent.log
launchctl unload ~/Library/LaunchAgents/com.thedubes.daily-briefing.plist
```

### Keychain Security (Recommended over plist env vars)

```python
import subprocess

def get_keychain_password(service: str, account: str) -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()

# Store once:  security add-generic-password -s "daily-briefing" -a "anthropic" -w "sk-ant-..."
# Read:        ANTHROPIC_API_KEY = get_keychain_password("daily-briefing", "anthropic")
```

### Cost Per Run

| Component | Tokens | Cost (Sonnet 4.6) |
|---|---|---|
| Prompt + raw data | ~2,000 input | ~$0.006 |
| HTML summary output | ~1,500 output | ~$0.015 |
| **Total / run** | | **~$0.02** |
| **Monthly (30 days)** | | **~$0.60** |

### Implementation Checklist

#### Phase 1 — MVP
- [x] Add `anthropic` dep: `uv add --optional agent anthropic` (v0.86.0)
- [x] Create `scheduled_agent.py` (Mail.app email + iMessage nudge + `--dry-run`)
- [x] Create `~/Library/Logs/macOSMCP/` directory
- [x] Pick email method → Mail.app AppleScript (no credentials needed)
- [x] Pick push method → iMessage via `send_imessage` (already built)
- [x] MCP data fetch verified (events, overdue, upcoming)
- [ ] Test full run: `uv run --extra agent scheduled_agent.py` (requires API credits)
- [ ] Verify email arrives with correct formatting

#### Phase 2 — Schedule
- [ ] Create launchd plist at `~/Library/LaunchAgents/com.thedubes.daily-briefing.plist`
- [ ] `launchctl load` + test with `launchctl start`
- [ ] Verify logs at `~/Library/Logs/macOSMCP/`

#### Phase 3 — Harden
- [ ] Move secrets to macOS Keychain
- [ ] Add retry logic (1 retry on network failure)
- [ ] Add `--dry-run` flag (prints HTML to stdout instead of emailing)
- [ ] Pick + integrate iPhone push notification (see below)
- [ ] Add "last successful run" timestamp file for monitoring

---

## iPhone Push Alert Options

**Goal:** Short nudge alongside the full HTML email, e.g. *"3 events today, 2 overdue reminders. Check email."*

### Option 1: iMessage via `send_imessage` (most native, zero cost)

Already built into the MCP server. Call it directly from `scheduled_agent.py`:

```python
# After send_email():
async with Client(MCP_CONFIG) as client:
    await client.call_tool("send_imessage", {
        "recipient": "+1YOURNUMBER",
        "message": f"Daily Briefing: X events today, Y overdue. Check email.",
    })
```

**Pros:** Zero extra code — tool already works; instant iPhone notification; no extra apps or API keys.
**Cons:** Messages.app AppleScript flaky on Ventura+; macOS TCC permission prompt (one-time); plain text only.
**Effort:** ~5 lines — already have the tool.

### Option 2: Pushover ($5 one-time, most reliable)

```python
import httpx

def push_alert(message: str, title: str = "Daily Briefing"):
    httpx.post("https://api.pushover.net/1/messages.json", data={
        "token": "YOUR_APP_TOKEN",
        "user": "YOUR_USER_KEY",
        "message": message,
        "title": title,
        "html": 1,
        "priority": 0,   # -2 silent → 0 normal → 2 requires acknowledgment
    })
```

**Pros:** Rock solid; HTML, priority levels, sounds, action URLs; emergency priority (repeats until acknowledged); 10,000 messages/month free after $5 iOS app; works from anywhere.
**Cons:** $5 iOS app; requires internet; another API token to manage.
**Effort:** ~5 lines.

### Option 3: ntfy.sh (free, open source)

```python
import httpx

def push_alert(message: str, title: str = "Daily Briefing"):
    httpx.post(
        "https://ntfy.sh/your-long-random-secret-topic",
        content=message,
        headers={"Title": title, "Priority": "default"},
    )
```

**Pros:** Completely free; self-hostable; iOS + Android + web UI; markdown, attachments, action buttons.
**Cons:** Topics public by default (use long random name or self-host); iOS app less polished than Pushover.
**Effort:** ~3 lines.

### Option 4: Create Reminder with Alert (iCloud, zero cost)

```applescript
tell application "Reminders"
    tell list "Inbox"
        make new reminder with properties {
            name: "Daily Briefing: 3 events, 2 overdue",
            body: "Check your email for full details",
            due date: current date,
            priority: 1
        }
    end tell
end tell
```

**Pros:** Zero cost; native iPhone notification via iCloud; reminder persists.
**Cons:** Creates reminder clutter; notification limited to title text; 1–30 second iCloud sync delay; adds a write operation.
**Effort:** ~15 lines.

### Option 5: Calendar Event with Alarm (iCloud, zero cost)

Create a calendar event starting now with a 0-minute alarm. Functionally identical to Option 4 but creates calendar clutter instead.

### Alert Option Comparison

| Option | Cost | Reliability | Effort | Apple-Native |
|---|---|---|---|---|
| **1. iMessage** | Free | Medium (flaky Ventura+) | Minimal (already built) | Yes |
| **2. Pushover** | $5 one-time | High | ~5 lines | No |
| **3. ntfy.sh** | Free | Medium-High | ~3 lines | No |
| **4. Reminder** | Free | Medium | ~15 lines | Yes |
| **5. Calendar event** | Free | Medium | ~15 lines | Yes |

**Recommendation:** Messages.app reliable on your Mac → **Option 1** (zero effort). Want set-and-forget → **Option 2**. Free without Apple quirks → **Option 3**.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Python + fastmcp + AppleScript + Swift | No Node/Bun deps; auditable AppleScript for Reminders; Swift/EventKit for fast calendar queries |
| Tab-separated `key=value` output | Reminder titles/notes can contain commas; `body=` always last for safe tab-rejoining |
| Per-item `repeat with r in (every reminder of list)` | Batch property fetch (`name of rems`) and indexed access (`item i of`) both fail on macOS with error -1728 or 17s+ hangs. Per-item iteration is reliable |
| Swift/EventKit for calendar events | EventKit's `predicateForEvents` is O(log N) indexed vs AppleScript's O(N) `whose` scan; <1s vs ~45s |
| `whose completed is false` always | Completed reminders excluded from all queries (user preference, hardcoded) |
| Exclude "Scheduled Reminders" cal | Virtual calendar mirroring all reminders; caused 60-90s timeouts |

---

## Best Practices Status

### MCP Spec Compliance

Per the [MCP specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25):

| Requirement | Status | Notes |
|---|---|---|
| Validate all tool inputs | Done | Types checked by FastMCP; `Annotated[..., Field(...)]` constraints; AppleScript injection sanitized |
| Proper access controls | Done | Read-only tools; stdio transport limits access to MCP client |
| Sanitize tool outputs | Done | TSV parser handles missing values and bad fields |
| `tools` capability declared | Done | FastMCP handles automatically |
| Tool `readOnlyHint` annotations | Done | All 10 read-only tools annotated |
| Structured `outputSchema` | Done | All tools return TypedDicts; FastMCP auto-generates `outputSchema` |
| `ToolError` for error signaling | Done | All tools `raise ToolError(...)` — FastMCP sets `isError: true` |
| Human-in-the-loop | Done | Client-side (Claude Desktop/Code handles approval) |
| Rate limit tool invocations | Not done | Low priority for local-only server |

### FastMCP Best Practices

Per [FastMCP docs](https://gofastmcp.com/servers/tools):

| Practice | Status | Notes |
|---|---|---|
| Type hints + docstrings on all tools | Done | All parameters use `Annotated[type, Field(...)]` |
| `@mcp.tool(timeout=N)` per tool | Done | 60s bounded tools, 30s Swift-backed calendar event tools |
| `on_duplicate="error"` | Done | Added to `FastMCP()` constructor |
| Return TypedDicts | Done | All tools return TypedDicts; FastMCP generates `outputSchema` and `structuredContent` |
| `async def` for I/O-bound tools | Not done | Sync functions run in threadpool (acceptable) |
| `Context` for logging/progress | Not done | Uses Python `logging` directly |

### Security

| Concern | Status | Action |
|---|---|---|
| AppleScript injection via string interpolation | Done | `sanitize_for_applescript()` escapes `\`, `"`, strips control chars on all user inputs |
| Subprocess command injection | Safe | Only calls `osascript -e`; no `shell=True` |
| File system / network access | Safe | No file or network operations in MCP server |
| macOS permissions (TCC) | Documented | Reminders + Calendar + Messages access prompted on first use |
| Agent secrets (plist env vars) | Pending | Move to macOS Keychain (see [Keychain Security](#keychain-security-recommended-over-plist-env-vars)) |

---

## Dependencies

```toml
# pyproject.toml — core deps already installed
[project.optional-dependencies]
agent = ["anthropic>=0.42.0"]
```

```bash
uv sync --extra agent
# If using Pushover or ntfy.sh alerts, also: uv add --optional agent httpx
```

---

## Version History

### v0.5.1
- Added `send_imessage` tool via Messages.app AppleScript
- `messaging.py` module added
- `readOnlyHint: False` for write operation

### v0.5.0
- Swift/EventKit helper for calendar queries — O(log N) indexed, <1s vs ~45s AppleScript
- Reduced calendar tool timeouts from 90s to 30s
- Test suite expanded to 81 tests

### v0.4.0
- `ToolError` for all error paths (replaced `return {"error": ...}`)
- `on_duplicate="error"` on `FastMCP()` constructor
- Test suite (78 tests) — 5 modules

### v0.3.1 — Bugs Fixed
- `id of rems` batch fetch crash (error -1728) in `get_overdue_reminders` / `get_upcoming_reminders` — fixed with per-item iteration
- Calendar 60-90s timeouts — fixed by excluding "Scheduled Reminders" virtual calendar
- `include_completed` parameter removed — `whose completed is false` hardcoded in all queries

---

## Competitor Landscape

| Project | Backend | Apps | Notes |
|---|---|---|---|
| **mac-bridge** (this) | Python + AppleScript + Swift | Reminders, Calendar, Messages | Active |
| [mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | TypeScript + Swift/EventKit | Reminders, Calendar | Active; full CRUD, MCP Prompts |
| [applescript-mcp (JoshRutkowski)](https://github.com/joshrutkowski/applescript-mcp) | TypeScript + AppleScript | System, Files, Notifications | Active |
| [applescript-mcp (PeakMojo)](https://github.com/peakmojo/applescript-mcp) | TypeScript + AppleScript | Generic (any script) | Active |
| [apple-mcp (supermemoryai)](https://github.com/supermemoryai/apple-mcp) | TypeScript + AppleScript | Messages, Notes, Mail, Reminders, Calendar | **Archived Jan 2026** |

**Advantages of mac-bridge:** No Node/Bun required; smallest dependency footprint; structured JSON output; fully auditable inline AppleScript; Swift/EventKit for calendar performance.

**Features to consider from competitors (FradSer):** MCP Prompts for structured workflows; write operations gated behind config; recurrence rules, location triggers, subtasks, tags; automatic permission retry.

---

## Reference Links

- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP Prompts Spec](https://modelcontextprotocol.io/specification/2025-06-18/server/prompts)
- [MCP Security Best Practices (Draft)](https://modelcontextprotocol.io/specification/draft/basic/security_best_practices)
- [FastMCP Documentation](https://gofastmcp.com/getting-started/welcome)
- [FastMCP Tools](https://gofastmcp.com/servers/tools)
- [FastMCP GitHub](https://github.com/jlowin/fastmcp)
- [MCP Best Practices (Peter Steinberger)](https://steipete.me/posts/2025/mcp-best-practices)
- [MCP Performance Optimization (CData)](https://www.cdata.com/blog/proven-mcp-performance-optimization-techniques)
- [MCP Security Guide (WorkOS)](https://workos.com/blog/mcp-security-risks-best-practices)
