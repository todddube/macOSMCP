#!/usr/bin/env bash
# Install and activate the daily briefing launchd agent.
# Safe to run multiple times — unloads first if already loaded.
set -euo pipefail

PLIST_SRC="$(cd "$(dirname "$0")/.." && pwd)/com.thedubes.daily-briefing.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.thedubes.daily-briefing.plist"
LABEL="com.thedubes.daily-briefing"
LOG_DIR="$HOME/Library/Logs/macOSMCP"

echo "==> mac-bridge daily briefing installer"

# Verify the plist source exists in the repo
if [[ ! -f "$PLIST_SRC" ]]; then
    echo "ERROR: plist not found at $PLIST_SRC"
    echo "       Run this script from the macOSMCP repo directory."
    exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"
echo "    log dir: $LOG_DIR"

# Unload existing agent if loaded (suppress error if not loaded)
if launchctl list "$LABEL" &>/dev/null; then
    echo "    unloading existing agent..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# Copy plist to LaunchAgents
cp "$PLIST_SRC" "$PLIST_DST"
echo "    plist copied to $PLIST_DST"

# Load the agent
launchctl load "$PLIST_DST"
echo "    agent loaded"

# Confirm
if launchctl list "$LABEL" &>/dev/null; then
    echo ""
    echo "==> Done. Agent scheduled daily at 7:00 AM."
    echo ""
    echo "    Test run now:  launchctl start $LABEL"
    echo "    Watch logs:    tail -f $LOG_DIR/scheduled_agent.log"
    echo "    Dry run:       uv run --extra agent scheduled_agent.py --dry-run"
    echo "    Remove agent:  bash scripts/uninstall-briefing.sh"
else
    echo "ERROR: agent did not load — check plist syntax"
    exit 1
fi
