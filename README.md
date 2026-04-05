# mac-bridge

A [Model Context Protocol](https://modelcontextprotocol.io/) server that bridges Claude to macOS native apps. Provides read-only access to Reminders and Calendar, plus iMessage send, via Python + [`fastmcp`](https://gofastmcp.com). Reminders use AppleScript (`osascript`); Calendar event queries use a compiled Swift/EventKit helper for fast indexed lookups (<1s vs ~45s with AppleScript on large calendars). No Node/Bun runtime required.

**Mail support is planned (P2).**

---

## Tools

### Reminders

| Tool | Description | Key Arguments |
|---|---|---|
| `list_reminders` | All Reminder lists with item counts | — |
| `get_reminders` | Fetch reminders from one or all lists | `list_name?`, `limit`, `offset` |
| `get_reminder_detail` | Full property set for a specific reminder | `list_name`, `title` |
| `search_reminders` | Title search across all (or one) list | `query`, `list_name?`, `limit` |
| `get_overdue_reminders` | Incomplete reminders past their due date | `limit` |
| `get_upcoming_reminders` | Incomplete reminders due within N days | `days`, `limit` |

### Calendar

| Tool | Description | Key Arguments |
|---|---|---|
| `list_calendars` | All calendars with names and descriptions | — |
| `get_calendar_events` | Events in a date range (all or one calendar) | `calendar_name?`, `start_date?`, `end_date?`, `limit` |
| `get_today_events` | All events overlapping today | `calendar_name?` |
| `search_calendar_events` | Title search within a rolling date window | `query`, `calendar_name?`, `days_back?`, `days_forward?`, `limit` |

### Messaging

| Tool | Description | Key Arguments |
|---|---|---|
| `send_imessage` | Send an iMessage via Messages.app | `recipient` (phone or Apple ID), `message` |

All tools return structured JSON. All Reminders and Calendar tools are **read-only**. `send_imessage` is a write operation.

> **Note:** Completed reminders are always excluded from all queries. The "Scheduled Reminders" virtual calendar is always excluded from calendar queries to avoid scanning reminder-derived entries.

---

## Architecture

```
Claude Code / Claude Desktop
        │
        │  MCP (stdio transport)
        ▼
  server.py              (FastMCP entry point)
        │
  macos_mcp/
    applescript.py       (osascript subprocess helper + TTL cache + sanitization)
    models.py            (TypedDict return types → outputSchema)
    reminders.py         (6 tools — per-item AppleScript iteration)
    calendar.py          (4 tools — Swift/EventKit for events, AppleScript for list)
    messaging.py         (1 tool — send_imessage via Messages.app AppleScript)
        │
        ├── subprocess → swift/calendar_helper  (EventKit, indexed queries, <1s)
        └── subprocess → osascript              (Reminders + list_calendars + send_imessage)
        ▼
  macOS Reminders.app / Calendar.app / Messages.app
```

### Performance

**Reminders — Per-item iteration:** The server uses `repeat with r in (every reminder of list)` with per-item property access. AppleScript batch property fetching (`name of rems`) and indexed access (`item i of rems`) both fail on macOS with error -1728 or 17s+ hangs; per-item iteration via `repeat with r in` is reliable and fast enough for all list sizes. Completed reminders are filtered per-item rather than via a `whose` clause (which creates broken object refs when combined with iteration).

**Calendar — Swift/EventKit:** Calendar event queries (`get_calendar_events`, `get_today_events`, `search_calendar_events`) use a compiled Swift CLI that calls EventKit's `predicateForEvents(withStart:end:calendars:)` for O(log N) indexed date lookups. This replaced AppleScript's `whose` clause which did O(N) linear scans over all historical events (~45s on calendars with 3,000+ events → <1s with EventKit). `list_calendars` still uses AppleScript (fast for metadata-only).

---

## Requirements

- macOS 12 Monterey or later
- Python 3.10+
- [uv](https://docs.astral.sh/uv/) — fast Python package manager
- Xcode Command Line Tools — needed to compile the Swift calendar helper

---

## Setup

### 1. Install prerequisites

```bash
# Install uv (if not already installed)
brew install uv

# Install Xcode Command Line Tools (if not already installed)
xcode-select --install
```

### 2. Clone and build

```bash
git clone https://github.com/todddube/macOSMCP.git
cd macOSMCP
uv sync
bash swift/build.sh
```

`uv sync` installs Python dependencies. `swift/build.sh` compiles the EventKit calendar helper binary.

### 3. Verify the build

```bash
# Run the test suite (90 tests, no macOS app access needed)
uv run pytest tests/ -q

# Verify Reminders access (macOS will prompt for permission — grant it)
osascript -e 'tell application "Reminders" to return name of lists'

# Verify Calendar access (macOS will prompt for permission — grant it)
swift/calendar_helper --start 2025-01-01 --end 2025-01-02
```

### 4. Quick smoke test

```bash
uv run server.py
```

The server starts on stdio and waits for MCP messages. Press `Ctrl-C` to stop. If it starts without errors, you're ready to connect a client.

---

## Connect to Claude Code (CLI / Terminal)

The project ships with `.mcp.json` which Claude Code picks up **automatically** when you open a session from the project directory.

```bash
cd /path/to/macOSMCP
claude
```

Confirm the server is connected:

```
/mcp
```

You should see `mac-bridge` listed as connected with 11 tools.

**If your checkout is not at the default path**, edit `.mcp.json` and update the `--directory` value:

```json
{
  "mcpServers": {
    "mac-bridge": {
      "command": "uv",
      "args": [
        "--directory", "/your/path/to/macOSMCP",
        "run", "server.py"
      ]
    }
  }
}
```

> **Permissions note:** macOS grants Reminders and Calendar access to the **terminal app** running the server (Terminal.app, iTerm2, etc.). Grant access when prompted.

---

## Connect to Claude Desktop (GUI app)

### 1. Add the server config

Open (or create) `~/Library/Application Support/Claude/claude_desktop_config.json` and add:

```json
{
  "mcpServers": {
    "mac-bridge": {
      "command": "uv",
      "args": [
        "--directory", "/your/path/to/macOSMCP",
        "run", "server.py"
      ]
    }
  }
}
```

Replace `/your/path/to/macOSMCP` with the actual path to your clone.

### 2. Restart Claude Desktop

Quit and reopen Claude Desktop. The server will start automatically.

### 3. Verify

Open a new conversation and ask: *"What Reminders lists do I have?"*

On first use, macOS will prompt for Reminders and Calendar access — grant both.

> **Permissions note:** When running via Claude Desktop, macOS grants access to the **Claude** app (not Terminal). If you see permission errors, check:
> `System Settings → Privacy & Security → Reminders` and `→ Calendars` — ensure **Claude** is enabled.

---

## Example Queries

Once connected, try these in Claude:

**Reminders**
- *"What Reminders lists do I have and how many items are in each?"*
- *"Show me all incomplete reminders in my Work list"*
- *"Search my reminders for anything about dentist"*
- *"What reminders are overdue?"*
- *"What's due in the next 7 days?"*
- *"Give me full details on the reminder called 'Call insurance' in my DFD list"*

**Calendar**
- *"What calendars do I have?"*
- *"What's on my calendar today?"*
- *"Show me everything on my Work calendar for next week"*
- *"Search my calendar for any events mentioning 'dentist' in the last 60 days"*
- *"What do I have coming up between March 1 and March 15?"*

---

## Troubleshooting Permissions

macOS uses TCC (Transparency, Consent, and Control) to gate access. If you denied a permission prompt or need to re-enable:

```
System Settings → Privacy & Security → Reminders   (enable for your terminal or Claude)
System Settings → Privacy & Security → Calendars   (enable for your terminal or Claude)
```

| Client | Grant access to |
|---|---|
| Claude Code via Terminal.app | Terminal |
| Claude Code via iTerm2 | iTerm2 |
| Claude Desktop | Claude |

To test permissions manually:

```bash
# Reminders (AppleScript)
osascript -e 'tell application "Reminders" to return name of lists'

# Calendar (EventKit via Swift helper)
swift/calendar_helper --start 2025-01-01 --end 2025-01-02
```

A permissions error will say `not authorized to send Apple events` (Reminders) or `Calendar access not granted` (Calendar).

> **Note:** Reminders with due dates appear in Calendar.app under "Scheduled Reminders". This calendar is **automatically excluded** from all queries to avoid slow scans and duplicate data. Use the Reminders tools for full reminder metadata.

---

## File Structure

```
macOSMCP/
├── server.py              ← MCP entry point (11 tools)
├── macos_mcp/
│   ├── __init__.py
│   ├── applescript.py     ← osascript helper + TTL cache + sanitization
│   ├── models.py          ← TypedDict return types → FastMCP outputSchema
│   ├── reminders.py       ← 6 Reminders tools (per-item AppleScript iteration)
│   ├── calendar.py        ← 4 Calendar tools (Swift/EventKit + AppleScript)
│   └── messaging.py       ← 1 Messaging tool (send_imessage via Messages.app)
├── swift/
│   ├── calendar_helper.swift  ← EventKit CLI for fast event queries
│   └── build.sh               ← compile script (swiftc → swift/calendar_helper)
├── scripts/
│   ├── install-briefing.sh    ← copy plist to LaunchAgents + launchctl load
│   └── uninstall-briefing.sh  ← launchctl unload + remove plist
├── tests/                 ← 90 pytest tests
│   ├── conftest.py
│   ├── test_applescript.py
│   ├── test_parsing.py
│   ├── test_tool_registration.py
│   ├── test_tools_mocked.py
│   └── test_server.py
├── scheduled_agent.py     ← Daily briefing agent (Ollama + Mail.app + iMessage)
├── com.thedubes.daily-briefing.plist  ← launchd schedule (7:00 AM daily)
├── pyproject.toml         ← uv/hatch project config (v0.5.1)
├── .mcp.json              ← Claude Code auto-discovery config
└── specs.md               ← design specs, roadmap, and implementation notes
```

---

## Design Decisions

**Why fastmcp + AppleScript + Swift instead of a pre-built server?**
- Full control over output shape (structured JSON)
- No Bun/Node runtime dependency
- Reminders: every AppleScript is readable inline — fully auditable
- Calendar: Swift/EventKit helper gives native indexed performance without a full Swift MCP framework
- Easy to extend with Mail and custom business logic

**Why `uv run` as the MCP command?**
- `uv run` handles venv creation and activation in a single step
- No `source venv/bin/activate` ceremony required

**Why tab-separated key=value instead of AppleScript list output?**
- Reminder titles and notes can contain commas; comma-delimited output would break naively
- Tab-separated `key=value` fields give structured data without JSON overhead at the AppleScript layer
- `body=` is always emitted last so bodies containing tabs can be safely re-joined by the Python parser

---

## Roadmap

### Phase 2 — Write Operations
- [ ] `create_reminder(title, list_name, due_date?, note?)`
- [ ] `complete_reminder(title, list_name)`
- [ ] `delete_reminder(title, list_name)`

### Phase 3 — Calendar Integration ✓
- [x] `list_calendars` (AppleScript)
- [x] `get_today_events` (Swift/EventKit)
- [x] `get_calendar_events(start_date, end_date)` (Swift/EventKit)
- [x] `search_calendar_events(query)` (Swift/EventKit)

### Phase 4 — Mail Integration
- [ ] `get_unread_emails(mailbox?, count?)`
- [ ] `search_emails(query)`
- [ ] `get_email_body(message_id)`

### Phase 5 — Scheduled Daily Briefing Agent
- [x] `scheduled_agent.py` — fetches calendar + reminders + unread mail via MCP, generates HTML with Ollama, sends via Mail.app + iMessage
- [x] Local Ollama (`qwen2.5:7b` default) — zero cost, fully private, no API key
- [x] Professional HTML email — 6 sections with color-coded cards, priority badges, conflict highlighting, time-sensitive mail flagging
- [x] Detailed iMessage nudge — today's events by time, overdue count, unread mail count
- [x] `--dry-run` flag — prints HTML + iMessage preview, nothing sent
- [x] launchd plist + `scripts/install-briefing.sh` / `uninstall-briefing.sh`
- [x] `MAIL_COUNT` / `MAIL_MAILBOX` env vars — control mail inclusion; set `MAIL_COUNT=0` to disable
- [ ] Dry-run tested and HTML output verified
- [ ] Email delivery via Mail.app verified
- [ ] launchd schedule activated (`bash scripts/install-briefing.sh`)

---

## Daily Briefing Agent

`scheduled_agent.py` fetches calendar events, reminders, and unread email via the MCP server, generates a professional HTML email summary using a local Ollama model, sends it via Mail.app, and fires a detailed iMessage nudge — all with no cloud API calls.

The HTML email includes six sections: Today's Schedule, This Week, Overdue Reminders, Due This Week, Email Follow-up (with time-sensitive flagging), and a footer. The iMessage lists today's events by time plus counts for overdue items and unread email.

### Requirements

- [Ollama](https://ollama.com) installed with `qwen2.5:7b` pulled (or another model — see env vars below)
- `uv sync --extra agent` run at least once

```bash
# One-time setup
brew install ollama
ollama pull qwen2.5:7b   # default model; swap via OLLAMA_MODEL env var
uv sync --extra agent
mkdir -p ~/Library/Logs/macOSMCP
```

### Test runs

```bash
# Dry run — generates HTML and prints to stdout, no email or iMessage sent
uv run --extra agent scheduled_agent.py --dry-run

# Live run — sends email via Mail.app + iMessage nudge
uv run --extra agent scheduled_agent.py
```

### Watch logs

```bash
tail -f ~/Library/Logs/macOSMCP/scheduled_agent.log
```

### Schedule with launchd (runs daily at 7:00 AM)

```bash
# Ensure Ollama starts at login
brew services start ollama

# Install and activate the schedule (copies plist to ~/Library/LaunchAgents/)
bash scripts/install-briefing.sh

# Trigger a test run immediately (check logs after)
launchctl start com.thedubes.daily-briefing

# Verify it loaded and check last exit status
launchctl list | grep daily-briefing

# Uninstall if you want to disable it
bash scripts/uninstall-briefing.sh
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API endpoint |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Model for summarization (`qwen3-fast:latest`, `llama3.1:8b`, `llama3.2:latest` also work) |
| `IMESSAGE_RECIPIENT` | `+18044328850` | Phone or Apple ID for push nudge |
| `MAIL_COUNT` | `20` | Unread emails to include in briefing. Set `0` to disable mail entirely |
| `MAIL_MAILBOX` | *(all inboxes)* | Restrict mail fetch to one mailbox name (e.g. `INBOX`) |

Override at runtime:

```bash
OLLAMA_MODEL=qwen3-fast:latest uv run --extra agent scheduled_agent.py --dry-run
```

---

## References

- [Model Context Protocol spec](https://modelcontextprotocol.io/docs)
- [fastmcp docs](https://gofastmcp.com)
- [apple-mcp (Bun, all-in-one)](https://github.com/supermemoryai/apple-mcp)
- [mcp-server-apple-events (Swift/EventKit)](https://github.com/FradSer/mcp-server-apple-events)

---

## License

MIT © 2025-2026 Todd Dube
