"""Tests for the server entry point and MCP server configuration."""

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
        assert len(tools) == 11

    def test_on_duplicate_error(self):
        assert mcp._on_duplicate == "error"
