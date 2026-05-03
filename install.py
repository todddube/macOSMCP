#!/usr/bin/env python3
# mac-bridge — Python Installer
# Author: Todd Dube | May 2026

"""
mac-bridge agent installer.

What this does:
  1. Checks prerequisites (uv, op, osascript)
  2. Syncs Python deps (uv sync --extra agent)
  3. Pulls Anthropic API key from 1Password → stores in macOS Keychain
  4. Creates runtime directories (~/.mac-bridge, ~/Library/Logs/macOSMCP)
  5. Copies launchd plists to ~/Library/LaunchAgents/
  6. Loads (or reloads) each launchd agent
  7. Runs a dry-run of the morning briefing to validate the stack

Usage:
    uv run install.py              # full install
    uv run install.py --dry-run    # install without loading launchd agents
    uv run install.py --uninstall  # unload and remove all agents
    uv run install.py --status     # show launchd agent status
    uv run install.py --refresh-key  # re-pull API key from 1Password → Keychain
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).parent.resolve()
PLISTS_DIR = PROJECT_DIR / "plists"
LAUNCH_AGENTS_DIR = Path.home() / "Library" / "LaunchAgents"
LOG_DIR = Path.home() / "Library" / "Logs" / "macOSMCP"
STATE_DIR = Path.home() / ".mac-bridge"

OP_ANTHROPIC_REF = os.environ.get(
    "OP_ANTHROPIC_REF",
    "op://Personal/Claude API Todd Secret/credential",
)

AGENTS = [
    "com.thedubes.morning-briefing",
    "com.thedubes.weekly-review",
    "com.thedubes.priority-alert",
    "com.thedubes.evening-prep",
]

# ANSI colors for terminal output
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BOLD = "\033[1m"
RESET = "\033[0m"


def ok(msg: str) -> None:
    print(f"  {GREEN}✓{RESET} {msg}")


def warn(msg: str) -> None:
    print(f"  {YELLOW}⚠{RESET}  {msg}")


def err(msg: str) -> None:
    print(f"  {RED}✗{RESET} {msg}")


def header(msg: str) -> None:
    print(f"\n{BOLD}{msg}{RESET}")


def run(cmd: list[str], check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=True,
    )


# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------

def check_prerequisites() -> bool:
    header("Checking prerequisites")
    ok_count = 0

    for tool, hint in [
        ("uv", "brew install uv"),
        ("op", "brew install 1password-cli"),
        ("osascript", "built-in macOS (should always be present)"),
        ("security", "built-in macOS (should always be present)"),
    ]:
        path = shutil.which(tool)
        if path:
            ok(f"{tool} → {path}")
            ok_count += 1
        else:
            err(f"{tool} not found — install with: {hint}")

    return ok_count == 4


# ---------------------------------------------------------------------------
# Step 2 — Python deps
# ---------------------------------------------------------------------------

def sync_deps() -> None:
    header("Syncing Python dependencies")
    run(["uv", "sync", "--extra", "agent", "--directory", str(PROJECT_DIR)])
    ok("uv sync --extra agent complete")


# ---------------------------------------------------------------------------
# Step 3 — API key: 1Password → Keychain
# ---------------------------------------------------------------------------

def check_op_signed_in() -> bool:
    result = run(["op", "account", "list"], capture=True, check=False)
    return result.returncode == 0 and "thedubes.1password.com" in result.stdout


def fetch_key_from_1password() -> str:
    result = run(["op", "read", OP_ANTHROPIC_REF], capture=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"1Password read failed: {result.stderr.strip()}\n"
            f"  Reference: {OP_ANTHROPIC_REF}\n"
            f"  Try: op signin"
        )
    key = result.stdout.strip()
    if not key.startswith("sk-ant-"):
        raise RuntimeError(f"Unexpected key format from 1Password (got {key[:12]}...)")
    return key


def store_key_in_keychain(api_key: str) -> None:
    run([
        "security", "add-generic-password",
        "-s", "mac-bridge",
        "-a", "ANTHROPIC_API_KEY",
        "-w", api_key,
        "-U",
    ])


def keychain_key_exists() -> bool:
    result = run(
        ["security", "find-generic-password", "-s", "mac-bridge", "-a", "ANTHROPIC_API_KEY", "-w"],
        check=False, capture=True,
    )
    return result.returncode == 0 and bool(result.stdout.strip())


def setup_api_key(force_refresh: bool = False, op_ref: str = OP_ANTHROPIC_REF) -> None:
    header("API key setup (1Password → Keychain)")

    if keychain_key_exists() and not force_refresh:
        ok("API key already in Keychain — skipping (use --refresh-key to update)")
        return

    if not check_op_signed_in():
        err("1Password CLI not signed in. Run: op signin")
        sys.exit(1)

    print(f"  Pulling from 1Password: {op_ref}")
    result = run(["op", "read", op_ref], capture=True, check=False)
    if result.returncode != 0:
        err(f"1Password read failed: {result.stderr.strip()}")
        sys.exit(1)
    key = result.stdout.strip()
    if not key.startswith("sk-ant-"):
        err(f"Unexpected key format (got {key[:12]}...)")
        sys.exit(1)
    store_key_in_keychain(key)
    ok(f"API key stored in Keychain (service=mac-bridge, account=ANTHROPIC_API_KEY, key={key[:12]}...)")


# ---------------------------------------------------------------------------
# Step 4 — Runtime directories
# ---------------------------------------------------------------------------

def create_directories() -> None:
    header("Creating runtime directories")
    for d in [LOG_DIR, STATE_DIR, LAUNCH_AGENTS_DIR]:
        d.mkdir(parents=True, exist_ok=True)
        ok(str(d))


# ---------------------------------------------------------------------------
# Step 5 — Install launchd plists
# ---------------------------------------------------------------------------

def install_plists() -> None:
    header("Installing launchd plists")
    for agent in AGENTS:
        src = PLISTS_DIR / f"{agent}.plist"
        dst = LAUNCH_AGENTS_DIR / f"{agent}.plist"
        if not src.exists():
            err(f"Missing plist: {src}")
            continue
        shutil.copy2(src, dst)
        ok(f"{agent}.plist → {dst}")


# ---------------------------------------------------------------------------
# Step 6 — Load launchd agents
# ---------------------------------------------------------------------------

def agent_is_loaded(label: str) -> bool:
    result = run(["launchctl", "list", label], check=False, capture=True)
    return result.returncode == 0


def load_agents() -> None:
    header("Loading launchd agents")
    for agent in AGENTS:
        plist_path = LAUNCH_AGENTS_DIR / f"{agent}.plist"

        # Unload first if already loaded (to pick up plist changes)
        if agent_is_loaded(agent):
            run(["launchctl", "unload", str(plist_path)], check=False)

        result = run(["launchctl", "load", str(plist_path)], check=False, capture=True)
        if result.returncode == 0:
            ok(f"Loaded: {agent}")
        else:
            err(f"Failed to load {agent}: {result.stderr.strip()}")


# ---------------------------------------------------------------------------
# Step 7 — Dry-run validation
# ---------------------------------------------------------------------------

def run_dry_run() -> None:
    header("Dry-run validation (morning_briefing)")
    print("  Running: uv run --extra agent agents/morning_briefing.py --dry-run")
    print("  (This will call Claude and your mac-bridge tools — takes ~15s)\n")
    result = run(
        [
            "uv", "run",
            "--directory", str(PROJECT_DIR),
            "--extra", "agent",
            "agents/morning_briefing.py",
            "--dry-run",
        ],
        check=False,
    )
    if result.returncode == 0:
        ok("Dry-run succeeded")
    else:
        err(f"Dry-run failed with exit code {result.returncode}")


# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

def uninstall() -> None:
    header("Uninstalling mac-bridge agents")
    for agent in AGENTS:
        plist_path = LAUNCH_AGENTS_DIR / f"{agent}.plist"
        if agent_is_loaded(agent):
            run(["launchctl", "unload", str(plist_path)], check=False)
            ok(f"Unloaded: {agent}")
        else:
            warn(f"Not loaded: {agent}")

        if plist_path.exists():
            plist_path.unlink()
            ok(f"Removed: {plist_path}")

    print(f"\n{YELLOW}Note: Keychain entry and log files were not removed.{RESET}")
    print("  To remove Keychain entry:")
    print("    security delete-generic-password -s mac-bridge -a ANTHROPIC_API_KEY")
    print("  To remove logs:")
    print(f"    rm -rf {LOG_DIR}")


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

def show_status() -> None:
    header("Agent status")
    for agent in AGENTS:
        plist_path = LAUNCH_AGENTS_DIR / f"{agent}.plist"
        plist_exists = plist_path.exists()
        loaded = agent_is_loaded(agent)

        status = f"{GREEN}loaded{RESET}" if loaded else f"{RED}not loaded{RESET}"
        plist_str = f"{GREEN}installed{RESET}" if plist_exists else f"{RED}missing{RESET}"
        print(f"  {agent}: {status} | plist: {plist_str}")

    print()
    if keychain_key_exists():
        ok("API key in Keychain")
    else:
        err("API key NOT in Keychain — run: uv run install.py")

    print(f"\n  Logs: {LOG_DIR}")
    print(f"  State: {STATE_DIR / 'agent_state.json'}")

    print("\n  Schedules:")
    print("    morning-briefing   07:00 daily")
    print("    weekly-review      17:00 Sunday")
    print("    priority-alert     11:30 + 16:30 daily")
    print("    evening-prep       18:00 Mon–Fri")

    print("\n  Manual run commands:")
    for agent_script in ["morning_briefing", "weekly_review", "priority_alert", "evening_prep"]:
        print(f"    uv run --extra agent agents/{agent_script}.py --dry-run")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="mac-bridge agent installer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--dry-run", action="store_true", help="Install but do not load launchd agents")
    parser.add_argument("--uninstall", action="store_true", help="Unload and remove all agents")
    parser.add_argument("--status", action="store_true", help="Show agent status")
    parser.add_argument("--refresh-key", action="store_true", help="Re-pull API key from 1Password")
    parser.add_argument("--skip-dry-run", action="store_true", help="Skip the validation dry-run")
    parser.add_argument(
        "--op-ref",
        default=OP_ANTHROPIC_REF,
        help="1Password reference for Anthropic API key",
    )
    args = parser.parse_args()
    # Allow CLI override of the 1Password reference used in setup_api_key()
    _op_ref = args.op_ref

    print(f"\n{BOLD}mac-bridge Agent Installer{RESET}")
    print(f"Project: {PROJECT_DIR}")

    if args.status:
        show_status()
        return

    if args.uninstall:
        uninstall()
        return

    # Full install
    if not check_prerequisites():
        err("Prerequisites not met — fix above errors and retry")
        sys.exit(1)

    sync_deps()
    setup_api_key(force_refresh=args.refresh_key, op_ref=_op_ref)
    create_directories()
    install_plists()

    if not args.dry_run:
        load_agents()
    else:
        warn("--dry-run: skipping launchd load")

    if not args.skip_dry_run:
        run_dry_run()

    header("Installation complete")
    print(f"\n  {GREEN}All agents installed and scheduled.{RESET}")
    print(f"\n  Check status:  uv run install.py --status")
    print(f"  View logs:     tail -f {LOG_DIR}/morning_briefing.log")
    print(f"  Test now:      uv run --extra agent agents/morning_briefing.py --dry-run")


if __name__ == "__main__":
    main()
