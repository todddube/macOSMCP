"""
macOS Reminders tools for the macOS Apps MCP server.

All six tools use batch AppleScript property fetching to minimise IPC round-trips:
instead of N × M osascript calls (one per item per property), each list is
resolved with ~5 batch fetches regardless of size, then pure-AppleScript loops
handle filtering — dramatically reducing latency for large lists.
"""

import logging
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
    ErrorResult,
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
    completed_clause = "" if include_completed else "whose completed is false"
    if include_completed:
        comp_fetch = "        set allComps to completed of rems"
        comp_field = (
            '            set rLine to rLine & tab & "priority=" & rPri'
            ' & tab & "completed=" & (item i of allComps)'
        )
    else:
        comp_fetch = ""
        comp_field = (
            '            set rLine to rLine & tab & "priority=" & rPri'
            ' & tab & "completed=false"'
        )
    return f"""tell application "Reminders"
    try
        set rems to reminders of list "{safe_list}" {completed_clause}
        set total to count of rems
        if total is 0 then return ""
        set allIds to id of rems
        set allNames to name of rems
        set allDates to due date of rems
        set allBodies to body of rems
        set allPris to priority of rems
{comp_fetch}
        set startIdx to {offset} + 1
        if startIdx > total then return ""
        set endIdx to {offset} + {limit}
        if endIdx > total then set endIdx to total
        set output to ""
        repeat with i from startIdx to endIdx
            set rId to item i of allIds
            set rName to item i of allNames
            set rDate to item i of allDates
            set rBody to item i of allBodies
            set rPri to item i of allPris
            set rLine to "id=" & rId & tab & "title=" & rName
            if rDate is not missing value then
                set rLine to rLine & tab & "due=" & (rDate as string)
            end if
{comp_field}
            if rBody is not missing value and rBody is not "" then
                set rLine to rLine & tab & "body=" & rBody
            end if
            set output to output & rLine & linefeed
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_all_lists_get_script(
    include_completed: bool, limit: int, offset: int
) -> str:
    completed_clause = "" if include_completed else "whose completed is false"
    if include_completed:
        comp_fetch = "            set allComps to completed of rems"
        comp_field = (
            '                    set rLine to rLine & tab & "priority=" & rPri'
            ' & tab & "completed=" & (item i of allComps)'
        )
    else:
        comp_fetch = ""
        comp_field = (
            '                    set rLine to rLine & tab & "priority=" & rPri'
            ' & tab & "completed=false"'
        )
    return f"""tell application "Reminders"
    set output to ""
    set hitCount to 0
    set skipCount to 0
    repeat with l in lists
        set listName to name of l
        set rems to reminders of l {completed_clause}
        set total to count of rems
        if total > 0 then
            set allIds to id of rems
            set allNames to name of rems
            set allDates to due date of rems
            set allBodies to body of rems
            set allPris to priority of rems
{comp_fetch}
            repeat with i from 1 to total
                if skipCount < {offset} then
                    set skipCount to skipCount + 1
                else
                    set rId to item i of allIds
                    set rName to item i of allNames
                    set rDate to item i of allDates
                    set rBody to item i of allBodies
                    set rPri to item i of allPris
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
{comp_field}
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end repeat
        end if
    end repeat
    return output
end tell"""


# ---------------------------------------------------------------------------
# AppleScript builders for search_reminders
# ---------------------------------------------------------------------------


def _build_single_list_search_script(
    safe_list: str, safe_query: str, completed_clause: str, limit: int
) -> str:
    return f"""tell application "Reminders"
    try
        set rems to reminders of list "{safe_list}" {completed_clause}
        set total to count of rems
        if total is 0 then return ""
        set allNames to name of rems
        set allIds to id of rems
        set allDates to due date of rems
        set allBodies to body of rems
        set allPris to priority of rems
        set allComps to completed of rems
        set output to ""
        set hitCount to 0
        repeat with i from 1 to total
            if (item i of allNames) contains "{safe_query}" then
                set rId to item i of allIds
                set rName to item i of allNames
                set rDate to item i of allDates
                set rBody to item i of allBodies
                set rPri to item i of allPris
                set rComp to item i of allComps
                set rLine to "id=" & rId & tab & "title=" & rName
                if rDate is not missing value then
                    set rLine to rLine & tab & "due=" & (rDate as string)
                end if
                set rLine to rLine & tab & "priority=" & rPri & tab & "completed=" & rComp
                if rBody is not missing value and rBody is not "" then
                    set rLine to rLine & tab & "body=" & rBody
                end if
                set output to output & rLine & linefeed
                set hitCount to hitCount + 1
                if hitCount >= {limit} then return output
            end if
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_all_lists_search_script(
    safe_query: str, completed_clause: str, limit: int
) -> str:
    return f"""tell application "Reminders"
    set output to ""
    set hitCount to 0
    repeat with l in lists
        set listName to name of l
        set rems to reminders of l {completed_clause}
        set total to count of rems
        if total > 0 then
            set allNames to name of rems
            set allIds to id of rems
            set allDates to due date of rems
            set allBodies to body of rems
            set allPris to priority of rems
            set allComps to completed of rems
            repeat with i from 1 to total
                if (item i of allNames) contains "{safe_query}" then
                    set rId to item i of allIds
                    set rName to item i of allNames
                    set rDate to item i of allDates
                    set rBody to item i of allBodies
                    set rPri to item i of allPris
                    set rComp to item i of allComps
                    set rLine to "list=" & listName & tab & "id=" & rId & tab & "title=" & rName
                    if rDate is not missing value then
                        set rLine to rLine & tab & "due=" & (rDate as string)
                    end if
                    set rLine to rLine & tab & "priority=" & rPri & tab & "completed=" & rComp
                    if rBody is not missing value and rBody is not "" then
                        set rLine to rLine & tab & "body=" & rBody
                    end if
                    set output to output & rLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {limit} then return output
                end if
            end repeat
        end if
    end repeat
    return output
end tell"""


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


def register_tools(mcp: FastMCP) -> None:
    """Register all Reminders tools on the given FastMCP instance."""

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=60)
    def list_reminders() -> ReminderListsResult | ErrorResult:
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
        set lCount to count of reminders of l
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
            return {"error": str(exc)}

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_reminders(
        list_name: Annotated[Optional[str], Field(description="Name of a specific list to query. Omit for all lists.")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
        offset: Annotated[int, Field(ge=0, description="Skip the first N results for pagination")] = 0,
    ) -> RemindersResult | ErrorResult:
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
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        reminders = []
        for ln in raw_lines:
            obj = _parse_tsv_line(ln)
            if list_name and "list" not in obj:
                obj["list"] = list_name
            reminders.append(obj)

        return {
            "reminders": reminders,
            "count": len(reminders),
            "list": list_name or "all",
            "offset": offset,
        }

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=60)
    def get_reminder_detail(
        list_name: Annotated[str, Field(description="The list containing the reminder")],
        title: Annotated[str, Field(description="Title (name) of the reminder")],
    ) -> ReminderDetailResult | ErrorResult:
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
        set theList to list "{safe_list}"
        set rems to reminders of theList
        set total to count of rems
        if total is 0 then return ""
        set allNames to name of rems
        set output to ""
        repeat with i from 1 to total
            if (item i of allNames) is "{safe_title}" then
                set r to item i of rems
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
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        results = []
        for ln in raw_lines:
            obj = _parse_tsv_line(ln)
            obj["list"] = list_name
            results.append(obj)

        return {
            "reminders": results,
            "count": len(results),
            "list": list_name,
            "query_title": title,
        }

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def search_reminders(
        query: Annotated[str, Field(min_length=1, description="Text to find in reminder titles")],
        list_name: Annotated[Optional[str], Field(description="Scope search to one list. Omit for all lists.")] = None,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> ReminderSearchResult | ErrorResult:
        """Search for reminders whose title contains the query string (case-insensitive).

        Completed reminders are always excluded.

        Args:
            query:     Text to find in reminder titles.
            list_name: Scope search to one list (optional; all lists if omitted).
            limit:     Maximum results to return (default: 50).

        Returns a JSON object with matching reminder objects.
        """
        if not query or not query.strip():
            return {"error": "query must not be empty"}

        safe_query = sanitize_for_applescript(query)
        safe_list = sanitize_for_applescript(list_name) if list_name else None
        completed_clause = "whose completed is false"

        if list_name:
            script = _build_single_list_search_script(
                safe_list, safe_query, completed_clause, limit
            )
            timeout = TIMEOUT_NORMAL
        else:
            script = _build_all_lists_search_script(safe_query, completed_clause, limit)
            timeout = TIMEOUT_CROSS_LIST

        try:
            raw_lines = lines_from_applescript(script, timeout=timeout)
        except RuntimeError as exc:
            logger.error("search_reminders failed: %s", exc)
            return {"error": str(exc)}

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            return {"error": raw_lines[0]}

        results = []
        for ln in raw_lines:
            obj = _parse_tsv_line(ln)
            if list_name and "list" not in obj:
                obj["list"] = list_name
            results.append(obj)

        return {"query": query, "results": results, "count": len(results)}

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_overdue_reminders(
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> OverdueRemindersResult | ErrorResult:
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
        set rems to reminders of l whose completed is false
        set total to count of rems
        if total > 0 then
            set allNames to name of rems
            set allDates to due date of rems
            set allBodies to body of rems
            set allPris to priority of rems
            repeat with i from 1 to total
                set rDate to item i of allDates
                if rDate is not missing value and rDate < now then
                    set rId to id of (item i of rems)
                    set rName to item i of allNames
                    set rBody to item i of allBodies
                    set rPri to item i of allPris
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
            end repeat
        end if
    end repeat
    return output
end tell"""
        try:
            raw_lines = lines_from_applescript(script, timeout=TIMEOUT_CROSS_LIST)
        except RuntimeError as exc:
            logger.error("get_overdue_reminders failed: %s", exc)
            return {"error": str(exc)}

        results = [_parse_tsv_line(ln) for ln in raw_lines]
        return {"reminders": results, "count": len(results)}

    @mcp.tool(annotations={"readOnlyHint": True}, timeout=90)
    def get_upcoming_reminders(
        days: Annotated[int, Field(ge=0, le=365, description="Number of days to look ahead")] = 7,
        limit: Annotated[int, Field(ge=1, le=200, description="Maximum results to return")] = 50,
    ) -> UpcomingRemindersResult | ErrorResult:
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
        set rems to reminders of l whose completed is false
        set total to count of rems
        if total > 0 then
            set allNames to name of rems
            set allDates to due date of rems
            set allBodies to body of rems
            set allPris to priority of rems
            repeat with i from 1 to total
                set rDate to item i of allDates
                if rDate is not missing value and rDate >= now and rDate <= endDate then
                    set rId to id of (item i of rems)
                    set rName to item i of allNames
                    set rBody to item i of allBodies
                    set rPri to item i of allPris
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
            end repeat
        end if
    end repeat
    return output
end tell"""
        try:
            raw_lines = lines_from_applescript(script, timeout=TIMEOUT_CROSS_LIST)
        except RuntimeError as exc:
            logger.error("get_upcoming_reminders failed: %s", exc)
            return {"error": str(exc)}

        results = [_parse_tsv_line(ln) for ln in raw_lines]
        return {"reminders": results, "count": len(results), "days": days}
