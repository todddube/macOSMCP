# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""Tests for the mac-bridge server entry point and MCP server configuration."""

import asyncio

from server import mcp


class TestServerConfig:
    def test_server_name(self):
        assert mcp.name == "mac-bridge"

    def test_has_instructions(self):
        assert mcp.instructions is not None
        assert "Reminders" in mcp.instructions
        assert "Calendar" in mcp.instructions

    def test_all_tools_registered(self):
        tools = asyncio.run(mcp.list_tools())
        # 6 reminders + 4 calendar + 1 messaging + 4 mail = 15
        assert len(tools) == 15

    def test_on_duplicate_error(self):
        assert mcp._on_duplicate == "error"
