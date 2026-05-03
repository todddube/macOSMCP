#!/usr/bin/env python3
# mac-bridge — Evening Prep Agent
# Runs: 6:00 PM Mon–Fri via launchd
# Silent if tomorrow is clear.

"""
Evening prep — quick iMessage preview of tomorrow.

Fetches tomorrow's calendar events and reminders due tomorrow.
Sends a single iMessage only if there's something worth knowing.
No email — just a push notification.

Run manually:
    uv run --extra agent agents/evening_prep.py
    uv run --extra agent agents/evening_prep.py --dry-run
"""

import argparse
import asyncio
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from agents.runner import (
    extract_alert,
    run_agent,
    send_imessage_via_mcp,
    setup_logging,
)

TODAY = date.today()
TOMORROW = (TODAY + timedelta(days=1)).isoformat()

SYSTEM = f"""\
You are a concise personal assistant preparing a brief end-of-day check-in.

## Task
1. Call get_calendar_events — start_date="{TOMORROW}", end_date="{TOMORROW}", limit=20
2. Call get_upcoming_reminders — days=1, limit=20

## Decision logic
Send a message ONLY if:
- Tomorrow has calendar events, OR
- There are reminders due tomorrow

If tomorrow is completely clear → output: <alert></alert>

## Output format
If something is happening:
<alert>
[Under 180 chars. E.g. "Tomorrow: 9am Team standup, 2pm dentist. 2 reminders due. ✓ You're ready."]
</alert>

If clear:
<alert></alert>

## Rules
- Lead with first event time if there is one
- Mention total event count and reminder count
- Flag back-to-back meetings (< 15 min gap) with ⚠️
- Keep it brief — this is a glance notification
- Do NOT mention overdue items (that's priority_alert's job)
"""

TASK = f"Today is {TODAY.strftime('%A, %B %-d')}. Check what's on for tomorrow ({TOMORROW})."


async def main(dry_run: bool = False) -> None:
    log = setup_logging("evening_prep", dry_run)
    log.info("Starting evening prep (dry_run=%s)", dry_run)

    output = await run_agent(TASK, SYSTEM, model="claude-haiku-4-5-20251001", max_tokens=512, log=log)
    alert_text = extract_alert(output)

    if not alert_text:
        log.info("Tomorrow is clear — no message sent")
        return

    if dry_run:
        print(f"\n{'='*60}\nEVENING PREP PREVIEW\n{'='*60}")
        print(alert_text)
        return

    await send_imessage_via_mcp(alert_text, log=log)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Evening prep agent")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run))
