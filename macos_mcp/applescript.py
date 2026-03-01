"""
AppleScript execution helpers for macOS MCP.
"""

import logging
import subprocess
import time
from typing import Any

logger = logging.getLogger(__name__)

# Timeout constants (seconds)
TIMEOUT_NORMAL = 60       # single-list or bounded operations
TIMEOUT_CROSS_LIST = 90   # cross-list queries


def sanitize_for_applescript(s: str) -> str:
    """Escape a user-supplied string for safe embedding in AppleScript literals.

    Prevents injection attacks by escaping characters that could break out of
    a double-quoted AppleScript string context.  Handles backslashes, double
    quotes, and strips null bytes / other control characters that could
    interfere with osascript parsing.
    """
    # Strip null bytes and other ASCII control chars (keep tab/newline for bodies)
    s = "".join(ch for ch in s if ch == "\t" or ch == "\n" or (ord(ch) >= 32))
    # Escape backslashes first (so we don't double-escape), then double quotes
    s = s.replace("\\", "\\\\")
    s = s.replace('"', '\\"')
    return s


# ---------------------------------------------------------------------------
# Simple TTL cache for stable data (list_reminders, list_calendars)
# ---------------------------------------------------------------------------

_cache: dict[str, tuple[float, Any]] = {}
CACHE_TTL = 30  # seconds


def cached_result(key: str, ttl: int = CACHE_TTL) -> Any | None:
    """Return cached value if it exists and hasn't expired, else None."""
    entry = _cache.get(key)
    if entry is None:
        return None
    ts, value = entry
    if time.monotonic() - ts > ttl:
        del _cache[key]
        return None
    return value


def set_cached_result(key: str, value: Any) -> None:
    """Store a value in the cache with the current timestamp."""
    _cache[key] = (time.monotonic(), value)


def run_applescript(script: str, timeout: int = TIMEOUT_NORMAL) -> str:
    """Execute an AppleScript snippet via osascript and return stdout.

    Raises RuntimeError on non-zero exit so callers can handle gracefully.
    """
    logger.debug("AppleScript:\n%s", script)
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "AppleScript returned non-zero exit")
    return result.stdout.strip()


def lines_from_applescript(script: str, timeout: int = TIMEOUT_NORMAL) -> list[str]:
    """Run AppleScript and split output on newlines, filtering empty lines.

    Scripts must use ``linefeed`` as the record separator (not commas) so that
    reminder names containing commas are preserved correctly.
    """
    raw = run_applescript(script, timeout=timeout)
    return [ln.strip() for ln in raw.splitlines() if ln.strip()]
