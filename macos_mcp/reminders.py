# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""
macOS Reminders tools for mac-bridge.

All six tools use batch AppleScript property fetching to minimise IPC round-trips:
instead of N × M osascript calls (one per item per property), each list is
resolved with ~5 batch fetches regardless of size, then pure-AppleScript loops
handle filtering — dramatically reducing latency for large lists.
"""

import logging
from typing import Annotated, Optional

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
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
    OverdueRemindersResult,
    ReminderDetailResult,
    ReminderListsResult,
    ReminderSearchResult,
    RemindersResult,
    UpcomingRemindersResult,
)

logger = logging.getLogger(__name__)

# AppleScript priority integer → human label
_PRIORITY_MAP: dict[str, str] = {
    "0": "none",
    "1": "high",
    "5": "medium",
    "9": "low",
}


# ---------------------------------------------------------------------------
# TSV parsing helpers
# ---------------------------------------------------------------------------


_SKIPPED_PREFIX = "__SKIPPED__"


def _split_skipped_lines(raw_lines: list[str]) -> tuple[list[str], list[dict]]:
    """Separate data lines from __SKIPPED__ marker lines.

    Returns (data_lines, skipped_info) where each skipped entry is a dict
    with 'list', and optionally 'error' and 'errnum' keys.
    """
    data: list[str] = []
    skipped: list[dict] = []
    for ln in raw_lines:
        if ln.startswith(_SKIPPED_PREFIX):
            info: dict = {}
            for part in ln.split("\t"):
                if part.startswith("list="):
                    info["list"] = part[5:]
                elif part.startswith("error="):
                    info["error"] = part[6:]
                elif part.startswith("errnum="):
                    info["errnum"] = part[7:]
            if info.get("list"):
                skipped.append(info)
        else:
            data.append(ln)
    return data, skipped


def _add_skipped_warning(result: dict, skipped: list[dict]) -> dict:
    """Add skipped_lists and warning to result if any lists were skipped."""
    if skipped:
        list_names = [s["list"] for s in skipped]
        result["skipped_lists"] = list_names
        # Build detail lines showing error per list
        details = []
        for s in skipped:
            detail = s["list"]
            if "error" in s:
                detail += f": {s['error']}"
                if "errnum" in s:
                    detail += f" (error {s['errnum']})"
            details.append(detail)
        result["warning"] = (
            f"iCloud sync issue: {len(skipped)} list(s) could not be read and were skipped. "
            f"Details: {'; '.join(details)}. "
            "Try again in a few minutes."
        )
    return result


def _parse_tsv_line(line: str) -> dict:
    """Parse a tab-separated ``key=value`` reminder line into a dict.

    ``body=`` is always emitted last by the AppleScript so that bodies
    containing literal tab characters are handled by rejoining the tail.
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
        if key == "body":
            # body is always last; rejoin remaining tab-separated pieces
            rest = fields[i + 1 :]
            obj["body"] = (val + "\t" + "\t".join(rest)) if rest else val
            break
        elif key == "completed":
            obj["completed"] = val == "true"
        elif key == "priority":
            obj["priority"] = _PRIORITY_MAP.get(val, val)
        elif key == "count":
            obj["count"] = int(val) if val.isdigit() else val
        else:
            obj[key] = val
        i += 1
    return obj


# ---------------------------------------------------------------------------
# AppleScript builders for get_reminders
# ---------------------------------------------------------------------------


def _build_single_list_get_script(
    list_name: str, include_completed: bool, limit: int, offset: int
) -> str:
    safe_list = sanitize_for_applescript(list_name)
    # include_completed is always False in the public API; hardcode filter
    # Uses `repeat with r in` iteration (NOT indexed access) to avoid
    # hanging on ghost reminder objects.  Filters completed manually.
    return f"""tell application "Reminders"
    try
        set output to ""
        set hitCount to 0
        set skipCount to 0
        repeat with r in (every reminder of list "{safe_list}")
            if completed of r is false then
                if skipCount < {offset} then
                    set skipCount to skipCount + 1
                else
                    set rId to id of r
                    set rName to name of r
                    set rDate to due date of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_all_lists_get_script(
    include_completed: bool, limit: int, offset: int
) -> str:
    # include_completed is always False in the public API; hardcode filter
    # Uses `repeat with r in` iteration (NOT indexed access) to avoid
    # hanging on ghost reminder objects.  Filters completed manually.
    return f"""tell application "Reminders"
    set output to ""
    set hitCount to 0
    set skipCount to 0
    repeat with l in lists
        set listName to name of l
        repeat with r in (every reminder of l)
            if completed of r is false then
                if skipCount < {offset} then
                    set skipCount to skipCount + 1
                else
                    set rId to id of r
                    set rName to name of r
                    set rDate to due date of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
    end repeat
    return output
end tell"""


# ---------------------------------------------------------------------------
# AppleScript builders for search_reminders
# ---------------------------------------------------------------------------


def _build_single_list_search_script(
    safe_list: str, safe_query: str, limit: int
) -> str:
    return f"""tell application "Reminders"
    try
        set output to ""
        set hitCount to 0
        repeat with r in (every reminder of list "{safe_list}")
            if completed of r is false then
                set rName to name of r
                if rName contains "{safe_query}" then
                    set rId to id of r
                    set rDate to due date of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_all_lists_search_script(
    safe_query: str, limit: int
) -> str:
    return f"""tell application "Reminders"
    set output to ""
    set hitCount to 0
    repeat with l in lists
        set listName to name of l
        repeat with r in (every reminder of l)
            if completed of r is false then
                set rName to name of r
                if rName contains "{safe_query}" then
                    set rId to id of r
                    set rDate to due date of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
    end repeat
    return output
end tell"""


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


def register_tools(mcp: FastMCP) -> None:
    """Register all Reminders tools on the given FastMCP instance."""

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=60)
    def list_reminders() -> ReminderListsResult:
        """List all Reminder lists in macOS Reminders.

        Returns a JSON object:
            { "lists": [{"name": "Work", "count": 5}, ...], "count": N }
        """
        hit = cached_result("list_reminders")
        if hit is not None:
            return hit

        script = """tell application "Reminders"
    set output to ""
    repeat with l in lists
        set lName to name of l
        set lCount to count of (reminders of l whose completed is false)
        set output to output & "name=" & lName & tab & "count=" & lCount & linefeed
    end repeat
    return output
end tell"""
        try:
            raw_lines = lines_from_applescript(script)
            items = [_parse_tsv_line(ln) for ln in raw_lines]
            result = {"lists": items, "count": len(items)}
            set_cached_result("list_reminders", result)
            return result
        except RuntimeError as exc:
            logger.error("list_reminder_lists failed: %s", exc)
            raise ToolError(str(exc)) from exc

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_reminders(
        list_name: Annotated[Optional[str], Field(description="Name of a specific list to query. Omit for all lists.")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
        offset: Annotated[int, Field(ge=0, description="Skip the first N results for pagination")] = 0,
    ) -> RemindersResult:
        """Fetch reminders from macOS Reminders.

        Completed reminders are always excluded.

        Args:
            list_name: Name of a specific list to query.
                       Omit (or pass None) to query all lists.
            limit:     Maximum results to return (default: 50).
            offset:    Skip the first N results for pagination (default: 0).

        Returns a JSON object with a ``reminders`` array containing id, list,
        title, due, priority, completed, and body fields.
        """
        if list_name:
            script = _build_single_list_get_script(list_name, False, limit, offset)
            timeout = TIMEOUT_NORMAL
        else:
            script = _build_all_lists_get_script(False, limit, offset)
            timeout = TIMEOUT_CROSS_LIST

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("get_reminders failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        data_lines, skipped = _split_skipped_lines(raw_lines)
        reminders = []
        for ln in data_lines:
            obj = _parse_tsv_line(ln)
            if list_name and "list" not in obj:
                obj["list"] = list_name
            reminders.append(obj)

        result: dict = {
            "reminders": reminders,
            "count": len(reminders),
            "list": list_name or "all",
            "offset": offset,
        }
        return _add_skipped_warning(result, skipped)

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=60)
    def get_reminder_detail(
        list_name: Annotated[str, Field(description="The list containing the reminder")],
        title: Annotated[str, Field(description="Title (name) of the reminder")],
    ) -> ReminderDetailResult:
        """Get full details of a reminder by list name and title.

        Args:
            list_name: The list containing the reminder.
            title:     Title (name) of the reminder. Case-insensitive match.

        Returns a JSON object with all available fields: id, title, completed,
        completed_date, due, remind_me_date, creation_date, modification_date,
        priority, url, recurrence, and body.
        """
        safe_list = sanitize_for_applescript(list_name)
        safe_title = sanitize_for_applescript(title)
        script = f"""tell application "Reminders"
    try
        set output to ""
        repeat with r in (every reminder of list "{safe_list}")
            if name of r is "{safe_title}" then
                set rId to id of r
                set rName to name of r
                set rComp to completed of r
                set rDue to due date of r
                set rRemind to remind me date of r
                set rCreate to creation date of r
                set rMod to modification date of r
                set rPri to priority of r
                set rUrl to url of r
                set rRecur to recurrence of r
                set rBody to body of r
                set rCompDate to completion date of r
                set rLine to "id=" & rId & tab & "title=" & rName
                set rLine to rLine & tab & "completed=" & rComp
                if rDue is not missing value then
                    set rLine to rLine & tab & "due=" & (rDue as string)
                end if
                if rRemind is not missing value then
                    set rLine to rLine & tab & "remind_me_date=" & (rRemind as string)
                end if
                set rLine to rLine & tab & "creation_date=" & (rCreate as string)
                set rLine to rLine & tab & "modification_date=" & (rMod as string)
                set rLine to rLine & tab & "priority=" & rPri
                if rUrl is not missing value and rUrl is not "" then
                    set rLine to rLine & tab & "url=" & rUrl
                end if
                if rRecur is not missing value and rRecur is not "" then
                    set rLine to rLine & tab & "recurrence=" & rRecur
                end if
                if rCompDate is not missing value then
                    set rLine to rLine & tab & "completed_date=" & (rCompDate as string)
                end if
                if rBody is not missing value and rBody is not "" then
                    set rLine to rLine & tab & "body=" & rBody
                end if
                set output to output & rLine & linefeed
            end if
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""
        try:
            raw_lines = lines_from_applescript(script)
        except RuntimeError as exc:
            logger.error("get_reminder_detail failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        data_lines, skipped = _split_skipped_lines(raw_lines)
        results = []
        for ln in data_lines:
            obj = _parse_tsv_line(ln)
            obj["list"] = list_name
            results.append(obj)

        result = {
            "reminders": results,
            "count": len(results),
            "list": list_name,
            "query_title": title,
        }
        return _add_skipped_warning(result, skipped)

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def search_reminders(
        query: Annotated[str, Field(min_length=1, description="Text to find in reminder titles")],
        list_name: Annotated[Optional[str], Field(description="Scope search to one list. Omit for all lists.")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> ReminderSearchResult:
        """Search for reminders whose title contains the query string (case-insensitive).

        Completed reminders are always excluded.

        Args:
            query:     Text to find in reminder titles.
            list_name: Scope search to one list (optional; all lists if omitted).
            limit:     Maximum results to return (default: 50).

        Returns a JSON object with matching reminder objects.
        """
        if not query or not query.strip():
            raise ToolError("query must not be empty")

        safe_query = sanitize_for_applescript(query)
        safe_list = sanitize_for_applescript(list_name) if list_name else None

        if list_name:
            script = _build_single_list_search_script(
                safe_list, safe_query, limit
            )
            timeout = TIMEOUT_NORMAL
        else:
            script = _build_all_lists_search_script(safe_query, limit)
            timeout = TIMEOUT_CROSS_LIST

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("search_reminders failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        data_lines, skipped = _split_skipped_lines(raw_lines)
        results = []
        for ln in data_lines:
            obj = _parse_tsv_line(ln)
            if list_name and "list" not in obj:
                obj["list"] = list_name
            results.append(obj)

        result: dict = {"query": query, "results": results, "count": len(results)}
        return _add_skipped_warning(result, skipped)

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_overdue_reminders(
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> OverdueRemindersResult:
        """Get all incomplete reminders with a due date in the past.

        Args:
            limit: Maximum results to return (default: 50).

        Returns a JSON object with overdue reminders sorted by list order.
        """
        script = f"""tell application "Reminders"
    set now to current date
    set output to ""
    set hitCount to 0
    repeat with l in lists
        set listName to name of l
        repeat with r in (every reminder of l)
            if completed of r is false then
                set rDate to due date of r
                if rDate is not missing value and rDate < now then
                    set rId to id of r
                    set rName to name of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    set rLine to rLine & tab & "due=" & (rDate as string)
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
    end repeat
    return output
end tell"""
        try:
            raw_lines = lines_from_applescript(script, timeout=TIMEOUT_CROSS_LIST)
        except RuntimeError as exc:
            logger.error("get_overdue_reminders failed: %s", exc)
            raise ToolError(str(exc)) from exc

        data_lines, skipped = _split_skipped_lines(raw_lines)
        results = [_parse_tsv_line(ln) for ln in data_lines]
        result: dict = {"reminders": results, "count": len(results)}
        return _add_skipped_warning(result, skipped)

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_upcoming_reminders(
        days: Annotated[int, Field(ge=0, le=365, description="Number of days to look ahead")] = 7,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> UpcomingRemindersResult:
        """Get incomplete reminders due within the next N days.

        Args:
            days:  Number of days to look ahead (default: 7).
            limit: Maximum results to return (default: 50).

        Returns a JSON object with upcoming reminders sorted by list order.
        """
        script = f"""tell application "Reminders"
    set now to current date
    set endDate to now + ({days} * days)
    set output to ""
    set hitCount to 0
    repeat with l in lists
        set listName to name of l
        repeat with r in (every reminder of l)
            if completed of r is false then
                set rDate to due date of r
                if rDate is not missing value and rDate >= now and rDate <= endDate then
                    set rId to id of r
                    set rName to name of r
                    set rBody to body of r
                    set rPri to priority of r
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    set rLine to rLine & tab & "due=" & (rDate as string)
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=false"
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end if
        end repeat
    end repeat
    return output
end tell"""
        try:
            raw_lines = lines_from_applescript(script, timeout=TIMEOUT_CROSS_LIST)
        except RuntimeError as exc:
            logger.error("get_upcoming_reminders failed: %s", exc)
            raise ToolError(str(exc)) from exc

        data_lines, skipped = _split_skipped_lines(raw_lines)
        results = [_parse_tsv_line(ln) for ln in data_lines]
        result: dict = {"reminders": results, "count": len(results), "days": days}
        return _add_skipped_warning(result, skipped)
