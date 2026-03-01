# macOS MCP — Project Specs & Roadmap

## Next Steps (Prioritized)

### P0 — Ship-Blocking (do before next release)

- [x] **AppleScript input sanitization** — Created `sanitize_for_applescript(s: str) -> str` in `applescript.py` that escapes `\`, `"`, and strips control characters. Applied to every user-supplied string (`list_name`, `title`, `query`, `calendar_name`) before embedding in AppleScript f-strings.
- [x] **Add `readOnlyHint` annotations** to all 10 tools — tells MCP clients the tool is safe and reduces confirmation prompts.
- [x] **Update README** — removed `include_completed` from Reminders tool table, added note that completed reminders are always excluded and "Scheduled Reminders" calendar is always excluded.

### P1 — Quality & Performance

- [x] **Per-tool timeouts via FastMCP** — 60s for bounded tools (`list_reminders`, `list_calendars`, `get_reminder_detail`), 90s for cross-list tools.
- [x] **Typed return values** — all tools return TypedDicts (`models.py`). FastMCP auto-generates `outputSchema` and includes `structuredContent`. Removed `json.dumps()` from all tools.
- [x] **Cache stable data** — `list_reminders` and `list_calendars` use a 30s TTL cache via `cached_result()`/`set_cached_result()` in `applescript.py`.
- [x] **Annotated parameters** — all tool parameters use `Annotated[type, Field(ge=..., le=..., description="...")]` for schema generation and input validation.

### P2 — New Features

- [ ] **Mail integration (read-only)** — Phase 4 from the roadmap:
  - `list_mailboxes()` — all accounts/mailboxes
  - `get_unread_emails(mailbox?, account?, count?)` — recent unread
  - `search_emails(query, mailbox?, count?)` — subject/sender search
  - `get_email_detail(message_id)` — full body + headers
  - Use same batch AppleScript pattern; Mail.app supports batch property fetching.
- [ ] **Write operations for Reminders** — Phase 2 from the roadmap:
  - `create_reminder(title, list_name, due_date?, note?)` — mark with `destructiveHint: False`
  - `complete_reminder(title, list_name)` — mark with `destructiveHint: False`
  - `delete_reminder(title, list_name)` — mark with `destructiveHint: True`
  - Gate behind a config flag (default off) so the server stays read-only unless opted in.
- [ ] **MCP Prompts** — structured templates for common workflows:
  - `daily_planner` — "What's on my calendar today + overdue/upcoming reminders?"
  - `weekly_review` — "Show me this week's events and any overdue items"
  - These are prompt templates the LLM can invoke, not tools. See [MCP Prompts spec](https://modelcontextprotocol.io/specification/2025-06-18/server/prompts).

### P3 — Polish & Scale

- [ ] **Async AppleScript execution** — replace `subprocess.run()` with `asyncio.create_subprocess_exec()` so blocking AppleScript calls don't stall the FastMCP event loop.
- [ ] **Error handling with `ToolError`** — replace raw `json.dumps({"error": ...})` returns with `raise ToolError("message")`. FastMCP will set `isError: true` on the result automatically, and the LLM can see the error and retry with different arguments.
- [ ] **Progress reporting** — for slow cross-list queries, use FastMCP's `Context.report_progress()` to show progress in clients that support it.
- [ ] **File-based logging** — move logging to `~/Library/Logs/macOSMCP/` instead of stdout/stderr. Stdout output interferes with stdio transport. Use Python `logging.FileHandler` or FastMCP's `Context.log`.
- [ ] **Swift/EventKit helper** — for Calendar specifically, a compiled Swift CLI using EventKit would return 100 events in <1 second vs 60+ seconds via AppleScript. Could be a drop-in replacement for `_build_events_script()`.
- [ ] **`search_tools` meta-tool** — when tool count exceeds ~15, add a tool that lets the LLM discover tools on-demand rather than loading all definitions upfront (Anthropic-recommended pattern for scale).

---

## Current State (v0.3.0)

### What's Built

| Module | Tools | Status |
|---|---|---|
| Reminders | 6 tools (list, get, detail, search, overdue, upcoming) | Working, read-only |
| Calendar | 4 tools (list, get_events, today, search) | Working, read-only |
| Mail | — | Not started |

### Architecture

```
Claude Code / Claude Desktop
        |
        |  MCP (stdio transport, JSON-RPC 2.0)
        v
  server.py              (FastMCP 3.0.2 entry point)
        |
  macos_mcp/
    applescript.py       (osascript subprocess + timeout constants)
    reminders.py         (6 tools — batch AppleScript property fetching)
    calendar.py          (4 tools — per-item AppleScript iteration)
        |
        |  subprocess -> osascript
        v
  macOS Reminders.app / Calendar.app   (AppleScript bridge -> EventKit)
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Python + fastmcp + AppleScript | No Node/Bun/Swift deps; fully auditable scripts; easy to extend |
| Tab-separated `key=value` output | Reminder titles/notes can contain commas; `body=` always last for safe tab-rejoining |
| Batch property fetching (Reminders) | 5 IPC calls per list vs N x M; handles 100+ item lists without timeout |
| Per-item iteration (Calendar) | Calendar.app doesn't support batch property fetching on events |
| `whose completed is false` always | Completed reminders are excluded from all queries (user preference) |
| Exclude "Scheduled Reminders" cal | Virtual calendar that mirrors all reminders; causes 60-90s timeouts |

### Bugs Fixed (v0.3.1)

1. **`id of rems` batch fetch crash** — `get_overdue_reminders` and `get_upcoming_reminders` crashed with error -1728 because `id` can't be batch-fetched from `whose`-filtered reminder lists on modern macOS. Fix: per-item `id of (item i of rems)`.
2. **Calendar 60-90s timeouts** — the hidden "Scheduled Reminders" calendar was being scanned, adding thousands of reminder-derived events. Fix: `every calendar whose name is not "Scheduled Reminders"`.
3. **`include_completed` removed** — parameter removed from `get_reminders` and `search_reminders`; `whose completed is false` is now hardcoded in all queries.

---

## Best Practices Applied & To Apply

### MCP Spec Compliance

Per the [MCP specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25):

| Requirement | Status | Notes |
|---|---|---|
| Validate all tool inputs | Done | Types checked by FastMCP; `Annotated[..., Field(...)]` with constraints; AppleScript injection sanitized via `sanitize_for_applescript()` |
| Proper access controls | Done | Read-only tools, stdio transport limits access to MCP client |
| Rate limit tool invocations | Not done | Low priority for local-only server |
| Sanitize tool outputs | Done | TSV parser handles missing values, bad fields |
| `tools` capability declared | Done | FastMCP handles automatically |
| Tool `readOnlyHint` annotations | Done | All 10 tools have `annotations={"readOnlyHint": True}` |
| Structured `outputSchema` | Done | All tools return TypedDicts (`models.py`); FastMCP auto-generates `outputSchema` |
| `ToolError` for error signaling | Done | All tools `raise ToolError(...)` — FastMCP sets `isError: true` automatically |
| Human-in-the-loop | Done | Client-side (Claude Desktop/Code handles approval) |

### FastMCP Best Practices

Per [FastMCP docs (gofastmcp.com)](https://gofastmcp.com/servers/tools):

| Practice | Status | Notes |
|---|---|---|
| Type hints on all parameters | Done | All parameters use `Annotated[type, Field(ge=..., le=..., description="...")]` |
| Docstrings for schema generation | Done | All tools have detailed docstrings |
| `ToolError` for user-facing errors | Done | All tools raise `ToolError`; FastMCP sets `isError: true` on MCP result |
| `@mcp.tool(timeout=N)` per tool | Done | 60s for bounded tools, 90s for cross-list tools |
| `on_duplicate="error"` | Done | Added to `FastMCP()` constructor to catch accidental duplicate registrations |
| `async def` for I/O-bound tools | Not done | Sync functions run in threadpool (ok but not ideal) |
| `Context` for logging/progress | Not done | Uses Python `logging` directly |
| Return TypedDicts | Done | All tools return TypedDicts; FastMCP generates `outputSchema` and `structuredContent` |

### Security

| Concern | Status | Action |
|---|---|---|
| AppleScript injection via string interpolation | Done | `sanitize_for_applescript()` escapes `\`, `"`, strips control chars on all user inputs |
| Subprocess command injection | Safe | Only calls `osascript -e`; no shell=True |
| File system access | Safe | No file operations |
| Network access | Safe | No network calls |
| macOS permissions (TCC) | Documented | Reminders + Calendar access prompted on first use |

---

## Competitor Landscape

### Active Projects

| Project | Backend | Apps | Maintenance |
|---|---|---|---|
| **mac-bridge** (this project) | Python + AppleScript | Reminders, Calendar | Active |
| [mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | TypeScript + Swift/EventKit | Reminders, Calendar | Active |
| [applescript-mcp (JoshRutkowski)](https://github.com/joshrutkowski/applescript-mcp) | TypeScript + AppleScript | System, Files, Notifications | Active |
| [applescript-mcp (PeakMojo)](https://github.com/peakmojo/applescript-mcp) | TypeScript + AppleScript | Generic (any script) | Active |

### Archived

| Project | Notes |
|---|---|
| [apple-mcp (supermemoryai)](https://github.com/supermemoryai/apple-mcp) | **Archived Jan 2026.** Was the most popular (3k+ stars). Covered Messages, Notes, Contacts, Mail, Reminders, Calendar, Maps. Bun runtime. |

### Competitive Advantages of mac-bridge

- **No Node/Bun/Swift required** — pure Python, installs with `uv sync`
- **Smallest dependency footprint** — just `fastmcp` (which pulls `pydantic`, `starlette`, etc.)
- **Batch property fetching** — same performance insight that led FradSer to use compiled Swift
- **Structured JSON output** — every tool returns typed, parseable JSON
- **Fully auditable** — every AppleScript is readable inline in Python source

### Features to Consider From Competitors

From **mcp-server-apple-events** (FradSer):
- MCP Prompts (structured workflow templates like `daily-task-organizer`)
- Write operations gated behind config
- Recurrence rules, location triggers, geofencing, subtasks, tags
- Automatic permission retry with dialog surfacing

---

## Reference: Pre-Built MCP Servers

### mcp-server-apple-events (Best for Calendar + Reminders)

- **Repo:** https://github.com/FradSer/mcp-server-apple-events
- **Backend:** Native Swift/EventKit (compiled binary) + TypeScript MCP layer
- **Runtime:** Node.js

**Capabilities:**
- Full CRUD for Reminders and Calendar via EventKit
- Priority levels, recurring reminders, location-based triggers, tags, subtasks, alarms
- Filtering by due date range, priority, recurring status, tags
- Built-in MCP Prompts (`daily-task-organizer`, `smart-reminder-creator`)

**Installation:**
```json
{
  "mcpServers": {
    "apple-reminders": {
      "command": "npx",
      "args": ["-y", "mcp-server-apple-events"]
    }
  }
}
```

### mcp-ical (Python-based, Calendar Only)

- **Repo:** https://github.com/Omar-V2/mcp-ical
- **Backend:** Python + EventKit
- **Runtime:** Python (uv)

**Capabilities:**
- Natural language calendar interaction
- Create events with location, notes, reminders
- Recurring event support, multi-calendar support, date range queries

---

## Reference: Claude.ai Built-in Connectors

If you use Google services, Claude.ai already has native connectors for:
- **Google Calendar** — check events, create events, find free time
- **Gmail** — search/read emails, draft replies, summarize threads

These work out of the box in claude.ai chat. No setup needed. They do **not** connect to native macOS apps unless those apps sync to Google.

---

## Reference: Useful Links

- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP Tools Spec](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
- [MCP Security Best Practices (Draft)](https://modelcontextprotocol.io/specification/draft/basic/security_best_practices)
- [FastMCP Documentation](https://gofastmcp.com/getting-started/welcome)
- [FastMCP Tools](https://gofastmcp.com/servers/tools)
- [FastMCP GitHub](https://github.com/jlowin/fastmcp)
- [MCP Best Practices (Peter Steinberger)](https://steipete.me/posts/2025/mcp-best-practices)
- [MCP Performance Optimization (CData)](https://www.cdata.com/blog/proven-mcp-performance-optimization-techniques)
- [MCP Security Guide (WorkOS)](https://workos.com/blog/mcp-security-risks-best-practices)
- [Anthropic MCP Courses](https://anthropic.skilljar.com/introduction-to-model-context-protocol)
