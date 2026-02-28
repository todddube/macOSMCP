"""
macOS Apps MCP Server

Entry point for the macOS Apps MCP server. Currently provides read-only
access to macOS Reminders via AppleScript. Calendar and Mail support
are planned for future releases.

Run with:
    uv run server.py
"""

import logging

from fastmcp import FastMCP

from macos_mcp.reminders import register_tools

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger("macos_mcp")

mcp = FastMCP(
    name="macOS Apps",
    instructions=(
        "Read-only access to macOS Reminders via AppleScript. "
        "Call list_reminder_lists first to discover available lists, "
        "then use get_reminders or search_reminders to fetch tasks."
    ),
)

register_tools(mcp)

if __name__ == "__main__":
    logger.info("Starting macOS Apps MCP server")
    mcp.run()
