# macOS MCP — Project Specs, Roadmap & Automation

---

## Multi-Agent Architecture (v0.6.0)

### Overview

Four autonomous Claude-powered agents replace the Ollama-based `scheduled_agent.py`.
Each agent calls mac-bridge MCP tools itself via the Anthropic API tool-use loop —
Claude decides what to fetch, reasons over the results, and acts conditionally.

### Key upgrade: Ollama template fill → Claude tool-calling loop

```
BEFORE (v0.5.x — not agentic):
  Python fetches data upfront → JSON blob → Ollama formats HTML

AFTER (v0.6.0 — truly agentic):
  Claude receives task → calls MCP tools iteratively → reasons → produces output
                              ↑ haiku-4-5 (daily) / sonnet-4-6 (weekly)
```

### API Key Management (1Password → Keychain, never in plists)

```
install.py:   op read "op://Personal/Claude API Todd Secret/credential"
                  → security add-generic-password -s mac-bridge -a ANTHROPIC_API_KEY
agents/runner.py: security find-generic-password -s mac-bridge -a ANTHROPIC_API_KEY -w
                  (no biometrics needed at launchd runtime)
```

### The Four Agents

| Agent | File | Model | Schedule | Output |
|---|---|---|---|---|
| Morning Briefing | `agents/morning_briefing.py` | haiku-4-5 | 7:00 AM daily | HTML email + iMessage |
| Weekly Review | `agents/weekly_review.py` | sonnet-4-6 | Sunday 5:00 PM | HTML email + iMessage |
| Priority Alert | `agents/priority_alert.py` | haiku-4-5 | 11:30 AM + 4:30 PM | iMessage only (conditional) |
| Evening Prep | `agents/evening_prep.py` | haiku-4-5 | 6:00 PM Mon–Fri | iMessage only (conditional) |

### Cost Estimate

| Agent | Model | Frequency | Est. tokens/run | Monthly |
|---|---|---|---|---|
| Morning briefing | haiku-4-5 | Daily | ~8K | ~$0.06 |
| Weekly review | sonnet-4-6 | Weekly | ~20K | ~$0.15 |
| Priority alert | haiku-4-5 | 2x daily | ~3K | ~$0.09 |
| Evening prep | haiku-4-5 | 5x/week | ~3K | ~$0.06 |
| **Total** | | | | **~$0.36/month** |

### File Layout

```
agents/
  __init__.py
  runner.py            — shared: get_api_key, run_agent (tool loop), send_*, extract_*
  morning_briefing.py  — 7:00 AM daily
  weekly_review.py     — Sunday 5:00 PM
  priority_alert.py    — 11:30 AM + 4:30 PM, conditional, rate-limited
  evening_prep.py      — 6:00 PM Mon–Fri, conditional
plists/
  com.thedubes.morning-briefing.plist
  com.thedubes.weekly-review.plist
  com.thedubes.priority-alert.plist
  com.thedubes.evening-prep.plist
install.py             — Python installer: prereqs, deps, 1Password→Keychain, launchd
```

### Runner.py Core Pattern

```python
# 1. Load mac-bridge tools
async with Client(MCP_CONFIG) as mcp:
    tools = await mcp.list_tools()
    anthropic_tools = [{"name": t.name, "description": t.description,
                        "input_schema": t.inputSchema} for t in tools]

# 2. Tool-calling loop
messages = [{"role": "user", "content": task}]
while True:
    response = anthropic_client.messages.create(
        model=model, tools=anthropic_tools, messages=messages
    )
    if response.stop_reason == "end_turn":
        return final_text
    # Execute tool calls, append results, continue loop
```

### Output Protocol

Claude produces output in tagged sections:
- `<html>…</html>` — full HTML email body (inline CSS, no wrappers)
- `<imessage>…</imessage>` — ≤200 char iMessage push
- `<alert>…</alert>` — ≤160 char conditional alert (priority_alert / evening_prep)
- Empty `<alert></alert>` = silent run (nothing to report)

### State File

`~/.mac-bridge/agent_state.json` — rate-limiting for priority_alert:
```json
{
  "alert_date": "2026-05-02",
  "alerted_today": ["⚠️ Overdue: 'Call accountant'..."]
}
```

### Install Commands

```bash
# Full install (pulls key from 1Password, installs all agents)
uv run install.py

# Status / dry-run / uninstall
uv run install.py --status
uv run install.py --dry-run
uv run install.py --uninstall
uv run install.py --refresh-key   # re-pull API key from 1Password

# Manual test (any agent)
uv run --extra agent agents/morning_briefing.py --dry-run
uv run --extra agent agents/weekly_review.py --dry-run
uv run --extra agent agents/priority_alert.py --dry-run
uv run --extra agent agents/evening_prep.py --dry-run
```

---

## Current State (v0.6.0)

### What's Built

| Module | Tools | Status |
|---|---|---|
| Reminders | 6 tools (list, get, detail, search, overdue, upcoming) | Working, read-only |
| Calendar | 4 tools (list, get_events, today, search) | Working, read-only |
| Messaging | 1 tool (send_imessage) | Working, write |
| Mail | 4 tools (list_mailboxes, get_unread_emails, search_emails, get_email_detail) | Working, read-only |
| MCP Prompts | 2 prompts (daily_planner, weekly_review) | Working |
| Multi-Agent System | `agents/` (4 agents) + `plists/` (4 plists) + `install.py` | v0.6.0 — Claude API + 1Password + launchd |
| Legacy Ollama Agent | `scheduled_agent.py` | Superseded by agents/ (kept for reference) |
| Tests | 127 pytest tests (parsing, sanitization, registration, mocked integration, prompts) | Passing |

### Architecture

```
Claude Code / Claude Desktop
        |
        |  MCP (stdio transport, JSON-RPC 2.0)
        v
  server.py              (FastMCP 3.x entry point, on_duplicate="error")
        |
  macos_mcp/
    applescript.py       (osascript subprocess + timeout + TTL cache + sanitization)
    models.py            (TypedDict return types → FastMCP outputSchema)
    reminders.py         (6 tools — per-item AppleScript iteration, ToolError on failure)
    calendar.py          (4 tools — Swift/EventKit for events, AppleScript for list)
    messaging.py         (1 tool — send_imessage via Messages.app AppleScript)
    mail.py              (4 tools — Mail.app batch property fetch + per-item search)
    prompts.py           (2 MCP prompts — daily_planner, weekly_review)
        |
        ├── subprocess -> swift/calendar_helper (EventKit, indexed queries, <1s)
        └── subprocess -> osascript (Reminders + Calendars + Messages + Mail)
        v
  macOS Reminders.app / Calendar.app / Messages.app / Mail.app

  swift/
    calendar_helper.swift  (EventKit CLI — fast date-range event queries)
    build.sh               (compile: swiftc → swift/calendar_helper)

  tests/
    test_applescript.py        (sanitization, cache, run_applescript)
    test_parsing.py            (reminders + calendar TSV parsing)
    test_tool_registration.py  (14 read-only tools, readOnlyHint, timeouts, schemas)
    test_tools_mocked.py       (full tool flows with mocked subprocess)
    test_server.py             (15 total tools, server config)
    test_mail.py               (mail TSV parsing, 4 tools, prompts)
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

### P1 — Multi-Agent System (v0.6.0)

- **Truly agentic Claude API agents** replacing Ollama `scheduled_agent.py`
  - [x] `agents/runner.py` — shared AgentRunner: 1Password→Keychain key fetch, MCP tool loop, email, iMessage, state
  - [x] `agents/morning_briefing.py` — 7:00 AM daily, haiku-4-5, HTML email + iMessage
  - [x] `agents/weekly_review.py` — Sunday 5 PM, sonnet-4-6, strategic review email + iMessage
  - [x] `agents/priority_alert.py` — 11:30 AM + 4:30 PM, conditional iMessage, rate-limited via state file
  - [x] `agents/evening_prep.py` — 6 PM Mon–Fri, conditional tomorrow preview iMessage
  - [x] `plists/` — 4 launchd plists (no API key in env vars, pulled from Keychain at runtime)
  - [x] `install.py` — Python installer: prereqs, uv sync, 1Password→Keychain, launchd load, dry-run validation
  - [x] `pyproject.toml` — agent deps updated: `anthropic>=0.50.0` (replaced `ollama>=0.4.0`)
  - [ ] **Next: run installer** — `uv run install.py`
  - [ ] Dry-run each agent to validate Claude tool loop
  - [ ] Activate launchd schedule and monitor first live runs

### P2 — New Features

- [x] **Mail integration (read-only MCP tools)** — `macos_mcp/mail.py`
  - `list_mailboxes()` — all accounts/mailboxes with unread counts; 30s TTL cached
  - `get_unread_emails(mailbox?, account?, count=20)` — batch property fetch (Mail.app supports it unlike Reminders)
  - `search_emails(query, mailbox?, count=20)` — subject/sender per-item search, early exit
  - `get_email_detail(message_id, mailbox?)` — full body by RFC 2822 Message-ID; `body=` always last in TSV
  - TypedDicts: `MailboxesResult`, `EmailListResult`, `EmailSearchResult`, `EmailDetailResult` in `models.py`
  - 37 new tests in `tests/test_mail.py`

- [x] **Mail follow-up in Daily Briefing** (`scheduled_agent.py`)
  - `fetch_data()` calls `get_unread_emails` and returns 4-tuple `(events, overdue, upcoming, mail)`
  - `SUMMARY_PROMPT` includes `{mail_json}` section + **Email Follow-up card** (purple accent)
  - Model flags time-sensitive subjects: "urgent", "action required", "deadline", "invoice", "payment"
  - Config: `MAIL_COUNT` env var (default 20, set 0 to disable); `MAIL_MAILBOX` to scope to one mailbox
  - iMessage nudge includes `✉️ N unread emails` line
  - Mail.app requires Automation TCC permission (one-time prompt on first run)

- [ ] **Write operations for Reminders**
  - `create_reminder(title, list_name, due_date?, note?)` — `destructiveHint: False`
  - `complete_reminder(title, list_name)` — `destructiveHint: False`
  - `delete_reminder(title, list_name)` — `destructiveHint: True`
  - Gate behind config flag (default off) to keep server read-only unless opted in

- [x] **MCP Prompts** — structured workflow templates (`macos_mcp/prompts.py`)
  - `daily_planner` — calls `get_today_events` + `get_overdue_reminders` + `get_upcoming_reminders(days=3)`; presents Today / Overdue / Due Soon
  - `weekly_review` — calls `get_calendar_events(7 days)` + `get_overdue_reminders` + `get_upcoming_reminders(days=7)`; presents full week grouped by day with summary line
  - Both return `str` (FastMCP wraps as user-role `PromptMessage`)

### P3 — Polish & Scale

- [ ] **Async AppleScript execution** — replace `subprocess.run()` with `asyncio.create_subprocess_exec()` so blocking calls don't stall FastMCP event loop
- [ ] **Progress reporting** — use `Context.report_progress()` for slow cross-list queries
- [x] **File-based logging** — `~/Library/Logs/macOSMCP/` (used by `scheduled_agent.py`); MCP server still logs to stdout (acceptable for stdio transport)
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
    |       +-- get_calendar_events       (next 7 days)
    |       +-- get_overdue_reminders
    |       +-- get_upcoming_reminders    (7 days)
    |       +-- get_unread_emails         (MAIL_COUNT emails, default 20; set 0 to disable)
    |       v
    |   Structured dicts via CallToolResult.structured_content
    |
    +-- Ollama (local, http://localhost:11434)        ← zero cost, fully private
    |       model: qwen2.5:7b (default) or OLLAMA_MODEL env var
    |       v
    |   HTML summary (with <think> tag stripping for thinking models)
    |
    +-- Email → Mail.app AppleScript   -->  todd@thedubes.com
    +-- iPhone nudge → send_imessage   -->  iPhone
```

### launchd + Python: Is This the Right macOS Pattern?

**Yes.** `~/Library/LaunchAgents/` UserAgents are the standard macOS scheduler for user-context tasks. Key reasons this is correct:

- **TCC permissions** — runs as your user, so it inherits Reminders/Calendar/Messages automation access already granted
- **`uv run` under launchd** — works correctly; uv manages the virtualenv; deps resolve from `pyproject.toml` automatically
- **Startup overhead** — ~1–2s for uv + Python startup is fine for a daily job
- **Alternative considered: cron** — cron lacks `EnvironmentVariables`, log path config, and the run-at-boot/wake semantics; launchd is strictly better on macOS

No change needed here — the existing plist design is correct.

### LLM Options: Anthropic API vs. Ollama (Local)

**Ollama on Mac Mini (Apple Silicon) is a fully viable alternative.** No API cost, no data leaving the machine, works offline.

| | Anthropic API (Claude) | Ollama (Local) |
|---|---|---|
| Cost | ~$0.02/run (~$0.60/mo) | Free |
| Privacy | Data sent to Anthropic | Stays on device |
| HTML quality | Excellent | Good (model-dependent) |
| Offline | No | Yes |
| Setup | API key in Keychain | `brew install ollama` |
| Model swap | n/a | Pick any Ollama model |
| Startup latency | ~1s network | ~1–3s model load (cached) |

**Recommended Ollama models for Mac Mini (Apple Silicon):**

| Model | Size | Speed | HTML quality |
|---|---|---|---|
| `qwen2.5:7b` | 4.7 GB | Fast | Best for structured output |
| `llama3.1:8b` | 4.9 GB | Fast | Good general purpose |
| `mistral:7b` | 4.1 GB | Fastest | Good |
| `llama3.2:3b` | 2.0 GB | Very fast | Acceptable |

**Recommendation:** Use Ollama for zero cost + privacy. `qwen2.5:7b` is the best choice for HTML generation from structured data.

### Approach Comparison

| | Option A: Claude API (current) | Option B: Ollama (local) | Option C: No-LLM |
|---|---|---|---|
| Data fetching | FastMCP Client | FastMCP Client | FastMCP Client |
| Summarization | Single Anthropic API call | Single Ollama local call | Python template |
| API calls | 1 (external) | 1 (localhost) | 0 |
| Cost per run | ~$0.02 | $0 | $0 |
| Conflict detection | Yes | Yes | No |
| Privacy | Data sent to Anthropic | Stays on Mac Mini | Stays on Mac Mini |
| Lines of code | ~80 | ~80 (swap 5 lines) | ~60 |

**Recommendation: Option B (Ollama)** for a Mac Mini that's always on — zero cost, private, no API key to manage. Fall back to Option A if HTML quality is insufficient.

### Implementation Code (Option A)

```python
#!/usr/bin/env python3
"""Daily briefing agent — pulls calendar + reminders via MCP, emails summary."""

import asyncio, smtplib, os, logging
from datetime import date, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

from ollama import chat as ollama_chat
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
    prompt = SUMMARY_PROMPT.format(
        today=TODAY.isoformat(), end=END.isoformat(),
        events_json=events_json, overdue_json=overdue_json, upcoming_json=upcoming_json,
    )
    response = ollama_chat(
        model=os.environ.get("OLLAMA_MODEL", "qwen2.5:7b"),
        messages=[{"role": "user", "content": prompt}],
        options={"num_predict": 4096},
    )
    html = response.message.content
    # qwen3 is a thinking model — strip <think>...</think> blocks
    import re
    html = re.sub(r"<think>.*?</think>", "", html, flags=re.DOTALL).strip()
    html = re.sub(r"^```[a-z]*\n?", "", html).rstrip("```").strip()
    return html


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
        <key>OLLAMA_HOST</key><string>http://localhost:11434</string>
        <!-- OLLAMA_MODEL: qwen2.5:7b (best HTML quality) or qwen3-fast:latest (faster, strip <think> tags) -->
        <key>OLLAMA_MODEL</key><string>qwen2.5:7b</string>
        <key>IMESSAGE_RECIPIENT</key><string>+18044328850</string>
        <key>HOME</key><string>/Users/todddube</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
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

### Cost Per Run

| Component | Cost |
|---|---|
| Ollama (`qwen2.5:7b` default) | **$0** — runs locally on Mac Mini |
| Mail.app AppleScript | **$0** |
| iMessage via `send_imessage` | **$0** |
| **Total / run** | **$0** |

### Implementation Checklist

#### Phase 1 — MVP ✓
- [x] `ollama` dep added (`ollama==0.6.1`); Anthropic dep removed
- [x] Create `scheduled_agent.py` — Mail.app email + iMessage nudge + `--dry-run`
- [x] `generate_summary()` uses Ollama (`qwen2.5:7b` default; `qwen3-fast:latest` also supported); `<think>` tag stripping
- [x] `~/Library/Logs/macOSMCP/` log directory created
- [x] Email → Mail.app AppleScript (no credentials needed)
- [x] Push → iMessage via `send_imessage` (already built into MCP server)
- [ ] **Dry-run test:** `uv run --extra agent scheduled_agent.py --dry-run`
- [ ] Verify HTML output quality; switch model via `OLLAMA_MODEL=` if needed
- [ ] Verify email arrives with correct formatting in Mail.app

#### Phase 2 — Schedule
- [x] launchd plist at project root `com.thedubes.daily-briefing.plist`
- [x] `scripts/install-briefing.sh` — copies plist to `~/Library/LaunchAgents/` + `launchctl load`
- [x] `scripts/uninstall-briefing.sh` — `launchctl unload` + removes plist from LaunchAgents
- [ ] `brew services start ollama` — ensure Ollama auto-starts at login
- [ ] `bash scripts/install-briefing.sh` — install and activate schedule
- [ ] `launchctl start com.thedubes.daily-briefing` — trigger test run
- [ ] Verify logs at `~/Library/Logs/macOSMCP/`

#### Phase 3 — Harden
- [ ] Add retry logic (1 retry on Ollama/network failure)
- [ ] Add "last successful run" timestamp file for monitoring
- [ ] Move any future secrets to macOS Keychain

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
agent = ["anthropic>=0.42.0", "ollama>=0.4.0"]
```

```bash
# Anthropic path
uv sync --extra agent

# Ollama path — also install + pull model
brew install ollama
ollama serve &          # start daemon (or add to LaunchAgents)
ollama pull qwen2.5:7b  # ~4.7 GB, best for structured HTML output

# Set model via env var (default: qwen2.5:7b)
OLLAMA_MODEL=llama3.1:8b uv run --extra agent scheduled_agent.py --dry-run

# If using Pushover or ntfy.sh alerts, also: uv add --optional agent httpx
```

> **launchd note for Ollama:** If running `scheduled_agent.py` under launchd, add `OLLAMA_HOST` to the plist's `EnvironmentVariables` (default: `http://localhost:11434`) and ensure `ollama serve` is running as a LaunchAgent separately, or use `brew services start ollama` to auto-start it at login.

---

## Version History

### v0.6.0
- Multi-agent system: 4 Claude API-powered agents replacing Ollama `scheduled_agent.py`
- `agents/runner.py` — shared AgentRunner with MCP tool-calling loop, 1Password→Keychain key management
- `agents/morning_briefing.py`, `weekly_review.py`, `priority_alert.py`, `evening_prep.py`
- `install.py` — Python installer (prereqs, uv sync, 1Password→Keychain, launchd)
- `plists/` — 4 launchd plists with no secrets in EnvironmentVariables
- `pyproject.toml` — `anthropic>=0.50.0` replaces `ollama>=0.4.0`

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
