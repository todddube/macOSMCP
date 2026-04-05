# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""Shared fixtures for mac-bridge tests."""

import pytest

from fastmcp import FastMCP

from macos_mcp.calendar import register_tools as register_calendar_tools
from macos_mcp.mail import register_tools as register_mail_tools
from macos_mcp.reminders import register_tools as register_reminder_tools


@pytest.fixture()
def mcp_server():
    """Create a FastMCP server with all read-only tools registered (no subprocess calls).

    Includes: reminders (6) + calendar (4) + mail (4) = 14 tools.
    messaging (send_imessage) is excluded — it is a write operation with
    readOnlyHint=False and is tested separately.
    """
    mcp = FastMCP(name="mac-bridge-test", on_duplicate="error")
    register_reminder_tools(mcp)
    register_calendar_tools(mcp)
    register_mail_tools(mcp)
    return mcp
