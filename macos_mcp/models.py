"""
Typed return models for macOS MCP tools.

FastMCP auto-generates ``outputSchema`` from these TypedDicts so that MCP
clients can validate responses programmatically.
"""

from __future__ import annotations

from typing import TypedDict


# ---------------------------------------------------------------------------
# Reminders
# ---------------------------------------------------------------------------


class ReminderListInfo(TypedDict):
    name: str
    count: int


class ReminderListsResult(TypedDict):
    lists: list[ReminderListInfo]
    count: int


class ReminderItem(TypedDict, total=False):
    id: str
    title: str
    list: str
    due: str
    priority: str
    completed: bool
    body: str


class RemindersResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    list: str
    offset: int


class ReminderDetailResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    list: str
    query_title: str


class ReminderSearchResult(TypedDict):
    query: str
    results: list[ReminderItem]
    count: int


class OverdueRemindersResult(TypedDict):
    reminders: list[ReminderItem]
    count: int


class UpcomingRemindersResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    days: int


# ---------------------------------------------------------------------------
# Calendar
# ---------------------------------------------------------------------------


class CalendarInfo(TypedDict, total=False):
    name: str
    description: str


class CalendarListResult(TypedDict):
    calendars: list[CalendarInfo]
    count: int


class CalendarEvent(TypedDict, total=False):
    cal: str
    title: str
    start: str
    end: str
    allday: bool
    location: str
    notes: str


class CalendarEventsResult(TypedDict):
    events: list[CalendarEvent]
    count: int
    start_date: str
    end_date: str
    calendar: str


class TodayEventsResult(TypedDict):
    events: list[CalendarEvent]
    count: int
    date: str
    calendar: str


class CalendarSearchResult(TypedDict):
    query: str
    results: list[CalendarEvent]
    count: int
    start_date: str
    end_date: str
    calendar: str


# ---------------------------------------------------------------------------
# Error
# ---------------------------------------------------------------------------


class ErrorResult(TypedDict):
    error: str
