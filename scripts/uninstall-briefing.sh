#!/usr/bin/env bash
# Unload and remove the daily briefing launchd agent.
# Does not delete logs or scheduled_agent.py.
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.thedubes.daily-briefing.plist"
LABEL="com.thedubes.daily-briefing"

echo "==> mac-bridge daily briefing uninstaller"

# Unload if running
if launchctl list "$LABEL" &>/dev/null; then
    launchctl unload "$PLIST_DST"
    echo "    agent unloaded"
else
    echo "    agent was not loaded (nothing to unload)"
fi

# Remove the plist from LaunchAgents
if [[ -f "$PLIST_DST" ]]; then
    rm "$PLIST_DST"
    echo "    plist removed: $PLIST_DST"
else
    echo "    plist not found at $PLIST_DST (already removed?)"
fi

echo ""
echo "==> Done. Daily briefing agent removed."
echo "    Logs preserved at: $HOME/Library/Logs/macOSMCP/"
echo "    Reinstall:  bash scripts/install-briefing.sh"
