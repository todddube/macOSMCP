# mac-bridge

A [Model Context Protocol](https://modelcontextprotocol.io/) server that bridges Claude to macOS native apps. Provides read-only access to Reminders and Calendar via Python + [`fastmcp`](https://gofastmcp.com). Reminders use AppleScript (`osascript`); Calendar event queries use a compiled Swift/EventKit helper for fast indexed lookups (<1s vs ~45s with AppleScript on large calendars). No Node/Bun runtime required.

**Mail support is planned for a future release.**

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

All tools return structured JSON. Only **read** operations are implemented.

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
    applescript.py       (osascript subprocess helper)
    models.py            (TypedDict return types → outputSchema)
    reminders.py         (6 tools — batch AppleScript)
    calendar.py          (4 tools — Swift/EventKit for events, AppleScript for list)
        │
        ├── subprocess → swift/calendar_helper  (EventKit, indexed queries, <1s)
        └── subprocess → osascript              (Reminders + list_calendars only)
        ▼
  macOS Reminders.app / Calendar.app
```

### Performance

**Reminders — Batch Property Fetching:** The server uses AppleScript batch property fetching to avoid the N × M IPC calls that cause timeouts on large lists. Each list is resolved with ~5 batch fetches regardless of item count, then pure-AppleScript loops handle filtering with zero additional round-trips:

```applescript
-- One IPC call per property — not one per item
set allNames  to name  of rems
set allDates  to due date of rems
set allBodies to body  of rems
```

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
# Run the test suite (81 tests, no macOS app access needed)
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

You should see `mac-bridge` listed as connected with 10 tools.

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
├── server.py              ← MCP entry point
├── macos_mcp/
│   ├── __init__.py
│   ├── applescript.py     ← osascript helper + TTL cache + sanitization
│   ├── models.py          ← TypedDict return types → FastMCP outputSchema
│   ├── reminders.py       ← 6 Reminders tools (batch AppleScript)
│   └── calendar.py        ← 4 Calendar tools (Swift/EventKit + AppleScript)
├── swift/
│   ├── calendar_helper.swift  ← EventKit CLI for fast event queries
│   └── build.sh               ← compile script (swiftc → swift/calendar_helper)
├── tests/                 ← 81 pytest tests
│   ├── conftest.py
│   ├── test_applescript.py
│   ├── test_parsing.py
│   ├── test_tool_registration.py
│   ├── test_tools_mocked.py
│   └── test_server.py
├── pyproject.toml         ← uv/hatch project config (v0.5.0)
├── .mcp.json              ← Claude Code auto-discovery config
└── macOSMCP_specs.md      ← design specs and implementation notes
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
- [ ] Headless Python agent (`scheduled_agent.py`) runs via launchd at 7:00 AM
- [ ] Fetches calendar events + reminders via FastMCP Client
- [ ] Summarizes with a single Claude API call (Anthropic Python SDK)
- [ ] Emails HTML briefing to configured recipient
- [ ] See `AIAgentAutomate_Specs.md` for full design

---

## References

- [Model Context Protocol spec](https://modelcontextprotocol.io/docs)
- [fastmcp docs](https://gofastmcp.com)
- [apple-mcp (Bun, all-in-one)](https://github.com/supermemoryai/apple-mcp)
- [mcp-server-apple-events (Swift/EventKit)](https://github.com/FradSer/mcp-server-apple-events)

---

## License

MIT © 2025-2026 Todd Dube
