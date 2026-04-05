# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""Tests for mac-bridge tool registration, schema generation, and MCP compliance."""

import asyncio

import pytest

from fastmcp import FastMCP

from macos_mcp.calendar import register_tools as register_calendar_tools
from macos_mcp.mail import register_tools as register_mail_tools
from macos_mcp.reminders import register_tools as register_reminder_tools


EXPECTED_TOOLS = {
    # Reminders (6)
    "list_reminders",
    "get_reminders",
    "get_reminder_detail",
    "search_reminders",
    "get_overdue_reminders",
    "get_upcoming_reminders",
    # Calendar (4)
    "list_calendars",
    "get_calendar_events",
    "get_today_events",
    "search_calendar_events",
    # Mail (4)
    "list_mailboxes",
    "get_unread_emails",
    "search_emails",
    "get_email_detail",
}


@pytest.fixture()
def tool_list(mcp_server):
    """Get the list of FunctionTool objects from the server."""
    return asyncio.run(mcp_server.list_tools())


@pytest.fixture()
def tools_by_name(tool_list):
    """Map of tool name → FunctionTool."""
    return {t.name: t for t in tool_list}


class TestToolRegistration:
    def test_all_14_tools_registered(self, tools_by_name):
        assert set(tools_by_name.keys()) == EXPECTED_TOOLS

    def test_no_duplicate_registration(self):
        """on_duplicate='error' should raise if a tool is registered twice."""
        mcp = FastMCP(name="dup-test", on_duplicate="error")
        register_reminder_tools(mcp)
        with pytest.raises(Exception):
            register_reminder_tools(mcp)

    def test_all_tools_have_readonly_hint(self, tools_by_name):
        for name, tool in tools_by_name.items():
            assert tool.annotations is not None, f"{name} missing annotations"
            assert tool.annotations.readOnlyHint is True, (
                f"{name} missing readOnlyHint"
            )

    def test_all_tools_have_descriptions(self, tools_by_name):
        for name, tool in tools_by_name.items():
            assert tool.description, f"{name} has no description"
            assert len(tool.description) > 20, f"{name} description too short"

    def test_all_tools_have_timeout(self, tools_by_name):
        for name, tool in tools_by_name.items():
            assert tool.timeout is not None, f"{name} missing timeout"
            assert tool.timeout > 0, f"{name} has non-positive timeout"


class TestToolSchemas:
    """Verify JSON Schema is generated for tool parameters."""

    def test_get_reminders_has_parameter_schema(self, tools_by_name):
        tool = tools_by_name["get_reminders"]
        props = tool.parameters.get("properties", {})
        assert "list_name" in props
        assert "limit" in props
        assert "offset" in props

    def test_limit_has_constraints(self, tools_by_name):
        tool = tools_by_name["get_reminders"]
        limit_schema = tool.parameters["properties"]["limit"]
        assert limit_schema.get("minimum") == 1
        assert limit_schema.get("maximum") == 200

    def test_search_query_has_min_length(self, tools_by_name):
        tool = tools_by_name["search_reminders"]
        query_schema = tool.parameters["properties"]["query"]
        assert query_schema.get("minLength") == 1

    def test_get_calendar_events_has_parameter_schema(self, tools_by_name):
        tool = tools_by_name["get_calendar_events"]
        props = tool.parameters.get("properties", {})
        assert "calendar_name" in props
        assert "start_date" in props
        assert "end_date" in props
        assert "limit" in props

    def test_days_field_has_constraints(self, tools_by_name):
        tool = tools_by_name["get_upcoming_reminders"]
        days_schema = tool.parameters["properties"]["days"]
        assert days_schema.get("minimum") == 0
        assert days_schema.get("maximum") == 365

    def test_offset_has_minimum(self, tools_by_name):
        tool = tools_by_name["get_reminders"]
        offset_schema = tool.parameters["properties"]["offset"]
        assert offset_schema.get("minimum") == 0

    def test_days_back_forward_constraints(self, tools_by_name):
        tool = tools_by_name["search_calendar_events"]
        props = tool.parameters["properties"]
        assert props["days_back"]["minimum"] == 0
        assert props["days_back"]["maximum"] == 365
        assert props["days_forward"]["minimum"] == 0
        assert props["days_forward"]["maximum"] == 365
