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
- [x] **Error handling with `ToolError`** — replaced all `return {"error": ...}` with `raise ToolError("message")` in reminders.py and calendar.py. FastMCP sets `isError: true` on the MCP result automatically, and the LLM can see the error and retry with different arguments. Removed unused `ErrorResult` TypedDict.
- [x] **`on_duplicate="error"`** — added to `FastMCP()` constructor to catch accidental duplicate tool registrations at startup.
- [x] **Test suite (78 tests)** — pytest suite covering sanitization, TSV parsing, TTL cache, tool registration (readOnlyHint, timeouts, schema constraints), and full tool flows with mocked subprocess. Run with `uv run pytest tests/ -v`.

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
- [ ] **Progress reporting** — for slow cross-list queries, use FastMCP's `Context.report_progress()` to show progress in clients that support it.
- [ ] **File-based logging** — move logging to `~/Library/Logs/macOSMCP/` instead of stdout/stderr. Stdout output interferes with stdio transport. Use Python `logging.FileHandler` or FastMCP's `Context.log`.
- [x] **Swift/EventKit helper** — compiled Swift CLI (`swift/calendar_helper`) using EventKit's `predicateForEvents(withStart:end:calendars:)` for O(log N) indexed date queries. Replaces AppleScript's `whose` clause (O(N) linear scan) for `get_calendar_events`, `get_today_events`, and `search_calendar_events`. Reduces calendar queries from ~45s to <1s on calendars with thousands of historical events. Build: `bash swift/build.sh`.
- [ ] **`search_tools` meta-tool** — when tool count exceeds ~15, add a tool that lets the LLM discover tools on-demand rather than loading all definitions upfront (Anthropic-recommended pattern for scale).

---

## Current State (v0.5.0)

### What's Built

| Module | Tools | Status |
|---|---|---|
| Reminders | 6 tools (list, get, detail, search, overdue, upcoming) | Working, read-only |
| Calendar | 4 tools (list, get_events, today, search) | Working, read-only |
| Tests | 81 pytest tests (parsing, sanitization, registration, mocked integration) | Passing |
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
    reminders.py         (6 tools — batch AppleScript, ToolError on failure)
    calendar.py          (4 tools — Swift/EventKit for events, AppleScript for list)
        |
        ├── subprocess -> swift/calendar_helper (EventKit, indexed queries, <1s)
        └── subprocess -> osascript (Reminders + list_calendars only)
        v
  macOS Reminders.app / Calendar.app

  swift/
    calendar_helper.swift  (EventKit CLI — fast date-range event queries)
    build.sh               (compile script: swiftc → swift/calendar_helper)

  tests/
    test_applescript.py      (sanitization, cache, run_applescript)
    test_parsing.py          (reminders + calendar TSV parsing)
    test_tool_registration.py (10 tools, readOnlyHint, timeouts, schemas)
    test_tools_mocked.py     (full tool flows with mocked subprocess)
    test_server.py           (server config verification)
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Python + fastmcp + AppleScript + Swift | No Node/Bun deps; auditable AppleScript for Reminders; Swift/EventKit for fast calendar queries |
| Tab-separated `key=value` output | Reminder titles/notes can contain commas; `body=` always last for safe tab-rejoining |
| Batch property fetching (Reminders) | 5 IPC calls per list vs N x M; handles 100+ item lists without timeout |
| Swift/EventKit for calendar events | EventKit's `predicateForEvents` is O(log N) indexed vs AppleScript's O(N) `whose` scan; <1s vs ~45s |
| `whose completed is false` always | Completed reminders are excluded from all queries (user preference) |
| Exclude "Scheduled Reminders" cal | Virtual calendar that mirrors all reminders; causes 60-90s timeouts |

### Bugs Fixed (v0.3.1)

1. **`id of rems` batch fetch crash** — `get_overdue_reminders` and `get_upcoming_reminders` crashed with error -1728 because `id` can't be batch-fetched from `whose`-filtered reminder lists on modern macOS. Fix: per-item `id of (item i of rems)`.
2. **Calendar 60-90s timeouts** — the hidden "Scheduled Reminders" calendar was being scanned, adding thousands of reminder-derived events. Fix: `every calendar whose name is not "Scheduled Reminders"`.
3. **`include_completed` removed** — parameter removed from `get_reminders` and `search_reminders`; `whose completed is false` is now hardcoded in all queries.

### Changes in v0.4.0

1. **`ToolError` for all error paths** — replaced `return {"error": ...}` with `raise ToolError(...)` in all 10 tools. FastMCP now sets `isError: true` on MCP responses, giving LLMs proper error context. Removed unused `ErrorResult` TypedDict from `models.py`.
2. **`on_duplicate="error"`** — added to `FastMCP()` constructor to catch accidental duplicate tool registrations at startup.
3. **Test suite (78 tests)** — added `tests/` directory with 5 test modules covering sanitization, TSV parsing, TTL cache, tool registration (readOnlyHint, timeouts, schema constraints), and full tool flows with mocked subprocess calls. Run: `uv run pytest tests/ -v`.
4. **`.gitignore`** — added to exclude `__pycache__/`, `.venv/`, `.pytest_cache/`, etc.

### Changes in v0.5.0

1. **Swift/EventKit helper for calendar queries** — replaced AppleScript's `whose` date filter (O(N) linear scan, ~45s on calendars with 3,000+ events) with a compiled Swift CLI using EventKit's `predicateForEvents` (O(log N) indexed, <1s). Affects `get_calendar_events`, `get_today_events`, `search_calendar_events`. `list_calendars` remains AppleScript (fast for metadata). Build: `bash swift/build.sh`.
2. **Reduced calendar tool timeouts** — from 90s to 30s since EventKit queries complete in <1s.
3. **Test suite expanded to 81 tests** — added Swift helper mock tests, calendar scoping tests, and search argument verification.

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
| `@mcp.tool(timeout=N)` per tool | Done | 60s for bounded tools, 30s for Swift-backed calendar event tools |
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

- **No Node/Bun required** — Python + a small Swift helper, installs with `uv sync` + `bash swift/build.sh`
- **Smallest dependency footprint** — just `fastmcp` (which pulls `pydantic`, `starlette`, etc.)
- **Swift/EventKit for calendar queries** — same performance insight as FradSer, but only for calendar events; reminders stay pure AppleScript
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
