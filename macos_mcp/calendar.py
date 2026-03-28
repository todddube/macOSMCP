# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""
macOS Calendar tools for mac-bridge.

Event queries (get_calendar_events, get_today_events, search_calendar_events)
use a compiled Swift/EventKit helper for fast date-range lookups.  EventKit's
``predicateForEvents(withStart:end:calendars:)`` uses indexed date queries
(O(log N)) instead of AppleScript's ``whose`` clause which does a linear
scan over every historical event (O(N)).  On calendars with thousands of
events this reduces query time from ~45 seconds to <1 second.

list_calendars still uses AppleScript (fast for metadata-only queries).

The Swift binary is at ``swift/calendar_helper`` relative to the project root.
Build it with: ``bash swift/build.sh``
"""

import logging
import os
import subprocess
from datetime import date, timedelta
from pathlib import Path
from typing import Annotated, Optional

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from .applescript import (
    TIMEOUT_NORMAL,
    cached_result,
    lines_from_applescript,
    set_cached_result,
)
from .models import (
    CalendarEventsResult,
    CalendarListResult,
    CalendarSearchResult,
    TodayEventsResult,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Swift helper binary path
# ---------------------------------------------------------------------------

_SWIFT_BINARY = Path(__file__).resolve().parent.parent / "swift" / "calendar_helper"


def _swift_helper_available() -> bool:
    """Return True if the compiled Swift calendar_helper binary exists."""
    return _SWIFT_BINARY.is_file() and os.access(_SWIFT_BINARY, os.X_OK)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_date_param(value: Optional[str], default: date) -> date:
    if not value:
        return default
    try:
        return date.fromisoformat(value)
    except ValueError:
        return default


def _parse_calendar_tsv(line: str) -> dict:
    """Parse a tab-separated ``key=value`` calendar event line into a dict.

    ``notes=`` is always emitted last; its value may span multiple tab-fields
    if the original description contained tabs (trailing fields are rejoined).
    """
    fields = line.split("\t")
    obj: dict = {}
    i = 0
    while i < len(fields):
        field = fields[i]
        if not field or "=" not in field:
            i += 1
            continue
        key, _, val = field.partition("=")
        if key == "notes":
            rest = fields[i + 1 :]
            obj["notes"] = (val + "\t" + "\t".join(rest)) if rest else val
            break
        elif key == "allday":
            obj["allday"] = val == "true"
        elif key == "count":
            obj["count"] = int(val) if val.isdigit() else val
        else:
            obj[key] = val
        i += 1
    return obj


# ---------------------------------------------------------------------------
# Swift EventKit helper
# ---------------------------------------------------------------------------

SWIFT_TIMEOUT = 30  # seconds — EventKit queries are fast (<1s typically)


def _run_swift_helper(
    start: date,
    end: date,
    calendar_name: Optional[str] = None,
    search: Optional[str] = None,
    limit: int = 200,
) -> list[str]:
    """Run the Swift calendar_helper binary and return output lines.

    Raises RuntimeError on non-zero exit or timeout.
    """
    cmd = [
        str(_SWIFT_BINARY),
        "--start", start.isoformat(),
        "--end", end.isoformat(),
        "--limit", str(limit),
    ]
    if calendar_name:
        cmd.extend(["--calendar", calendar_name])
    if search:
        cmd.extend(["--search", search])

    logger.debug("Swift helper: %s", " ".join(cmd))
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=SWIFT_TIMEOUT,
    )
    if result.returncode != 0:
        err = result.stderr.strip()
        raise RuntimeError(err or "calendar_helper returned non-zero exit")
    raw = result.stdout.strip()
    return [ln.strip() for ln in raw.splitlines() if ln.strip()]


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


def register_tools(mcp: FastMCP) -> None:
    """Register all Calendar tools on the given FastMCP instance."""

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=60)
    def list_calendars() -> CalendarListResult:
        """List all calendars in macOS Calendar.

        Returns a JSON object:
            { "calendars": [{"name": "Work", "description": "..."}, ...], "count": N }
        """
        hit = cached_result("list_calendars")
        if hit is not None:
            return hit

        script = """tell application "Calendar"
    try
        set total to count of calendars
        if total is 0 then return ""
        set output to ""
        repeat with c in calendars
            set cName to name of c
            set cDesc to description of c
            set cLine to "name=" & cName
            if cDesc is not missing value and cDesc is not "" then
                set cLine to cLine & tab & "description=" & cDesc
            end if
            set output to output & cLine & linefeed
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""
        try:
            raw_lines = lines_from_applescript(script)
            if raw_lines and raw_lines[0].startswith("ERROR:"):
                raise ToolError(raw_lines[0])
            items = [_parse_calendar_tsv(ln) for ln in raw_lines]
            result = {"calendars": items, "count": len(items)}
            set_cached_result("list_calendars", result)
            return result
        except ToolError:
            raise
        except RuntimeError as exc:
            logger.error("list_calendars failed: %s", exc)
            raise ToolError(str(exc)) from exc

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=30)
    def get_calendar_events(
        calendar_name: Annotated[Optional[str], Field(description="Name of a specific calendar. Omit for all calendars.")] = None,
        start_date: Annotated[Optional[str], Field(description="Start of range as YYYY-MM-DD (default: today)")] = None,
        end_date: Annotated[Optional[str], Field(description="End of range as YYYY-MM-DD (default: 7 days from today)")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum events to return")] = 50,
    ) -> CalendarEventsResult:
        """Get events from macOS Calendar for a date range.

        Args:
            calendar_name: Name of a specific calendar. Omit for all calendars.
            start_date:    Start of range as YYYY-MM-DD (default: today).
            end_date:      End of range as YYYY-MM-DD (default: 7 days from today).
            limit:         Maximum events to return (default: 50).

        Returns events that overlap the range, including all-day and multi-day events.
        Each event includes: cal, title, start, end, allday, location (if set),
        and notes (if set).

        Note: Reminders with due dates also appear visually in Calendar via the
        "Scheduled Reminders" calendar. To query them directly, use get_reminders
        or get_upcoming_reminders instead.
        """
        today = date.today()
        start = _parse_date_param(start_date, today)
        end = _parse_date_param(end_date, today + timedelta(days=7))

        try:
            raw_lines = _run_swift_helper(start, end, calendar_name=calendar_name, limit=limit)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            logger.error("get_calendar_events failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        events = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "events": events,
            "count": len(events),
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "calendar": calendar_name or "all",
        }

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=30)
    def get_today_events(
        calendar_name: Annotated[Optional[str], Field(description="Scope to one calendar. Omit for all calendars.")] = None,
    ) -> TodayEventsResult:
        """Get all Calendar events for today (including all-day and multi-day events).

        Args:
            calendar_name: Scope to one calendar (optional; all calendars if omitted).

        Returns events overlapping today. Each event includes: cal, title,
        start, end, allday, location (if set), and notes (if set).

        Note: Reminders due today can be fetched via get_upcoming_reminders(days=0)
        or get_reminders (completed reminders are always excluded).
        """
        today = date.today()

        try:
            raw_lines = _run_swift_helper(today, today, calendar_name=calendar_name, limit=200)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            logger.error("get_today_events failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        events = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "events": events,
            "count": len(events),
            "date": today.isoformat(),
            "calendar": calendar_name or "all",
        }

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=30)
    def search_calendar_events(
        query: Annotated[str, Field(min_length=1, description="Text to find in event titles")],
        calendar_name: Annotated[Optional[str], Field(description="Scope to one calendar. Omit for all calendars.")] = None,
        days_back: Annotated[int, Field(ge=0, le=365, description="Days before today to search")] = 30,
        days_forward: Annotated[int, Field(ge=0, le=365, description="Days after today to search")] = 30,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> CalendarSearchResult:
        """Search Calendar event titles within a date window (case-insensitive).

        Args:
            query:         Text to find in event titles.
            calendar_name: Scope to one calendar (optional; all calendars if omitted).
            days_back:     Days before today to search (default: 30).
            days_forward:  Days after today to search (default: 30).
            limit:         Maximum results to return (default: 50).

        Returns matching events with: cal, title, start, end, allday,
        location (if set), and notes (if set).
        """
        if not query or not query.strip():
            raise ToolError("query must not be empty")

        today = date.today()
        start = today - timedelta(days=days_back)
        end = today + timedelta(days=days_forward)

        try:
            raw_lines = _run_swift_helper(
                start, end, calendar_name=calendar_name, search=query, limit=limit
            )
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            logger.error("search_calendar_events failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        results = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "query": query,
            "results": results,
            "count": len(results),
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "calendar": calendar_name or "all",
        }
