# mac-bridge — MCP server bridging Claude to macOS Reminders, Calendar & iMessage
# Author: Todd Dube | March 2026

"""Tests for mac-bridge applescript module — sanitization, caching, and helpers."""

import time

import pytest

from macos_mcp.applescript import (
    CACHE_TTL,
    cached_result,
    run_applescript,
    sanitize_for_applescript,
    set_cached_result,
    _cache,
)


# ---------------------------------------------------------------------------
# sanitize_for_applescript
# ---------------------------------------------------------------------------


class TestSanitize:
    def test_plain_text_unchanged(self):
        assert sanitize_for_applescript("hello world") == "hello world"

    def test_escapes_backslash(self):
        assert sanitize_for_applescript("path\\to\\file") == "path\\\\to\\\\file"

    def test_escapes_double_quote(self):
        assert sanitize_for_applescript('say "hi"') == 'say \\"hi\\"'

    def test_strips_null_bytes(self):
        assert sanitize_for_applescript("ab\x00cd") == "abcd"

    def test_strips_control_chars(self):
        # Bell, backspace, etc. should be stripped
        assert sanitize_for_applescript("a\x07b\x08c") == "abc"

    def test_preserves_tabs_and_newlines(self):
        assert sanitize_for_applescript("a\tb\nc") == "a\tb\nc"

    def test_combined_injection_attempt(self):
        # Attempt to break out of AppleScript string context
        malicious = 'foo" & (do shell script "rm -rf /") & "'
        result = sanitize_for_applescript(malicious)
        assert '"' not in result.replace('\\"', '')

    def test_empty_string(self):
        assert sanitize_for_applescript("") == ""

    def test_unicode_preserved(self):
        assert sanitize_for_applescript("Café résumé") == "Café résumé"


# ---------------------------------------------------------------------------
# TTL cache
# ---------------------------------------------------------------------------


class TestCache:
    @pytest.fixture(autouse=True)
    def clear_cache(self):
        _cache.clear()
        yield
        _cache.clear()

    def test_set_and_get(self):
        set_cached_result("key1", {"data": 42})
        assert cached_result("key1") == {"data": 42}

    def test_returns_none_for_missing_key(self):
        assert cached_result("nonexistent") is None

    def test_expired_entry_returns_none(self):
        set_cached_result("key2", "value")
        # Manually expire
        ts, val = _cache["key2"]
        _cache["key2"] = (ts - CACHE_TTL - 1, val)
        assert cached_result("key2") is None

    def test_custom_ttl(self):
        set_cached_result("key3", "val")
        # With a very short TTL, it should still be valid
        assert cached_result("key3", ttl=9999) == "val"

    def test_expired_entry_is_removed(self):
        set_cached_result("key4", "val")
        ts, val = _cache["key4"]
        _cache["key4"] = (ts - CACHE_TTL - 1, val)
        cached_result("key4")
        assert "key4" not in _cache


# ---------------------------------------------------------------------------
# run_applescript
# ---------------------------------------------------------------------------


class TestRunAppleScript:
    def test_simple_return(self):
        result = run_applescript('return "hello"')
        assert result == "hello"

    def test_nonzero_exit_raises(self):
        with pytest.raises(RuntimeError):
            run_applescript("this is not valid applescript")

    def test_timeout_raises(self):
        # delay 10 with a 1s timeout should raise
        with pytest.raises(Exception):  # subprocess.TimeoutExpired
            run_applescript("delay 10", timeout=1)
