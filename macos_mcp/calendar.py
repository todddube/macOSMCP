"""
macOS Calendar tools for the macOS Apps MCP server.

IMPORTANT: Calendar.app does NOT support batch property fetching on events
(unlike Reminders.app). Accessing ``summary of evts`` where evts is a list
raises "Can't get summary of {event id ...}". All event properties must be
accessed per-item inside a ``repeat with evt in evts`` loop.

Date range queries use the Calendar app's native ``whose`` clause, which is
efficient because EventKit maintains date indexes. With date filtering the
result set is small enough that per-item iteration is fast in practice.

Key AppleScript differences from Reminders:
  - Event title is ``summary``, NOT ``name``
  - ``allday event`` is a two-word property (with space)
  - ``description`` is the notes field (may contain newlines → escaped to " | ")
  - Dates are constructed with property assignment (locale-independent)
  - NO batch property fetching — Calendar.app does not support it
"""

import logging
from datetime import date, timedelta
from typing import Annotated, Optional

from fastmcp import FastMCP
from pydantic import Field

from .applescript import (
    TIMEOUT_CROSS_LIST,
    TIMEOUT_NORMAL,
    cached_result,
    lines_from_applescript,
    sanitize_for_applescript,
    set_cached_result,
)
from .models import (
    CalendarEventsResult,
    CalendarListResult,
    CalendarSearchResult,
    ErrorResult,
    TodayEventsResult,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _date_setup(var: str, d: date, *, end_of_day: bool = False) -> str:
    """Return AppleScript statements that set ``var`` to the given date.

    Uses property assignment rather than the locale-dependent ``date "..."``
    literal so the script works regardless of system locale.
    """
    t = 86399 if end_of_day else 0
    return (
        f"        set {var} to current date\n"
        f"        set year of {var} to {d.year}\n"
        f"        set month of {var} to {d.month}\n"
        f"        set day of {var} to {d.day}\n"
        f"        set time of {var} to {t}"
    )


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
# Shared AppleScript: event loop body (per-item, not batch)
# ---------------------------------------------------------------------------
# Inserted inside: repeat with evt in evts ... end repeat
# Requires: calName, output, hitCount already set in outer scope.
# extra_cond: if non-empty, wraps the output block in `if <cond> then ... end if`

def _build_events_script(
    calendar_filter: str,
    date_setup: str,
    extra_cond: str,
    limit: int,
) -> str:
    """Build the full AppleScript for event queries.

    Args:
        calendar_filter: Sets ``calList`` to the target calendar(s).
        date_setup:      Sets ``startDate`` and ``endDate``.
        extra_cond:      Optional AppleScript boolean expression used as
                         ``if <extra_cond> then`` to filter events in the loop
                         (empty string = no extra filter). The expression may
                         reference ``eTitle`` which is set before the test.
        limit:           Hard cap on total events returned.
    """
    # Per-item event output block
    event_output = f"""\
                set eTitle to summary of evt
                set eStart to start date of evt
                set eEnd to end date of evt
                set eAllday to allday event of evt
                set eLoc to location of evt
                set eDesc to description of evt
                set eLine to "cal=" & calName & tab & "title=" & eTitle
                set eLine to eLine & tab & "start=" & (eStart as string)
                set eLine to eLine & tab & "end=" & (eEnd as string)
                set eLine to eLine & tab & "allday=" & eAllday
                if eLoc is not missing value and eLoc is not "" then
                    set eLine to eLine & tab & "location=" & eLoc
                end if
                if eDesc is not missing value and eDesc is not "" then
                    set origDelim to AppleScript's text item delimiters
                    set AppleScript's text item delimiters to linefeed
                    set descParts to text items of eDesc
                    set AppleScript's text item delimiters to " | "
                    set eDescClean to descParts as text
                    set AppleScript's text item delimiters to origDelim
                    set eLine to eLine & tab & "notes=" & eDescClean
                end if
                set output to output & eLine & linefeed
                set hitCount to hitCount + 1
                if hitCount >= {limit} then return output"""

    if extra_cond:
        # For search: read title first, test it, then emit full output
        loop_body = f"""\
                set eTitle to summary of evt
                if {extra_cond} then
{event_output.replace('                set eTitle to summary of evt', '                -- eTitle already set above')}
                end if"""
    else:
        loop_body = event_output

    return f"""tell application "Calendar"
    try
{date_setup}
        {calendar_filter}
        set output to ""
        set hitCount to 0
        repeat with c in calList
            set calName to name of c
            set evts to (every event of c whose start date <= endDate and end date >= startDate)
            repeat with evt in evts
{loop_body}
            end repeat
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


def register_tools(mcp: FastMCP) -> None:
    """Register all Calendar tools on the given FastMCP instance."""

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=60)
    def list_calendars() -> CalendarListResult | ErrorResult:
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
                return {"error": raw_lines[0]}
            items = [_parse_calendar_tsv(ln) for ln in raw_lines]
            result = {"calendars": items, "count": len(items)}
            set_cached_result("list_calendars", result)
            return result
        except RuntimeError as exc:
            logger.error("list_calendars failed: %s", exc)
            return {"error": str(exc)}

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_calendar_events(
        calendar_name: Annotated[Optional[str], Field(description="Name of a specific calendar. Omit for all calendars.")] = None,
        start_date: Annotated[Optional[str], Field(description="Start of range as YYYY-MM-DD (default: today)")] = None,
        end_date: Annotated[Optional[str], Field(description="End of range as YYYY-MM-DD (default: 7 days from today)")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum events to return")] = 50,
    ) -> CalendarEventsResult | ErrorResult:
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

        date_setup = (
            _date_setup("startDate", start)
            + "\n"
            + _date_setup("endDate", end, end_of_day=True)
        )

        if calendar_name:
            safe_cal = sanitize_for_applescript(calendar_name)
            cal_filter = f'set calList to {{calendar "{safe_cal}"}}'
            timeout = TIMEOUT_NORMAL
        else:
            cal_filter = 'set calList to (every calendar whose name is not "Scheduled Reminders")'
            timeout = TIMEOUT_CROSS_LIST

        script = _build_events_script(cal_filter, date_setup, "", limit)

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("get_calendar_events failed: %s", exc)
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        events = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "events": events,
            "count": len(events),
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "calendar": calendar_name or "all",
        }

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_today_events(
        calendar_name: Annotated[Optional[str], Field(description="Scope to one calendar. Omit for all calendars.")] = None,
    ) -> TodayEventsResult | ErrorResult:
        """Get all Calendar events for today (including all-day and multi-day events).

        Args:
            calendar_name: Scope to one calendar (optional; all calendars if omitted).

        Returns events overlapping today. Each event includes: cal, title,
        start, end, allday, location (if set), and notes (if set).

        Note: Reminders due today can be fetched via get_upcoming_reminders(days=0)
        or get_reminders (completed reminders are always excluded).
        """
        today = date.today()
        date_setup = (
            _date_setup("startDate", today)
            + "\n"
            + _date_setup("endDate", today, end_of_day=True)
        )

        if calendar_name:
            safe_cal = sanitize_for_applescript(calendar_name)
            cal_filter = f'set calList to {{calendar "{safe_cal}"}}'
            timeout = TIMEOUT_NORMAL
        else:
            cal_filter = 'set calList to (every calendar whose name is not "Scheduled Reminders")'
            timeout = TIMEOUT_CROSS_LIST

        script = _build_events_script(cal_filter, date_setup, "", 200)

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("get_today_events failed: %s", exc)
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        events = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "events": events,
            "count": len(events),
            "date": today.isoformat(),
            "calendar": calendar_name or "all",
        }

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def search_calendar_events(
        query: Annotated[str, Field(min_length=1, description="Text to find in event titles")],
        calendar_name: Annotated[Optional[str], Field(description="Scope to one calendar. Omit for all calendars.")] = None,
        days_back: Annotated[int, Field(ge=0, le=365, description="Days before today to search")] = 30,
        days_forward: Annotated[int, Field(ge=0, le=365, description="Days after today to search")] = 30,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> CalendarSearchResult | ErrorResult:
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
            return {"error": "query must not be empty"}

        safe_query = sanitize_for_applescript(query)
        today = date.today()
        start = today - timedelta(days=days_back)
        end = today + timedelta(days=days_forward)

        date_setup = (
            _date_setup("startDate", start)
            + "\n"
            + _date_setup("endDate", end, end_of_day=True)
        )

        if calendar_name:
            safe_cal = sanitize_for_applescript(calendar_name)
            cal_filter = f'set calList to {{calendar "{safe_cal}"}}'
            timeout = TIMEOUT_NORMAL
        else:
            cal_filter = 'set calList to (every calendar whose name is not "Scheduled Reminders")'
            timeout = TIMEOUT_CROSS_LIST

        extra = f'eTitle contains "{safe_query}"'
        script = _build_events_script(cal_filter, date_setup, extra, limit)

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("search_calendar_events failed: %s", exc)
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        results = [_parse_calendar_tsv(ln) for ln in raw_lines]
        return {
            "query": query,
            "results": results,
            "count": len(results),
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "calendar": calendar_name or "all",
        }
