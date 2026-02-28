#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "fastmcp>=2.0",
# ]
# ///
"""
macOS Reminders MCP Server — Read-Only POC

Exposes macOS Reminders to Claude via the Model Context Protocol.
Uses AppleScript (osascript) as the bridge; no third-party native
frameworks required.

Tools exposed:
  - list_reminder_lists   : enumerate all Reminders lists
  - get_reminders         : fetch incomplete (or all) reminders from a list
  - search_reminders      : full-text search across all lists

Only READ operations are implemented in this POC.
"""

import json
import logging
import subprocess
from typing import Optional

from fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Server bootstrap
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger("reminders_mcp")

mcp = FastMCP(
    name="macOS Reminders",
    instructions=(
        "Read-only access to macOS Reminders via AppleScript. "
        "Call list_reminder_lists first to discover available lists, "
        "then use get_reminders or search_reminders to fetch tasks."
    ),
)

# ---------------------------------------------------------------------------
# AppleScript helper
# ---------------------------------------------------------------------------

_TIMEOUT = 30  # seconds


def _run_applescript(script: str) -> str:
    """
    Execute an AppleScript snippet via osascript and return stdout.

    Raises RuntimeError on non-zero exit so callers can handle gracefully.
    """
    logger.debug("Running AppleScript:\n%s", script)
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=_TIMEOUT,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "AppleScript returned non-zero exit")
    return result.stdout.strip()


def _lines_from_applescript(script: str) -> list[str]:
    """
    Run AppleScript and split output on newlines, filtering empty lines.
    Scripts must use `linefeed` as the item separator (not commas) so that
    reminder names containing commas are preserved correctly.
    """
    raw = _run_applescript(script)
    return [ln.strip() for ln in raw.splitlines() if ln.strip()]


# ---------------------------------------------------------------------------
# MCP Tools (read-only)
# ---------------------------------------------------------------------------


@mcp.tool()
def list_reminder_lists() -> str:
    """
    List all Reminder lists in macOS Reminders.

    Returns a JSON object:
        { "lists": ["Work", "Personal", ...], "count": N }
    """
    script = """
tell application "Reminders"
    set output to ""
    repeat with l in lists
        set output to output & (name of l) & linefeed
    end repeat
    return output
end tell
"""
    try:
        items = _lines_from_applescript(script)
        return json.dumps({"lists": items, "count": len(items)}, indent=2)
    except RuntimeError as exc:
        logger.error("list_reminder_lists failed: %s", exc)
        return json.dumps({"error": str(exc)})


@mcp.tool()
def get_reminders(
    list_name: Optional[str] = None,
    include_completed: bool = False,
    max_results: int = 50,
) -> str:
    """
    Fetch reminders from macOS Reminders.

    Args:
        list_name:         Name of a specific list to query.
                           Omit (or pass None) to query all lists.
        include_completed: Include already-completed reminders (default: False).
        max_results:       Cap results to avoid timeouts on large libraries (default: 50).

    Returns a JSON array of reminder objects:
        [{ "list": "Work", "title": "...", "due": "...", "note": "...", "completed": false }, ...]

    Note: The all-lists query iterates every list sequentially via AppleScript.
    For large Reminders libraries prefer querying a specific list_name.
    """
    # Use `whose` only on single-list queries — it's fast there but can be
    # extremely slow when applied across all reminders (known AppleScript/Reminders perf issue).
    if list_name:
        completed_clause = "" if include_completed else "whose completed is false"
        script = f"""
tell application "Reminders"
    set output to ""
    try
        repeat with r in (reminders of list "{list_name}" {completed_clause})
            set rLine to (name of r)
            if due date of r is not missing value then
                set rLine to rLine & tab & "due=" & (due date of r as string)
            end if
            if body of r is not missing value and body of r is not "" then
                set rLine to rLine & tab & "note=" & (body of r)
            end if
            if completed of r then
                set rLine to rLine & tab & "completed=true"
            end if
            set output to output & rLine & linefeed
        end repeat
    on error errMsg
        return "ERROR:" & errMsg
    end try
    return output
end tell
"""
    else:
        # All-lists: iterate manually and filter completed in AppleScript
        # to avoid the slow `whose` predicate across all lists.
        skip_completed = "if completed of r is false then" if not include_completed else "if true then"
        script = f"""
tell application "Reminders"
    set output to ""
    set hitCount to 0
    repeat with l in lists
        set listName to name of l
        repeat with r in reminders of l
            {skip_completed}
                set rLine to "list=" & listName & tab & (name of r)
                if due date of r is not missing value then
                    set rLine to rLine & tab & "due=" & (due date of r as string)
                end if
                if body of r is not missing value and body of r is not "" then
                    set rLine to rLine & tab & "note=" & (body of r)
                end if
                if completed of r then
                    set rLine to rLine & tab & "completed=true"
                end if
                set output to output & rLine & linefeed
                set hitCount to hitCount + 1
                if hitCount >= {max_results} then return output
            end if
        end repeat
    end repeat
    return output
end tell
"""

    try:
        raw_lines = _lines_from_applescript(script)
    except RuntimeError as exc:
        logger.error("get_reminders failed: %s", exc)
        return json.dumps({"error": str(exc)})

    if raw_lines and raw_lines[0].startswith("ERROR:"):
        return json.dumps({"error": raw_lines[0]})

    reminders = []
    for line in raw_lines:
        fields = line.split("\t")
        obj: dict = {"list": list_name or "unknown", "completed": False}

        # First field is either "list=<name>" (all-lists mode) or the title directly
        first = fields[0]
        if first.startswith("list="):
            obj["list"] = first[5:]
            obj["title"] = fields[1] if len(fields) > 1 else ""
            rest = fields[2:]
        else:
            obj["title"] = first
            rest = fields[1:]

        for kv in rest:
            if kv.startswith("due="):
                obj["due"] = kv[4:]
            elif kv.startswith("note="):
                obj["note"] = kv[5:]
            elif kv == "completed=true":
                obj["completed"] = True

        reminders.append(obj)

    return json.dumps(
        {"reminders": reminders, "count": len(reminders), "list": list_name or "all"},
        indent=2,
    )


@mcp.tool()
def search_reminders(query: str) -> str:
    """
    Search for reminders whose title contains the query string (case-sensitive).
    Searches across all Reminder lists.

    Args:
        query: Text to find in reminder titles.

    Returns a JSON array of matching reminder objects with list, title, due, note, completed.
    """
    if not query or not query.strip():
        return json.dumps({"error": "query must not be empty"})

    # Escape double-quotes in the query to avoid AppleScript injection
    safe_query = query.replace('"', '\\"')

    script = f"""
tell application "Reminders"
    set output to ""
    repeat with l in lists
        set listName to name of l
        repeat with r in reminders of l
            if name of r contains "{safe_query}" then
                set rLine to "list=" & listName & tab & (name of r)
                if due date of r is not missing value then
                    set rLine to rLine & tab & "due=" & (due date of r as string)
                end if
                if body of r is not missing value and body of r is not "" then
                    set rLine to rLine & tab & "note=" & (body of r)
                end if
                if completed of r then
                    set rLine to rLine & tab & "completed=true"
                end if
                set output to output & rLine & linefeed
            end if
        end repeat
    end repeat
    return output
end tell
"""
    try:
        raw_lines = _lines_from_applescript(script)
    except RuntimeError as exc:
        logger.error("search_reminders failed: %s", exc)
        return json.dumps({"error": str(exc)})

    results = []
    for line in raw_lines:
        fields = line.split("\t")
        obj: dict = {"completed": False}
        first = fields[0]
        if first.startswith("list="):
            obj["list"] = first[5:]
            obj["title"] = fields[1] if len(fields) > 1 else ""
            rest = fields[2:]
        else:
            obj["list"] = "unknown"
            obj["title"] = first
            rest = fields[1:]

        for kv in rest:
            if kv.startswith("due="):
                obj["due"] = kv[4:]
            elif kv.startswith("note="):
                obj["note"] = kv[5:]
            elif kv == "completed=true":
                obj["completed"] = True

        results.append(obj)

    return json.dumps(
        {"query": query, "results": results, "count": len(results)},
        indent=2,
    )


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    logger.info("Starting macOS Reminders MCP server (read-only)")
    mcp.run()
