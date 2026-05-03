#!/usr/bin/env python3
# mac-bridge — shared agent infrastructure
# Author: Todd Dube | May 2026

"""
AgentRunner shared infrastructure for all mac-bridge agents.

Key retrieval priority:
  1. ANTHROPIC_API_KEY env var (dev / dry-run)
  2. macOS Keychain  (service=mac-bridge, account=ANTHROPIC_API_KEY)
     → populated by install.py from 1Password at install time

API key is NEVER stored in launchd plists or source files.
"""

import asyncio
import email.mime.multipart
import email.mime.text
import json
import logging
import os
import re
import subprocess
import tempfile
from datetime import date
from pathlib import Path
from typing import Any

import anthropic
from fastmcp import Client

PROJECT_DIR = Path(__file__).parent.parent
LOG_DIR = Path.home() / "Library" / "Logs" / "macOSMCP"
STATE_FILE = Path.home() / ".mac-bridge" / "agent_state.json"

MCP_CONFIG = {
    "mcpServers": {
        "mac-bridge": {
            "command": "uv",
            "args": ["--directory", str(PROJECT_DIR), "run", "server.py"],
        }
    }
}

IMESSAGE_RECIPIENT = os.environ.get("IMESSAGE_RECIPIENT", "+18044328850")
EMAIL_RECIPIENT = "todd@thedubes.com"

# 1Password reference for install.py (not used at agent runtime)
OP_ANTHROPIC_REF = os.environ.get(
    "OP_ANTHROPIC_REF",
    "op://Personal/Claude API Todd Secret/credential",
)


# ---------------------------------------------------------------------------
# Key management
# ---------------------------------------------------------------------------

def get_api_key() -> str:
    """Return Anthropic API key: env var → Keychain. Never from plists."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "mac-bridge", "-a", "ANTHROPIC_API_KEY", "-w"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    raise RuntimeError(
        "No ANTHROPIC_API_KEY found in env or Keychain.\n"
        "Run install.py to pull from 1Password and store in Keychain:\n"
        "  uv run install.py\n"
        "Or set the env var manually:\n"
        "  export ANTHROPIC_API_KEY=sk-ant-..."
    )


def store_key_in_keychain(api_key: str) -> None:
    """Store API key in macOS Keychain (called by install.py)."""
    subprocess.run(
        [
            "security", "add-generic-password",
            "-s", "mac-bridge",
            "-a", "ANTHROPIC_API_KEY",
            "-w", api_key,
            "-U",  # update if exists
        ],
        check=True,
    )


def fetch_key_from_1password() -> str:
    """Pull API key from 1Password via op CLI (called by install.py, requires auth)."""
    result = subprocess.run(
        ["op", "read", OP_ANTHROPIC_REF],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to read from 1Password: {result.stderr.strip()}\n"
            f"Ref: {OP_ANTHROPIC_REF}\n"
            f"Make sure 'op' is signed in: op signin"
        )
    key = result.stdout.strip()
    if not key.startswith("sk-ant-"):
        raise RuntimeError(f"Unexpected key format from 1Password (got {key[:10]}...)")
    return key


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(agent_name: str, dry_run: bool = False) -> logging.Logger:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = logging.getLogger(agent_name)
    log.setLevel(logging.DEBUG if dry_run else logging.INFO)

    fh = logging.FileHandler(LOG_DIR / f"{agent_name}.log")
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)-8s %(message)s"))
    log.addHandler(fh)

    sh = logging.StreamHandler()
    sh.setLevel(logging.DEBUG if dry_run else logging.INFO)
    sh.setFormatter(logging.Formatter("%(levelname)-8s %(message)s"))
    log.addHandler(sh)

    return log


# ---------------------------------------------------------------------------
# State (rate-limiting, deduplication)
# ---------------------------------------------------------------------------

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, default=str))


# ---------------------------------------------------------------------------
# Core agent loop — Claude + mac-bridge tools
# ---------------------------------------------------------------------------

async def run_agent(
    task: str,
    system: str,
    model: str = "claude-haiku-4-5-20251001",
    max_tokens: int = 6000,
    log: logging.Logger | None = None,
) -> str:
    """
    Run Claude with all mac-bridge MCP tools available.

    Claude calls tools iteratively until stop_reason == 'end_turn'.
    Returns the final text response.
    """
    api_key = get_api_key()
    anthropic_client = anthropic.Anthropic(api_key=api_key)

    async with Client(MCP_CONFIG) as mcp:
        raw_tools = await mcp.list_tools()
        anthropic_tools = [
            {
                "name": t.name,
                "description": t.description or "",
                "input_schema": t.inputSchema,
            }
            for t in raw_tools
        ]

        if log:
            log.info("Loaded %d mac-bridge tools", len(anthropic_tools))

        messages: list[dict[str, Any]] = [{"role": "user", "content": task}]
        iterations = 0

        while True:
            iterations += 1
            if log:
                log.info("Claude call #%d (%d messages in context)", iterations, len(messages))

            response = anthropic_client.messages.create(
                model=model,
                max_tokens=max_tokens,
                system=system,
                tools=anthropic_tools,
                messages=messages,
            )

            if response.stop_reason == "end_turn":
                return next(
                    (b.text for b in response.content if hasattr(b, "text")),
                    "",
                )

            # Build assistant turn from response content
            assistant_content = []
            tool_use_blocks = []
            for block in response.content:
                if block.type == "text":
                    assistant_content.append({"type": "text", "text": block.text})
                elif block.type == "tool_use":
                    assistant_content.append({
                        "type": "tool_use",
                        "id": block.id,
                        "name": block.name,
                        "input": block.input,
                    })
                    tool_use_blocks.append(block)

            messages.append({"role": "assistant", "content": assistant_content})

            # Execute tool calls and collect results
            tool_results = []
            for block in tool_use_blocks:
                if log:
                    log.info("  tool: %s(%s)", block.name, list(block.input.keys()))
                try:
                    result = await mcp.call_tool(block.name, block.input)
                    if result.structured_content:
                        content = json.dumps(result.structured_content)
                    else:
                        content = "\n".join(
                            item.text for item in result.content if hasattr(item, "text")
                        )
                    is_error = bool(result.is_error)
                except Exception as exc:
                    content = f"Tool error: {exc}"
                    is_error = True
                    if log:
                        log.warning("  tool %s failed: %s", block.name, exc)

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": content,
                    **({"is_error": True} if is_error else {}),
                })

            messages.append({"role": "user", "content": tool_results})

            if iterations > 20:
                if log:
                    log.error("Tool loop exceeded 20 iterations — aborting")
                break

    return ""


# ---------------------------------------------------------------------------
# Output utilities
# ---------------------------------------------------------------------------

def extract_sections(text: str) -> tuple[str, str]:
    """Extract <html>…</html> and <imessage>…</imessage> from Claude output."""
    html_m = re.search(r"<html>(.*?)</html>", text, re.DOTALL)
    msg_m = re.search(r"<imessage>(.*?)</imessage>", text, re.DOTALL)

    html = html_m.group(1).strip() if html_m else text.strip()
    imessage = msg_m.group(1).strip() if msg_m else ""
    return html, imessage


def extract_alert(text: str) -> str:
    """Extract <alert>…</alert> from Claude output. Returns '' if empty."""
    m = re.search(r"<alert>(.*?)</alert>", text, re.DOTALL)
    return m.group(1).strip() if m else ""


async def send_imessage_via_mcp(
    message: str,
    recipient: str = IMESSAGE_RECIPIENT,
    log: logging.Logger | None = None,
) -> None:
    async with Client(MCP_CONFIG) as mcp:
        await mcp.call_tool("send_imessage", {"recipient": recipient, "message": message})
    if log:
        log.info("iMessage sent to %s", recipient)


def send_html_email(
    html: str,
    subject: str,
    recipient: str = EMAIL_RECIPIENT,
    log: logging.Logger | None = None,
) -> None:
    msg = email.mime.multipart.MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = recipient
    msg["To"] = recipient
    msg.attach(email.mime.text.MIMEText(
        "Please view this email in an HTML-capable client.", "plain", "utf-8"
    ))
    msg.attach(email.mime.text.MIMEText(html, "html", "utf-8"))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".eml", delete=False, prefix="mac_bridge_"
    ) as f:
        f.write(msg.as_string())
        eml_path = f.name

    safe_subject = subject[:40].replace('"', '\\"')
    safe_path = eml_path.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
tell application "Mail"
    set eml to (POSIX file "{safe_path}") as alias
    open eml
    delay 2
    repeat with m in (every outgoing message)
        if subject of m contains "{safe_subject}" then
            send m
            exit repeat
        end if
    end repeat
end tell
'''
    try:
        subprocess.run(["osascript", "-e", script], check=True, timeout=30)
        if log:
            log.info("Email sent: %s → %s", subject, recipient)
    finally:
        try:
            os.unlink(eml_path)
        except OSError:
            pass
