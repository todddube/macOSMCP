# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | April 2026

"""Tests for mail tools: parsing, registration, mocked integration, and prompts."""

import asyncio
from unittest.mock import patch

import pytest
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

from macos_mcp.applescript import _cache
from macos_mcp.mail import _parse_mail_tsv_line, register_tools as register_mail_tools
from macos_mcp.prompts import register_prompts


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mock_applescript(output: str, returncode: int = 0, stderr: str = ""):
    class MockResult:
        def __init__(self):
            self.stdout = output
            self.returncode = returncode
            self.stderr = stderr
    return patch("macos_mcp.applescript.subprocess.run", return_value=MockResult())


@pytest.fixture()
def mail_tools():
    """Register mail tools and return a dict of {name: callable}."""
    mcp = FastMCP(name="test-mail", on_duplicate="error")
    register_mail_tools(mcp)
    tool_list = asyncio.run(mcp.list_tools())
    return {t.name: t.fn for t in tool_list}


@pytest.fixture(autouse=True)
def clear_cache():
    _cache.clear()
    yield
    _cache.clear()


# ---------------------------------------------------------------------------
# TSV parsing
# ---------------------------------------------------------------------------


class TestMailTsvParsing:
    def test_mailbox_line(self):
        line = "account=iCloud\tmailbox=INBOX\tunread=5"
        obj = _parse_mail_tsv_line(line)
        assert obj["account"] == "iCloud"
        assert obj["mailbox"] == "INBOX"
        assert obj["unread"] == 5

    def test_unread_zero(self):
        line = "account=Gmail\tmailbox=Sent\tunread=0"
        obj = _parse_mail_tsv_line(line)
        assert obj["unread"] == 0

    def test_email_item_line(self):
        line = "mailbox=INBOX\taccount=iCloud\tid=<abc@mail.example.com>\tsender=alice@example.com\tdate=Saturday, April 5, 2026 at 9:00:00 AM\tsubject=Hello World"
        obj = _parse_mail_tsv_line(line)
        assert obj["mailbox"] == "INBOX"
        assert obj["account"] == "iCloud"
        assert obj["id"] == "<abc@mail.example.com>"
        assert obj["sender"] == "alice@example.com"
        assert obj["subject"] == "Hello World"

    def test_detail_line_body_last(self):
        line = "found=true\tid=<abc@mail.example.com>\tmailbox=INBOX\tsender=alice@example.com\tdate=Saturday, April 5, 2026 at 9:00:00 AM\tsubject=Hello\tbody=Line one | Line two"
        obj = _parse_mail_tsv_line(line)
        assert obj["body"] == "Line one | Line two"
        assert obj["subject"] == "Hello"

    def test_body_with_tabs_rejoined(self):
        # body= field containing a tab character should be rejoined
        line = "id=<x>\tsubject=Test\tbody=part one\tpart two"
        obj = _parse_mail_tsv_line(line)
        assert obj["body"] == "part one\tpart two"

    def test_unread_non_numeric_defaults_zero(self):
        line = "account=X\tmailbox=Y\tunread=bad"
        obj = _parse_mail_tsv_line(line)
        assert obj["unread"] == 0

    def test_empty_line_returns_empty_dict(self):
        obj = _parse_mail_tsv_line("")
        assert obj == {}


# ---------------------------------------------------------------------------
# Tool registration
# ---------------------------------------------------------------------------


class TestMailToolRegistration:
    def test_all_four_tools_registered(self, mail_tools):
        assert set(mail_tools.keys()) == {
            "list_mailboxes",
            "get_unread_emails",
            "search_emails",
            "get_email_detail",
        }

    def test_all_tools_have_readonly_hint(self):
        mcp = FastMCP(name="hint-test", on_duplicate="error")
        register_mail_tools(mcp)
        tools = asyncio.run(mcp.list_tools())
        for tool in tools:
            assert tool.annotations is not None, f"{tool.name} missing annotations"
            assert tool.annotations.readOnlyHint is True, f"{tool.name} missing readOnlyHint"

    def test_all_tools_have_descriptions(self, mail_tools):
        mcp = FastMCP(name="desc-test", on_duplicate="error")
        register_mail_tools(mcp)
        for tool in asyncio.run(mcp.list_tools()):
            assert tool.description, f"{tool.name} has no description"
            assert len(tool.description) > 20, f"{tool.name} description too short"

    def test_all_tools_have_timeout(self):
        mcp = FastMCP(name="timeout-test", on_duplicate="error")
        register_mail_tools(mcp)
        for tool in asyncio.run(mcp.list_tools()):
            assert tool.timeout is not None, f"{tool.name} missing timeout"
            assert tool.timeout > 0


# ---------------------------------------------------------------------------
# Mocked integration tests
# ---------------------------------------------------------------------------


class TestListMailboxes:
    LIST_OUTPUT = (
        "account=iCloud\tmailbox=INBOX\tunread=3\n"
        "account=iCloud\tmailbox=Sent\tunread=0\n"
        "account=Gmail\tmailbox=INBOX\tunread=7\n"
    )

    def test_returns_mailboxes_list(self, mail_tools):
        with _mock_applescript(self.LIST_OUTPUT):
            result = mail_tools["list_mailboxes"]()
        assert result["count"] == 3
        assert len(result["mailboxes"]) == 3

    def test_unread_count_parsed(self, mail_tools):
        with _mock_applescript(self.LIST_OUTPUT):
            result = mail_tools["list_mailboxes"]()
        inboxes = [mb for mb in result["mailboxes"] if mb["mailbox"] == "INBOX"]
        assert any(mb["unread"] == 3 for mb in inboxes)
        assert any(mb["unread"] == 7 for mb in inboxes)

    def test_sent_mailbox_zero_unread(self, mail_tools):
        with _mock_applescript(self.LIST_OUTPUT):
            result = mail_tools["list_mailboxes"]()
        sent = next(mb for mb in result["mailboxes"] if mb["mailbox"] == "Sent")
        assert sent["unread"] == 0

    def test_result_is_cached(self, mail_tools):
        with _mock_applescript(self.LIST_OUTPUT) as mock:
            mail_tools["list_mailboxes"]()
            mail_tools["list_mailboxes"]()
        # AppleScript should only be called once (second call hits cache)
        assert mock.call_count == 1

    def test_applescript_error_raises_tool_error(self, mail_tools):
        with _mock_applescript("", returncode=1, stderr="Mail not running"):
            with pytest.raises(ToolError):
                mail_tools["list_mailboxes"]()


class TestGetUnreadEmails:
    UNREAD_OUTPUT = (
        "mailbox=INBOX\taccount=iCloud\tid=<msg1@example.com>\tsender=alice@example.com\tdate=Saturday, April 5, 2026 at 9:00:00 AM\tsubject=Hello World\n"
        "mailbox=INBOX\taccount=Gmail\tid=<msg2@gmail.com>\tsender=bob@example.com\tdate=Saturday, April 5, 2026 at 8:00:00 AM\tsubject=Meeting Tomorrow\n"
    )

    def test_returns_emails_list(self, mail_tools):
        with _mock_applescript(self.UNREAD_OUTPUT):
            result = mail_tools["get_unread_emails"]()
        assert result["count"] == 2
        assert len(result["emails"]) == 2

    def test_email_fields_present(self, mail_tools):
        with _mock_applescript(self.UNREAD_OUTPUT):
            result = mail_tools["get_unread_emails"]()
        email = result["emails"][0]
        assert email["id"] == "<msg1@example.com>"
        assert email["sender"] == "alice@example.com"
        assert email["subject"] == "Hello World"

    def test_default_mailbox_all_inboxes(self, mail_tools):
        with _mock_applescript(self.UNREAD_OUTPUT):
            result = mail_tools["get_unread_emails"]()
        assert result["mailbox"] == "all inboxes"
        assert result["account"] == "all"

    def test_with_mailbox_param(self, mail_tools):
        with _mock_applescript(self.UNREAD_OUTPUT):
            result = mail_tools["get_unread_emails"](mailbox="INBOX")
        assert result["mailbox"] == "INBOX"

    def test_empty_mailbox_returns_zero_count(self, mail_tools):
        with _mock_applescript(""):
            result = mail_tools["get_unread_emails"]()
        assert result["count"] == 0
        assert result["emails"] == []

    def test_applescript_error_raises_tool_error(self, mail_tools):
        with _mock_applescript("ERROR:mailbox not found", returncode=0):
            with pytest.raises(ToolError):
                mail_tools["get_unread_emails"](mailbox="Nonexistent")


class TestSearchEmails:
    SEARCH_OUTPUT = (
        "mailbox=INBOX\taccount=iCloud\tid=<msg3@example.com>\tsender=carol@example.com\tdate=Friday, April 4, 2026 at 3:00:00 PM\tsubject=Invoice April 2026\n"
    )

    def test_returns_search_results(self, mail_tools):
        with _mock_applescript(self.SEARCH_OUTPUT):
            result = mail_tools["search_emails"](query="Invoice")
        assert result["query"] == "Invoice"
        assert result["count"] == 1
        assert result["results"][0]["subject"] == "Invoice April 2026"

    def test_default_mailbox_all_inboxes(self, mail_tools):
        with _mock_applescript(self.SEARCH_OUTPUT):
            result = mail_tools["search_emails"](query="Invoice")
        assert result["mailbox"] == "all inboxes"

    def test_no_results_returns_empty(self, mail_tools):
        with _mock_applescript(""):
            result = mail_tools["search_emails"](query="zzznomatch")
        assert result["count"] == 0
        assert result["results"] == []

    def test_empty_query_raises_tool_error(self, mail_tools):
        with pytest.raises(ToolError):
            mail_tools["search_emails"](query="")

    def test_with_mailbox_scoped(self, mail_tools):
        with _mock_applescript(self.SEARCH_OUTPUT):
            result = mail_tools["search_emails"](query="Invoice", mailbox="INBOX")
        assert result["mailbox"] == "INBOX"


class TestGetEmailDetail:
    DETAIL_OUTPUT = "found=true\tid=<msg1@example.com>\tmailbox=INBOX\tsender=alice@example.com\tdate=Saturday, April 5, 2026 at 9:00:00 AM\tsubject=Hello World\tbody=Hi there! | This is the full message body."

    def test_returns_detail_with_body(self, mail_tools):
        with _mock_applescript(self.DETAIL_OUTPUT):
            result = mail_tools["get_email_detail"](message_id="<msg1@example.com>")
        assert result["found"] is True
        assert result["id"] == "<msg1@example.com>"
        assert result["subject"] == "Hello World"
        assert "Hi there!" in result["body"]

    def test_not_found_returns_found_false(self, mail_tools):
        with _mock_applescript("found=false"):
            result = mail_tools["get_email_detail"](message_id="<missing@example.com>")
        assert result["found"] is False

    def test_empty_output_returns_found_false(self, mail_tools):
        with _mock_applescript(""):
            result = mail_tools["get_email_detail"](message_id="<missing@example.com>")
        assert result["found"] is False

    def test_with_mailbox_hint(self, mail_tools):
        with _mock_applescript(self.DETAIL_OUTPUT):
            result = mail_tools["get_email_detail"](
                message_id="<msg1@example.com>", mailbox="INBOX"
            )
        assert result["found"] is True
        assert result["mailbox"] == "INBOX"

    def test_empty_message_id_raises_tool_error(self, mail_tools):
        with pytest.raises(ToolError):
            mail_tools["get_email_detail"](message_id="")

    def test_applescript_error_raises_tool_error(self, mail_tools):
        with _mock_applescript("ERROR:connection failed", returncode=0):
            with pytest.raises(ToolError):
                mail_tools["get_email_detail"](message_id="<x@y.com>")


# ---------------------------------------------------------------------------
# Prompt registration
# ---------------------------------------------------------------------------


class TestPrompts:
    def test_both_prompts_registered(self):
        mcp = FastMCP(name="prompt-test", on_duplicate="error")
        register_prompts(mcp)
        prompts = asyncio.run(mcp.list_prompts())
        names = {p.name for p in prompts}
        assert "daily_planner" in names
        assert "weekly_review" in names

    def test_prompts_have_descriptions(self):
        mcp = FastMCP(name="prompt-desc-test", on_duplicate="error")
        register_prompts(mcp)
        for prompt in asyncio.run(mcp.list_prompts()):
            assert prompt.description, f"{prompt.name} missing description"

    def test_daily_planner_returns_string(self):
        mcp = FastMCP(name="prompt-run-test", on_duplicate="error")
        register_prompts(mcp)
        prompts_by_name = {p.name: p for p in asyncio.run(mcp.list_prompts())}
        result = asyncio.run(prompts_by_name["daily_planner"].render())
        # FastMCP wraps str → PromptResult with .messages list
        assert len(result.messages) >= 1
        content_str = str(result.messages)
        assert "get_today_events" in content_str
        assert "get_overdue_reminders" in content_str

    def test_weekly_review_returns_string(self):
        mcp = FastMCP(name="prompt-weekly-test", on_duplicate="error")
        register_prompts(mcp)
        prompts_by_name = {p.name: p for p in asyncio.run(mcp.list_prompts())}
        result = asyncio.run(prompts_by_name["weekly_review"].render())
        content_str = str(result.messages)
        assert "get_calendar_events" in content_str
        assert "get_upcoming_reminders" in content_str
