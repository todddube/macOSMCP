# macOS MCP — Reminders Read-Only POC

**Status:** POC complete — read-only Reminders access via MCP

---

## What This Is

A minimal [Model Context Protocol](https://modelcontextprotocol.io/) server that gives Claude read-only access to macOS Reminders. Built with Python + `fastmcp` + `osascript` (AppleScript). No native Swift bridge, no third-party binaries — just Python talking to Reminders via the same scripting layer that Automator uses.

### Architecture

```
Claude Code / Claude Desktop
        │
        │  MCP (stdio transport)
        ▼
  reminders_mcp.py   (fastmcp Python server)
        │
        │  subprocess → osascript
        ▼
  macOS Reminders.app   (AppleScript bridge)
        │
        ▼
  EventKit data
```

---

## POC Tools

| Tool | Description | Arguments |
|---|---|---|
| `list_reminder_lists` | Enumerate all Reminder lists | — |
| `get_reminders` | Fetch reminders from one or all lists | `list_name?`, `include_completed?` |
| `search_reminders` | Full-text search across all lists | `query` |

All tools return structured JSON. Only **read** operations are implemented.

---

## Quick Start

### 1. Prerequisites

```bash
# Install uv (fast modern Python toolchain)
brew install uv

# Verify Python 3.10+ is available
python3 --version
```

### 2. Install dependencies

```bash
cd /path/to/macOSMCP

# uv reads pyproject.toml and creates a local venv automatically
uv sync
```

### 3. Test the server manually

```bash
# Run directly — you should see the fastmcp startup banner
uv run reminders_mcp.py
```

On first run, macOS will prompt for **Reminders access**. Grant it. The server communicates over stdio and will wait for MCP messages — `Ctrl-C` to stop.

### 4. Smoke-test with osascript (no Python needed)

```bash
# Verify AppleScript bridge works independently
osascript -e 'tell application "Reminders" to return name of lists'
```

---

## Claude Code Integration

The project ships with `.mcp.json` which Claude Code picks up automatically from the project directory.

**Edit the path** if your checkout is not at `/Users/todddube/Documents/Github/macOSMCP`:

```json
{
  "mcpServers": {
    "macos-reminders": {
      "command": "uv",
      "args": [
        "--directory", "/your/path/to/macOSMCP",
        "run", "reminders_mcp.py"
      ]
    }
  }
}
```

Restart Claude Code after editing. Confirm the server loads:

```
/mcp
```

You should see `macos-reminders` listed as connected.

---

## Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macos-reminders": {
      "command": "uv",
      "args": [
        "--directory", "/your/path/to/macOSMCP",
        "run", "reminders_mcp.py"
      ]
    }
  }
}
```

---

## Example Queries

Once connected, try these in Claude:

- `"What Reminders lists do I have?"`
- `"Show me all incomplete reminders in my Work list"`
- `"Search my reminders for anything about dentist"`
- `"What reminders are due this week?"` *(Claude filters from the returned JSON)*

---

## Design Decisions

**Why fastmcp + AppleScript instead of a pre-built server?**
- Full control over output shape (structured JSON vs raw strings)
- No Bun/Node runtime dependency
- Transparent — every AppleScript is readable in the source
- Easy to extend with custom business logic

**Why `uv run` as the MCP command?**
- `uv run` handles venv creation + activation in one step
- The PEP 723 inline metadata block in `reminders_mcp.py` means the file is also self-contained and runnable with `uv run reminders_mcp.py` without `pyproject.toml`
- No `source venv/bin/activate` ceremony required

**Why newline delimiters instead of AppleScript lists?**
- Reminder titles can contain commas; comma-delimited AppleScript list output would break naively
- Tab-separated key=value fields within each line give us structured data without JSON escaping complexity at the AppleScript layer

**Why read-only for the POC?**
- Minimises permissions footprint during exploration
- Write operations (create, complete, delete) need more careful UX — e.g., confirming list names exist before creating
- Easier to reason about correctness when nothing mutates

---

## macOS Permissions

Reminders access is governed by **TCC (Transparency, Consent, and Control)**. The server requests access automatically on first `osascript` call. If you accidentally denied it:

```
System Settings → Privacy & Security → Reminders
```

Enable access for **Terminal** (or whichever app launched Claude Code/Desktop).

---

## File Structure

```
macOSMCP/
├── README.md              ← this file
├── macOSMCP_specs.md      ← original design specs
├── reminders_mcp.py       ← MCP server (read-only, self-contained)
├── pyproject.toml         ← uv/hatch project config + dev deps
└── .mcp.json              ← Claude Code auto-discovery config
```

---

## Next Steps

### Phase 2 — Write Operations
- [ ] `create_reminder(title, list_name, due_date?, note?)` — with list existence check
- [ ] `complete_reminder(title, list_name)` — mark done by title match
- [ ] `delete_reminder(title, list_name)` — with confirmation guard

### Phase 3 — Richer Queries
- [ ] Filter by due date range: `today`, `this-week`, `overdue`, `no-date`
- [ ] Filter by completion status per list
- [ ] Return reminder count per list in `list_reminder_lists`
- [ ] Surface priority field (none/low/medium/high) in output

### Phase 4 — Calendar Integration
- [ ] `list_calendars` — enumerate Calendar.app calendars
- [ ] `get_today_events` — fetch today's events with time/location
- [ ] `get_events_range(start, end)` — configurable date range
- [ ] `create_event(title, start, end, calendar?)` — write path

### Phase 5 — Mail Integration
- [ ] `get_unread_emails(mailbox?, count?)` — read unread messages
- [ ] `search_emails(query)` — search by subject/sender
- [ ] `get_email_body(message_id)` — read full message content

### Phase 6 — Production Hardening
- [ ] Replace AppleScript output parsing with Swift helper binary (EventKit)
  — avoids string-escaping edge cases, handles Unicode reliably
- [ ] Add proper MCP resource types for Reminder objects (not just tool calls)
- [ ] Add MCP prompt templates (e.g., `daily-task-organizer`)
- [ ] Input sanitisation: strip/escape special chars in AppleScript arguments
- [ ] Add `pytest` unit tests with mocked `osascript` output
- [ ] Structured logging with `--log-level` CLI flag
- [ ] Package as standalone binary with PyInstaller or as a Homebrew formula

### Stretch — Unified Server
- [ ] Merge Reminders + Calendar + Mail into one `macos_mcp.py` server
- [ ] Benchmark against `apple-mcp` (Bun/bunx) for startup latency
- [ ] Compare feature parity with `mcp-server-apple-events` (Swift/EventKit)

---

## References

- [Model Context Protocol spec](https://modelcontextprotocol.io/docs)
- [fastmcp docs](https://gofastmcp.com)
- [apple-mcp (Bun, all-in-one)](https://github.com/supermemoryai/apple-mcp)
- [mcp-server-apple-events (Swift/EventKit)](https://github.com/FradSer/mcp-server-apple-events)
- [macOSMCP_specs.md](./macOSMCP_specs.md) — original design options
