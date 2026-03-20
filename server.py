# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""
mac-bridge MCP Server

Bridges Claude to macOS native apps via AppleScript and Swift/EventKit.
Provides access to Reminders, Calendar, and iMessage.

Run with:
    uv run server.py
    
MAC_BRIDGE_LOG_LEVEL:   Output level for debugging (optional, default: WARNING)
unset (default) 	    WARNING — errors only, silent in normal use
INFO:               	startup message + "iMessage sent to..."
DEBUG:              	everything including raw AppleScript scripts and Swift helper commands

"""

import logging
import os

from fastmcp import FastMCP

from macos_mcp.calendar import register_tools as register_calendar_tools
from macos_mcp.messaging import register_tools as register_messaging_tools
from macos_mcp.reminders import register_tools as register_reminder_tools

_log_level = getattr(logging, os.environ.get("MAC_BRIDGE_LOG_LEVEL", "WARNING").upper(), logging.WARNING)
logging.basicConfig(
    level=_log_level,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger("mac_bridge")

mcp = FastMCP(
    name="mac-bridge",
    instructions=(
        "Access to macOS Reminders, Calendar, and Messages via AppleScript. "
        "Call list_reminders to see Reminder lists, list_calendars to see "
        "calendars. Use get_reminders, search_reminders, get_overdue_reminders, "
        "or get_upcoming_reminders for tasks; use get_calendar_events, "
        "get_today_events, or search_calendar_events for calendar entries. "
        "Use send_imessage to send an iMessage (e.g. a push alert to yourself)."
    ),
    on_duplicate="error",
)

register_reminder_tools(mcp)
register_calendar_tools(mcp)
register_messaging_tools(mcp)

if __name__ == "__main__":
    logger.info("Starting mac-bridge MCP server")
    mcp.run()
