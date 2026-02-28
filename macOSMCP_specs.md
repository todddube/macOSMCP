# macOS MCP Integration Specs

## Goal

Automate and integrate macOS Calendar, Reminders, and Email with Claude using MCP servers — for use in Claude Code, Claude Desktop, Cowork, or claude.ai.

---

## Option 1: Claude.ai Built-in Connectors (Google Only)

If you use Google services, Claude.ai already has native connectors for:

- **Google Calendar** — check events, create events, find free time
- **Gmail** — search/read emails, draft replies, summarize threads

These work out of the box in claude.ai chat. No setup needed. However, they do **not** connect to native macOS Calendar/Reminders/Mail unless those apps sync to Google.

---

## Option 2: Pre-built MCP Servers (Recommended)

These run locally and connect Claude Code or Claude Desktop to native macOS apps.

### 2A. apple-mcp (All-in-One)

- **Repo:** https://github.com/supermemoryai/apple-mcp
- **Author:** Dhravya Shah / supermemory
- **Covers:** Messages, Notes, Contacts, Emails, Reminders, Calendar, Maps
- **Backend:** AppleScript via `osascript`
- **Runtime:** Bun (Node alternative)

**Capabilities:**

- **Email:** Send emails with multiple recipients (to, cc, bcc) and file attachments, search emails with custom queries and mailbox selection, schedule emails for future delivery, list/manage scheduled emails, check unread counts globally or per mailbox
- **Reminders:** List all reminders and reminder lists, search by text, create with optional due dates and notes, open Reminders app to specific items
- **Calendar:** Search events with customizable date ranges, list upcoming events, create new events with title, location, notes
- **Bonus:** Messages, Notes, Contacts, Maps integration

**Installation (Claude Code / Claude Desktop):**

Prerequisites:
```bash
brew install oven-sh/bun/bun
```

Config (`claude_desktop_config.json` or Claude Code MCP config):
```json
{
  "mcpServers": {
    "apple-mcp": {
      "command": "bunx",
      "args": ["--no-cache", "apple-mcp@latest"]
    }
  }
}
```

Alternative install via Smithery:
```bash
npx -y @smithery/cli@latest install @Dhravya/apple-mcp --client claude
```

**Workflow Examples:**

- "What's on my calendar this week?"
- "Create a reminder to call the dentist tomorrow at 2pm"
- "Read my conference notes, find contacts for the people I met, and send them a thank you message"
- "Find all my AI research notes and email them to sarah@company.com"

---

### 2B. mcp-server-apple-events (Best for Calendar + Reminders)

- **Repo:** https://github.com/FradSer/mcp-server-apple-events
- **Author:** FradSer
- **Covers:** Calendar + Reminders (deep integration)
- **Backend:** Native Swift/EventKit (compiled binary) + TypeScript MCP layer
- **Runtime:** Node.js

**Capabilities:**

- **Reminders:** Full CRUD, priority levels (high/medium/low/none), recurring reminders (daily/weekly/monthly/yearly), location-based geofence triggers, tags, subtasks, alarms, start/due/completion dates, URL attachments
- **Calendar:** Full CRUD for events, list available calendars, time block creation
- **Filtering:** By due date range (today, tomorrow, this-week, overdue, no-date), by priority, by recurring status, by location-based, by tags
- **Built-in Prompts:** `daily-task-organizer` — produces a same-day execution blueprint with intelligent task clustering, focus block scheduling, and auto-created calendar time blocks

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

**Permissions:**

macOS will prompt for Calendar and Reminders access on first use. The Swift bridge requests `requestFullAccessToReminders` and `requestFullAccessToEvents`. If permissions get stuck, run the included `./check-permissions.sh` script.

**Tool Structure:**

The server exposes service-scoped MCP tools:

- `reminders` — CRUD for individual reminder tasks
- `reminder-lists` — manage reminder lists
- `calendar-events` — CRUD for calendar events
- `calendars` — list available calendars

**Example Tool Calls:**

Create a reminder:
```json
{
  "action": "create",
  "title": "Buy groceries",
  "dueDate": "2024-03-25 18:00:00",
  "targetList": "Shopping",
  "note": "Don't forget milk and eggs",
  "url": "https://example.com/shopping-list"
}
```

Read today's reminders:
```json
{
  "action": "read",
  "filterList": "Work",
  "showCompleted": false,
  "dueWithin": "today"
}
```

---

### 2C. mcp-ical (Python-based, Calendar Only)

- **Repo:** https://github.com/Omar-V2/mcp-ical
- **Author:** Omar-V2
- **Covers:** macOS Calendar only
- **Backend:** Python + EventKit
- **Runtime:** Python (uv)

**Capabilities:**

- Natural language calendar interaction
- Create events with location, notes, reminders
- Recurring event support
- Multi-calendar support
- Date range queries

**Installation:**

```bash
# Clone and install
git clone https://github.com/Omar-V2/mcp-ical.git
cd mcp-ical
uv sync
```

Then configure in Claude Desktop/Code to point to the server entry point.

**Notes:**

- Better results with Claude Sonnet vs Haiku
- Non-standard recurring schedules may not always parse correctly
- macOS will prompt for calendar access on first use

---

## Option 3: Build Your Own (Python + AppleScript)

If you want full control or need custom logic, build a lightweight MCP server using `fastmcp` in Python that shells out to `osascript` (AppleScript).

### Skeleton MCP Server

```python
# macos_mcp_server.py
from fastmcp import FastMCP
import subprocess
import json

mcp = FastMCP("macOS Tools")

def run_applescript(script: str) -> str:
    """Execute AppleScript and return output."""
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise Exception(f"AppleScript error: {result.stderr}")
    return result.stdout.strip()

# ── Calendar ─────────────────────────────────────────────

@mcp.tool()
def get_today_events() -> str:
    """Get today's calendar events."""
    script = '''
    tell application "Calendar"
        set today to current date
        set tomorrow to today + (1 * days)
        set output to ""
        repeat with cal in calendars
            repeat with evt in (events of cal whose start date ≥ today and start date < tomorrow)
                set output to output & summary of evt & " | " & start date of evt & linefeed
            end repeat
        end repeat
        return output
    end tell
    '''
    return run_applescript(script)

@mcp.tool()
def create_calendar_event(title: str, start_date: str, end_date: str, calendar_name: str = "Calendar") -> str:
    """Create a new calendar event. Dates in format: 'March 25, 2025 2:00 PM'"""
    script = f'''
    tell application "Calendar"
        tell calendar "{calendar_name}"
            set newEvent to make new event with properties {{
                summary:"{title}",
                start date:date "{start_date}",
                end date:date "{end_date}"
            }}
            return summary of newEvent
        end tell
    end tell
    '''
    return run_applescript(script)

# ── Reminders ────────────────────────────────────────────

@mcp.tool()
def get_reminders(list_name: str = "Reminders") -> str:
    """Get incomplete reminders from a list."""
    script = f'''
    tell application "Reminders"
        set output to ""
        repeat with r in (reminders of list "{list_name}" whose completed is false)
            set output to output & name of r
            if due date of r is not missing value then
                set output to output & " | Due: " & due date of r
            end if
            set output to output & linefeed
        end repeat
        return output
    end tell
    '''
    return run_applescript(script)

@mcp.tool()
def create_reminder(title: str, list_name: str = "Reminders", notes: str = "", due_date: str = "") -> str:
    """Create a new reminder. Optional due_date format: 'March 25, 2025 2:00 PM'"""
    props = f'name:"{title}"'
    if notes:
        props += f', body:"{notes}"'
    if due_date:
        props += f', due date:date "{due_date}"'

    script = f'''
    tell application "Reminders"
        tell list "{list_name}"
            set newReminder to make new reminder with properties {{{props}}}
            return name of newReminder
        end tell
    end tell
    '''
    return run_applescript(script)

# ── Mail ─────────────────────────────────────────────────

@mcp.tool()
def get_unread_emails(mailbox_name: str = "INBOX", count: int = 10) -> str:
    """Get recent unread emails."""
    script = f'''
    tell application "Mail"
        set output to ""
        set msgs to (messages of mailbox "{mailbox_name}" of account 1 whose read status is false)
        set maxCount to {count}
        set i to 0
        repeat with msg in msgs
            if i ≥ maxCount then exit repeat
            set output to output & "From: " & sender of msg & " | Subject: " & subject of msg & " | Date: " & date received of msg & linefeed
            set i to i + 1
        end repeat
        return output
    end tell
    '''
    return run_applescript(script)

@mcp.tool()
def search_emails(query: str, count: int = 10) -> str:
    """Search emails by subject keyword."""
    script = f'''
    tell application "Mail"
        set output to ""
        set msgs to (messages of mailbox "INBOX" of account 1 whose subject contains "{query}")
        set maxCount to {count}
        set i to 0
        repeat with msg in msgs
            if i ≥ maxCount then exit repeat
            set output to output & "From: " & sender of msg & " | Subject: " & subject of msg & " | Date: " & date received of msg & linefeed
            set i to i + 1
        end repeat
        return output
    end tell
    '''
    return run_applescript(script)

@mcp.tool()
def send_email(to_address: str, subject: str, body: str) -> str:
    """Send an email via Mail.app."""
    script = f'''
    tell application "Mail"
        set newMessage to make new outgoing message with properties {{
            subject:"{subject}",
            content:"{body}",
            visible:true
        }}
        tell newMessage
            make new to recipient at end of to recipients with properties {{address:"{to_address}"}}
        end tell
        send newMessage
        return "Email sent to {to_address}"
    end tell
    '''
    return run_applescript(script)

if __name__ == "__main__":
    mcp.run()
```

### Running the Custom Server

```bash
# Install fastmcp
pip install fastmcp

# Run standalone for testing
python macos_mcp_server.py

# Or configure in Claude Code / Claude Desktop:
```

```json
{
  "mcpServers": {
    "macos-tools": {
      "command": "python",
      "args": ["/path/to/macos_mcp_server.py"]
    }
  }
}
```

---

## Option 4: Swift + EventKit (Most Robust Custom Approach)

For production-quality access, use Swift with Apple's native frameworks:

- **EventKit** — Calendar + Reminders (full read/write, recurring events, alarms, geofencing)
- **MessageUI / Mail scripting** — Email

This avoids AppleScript quirks and gives type-safe, performant access. The `mcp-server-apple-events` project (Option 2B) is a good reference implementation of this pattern.

---

## Option 5: Cowork (GUI Automation)

Cowork is Anthropic's desktop automation tool. It can interact with macOS apps directly through the GUI (clicking, typing, reading screen). No MCP or scripting needed.

**Good for:**
- Ad-hoc tasks ("open Calendar and create an event")
- Apps without good scripting support
- Quick one-off automations

**Limitations:**
- Slower than API-level access
- Less precise than structured tool calls
- Can't easily batch operations

---

## Recommended Setup

| Use Case | Tool | Why |
|---|---|---|
| Google Calendar/Gmail | claude.ai built-in | Zero setup, already connected |
| macOS Calendar + Reminders + Mail (quick start) | `apple-mcp` via Claude Code | One config, covers everything |
| Deep Calendar + Reminders (recurring, geofence, priorities) | `mcp-server-apple-events` via Claude Code | Native Swift/EventKit, most features |
| Full custom workflow | Build with `fastmcp` + AppleScript | Total control, extend as needed |
| GUI-based ad-hoc tasks | Cowork | No setup, works with any app |

### Suggested Claude Code Config (combining servers)

```json
{
  "mcpServers": {
    "apple-mcp": {
      "command": "bunx",
      "args": ["--no-cache", "apple-mcp@latest"]
    },
    "apple-events": {
      "command": "npx",
      "args": ["-y", "mcp-server-apple-events"]
    }
  }
}
```

This gives you broad coverage (`apple-mcp` for Mail, Messages, Notes, Maps) plus deep Calendar/Reminders support (`apple-events` with EventKit).

---

## Prerequisites

- **Node.js** 16+ — `brew install node`
- **Bun** (for apple-mcp) — `brew install oven-sh/bun/bun`
- **Python 3.10+** (if building custom) — `brew install python`
- **fastmcp** (if building custom) — `pip install fastmcp`
- **macOS permissions** — Calendar, Reminders, Mail access will be prompted on first use

---

## Next Steps

1. Install prerequisites (`node`, `bun`)
2. Add MCP server config to Claude Code (`~/.claude/claude_desktop_config.json` or project `.mcp.json`)
3. Launch Claude Code and test: "What's on my calendar today?"
4. Iterate — add custom tools as needed using the fastmcp skeleton above
