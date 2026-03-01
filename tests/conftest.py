"""Shared fixtures for macOS MCP tests."""

import pytest

from fastmcp import FastMCP

from macos_mcp.calendar import register_tools as register_calendar_tools
from macos_mcp.reminders import register_tools as register_reminder_tools


@pytest.fixture()
def mcp_server():
    """Create a FastMCP server with all tools registered (no subprocess calls)."""
    mcp = FastMCP(name="mac-bridge-test", on_duplicate="error")
    register_reminder_tools(mcp)
    register_calendar_tools(mcp)
    return mcp
