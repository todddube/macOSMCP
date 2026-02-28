# macOS Apps MCP

A [Model Context Protocol](https://modelcontextprotocol.io/) server that gives Claude read-only access to macOS Reminders. Built with Python + [`fastmcp`](https://gofastmcp.com) + `osascript` (AppleScript) — no native Swift bridge, no Node/Bun runtime, no third-party binaries.

**Calendar and Mail support are planned for future releases.**

---

## Tools

| Tool | Description | Key Arguments |
|---|---|---|
| `list_reminder_lists` | All lists with item counts | — |
| `get_reminders` | Fetch reminders from one or all lists | `list_name?`, `include_completed?`, `limit`, `offset` |
| `get_reminder_detail` | Full property set for a specific reminder | `list_name`, `title` |
| `search_reminders` | Title search across all (or one) list | `query`, `list_name?`, `include_completed?`, `limit` |
| `get_overdue_reminders` | Incomplete reminders past their due date | `limit` |
| `get_upcoming_reminders` | Incomplete reminders due within N days | `days`, `limit` |

All tools return structured JSON. Only **read** operations are implemented.

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
        │
        │  subprocess → osascript
        ▼
  macOS Reminders.app    (AppleScript bridge)
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
    "macos-apps": {
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

You should see `macos-apps` listed as connected.

---

## Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macos-apps": {
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

- *"What Reminders lists do I have and how many items are in each?"*
- *"Show me all incomplete reminders in my Work list"*
- *"Search my reminders for anything about dentist"*
- *"What reminders are overdue?"*
- *"What's due in the next 7 days?"*
- *"Give me full details on the reminder called 'Call insurance' in my DFD list"*

---

## macOS Permissions

Reminders access is governed by **TCC (Transparency, Consent, and Control)**. The server requests access automatically on the first `osascript` call. If you accidentally denied it:

```
System Settings → Privacy & Security → Reminders
```

Enable access for **Terminal** (or whichever app launched Claude Code/Desktop).

---

## File Structure

```
macOSMCP/
├── server.py              ← MCP entry point
├── macos_mcp/
│   ├── __init__.py
│   ├── applescript.py     ← osascript helper + timeout constants
│   └── reminders.py       ← 6 Reminders tools (batch AppleScript)
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

### Phase 3 — Calendar Integration
- [ ] `list_calendars`
- [ ] `get_today_events`
- [ ] `get_events_range(start, end)`

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
