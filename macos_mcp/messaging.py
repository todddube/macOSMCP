# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""
macOS Messages tools for mac-bridge.

Sends iMessages via Messages.app AppleScript. Requires macOS Automation
permission for Messages.app (TCC prompt on first use).

Note: Messages.app must be installed and signed in to iMessage. The
recipient can be a phone number (+1XXXXXXXXXX) or an Apple ID email address.
"""

import logging
from typing import Annotated

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from .applescript import TIMEOUT_NORMAL, run_applescript, sanitize_for_applescript
from .models import SendMessageResult

logger = logging.getLogger(__name__)


def register_tools(mcp: FastMCP) -> None:
    @mcp.tool(
        annotations={"readOnlyHint": False},
    )
    def send_imessage(
        recipient: Annotated[
            str,
            Field(
                description=(
                    "Phone number (+1XXXXXXXXXX) or Apple ID email address to send to. "
                    "Use your own number/email to send a notification to yourself."
                )
            ),
        ],
        message: Annotated[
            str,
            Field(description="Text of the iMessage to send (plain text only)."),
        ],
    ) -> SendMessageResult:
        """Send an iMessage via Messages.app using AppleScript.

        Delivers an iMessage to the specified recipient. Works best when
        sending to yourself as a push notification from the Mac to your iPhone.
        Messages.app must be running or will be launched automatically.

        Requires macOS Automation permission for Messages.app on first use.
        """
        safe_recipient = sanitize_for_applescript(recipient.strip())
        safe_message = sanitize_for_applescript(message.strip())

        if not safe_recipient:
            raise ToolError("recipient must not be empty")
        if not safe_message:
            raise ToolError("message must not be empty")

        script = f"""
tell application "Messages"
    set targetService to 1st service whose service type = iMessage
    set targetBuddy to buddy "{safe_recipient}" of targetService
    send "{safe_message}" to targetBuddy
end tell
"""
        try:
            run_applescript(script, timeout=TIMEOUT_NORMAL)
        except RuntimeError as exc:
            raise ToolError(f"Failed to send iMessage: {exc}") from exc

        logger.info("iMessage sent to %s", recipient)
        return SendMessageResult(
            success=True,
            recipient=recipient,
            message=message,
        )
