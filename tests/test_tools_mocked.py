"""Integration tests for tool functions with mocked subprocess calls.

These tests verify the full tool flow (parameter handling -> subprocess call ->
output parsing -> structured return) without requiring macOS Reminders/Calendar access.
"""

import asyncio
from unittest.mock import patch

import pytest
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

from macos_mcp.applescript import _cache
from macos_mcp.calendar import register_tools as register_calendar_tools
from macos_mcp.reminders import register_tools as register_reminder_tools


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mock_subprocess(target_module: str, output: str, returncode: int = 0, stderr: str = ""):
    """Create a mock for subprocess.run in the given module."""
    class MockResult:
        def __init__(self):
            self.stdout = output
            self.returncode = returncode
            self.stderr = stderr

    return patch(f"{target_module}.subprocess.run", return_value=MockResult())


def _mock_applescript(output: str, returncode: int = 0, stderr: str = ""):
    """Mock subprocess.run in the applescript module (for Reminders + list_calendars)."""
    return _mock_subprocess("macos_mcp.applescript", output, returncode, stderr)


def _mock_swift_helper(output: str, returncode: int = 0, stderr: str = ""):
    """Mock subprocess.run in the calendar module (for Swift EventKit helper)."""
    return _mock_subprocess("macos_mcp.calendar", output, returncode, stderr)


@pytest.fixture()
def tools():
    """Register tools and return a dict of {name: callable} using the raw fn."""
    mcp = FastMCP(name="test", on_duplicate="error")
    register_reminder_tools(mcp)
    register_calendar_tools(mcp)
    tool_list = asyncio.run(mcp.list_tools())
    return {t.name: t.fn for t in tool_list}


@pytest.fixture(autouse=True)
def clear_cache():
    _cache.clear()
    yield
    _cache.clear()


# ---------------------------------------------------------------------------
# Reminders tools
# ---------------------------------------------------------------------------


class TestListReminders:
    def test_returns_structured_result(self, tools):
        output = "name=Work\tcount=5\nname=Personal\tcount=3\n"
        with _mock_applescript(output):
            result = tools["list_reminders"]()
        assert result["count"] == 2
        assert result["lists"][0]["name"] == "Work"
        assert result["lists"][0]["count"] == 5
        assert result["lists"][1]["name"] == "Personal"

    def test_empty_result(self, tools):
        with _mock_applescript(""):
            result = tools["list_reminders"]()
        assert result["count"] == 0
        assert result["lists"] == []

    def test_caches_result(self, tools):
        output = "name=Work\tcount=5\n"
        with _mock_applescript(output) as mock_run:
            tools["list_reminders"]()
            tools["list_reminders"]()
            assert mock_run.call_count == 1

    def test_applescript_error_raises_tool_error(self, tools):
        with _mock_applescript("", returncode=1, stderr="some error"):
            with pytest.raises(ToolError, match="some error"):
                tools["list_reminders"]()


class TestGetReminders:
    def test_single_list(self, tools):
        output = "id=x1\ttitle=Buy milk\tdue=2025-01-01\tpriority=0\tcompleted=false\n"
        with _mock_applescript(output):
            result = tools["get_reminders"](list_name="Groceries")
        assert result["count"] == 1
        assert result["list"] == "Groceries"
        assert result["reminders"][0]["title"] == "Buy milk"
        assert result["reminders"][0]["list"] == "Groceries"

    def test_all_lists(self, tools):
        output = "list=Work\tid=1\ttitle=Task1\tpriority=1\tcompleted=false\n"
        with _mock_applescript(output):
            result = tools["get_reminders"]()
        assert result["list"] == "all"
        assert result["reminders"][0]["list"] == "Work"

    def test_applescript_inline_error_raises(self, tools):
        with _mock_applescript("ERROR:list not found"):
            with pytest.raises(ToolError, match="ERROR:list not found"):
                tools["get_reminders"](list_name="Nonexistent")

    def test_offset_passed(self, tools):
        with _mock_applescript(""):
            result = tools["get_reminders"](offset=10)
        assert result["offset"] == 10


class TestGetReminderDetail:
    def test_returns_detail_fields(self, tools):
        output = (
            "id=x1\ttitle=Call Bob\tcompleted=false\t"
            "due=2025-06-01\tcreation_date=2025-01-01\t"
            "modification_date=2025-05-30\tpriority=1\t"
            "body=Remember to discuss project"
        )
        with _mock_applescript(output):
            result = tools["get_reminder_detail"](list_name="Work", title="Call Bob")
        assert result["list"] == "Work"
        assert result["query_title"] == "Call Bob"
        assert result["reminders"][0]["priority"] == "high"
        assert result["reminders"][0]["body"] == "Remember to discuss project"

    def test_no_match(self, tools):
        with _mock_applescript(""):
            result = tools["get_reminder_detail"](list_name="Work", title="Nonexistent")
        assert result["count"] == 0


class TestSearchReminders:
    def test_returns_matching_reminders(self, tools):
        output = "id=1\ttitle=Buy groceries\tpriority=0\tcompleted=false\n"
        with _mock_applescript(output):
            result = tools["search_reminders"](query="groceries")
        assert result["query"] == "groceries"
        assert result["count"] == 1

    def test_empty_query_raises(self, tools):
        with pytest.raises(ToolError, match="query must not be empty"):
            tools["search_reminders"](query="   ")

    def test_scoped_to_list(self, tools):
        with _mock_applescript(""):
            result = tools["search_reminders"](query="test", list_name="Work")
        assert result["count"] == 0


class TestGetOverdueReminders:
    def test_returns_overdue(self, tools):
        output = (
            "list=Work\tid=1\ttitle=Overdue task\t"
            "due=2024-01-01\tpriority=5\tcompleted=false\n"
        )
        with _mock_applescript(output):
            result = tools["get_overdue_reminders"]()
        assert result["count"] == 1
        assert result["reminders"][0]["title"] == "Overdue task"
        assert result["reminders"][0]["priority"] == "medium"


class TestGetUpcomingReminders:
    def test_returns_upcoming(self, tools):
        output = (
            "list=Personal\tid=2\ttitle=Dentist\t"
            "due=2025-06-15\tpriority=9\tcompleted=false\n"
        )
        with _mock_applescript(output):
            result = tools["get_upcoming_reminders"](days=30)
        assert result["count"] == 1
        assert result["days"] == 30
        assert result["reminders"][0]["priority"] == "low"


# ---------------------------------------------------------------------------
# Calendar tools
# ---------------------------------------------------------------------------


class TestListCalendars:
    def test_returns_structured_result(self, tools):
        output = "name=Work\tdescription=Work calendar\nname=Personal\n"
        with _mock_applescript(output):
            result = tools["list_calendars"]()
        assert result["count"] == 2
        assert result["calendars"][0]["name"] == "Work"
        assert result["calendars"][0].get("description") == "Work calendar"

    def test_caches_result(self, tools):
        output = "name=Work\n"
        with _mock_applescript(output) as mock_run:
            tools["list_calendars"]()
            tools["list_calendars"]()
            assert mock_run.call_count == 1

    def test_applescript_error_raises(self, tools):
        with _mock_applescript("", returncode=1, stderr="Calendar error"):
            with pytest.raises(ToolError, match="Calendar error"):
                tools["list_calendars"]()

    def test_inline_error_raises(self, tools):
        with _mock_applescript("ERROR:something broke"):
            with pytest.raises(ToolError, match="ERROR:something broke"):
                tools["list_calendars"]()


class TestGetCalendarEvents:
    def test_returns_events(self, tools):
        output = (
            "cal=Work\ttitle=Meeting\tstart=2025-06-01 09:00\t"
            "end=2025-06-01 10:00\tallday=false\n"
        )
        with _mock_swift_helper(output):
            result = tools["get_calendar_events"](
                start_date="2025-06-01", end_date="2025-06-07"
            )
        assert result["count"] == 1
        assert result["events"][0]["title"] == "Meeting"
        assert result["events"][0]["allday"] is False
        assert result["start_date"] == "2025-06-01"
        assert result["end_date"] == "2025-06-07"

    def test_empty_result(self, tools):
        with _mock_swift_helper(""):
            result = tools["get_calendar_events"]()
        assert result["count"] == 0
        assert result["calendar"] == "all"

    def test_swift_error_raises(self, tools):
        with _mock_swift_helper("", returncode=1, stderr="EventKit access denied"):
            with pytest.raises(ToolError, match="EventKit access denied"):
                tools["get_calendar_events"]()

    def test_scoped_to_calendar(self, tools):
        output = "cal=Work\ttitle=Standup\tstart=09:00\tend=09:15\tallday=false\n"
        with _mock_swift_helper(output) as mock_run:
            result = tools["get_calendar_events"](calendar_name="Work")
        assert result["calendar"] == "Work"
        # Verify --calendar flag was passed
        call_args = mock_run.call_args[0][0]
        assert "--calendar" in call_args
        assert "Work" in call_args


class TestGetTodayEvents:
    def test_returns_today(self, tools):
        output = "cal=Personal\ttitle=Lunch\tstart=12:00\tend=13:00\tallday=false\n"
        with _mock_swift_helper(output):
            result = tools["get_today_events"]()
        assert result["count"] == 1
        assert result["calendar"] == "all"

    def test_scoped_to_calendar(self, tools):
        with _mock_swift_helper(""):
            result = tools["get_today_events"](calendar_name="Work")
        assert result["calendar"] == "Work"


class TestSearchCalendarEvents:
    def test_returns_matching_events(self, tools):
        output = "cal=Work\ttitle=Team Standup\tstart=09:00\tend=09:15\tallday=false\n"
        with _mock_swift_helper(output):
            result = tools["search_calendar_events"](query="standup")
        assert result["query"] == "standup"
        assert result["count"] == 1

    def test_empty_query_raises(self, tools):
        with pytest.raises(ToolError, match="query must not be empty"):
            tools["search_calendar_events"](query="  ")

    def test_custom_date_range(self, tools):
        with _mock_swift_helper(""):
            result = tools["search_calendar_events"](
                query="test", days_back=7, days_forward=7
            )
        assert result["count"] == 0

    def test_search_passes_query_to_swift(self, tools):
        with _mock_swift_helper("") as mock_run:
            tools["search_calendar_events"](query="meeting")
        call_args = mock_run.call_args[0][0]
        assert "--search" in call_args
        assert "meeting" in call_args
