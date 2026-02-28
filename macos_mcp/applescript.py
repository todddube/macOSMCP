"""
AppleScript execution helpers for macOS MCP.
"""

import logging
import subprocess

logger = logging.getLogger(__name__)

# Timeout constants (seconds)
TIMEOUT_NORMAL = 60       # single-list or bounded operations
TIMEOUT_CROSS_LIST = 90   # cross-list queries


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
