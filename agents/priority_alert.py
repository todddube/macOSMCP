#!/usr/bin/env python3
# mac-bridge — Priority Alert Agent
# Runs: 11:30 AM + 4:30 PM daily via launchd
# Silent unless something genuinely urgent is found.

"""
Conditional priority alert — fires iMessage ONLY if high-priority or overdue
items exist that haven't been alerted about today.

Rate-limited: each reminder ID is only alerted once per calendar day.

Run manually:
    uv run --extra agent agents/priority_alert.py
    uv run --extra agent agents/priority_alert.py --dry-run
    uv run --extra agent agents/priority_alert.py --reset   # clear today's alert history
"""

import argparse
import asyncio
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from agents.runner import (
    extract_alert,
    load_state,
    run_agent,
    save_state,
    send_imessage_via_mcp,
    setup_logging,
)

TODAY = date.today().isoformat()

SYSTEM = """\
You are a triage agent. Your job is to spot genuine urgency, not to be noisy.

## Task
Call get_overdue_reminders (limit=50) and get_upcoming_reminders (days=1, limit=30).

## Decision logic
Send an alert ONLY if ANY of these are true:
- There are HIGH priority overdue reminders
- There are reminders due TODAY that aren't marked complete
- There are MEDIUM priority reminders overdue by more than 3 days

If the above conditions are not met → output exactly: <alert></alert>

## Output format
If alert needed:
<alert>
[Under 160 chars. Name specific items. E.g. "⚠️ Overdue: 'Call accountant' (High, 3 days). Due today: 'Submit report'."]
</alert>

If nothing urgent:
<alert></alert>

## Rules
- Be specific. Name actual reminder titles and lists.
- Do NOT alert about LOW priority items.
- Do NOT alert if everything is on track.
- A silent run is a success — only speak up when it matters.
"""

TASK = f"Today is {TODAY}. Check for urgent reminders and decide whether to alert."


async def main(dry_run: bool = False, reset: bool = False) -> None:
    log = setup_logging("priority_alert", dry_run)

    state = load_state()

    if reset:
        state.pop("alerted_today", None)
        state.pop("alert_date", None)
        save_state(state)
        log.info("Alert history cleared")
        return

    # Reset daily alert log on new day
    if state.get("alert_date") != TODAY:
        state["alert_date"] = TODAY
        state["alerted_today"] = []
        save_state(state)

    log.info("Starting priority alert check (dry_run=%s)", dry_run)

    output = await run_agent(TASK, SYSTEM, model="claude-haiku-4-5-20251001", max_tokens=512, log=log)
    alert_text = extract_alert(output)

    if not alert_text:
        log.info("No urgent items — silent run")
        return

    # Basic deduplication: skip if identical alert sent today
    alerted_today: list[str] = state.get("alerted_today", [])
    if alert_text in alerted_today:
        log.info("Alert already sent today (same content) — skipping")
        return

    if dry_run:
        print(f"\n{'='*60}\nALERT PREVIEW\n{'='*60}")
        print(alert_text)
        return

    await send_imessage_via_mcp(alert_text, log=log)

    alerted_today.append(alert_text)
    state["alerted_today"] = alerted_today
    save_state(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Priority alert agent")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--reset", action="store_true", help="Clear today's alert history")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run, args.reset))
