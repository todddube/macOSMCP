# MacBridge roadmap

What's left after 1.9.0 (2026-11-20): things to check by hand, work deliberately
deferred, and housekeeping. Tick items off or move them into the README's version
history as they ship.

## Check by hand on 1.9.0

The automated tests (217) and builds pass, but these were not seen on screen: the
terminal used for the release had no Screen Recording permission.

- [ ] **Menu-bar icon.** Readable on a light and a dark menu bar and with a tinted
      wallpaper. Plain template when idle, colored only during activity, status dots
      visible.
- [ ] **Right-click menu.** Still appears on the icon, including on a notched
      built-in display and an external display. The status item is found by its
      window level and height (60pt or less), which hasn't been tried on those
      setups.
- [ ] **Delete confirmation.** Try it on a throwaway reminder, never real data:
  - [ ] It floats above the frontmost app without taking the keyboard.
  - [ ] Escape cancels and Return does nothing.
  - [ ] Tab moves between the buttons.
  - [ ] The countdown ticks down.
  - [ ] A second delete waits behind the first and gets its own deadline.
  - [ ] Other tool calls keep working while the prompt is up.
- [ ] **Sessions.** Claude Desktop shows as one client with "2 sessions"; Restart
      Bridge clears the count without leaving ghost sessions.
- [ ] **App icon.** Looks right in Finder › Applications, the Dock (while Settings is
      open) and About, in light, dark, tinted and clear appearances.
- [ ] **About and version.** About shows "Version 1.9.0 (9) · November 20, 2026";
      `macbridge --version` prints `macbridge 1.9.0 (2026-11-20)`.

## Check by hand before the next release

Built and reviewed, not yet seen on screen in the real app.

- [ ] **Settings window (toolbar tabs).** Open it from the panel, the right-click
      menu, ⌘, and by opening MacBridge from Finder.
  - [ ] Safety, General and Diagnostics show as icons in the toolbar, and the window
        is titled after the selected tab.
  - [ ] Each tab lays out cleanly at 460×400, help text sits under each label, and
        Diagnostics scrolls.
  - [ ] The window opens centred on the screen the mouse is on, clear of the Dock.
  - [ ] Closing it removes the Dock icon again.
- [ ] **Launch splash.** Quit MacBridge and open it from Finder.
  - [ ] The card comes in, stays about two seconds, and the icon flies into the
        menu-bar icon with a ring spreading from it.
  - [ ] Clicking the card ends it early. It never takes focus or shows a Dock icon.
  - [ ] With Reduce Motion on, it fades out in place.
  - [ ] It fades out in place when the menu-bar icon is hidden or behind the notch.
  - [ ] It doesn't show when a client starts MacBridge, or when switched off in
        Settings › General.
  - [ ] Right-clicking the menu-bar icon during and after the splash still shows
        the menu.
  - [ ] With two displays, the card opens on the one the mouse is on, and it flies
        only if that display's menu bar holds the icon; otherwise it fades.
  - [ ] Decide: it also shows at login when "Open MacBridge at login" is on (login
        items don't carry the client marker). Skip it there, or keep it?

## Feature gaps: Calendar and Reminders tools

Researched 2026-11-21. Compared the 18 tools against what EventKit allows, what other
Apple Calendar/Reminders MCP servers offer, and the MCP features beyond tools. No
EventKit APIs were added in macOS 26 or 27, so everything below works from macOS 14.

### Ranked by value for effort

| # | Addition | Effort | Notes |
|---|---|---|---|
| 1 | ✅ **Prompts** (done): `plan-my-week`, `daily-agenda`, `review-overdue` | Low | Show as slash commands in Claude Code. FradSer's server has four; MacBridge has none. |
| 2 | ✅ **Resources** (done; per-list via a URI template): `macbridge://agenda/today`, `…/week`, `…/overdue`, one per reminder list | Low | Read-only views a client can attach as context (@-mention in Claude Code). None of the other servers have them. |
| 3 | **Richer repeats and alerts**: weekdays ("every Mon/Wed"), nth weekday ("2nd Tuesday"), several alerts, per-event time zone | Medium | All public EventKit (`EKRecurrenceRule` with `daysOfTheWeek`/`setPositions`, `addAlarm`, `EKEvent.timeZone`). MacBridge already *reads* these; it can't write them. Other servers treat them as read-only too. |
| 4 | **Reminder start date and location reminders** ("remind me when I get home") | Medium | `startDateComponents`; `EKAlarm.structuredLocation` + `proximity`. Location needs a place name turned into coordinates. |
| 5 | **Completed reminders by date** ("what did I finish this week?") | Low | `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)`. Today `include_completed` has no date window. |
| 6 | **Create, rename and delete calendars** | Low | `EKCalendar(for:eventStore:)`, `saveCalendar`, `removeCalendar`. Reminder lists already have this; calendars don't. Delete goes through the confirmation prompt. |
| 7 | **Conflict check** (`calendar_check_conflicts` for a proposed time) | Low | Reuses the free-time logic. che-ical-mcp has it. |
| 8 | **Batch operations** (create, move or complete many at once, with per-item results) | Medium | Fewer round trips for "move all of Friday to Monday". Batch deletes need one confirmation listing everything. |
| 9 | **Change notifications** from `EKEventStoreChanged` | Medium | Lets clients refresh resources. Coarse signal (no diff). Better done after the 2026-07-28 move, which replaces subscriptions. |
| 10 | **Undo for destructive tools** (snapshot before delete) | Medium | Safety net only che-ical-mcp offers. EventKit can't restore an id, so undo recreates the item with a new id. |

### Not possible through EventKit

- **Inviting attendees.** `attendees` is read-only and there's no public way to add
  people; invites need Calendar.app or CalDAV.
- **Travel time.** Private to Calendar.app.
- **Reminder tags, subtasks, sections and flags.** Not public. Other servers fake
  tags and subtasks in the notes field, which doesn't show up in Reminders.app as the
  real feature, so it isn't worth copying.

### Waiting on the Swift MCP SDK

Elicitation (Claude asking you instead of the popup), long-running tasks and
`subscriptions/listen` all arrive with spec 2026-07-28, which swift-sdk 0.12.1 doesn't
support (PR #314 is open, unreviewed). Claude Code supports elicitation and tasks
today; Claude Desktop's support is "rolling out soon".

Sources: [EventKit](https://developer.apple.com/documentation/eventkit),
[FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events),
[PsychQuant/che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp),
[MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
[swift-sdk PR #314](https://github.com/modelcontextprotocol/swift-sdk/pull/314).

## Deferred work

| Item | Why it waited | When to pick it up |
|---|---|---|
| **Close the prompt when its client hangs up.** If a client quits while its delete prompt is showing, the prompt stays up for up to 60s, and approving it still runs the delete. | Needs a hangup watch on each client connection in `BridgeServer` that cancels that client's queued requests. | Next release; it's a small change to how the server tracks connections. |
| **Swift 6 language mode / approachable concurrency** | Moving to the stricter checks touches most files; too much for a polish release. | Its own release, with the reviewer agent running on every file it touches. |
| **MCP spec 2026-07-28** | swift-sdk 0.12.1 (the latest) doesn't support it yet; Claude Desktop negotiates 2025-11-25. | When swift-sdk 0.13 or later ships (watch modelcontextprotocol/swift-sdk PR #314). |
| **Confirm through the client (elicitation)** rather than MacBridge's own popup | Claude Desktop doesn't support it reliably yet. | Once the main clients support it; keep the popup as the fallback. |
| **Claude Desktop extension (.mcpb) / MCP registry listing** | Optional. A bundled extension fits poorly with an app that has to be installed and granted permissions. | If installing it gets in the way for new users. |
| **Per-connection threads** | GCD gives each connection a thread and caps at about 64. That's fine for a handful of clients. | If many clients connect at once, or when moving the server to Swift concurrency. |
| **README screenshot** | Needs a screen capture of the panel, which wasn't possible this release. | Any time; light and dark versions together. |

## Housekeeping

- **iCloud duplicates.** The repo lives in iCloud-synced `~/Documents`, and iCloud
  keeps adding "Name 2.swift" copies that break `swift build` with duplicate
  declarations. It happened twice during the 1.9.0 work, with 20 files in total.
  Moving the checkout to a folder iCloud doesn't sync (e.g. `~/Developer`) stops it.
  Until then, list them with:

  ```sh
  find . -path ./.build -prune -o -name '* [0-9].*' -print
  ```

  Compare each one to the committed file and move it out. Never commit them.

- **Dependabot alerts.** GitHub reports 40 open alerts (authlib, mcp, dnspython,
  pyjwt, fastmcp, opentelemetry). They come from `uv.lock` and `archive_python/uv.lock`,
  Python lockfiles that no longer exist in the repo. Dismiss them as "not used" on the
  repository's Security › Dependabot page.
