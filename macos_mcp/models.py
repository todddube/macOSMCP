# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""
Typed return models for mac-bridge tools.

FastMCP auto-generates ``outputSchema`` from these TypedDicts so that MCP
clients can validate responses programmatically.
"""

from __future__ import annotations

from typing import NotRequired, TypedDict


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
    skipped_lists: NotRequired[list[str]]
    warning: NotRequired[str]


class ReminderDetailResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    list: str
    query_title: str
    skipped_lists: NotRequired[list[str]]
    warning: NotRequired[str]


class ReminderSearchResult(TypedDict):
    query: str
    results: list[ReminderItem]
    count: int
    skipped_lists: NotRequired[list[str]]
    warning: NotRequired[str]


class OverdueRemindersResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    skipped_lists: NotRequired[list[str]]
    warning: NotRequired[str]


class UpcomingRemindersResult(TypedDict):
    reminders: list[ReminderItem]
    count: int
    days: int
    skipped_lists: NotRequired[list[str]]
    warning: NotRequired[str]


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
# Messaging
# ---------------------------------------------------------------------------


class SendMessageResult(TypedDict):
    success: bool
    recipient: str
    message: str


# ---------------------------------------------------------------------------
# Mail
# ---------------------------------------------------------------------------


class MailboxInfo(TypedDict):
    account: str
    mailbox: str
    unread: int


class MailboxesResult(TypedDict):
    mailboxes: list[MailboxInfo]
    count: int


class EmailItem(TypedDict, total=False):
    id: str       # RFC 2822 Message-ID (e.g. <abc@mail.example.com>)
    subject: str
    sender: str
    date: str
    mailbox: str
    account: str


class EmailListResult(TypedDict):
    emails: list[EmailItem]
    count: int
    mailbox: str
    account: str


class EmailSearchResult(TypedDict):
    query: str
    results: list[EmailItem]
    count: int
    mailbox: str


class EmailDetailResult(TypedDict, total=False):
    found: bool
    id: str
    subject: str
    sender: str
    date: str
    mailbox: str
    body: str    # full message body — always last in TSV output


