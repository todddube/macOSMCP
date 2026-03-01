# mac-bridge

A [Model Context Protocol](https://modelcontextprotocol.io/) server that bridges Claude to macOS native apps. Provides read-only access to Reminders and Calendar via Python + [`fastmcp`](https://gofastmcp.com) + `osascript` (AppleScript) — no native Swift bridge, no Node/Bun runtime, no third-party binaries.

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
    reminders.py         (6 Reminders tools — batch AppleScript)
    calendar.py          (4 Calendar tools  — batch AppleScript)
        │
        │  subprocess → osascript
        ▼
  macOS Reminders.app / Calendar.app   (AppleScript bridge)
        │
        ▼
  EventKit data
```

### Performance: Batch Property Fetching

The server uses AppleScript batch property fetching to avoid the N × M IPC calls that cause timeouts on large lists. Each list is resolved with ~5 batch fetches regardless of item count, then pure-AppleScript loops handle filtering with zero additional round-trips:

```applescript
-- One IPC call per property — not one per item
set allNames  to name  of rems
set allDates  to due date of rems
set allBodies to body  of rems
```

---

## Requirements

- macOS 12 Monterey or later (AppleScript Reminders dictionary)
- Python 3.10+
- [uv](https://docs.astral.sh/uv/) (fast Python package manager)

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/todddube/macOSMCP.git
cd macOSMCP
```

### 2. Install uv (if not already installed)

```bash
brew install uv
```

### 3. Install dependencies

```bash
uv sync
```

### 4. Verify the AppleScript bridge

```bash
osascript -e 'tell application "Reminders" to return name of lists'
```

On first run, macOS will prompt for **Reminders access** — grant it.

### 5. Start the server

```bash
uv run server.py
```

The server communicates over stdio and waits for MCP messages. Press `Ctrl-C` to stop.

---

## Claude Code Integration

The project ships with `.mcp.json` which Claude Code picks up automatically from the project directory.

**Edit the `--directory` path** if your checkout is not at `/Users/todddube/Documents/Github/macOSMCP`:

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

Restart Claude Code after editing, then confirm the server loads:

```
/mcp
```

You should see `mac-bridge` listed as connected.

---

## Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Restart Claude Desktop after saving.

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

## macOS Permissions

Access is governed by **TCC (Transparency, Consent, and Control)**. Both Reminders and Calendar request permission automatically on the first `osascript` call — macOS will prompt you the first time. If you accidentally denied either app or need to re-enable:

```
System Settings → Privacy & Security → Reminders   (enable for Terminal)
System Settings → Privacy & Security → Calendars   (enable for Terminal)
```

> **Which app to enable for:** The permission must be granted to the process that runs the server — typically **Terminal.app**. If you launch Claude Desktop directly, grant it to **Claude** instead. If you use iTerm2 or another terminal, grant it to that app.

### Testing permissions manually

```bash
# Verify Reminders access
osascript -e 'tell application "Reminders" to return name of lists'

# Verify Calendar access
osascript -e 'tell application "Calendar" to return name of calendars'
```

Both should return a list of names. A permissions error will say `not authorized to send Apple events`.

> **Note on Reminders in Calendar:** Reminders with due dates appear visually in Calendar.app under a "Scheduled Reminders" calendar. This calendar is **automatically excluded** from all calendar queries to avoid slow scans and duplicate data. To query Reminders (with full metadata like priority, body, list), use `get_reminders`, `get_upcoming_reminders`, or `get_overdue_reminders`.

---

## File Structure

```
macOSMCP/
├── server.py              ← MCP entry point
├── macos_mcp/
│   ├── __init__.py
│   ├── applescript.py     ← osascript helper + timeout constants
│   ├── reminders.py       ← 6 Reminders tools (batch AppleScript)
│   └── calendar.py        ← 4 Calendar tools  (batch AppleScript)
├── pyproject.toml         ← uv/hatch project config
├── .mcp.json              ← Claude Code auto-discovery config
└── macOSMCP_specs.md      ← design specs and implementation notes
```

---

## Design Decisions

**Why fastmcp + AppleScript instead of a pre-built server?**
- Full control over output shape (structured JSON)
- No Bun/Node runtime dependency
- Every AppleScript is readable in the source — fully auditable
- Easy to extend with Calendar, Mail, and custom business logic

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
- [x] `list_calendars`
- [x] `get_today_events`
- [x] `get_calendar_events(start_date, end_date)`
- [x] `search_calendar_events(query)`

### Phase 4 — Mail Integration
- [ ] `get_unread_emails(mailbox?, count?)`
- [ ] `search_emails(query)`
- [ ] `get_email_body(message_id)`

---

## References

- [Model Context Protocol spec](https://modelcontextprotocol.io/docs)
- [fastmcp docs](https://gofastmcp.com)
- [apple-mcp (Bun, all-in-one)](https://github.com/supermemoryai/apple-mcp)
- [mcp-server-apple-events (Swift/EventKit)](https://github.com/FradSer/mcp-server-apple-events)

---

## License

MIT © 2025 Todd Dube
