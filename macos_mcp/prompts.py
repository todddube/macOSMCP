# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | April 2026

"""
MCP Prompts for mac-bridge — structured workflow templates.

Prompts are pre-written instructions that guide Claude through multi-step
tool workflows. They appear in MCP clients as slash commands or templates
and are invoked by the user (not automatically by the server).

Unlike tools, prompts return a text message that becomes the user's first
turn in the conversation, pre-loaded with context and instructions.

Available prompts:
    daily_planner  — Today's schedule + overdue/upcoming reminders
    weekly_review  — This week's events + all overdue items + 7-day reminders
"""

from datetime import date, timedelta

from fastmcp import FastMCP


def register_prompts(mcp: FastMCP) -> None:
    """Register all mac-bridge MCP prompts on the given FastMCP instance."""

    @mcp.prompt(
        description="Build a concise daily brief: today's calendar events, overdue tasks, and reminders due soon.",
    )
    def daily_planner() -> str:
        """What's on my calendar today and what tasks need attention?

        Calls get_today_events, get_overdue_reminders, and get_upcoming_reminders
        then presents a structured daily plan.
        """
        today = date.today().isoformat()
        return f"""\
Today is {today}. Use the mac-bridge tools to build my daily plan.

Steps:
1. Call get_today_events to fetch everything on my calendar today.
2. Call get_overdue_reminders (limit=50) to find all overdue tasks.
3. Call get_upcoming_reminders with days=3 and limit=50 for items due in the next 3 days.

Present the results as a concise daily brief with three sections:

**Today's Schedule**
List events sorted by start time. Flag any conflicts (overlapping events).
Show "Nothing scheduled today" if empty.

**Overdue**
List by priority (high → medium → low → none). Include which list each is in and how many days overdue.
Show "Nothing overdue" if empty.

**Due Soon (next 3 days)**
Group by due date. Show list name and priority.
Show "Nothing due in the next 3 days" if empty.

Keep the response tight and scannable — no filler text."""

    @mcp.prompt(
        description="Build a full week overview: this week's calendar, all overdue items, and 7-day reminder list.",
    )
    def weekly_review() -> str:
        """Show me everything on my plate for the week ahead.

        Calls get_calendar_events, get_overdue_reminders, and get_upcoming_reminders
        then presents a complete weekly overview.
        """
        today = date.today().isoformat()
        week_end = (date.today() + timedelta(days=7)).isoformat()
        return f"""\
Today is {today}. Use the mac-bridge tools to build my weekly review.

Steps:
1. Call get_calendar_events with start_date="{today}" and end_date="{week_end}" and limit=100.
2. Call get_overdue_reminders with limit=100 to surface everything past due.
3. Call get_upcoming_reminders with days=7 and limit=100 for this week's tasks.

Present the results as a structured weekly overview:

**This Week's Calendar ({today} → {week_end})**
Group events by day. Within each day, sort by start time.
Flag any conflicts (overlapping events on the same day).
Show "No events this week" if empty.

**Overdue Items**
List all overdue reminders sorted by priority (high first), then by how many days overdue.
Include the list name for each item.
Show "Nothing overdue" if empty.

**This Week's Reminders**
Group by due date. Within each day, sort by priority.
Include the list name for each item.
Show "No reminders due this week" if empty.

**Summary**
One line: total events this week, overdue count, upcoming reminder count.

Keep sections clearly separated. Prefer bullet points over prose."""
