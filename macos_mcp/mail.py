# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | April 2026

"""
macOS Mail tools for mac-bridge.

Reads mail via Mail.app AppleScript. Unlike Reminders.app, Mail.app supports
batch property fetching (``subject of msgs``, ``sender of msgs``, etc.), so
list/unread tools use batch access for speed. Search and detail tools use
per-item iteration to filter by content.

TCC permission: Mail.app requires Automation access (one-time macOS prompt).
Grant via System Settings → Privacy & Security → Automation.

TSV output format (tab-separated key=value):
  list_mailboxes:    account=...\tmailbox=...\tunread=N
  get_unread_emails: mailbox=...\taccount=...\tid=...\tsender=...\tdate=...\tsubject=...
  search_emails:     mailbox=...\taccount=...\tid=...\tsender=...\tdate=...\tsubject=...
  get_email_detail:  id=...\tmailbox=...\tsender=...\tdate=...\tsubject=...\tbody=...
                     (body= is ALWAYS last — may contain tabs and newlines)
"""

import logging
from typing import Annotated, Optional

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from .applescript import (
    TIMEOUT_NORMAL,
    cached_result,
    lines_from_applescript,
    sanitize_for_applescript,
    set_cached_result,
)
from .models import (
    EmailDetailResult,
    EmailListResult,
    EmailSearchResult,
    MailboxesResult,
)

logger = logging.getLogger(__name__)

# Timeout for mail queries (seconds).
# Mail.app can be slower than Reminders for large mailboxes.
_TIMEOUT_MAIL_LIST = 30    # list_mailboxes — fast metadata only
_TIMEOUT_MAIL_QUERY = 60   # get_unread / search — bounded by count param
_TIMEOUT_MAIL_DETAIL = 30  # get_email_detail — single message fetch


# ---------------------------------------------------------------------------
# TSV parsing
# ---------------------------------------------------------------------------


def _parse_mail_tsv_line(line: str) -> dict:
    """Parse a tab-separated ``key=value`` mail line into a dict.

    ``body=`` is always emitted last by the AppleScript so bodies containing
    literal tab characters are handled by rejoining the tail (same pattern as
    reminders TSV parsing).
    """
    fields = line.split("\t")
    obj: dict = {}
    i = 0
    while i < len(fields):
        field = fields[i]
        if not field or "=" not in field:
            i += 1
            continue
        key, _, val = field.partition("=")
        if key == "body":
            # Body is always last — rejoin remaining tab-separated pieces
            rest = fields[i + 1:]
            obj["body"] = (val + "\t" + "\t".join(rest)) if rest else val
            break
        elif key == "unread":
            obj["unread"] = int(val) if val.isdigit() else 0
        else:
            obj[key] = val
        i += 1
    return obj


# ---------------------------------------------------------------------------
# AppleScript builders
# ---------------------------------------------------------------------------


def _build_list_mailboxes_script() -> str:
    """List all accounts and their mailboxes with unread counts."""
    return """tell application "Mail"
    set output to ""
    repeat with a in every account
        set acctName to name of a
        repeat with mb in every mailbox of a
            set mbName to name of mb
            set unreadCount to unread count of mb
            set mLine to "account=" & acctName & tab & "mailbox=" & mbName & tab & "unread=" & unreadCount
            set output to output & mLine & linefeed
        end repeat
    end repeat
    return output
end tell"""


def _build_get_unread_single_script(safe_mb: str, safe_acct: str | None, count: int) -> str:
    """Fetch unread messages from one named mailbox.

    Mail.app supports batch property fetching (unlike Reminders) so we fetch
    all properties in parallel, then loop over the resulting plain lists.
    """
    if safe_acct:
        mb_ref = f'mailbox "{safe_mb}" of account "{safe_acct}"'
    else:
        mb_ref = f'mailbox "{safe_mb}"'

    return f"""tell application "Mail"
    try
        set mb to {mb_ref}
        set mbName to name of mb
        set msgs to (every message of mb whose read status is false)
        set totalCount to count of msgs
        if totalCount = 0 then return ""
        set cap to {count}
        if totalCount < cap then set cap to totalCount
        -- Batch property fetch: Mail.app returns plain lists (not broken refs like Reminders)
        set msgIds to message id of msgs
        set subjects to subject of msgs
        set senders to sender of msgs
        set dates to date received of msgs
        set output to ""
        repeat with i from 1 to cap
            set mLine to "mailbox=" & mbName & tab & "id=" & (item i of msgIds) & tab & "sender=" & (item i of senders) & tab & "date=" & ((item i of dates) as string) & tab & "subject=" & (item i of subjects)
            set output to output & mLine & linefeed
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_get_unread_all_inboxes_script(safe_acct: str | None, count: int) -> str:
    """Fetch unread messages from all inbox-type mailboxes (across all or one account)."""
    if safe_acct:
        acct_iter = f'(every account whose name is "{safe_acct}")'
    else:
        acct_iter = "every account"

    return f"""tell application "Mail"
    set output to ""
    set hitCount to 0
    repeat with a in {acct_iter}
        set acctName to name of a
        repeat with mb in (every mailbox of a whose mailbox type is inbox)
            set mbName to name of mb
            set msgs to (every message of mb whose read status is false)
            set totalCount to count of msgs
            if totalCount > 0 then
                set cap to {count} - hitCount
                if totalCount < cap then set cap to totalCount
                -- Batch fetch then loop over plain lists
                set msgIds to message id of msgs
                set subjects to subject of msgs
                set senders to sender of msgs
                set dates to date received of msgs
                repeat with i from 1 to cap
                    set mLine to "mailbox=" & mbName & tab & "account=" & acctName & tab & "id=" & (item i of msgIds) & tab & "sender=" & (item i of senders) & tab & "date=" & ((item i of dates) as string) & tab & "subject=" & (item i of subjects)
                    set output to output & mLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {count} then return output
                end repeat
            end if
        end repeat
    end repeat
    return output
end tell"""


def _build_search_single_script(safe_mb: str, safe_acct: str | None, safe_query: str, count: int) -> str:
    """Search one mailbox by subject or sender (per-item iteration)."""
    if safe_acct:
        mb_ref = f'mailbox "{safe_mb}" of account "{safe_acct}"'
    else:
        mb_ref = f'mailbox "{safe_mb}"'

    return f"""tell application "Mail"
    try
        set mb to {mb_ref}
        set mbName to name of mb
        set queryText to "{safe_query}"
        set output to ""
        set hitCount to 0
        repeat with m in (every message of mb)
            set mSubject to subject of m
            set mSender to sender of m
            if mSubject contains queryText or mSender contains queryText then
                set mId to message id of m
                set mDate to date received of m
                set mLine to "mailbox=" & mbName & tab & "id=" & mId & tab & "sender=" & mSender & tab & "date=" & (mDate as string) & tab & "subject=" & mSubject
                set output to output & mLine & linefeed
                set hitCount to hitCount + 1
                if hitCount >= {count} then return output
            end if
        end repeat
        return output
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


def _build_search_all_inboxes_script(safe_query: str, count: int) -> str:
    """Search all inbox-type mailboxes by subject or sender."""
    return f"""tell application "Mail"
    set queryText to "{safe_query}"
    set output to ""
    set hitCount to 0
    repeat with a in every account
        set acctName to name of a
        repeat with mb in (every mailbox of a whose mailbox type is inbox)
            set mbName to name of mb
            repeat with m in (every message of mb)
                set mSubject to subject of m
                set mSender to sender of m
                if mSubject contains queryText or mSender contains queryText then
                    set mId to message id of m
                    set mDate to date received of m
                    set mLine to "mailbox=" & mbName & tab & "account=" & acctName & tab & "id=" & mId & tab & "sender=" & mSender & tab & "date=" & (mDate as string) & tab & "subject=" & mSubject
                    set output to output & mLine & linefeed
                    set hitCount to hitCount + 1
                    if hitCount >= {count} then return output
                end if
            end repeat
        end repeat
    end repeat
    return output
end tell"""


def _build_get_detail_script(safe_message_id: str, safe_mb: str | None) -> str:
    """Fetch full detail (including body) for one message by RFC 2822 Message-ID.

    If mailbox is provided, search only that mailbox (faster). Otherwise,
    search all inbox-type mailboxes across all accounts.

    body= is always last so the TSV parser can rejoin tab-containing bodies.
    """
    if safe_mb:
        search_block = f"""
        set msgs to (every message of mailbox "{safe_mb}" whose message id is "{safe_message_id}")
        if (count of msgs) = 0 then return "found=false"
        set m to item 1 of msgs
        set mbName to "{safe_mb}" """
    else:
        search_block = """
        set m to missing value
        set mbName to ""
        set found to false
        repeat with a in every account
            if found then exit repeat
            repeat with mb in (every mailbox of a whose mailbox type is inbox)
                set hits to (every message of mb whose message id is \"""" + safe_message_id + """\")
                if (count of hits) > 0 then
                    set m to item 1 of hits
                    set mbName to name of mb
                    set found to true
                    exit repeat
                end if
            end repeat
        end repeat
        if m is missing value then return "found=false" """

    return f"""tell application "Mail"
    try{search_block}
        set mId to message id of m
        set mSubject to subject of m
        set mSender to sender of m
        set mDate to date received of m
        set mContent to content of m
        -- Normalise newlines in body to " | " so TSV structure is preserved
        set AppleScript's text item delimiters to linefeed
        set bodyParts to text items of mContent
        set AppleScript's text item delimiters to " | "
        set cleanBody to bodyParts as string
        set AppleScript's text item delimiters to ""
        -- body= must be last (may contain tabs that the Python parser rejoins)
        set mLine to "found=true" & tab & "id=" & mId & tab & "mailbox=" & mbName & tab & "sender=" & mSender & tab & "date=" & (mDate as string) & tab & "subject=" & mSubject & tab & "body=" & cleanBody
        return mLine
    on error errMsg
        return "ERROR:" & errMsg
    end try
end tell"""


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


def register_tools(mcp: FastMCP) -> None:
    """Register all Mail tools on the given FastMCP instance."""

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=_TIMEOUT_MAIL_LIST)
    def list_mailboxes() -> MailboxesResult:
        """List all mail accounts and their mailboxes with unread counts.

        Returns a JSON object:
            { "mailboxes": [{"account": "iCloud", "mailbox": "INBOX", "unread": 3}, ...], "count": N }

        Requires macOS Automation permission for Mail.app (one-time prompt).
        """
        hit = cached_result("list_mailboxes")
        if hit is not None:
            return hit

        script = _build_list_mailboxes_script()
        try:
            raw_lines = lines_from_applescript(script, timeout=_TIMEOUT_MAIL_LIST)
        except RuntimeError as exc:
            logger.error("list_mailboxes failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        items = [_parse_mail_tsv_line(ln) for ln in raw_lines]
        result: MailboxesResult = {"mailboxes": items, "count": len(items)}
        set_cached_result("list_mailboxes", result)
        return result

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=_TIMEOUT_MAIL_QUERY)
    def get_unread_emails(
        mailbox: Annotated[Optional[str], Field(description="Mailbox name (e.g. 'INBOX'). Omit to query all inbox-type mailboxes.")] = None,
        account: Annotated[Optional[str], Field(description="Account name to scope the query. Omit for all accounts.")] = None,
        count: Annotated[int, Field(ge=1, le=100, description="Maximum emails to return")] = 20,
    ) -> EmailListResult:
        """Fetch recent unread emails from Mail.app.

        Args:
            mailbox: Specific mailbox name (e.g. 'INBOX'). Omit for all inbox-type mailboxes.
            account: Account name to scope the query (e.g. 'iCloud', 'Gmail'). Omit for all.
            count:   Maximum emails to return (default: 20).

        Returns a JSON object with an ``emails`` array. Each item has:
            id (RFC 2822 Message-ID), subject, sender, date, mailbox, account.
        Body is not included — use get_email_detail for full content.
        """
        safe_mb = sanitize_for_applescript(mailbox) if mailbox else None
        safe_acct = sanitize_for_applescript(account) if account else None

        if safe_mb:
            script = _build_get_unread_single_script(safe_mb, safe_acct, count)
        else:
            script = _build_get_unread_all_inboxes_script(safe_acct, count)

        try:
            raw_lines = lines_from_applescript(script, timeout=_TIMEOUT_MAIL_QUERY)
        except RuntimeError as exc:
            logger.error("get_unread_emails failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        emails = [_parse_mail_tsv_line(ln) for ln in raw_lines]
        return EmailListResult(
            emails=emails,
            count=len(emails),
            mailbox=mailbox or "all inboxes",
            account=account or "all",
        )

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=_TIMEOUT_MAIL_QUERY)
    def search_emails(
        query: Annotated[str, Field(min_length=1, description="Text to find in subject or sender")],
        mailbox: Annotated[Optional[str], Field(description="Mailbox to search. Omit to search all inbox-type mailboxes.")] = None,
        count: Annotated[int, Field(ge=1, le=100, description="Maximum results to return")] = 20,
    ) -> EmailSearchResult:
        """Search emails by subject or sender in Mail.app (case-insensitive).

        Args:
            query:   Text to match against subject or sender fields.
            mailbox: Specific mailbox to search. Omit to search all inbox-type mailboxes.
            count:   Maximum results to return (default: 20).

        Returns a JSON object with matching email items (id, subject, sender, date, mailbox).
        Body is not included — use get_email_detail for full content.
        """
        if not query or not query.strip():
            raise ToolError("query must not be empty")

        safe_query = sanitize_for_applescript(query)
        safe_mb = sanitize_for_applescript(mailbox) if mailbox else None

        if safe_mb:
            script = _build_search_single_script(safe_mb, None, safe_query, count)
        else:
            script = _build_search_all_inboxes_script(safe_query, count)

        try:
            raw_lines = lines_from_applescript(script, timeout=_TIMEOUT_MAIL_QUERY)
        except RuntimeError as exc:
            logger.error("search_emails failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if raw_lines and raw_lines[0].startswith("ERROR:"):
            raise ToolError(raw_lines[0])

        results = [_parse_mail_tsv_line(ln) for ln in raw_lines]
        return EmailSearchResult(
            query=query,
            results=results,
            count=len(results),
            mailbox=mailbox or "all inboxes",
        )

    @mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True}, timeout=_TIMEOUT_MAIL_DETAIL)
    def get_email_detail(
        message_id: Annotated[str, Field(min_length=1, description="RFC 2822 Message-ID returned by get_unread_emails or search_emails (e.g. '<abc@mail.example.com>')")],
        mailbox: Annotated[Optional[str], Field(description="Mailbox hint for faster lookup. Omit to search all inbox-type mailboxes.")] = None,
    ) -> EmailDetailResult:
        """Get the full content of an email by its RFC 2822 Message-ID.

        Args:
            message_id: The ``id`` field returned by get_unread_emails or search_emails.
            mailbox:    Optional mailbox name to speed up the search. If omitted,
                        all inbox-type mailboxes are searched (slower).

        Returns a JSON object with id, subject, sender, date, mailbox, and full body.
        Newlines in the body are replaced with \" | \" for safe transport.

        Note: fetching body may be slow for large HTML emails or if Mail.app needs
        to download the message from the server (IMAP).
        """
        if not message_id or not message_id.strip():
            raise ToolError("message_id must not be empty")

        safe_id = sanitize_for_applescript(message_id.strip())
        safe_mb = sanitize_for_applescript(mailbox) if mailbox else None

        script = _build_get_detail_script(safe_id, safe_mb)
        try:
            raw_lines = lines_from_applescript(script, timeout=_TIMEOUT_MAIL_DETAIL)
        except RuntimeError as exc:
            logger.error("get_email_detail failed: %s", exc)
            raise ToolError(str(exc)) from exc

        if not raw_lines:
            return EmailDetailResult(found=False)

        first = raw_lines[0]
        if first.startswith("ERROR:"):
            raise ToolError(first)
        if first == "found=false":
            return EmailDetailResult(found=False)

        # Rejoin in case body spanned multiple output lines (shouldn't happen — newlines
        # are replaced in the AppleScript — but defensive merge just in case)
        full_line = "\t".join(raw_lines)
        obj = _parse_mail_tsv_line(full_line)
        # Convert "found=true" string → bool
        obj["found"] = obj.get("found", "false") == "true"
        return obj
