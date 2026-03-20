# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""Tests for TSV parsing in mac-bridge reminders and calendar modules."""

from macos_mcp.reminders import _parse_tsv_line
from macos_mcp.calendar import _parse_calendar_tsv


# ---------------------------------------------------------------------------
# Reminders TSV parsing
# ---------------------------------------------------------------------------


class TestParseReminderTSV:
    def test_basic_fields(self):
        line = "id=123\ttitle=Buy milk\tdue=2025-01-01\tpriority=0\tcompleted=false"
        result = _parse_tsv_line(line)
        assert result["id"] == "123"
        assert result["title"] == "Buy milk"
        assert result["due"] == "2025-01-01"
        assert result["priority"] == "none"
        assert result["completed"] is False

    def test_priority_mapping(self):
        for raw, expected in [("0", "none"), ("1", "high"), ("5", "medium"), ("9", "low")]:
            line = f"id=1\tpriority={raw}"
            assert _parse_tsv_line(line)["priority"] == expected

    def test_unknown_priority_passthrough(self):
        line = "id=1\tpriority=42"
        assert _parse_tsv_line(line)["priority"] == "42"

    def test_completed_true(self):
        line = "id=1\tcompleted=true"
        assert _parse_tsv_line(line)["completed"] is True

    def test_body_with_tabs(self):
        # body= is always last; tabs in body should be preserved
        line = "id=1\ttitle=Test\tbody=line1\tline2\tline3"
        result = _parse_tsv_line(line)
        assert result["body"] == "line1\tline2\tline3"

    def test_body_empty(self):
        line = "id=1\ttitle=Test\tbody="
        result = _parse_tsv_line(line)
        assert result["body"] == ""

    def test_list_field(self):
        line = "list=Work\tid=1\ttitle=Task"
        result = _parse_tsv_line(line)
        assert result["list"] == "Work"

    def test_count_field_numeric(self):
        line = "name=Shopping\tcount=12"
        result = _parse_tsv_line(line)
        assert result["count"] == 12

    def test_count_field_non_numeric(self):
        line = "name=Test\tcount=abc"
        result = _parse_tsv_line(line)
        assert result["count"] == "abc"

    def test_empty_line(self):
        assert _parse_tsv_line("") == {}

    def test_field_without_equals(self):
        line = "id=1\tbadfield\ttitle=Test"
        result = _parse_tsv_line(line)
        assert result["id"] == "1"
        assert result["title"] == "Test"
        assert "badfield" not in result

    def test_missing_value_fields(self):
        line = "id=1\ttitle=Test\tdue="
        result = _parse_tsv_line(line)
        assert result["due"] == ""


# ---------------------------------------------------------------------------
# Calendar TSV parsing
# ---------------------------------------------------------------------------


class TestParseCalendarTSV:
    def test_basic_event(self):
        line = "cal=Work\ttitle=Meeting\tstart=2025-01-01 09:00\tend=2025-01-01 10:00\tallday=false"
        result = _parse_calendar_tsv(line)
        assert result["cal"] == "Work"
        assert result["title"] == "Meeting"
        assert result["allday"] is False

    def test_allday_true(self):
        line = "cal=Personal\ttitle=Holiday\tallday=true"
        result = _parse_calendar_tsv(line)
        assert result["allday"] is True

    def test_notes_with_tabs(self):
        # notes= is always last, may contain tabs
        line = "cal=Work\ttitle=Meeting\tnotes=agenda\titem 1\titem 2"
        result = _parse_calendar_tsv(line)
        assert result["notes"] == "agenda\titem 1\titem 2"

    def test_notes_empty(self):
        line = "cal=Work\ttitle=Test\tnotes="
        result = _parse_calendar_tsv(line)
        assert result["notes"] == ""

    def test_location_field(self):
        line = "cal=Work\ttitle=Meeting\tlocation=Room 42"
        result = _parse_calendar_tsv(line)
        assert result["location"] == "Room 42"

    def test_count_numeric(self):
        line = "name=Calendar\tcount=5"
        result = _parse_calendar_tsv(line)
        assert result["count"] == 5

    def test_empty_line(self):
        assert _parse_calendar_tsv("") == {}
