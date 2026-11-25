# MacBridge roadmap

Where things stand on 2026-11-25, what to do next, and what's deferred. Tick items off
or move them into the README's version history as they ship.

## Where things stand

**1.9.0 is ready to publish.** There are no git tags or GitHub releases yet;
1.9.0 will be the first. The repo is public. CI is green on
`main`, with 316 tests.

Done since the 1.9.0 build (2026-11-20). All of it is already in the README's 1.9.0
notes:

| Date | Change |
|---|---|
| 2026-11-21 | MCP **prompts**: `daily-agenda`, `plan-my-week`, `review-overdue` (slash commands in Claude Code) |
| 2026-11-21 | Menu-bar client dots show green again (regression from the template icon in 1.9.0) |
| 2026-11-21 | MCP **resources**: `macbridge://agenda/today`, `…/agenda/week`, `…/reminders/overdue`, one per list |
| 2026-11-21 | Menu-bar animation CPU cut about 10× (one call: ~44% for 11 s → ~1 s); accept loop hardened |
| 2026-11-21 | Writes **richer repeats** (weekdays, "2nd Tuesday", last weekday, days of the month), **several alerts** and **per-event time zones** |

## Next up (in order)

1. [x] **Decide the version.** Kept **1.9.0**, build 10, dated 2026-11-25, since nothing
       had been published.
2. [x] **Close the prompt when its client hangs up.** Done: the bridge checks for a
       hangup every 500 ms while a call is pending and cancels it; the prompt closes.
3. [ ] **Hand-check pass.** Partly done 2026-11-25 (menu-bar icon, right-click menu).
       The rest of "Check by hand before publishing" below is still open.
4. [x] **README screenshot and icon.** Light-mode panel in `docs/images/panel.png`.
       A dark version is still wanted.
5. [ ] **Publish.** Needs notary credentials stored once
       (`xcrun notarytool store-credentials macbridge-notary ...`), then `make release`
       and `make publish`, then review the draft release and publish it.
6. [x] **Dismiss the Dependabot alerts.** All 40 dismissed as "not used" on 2026-11-25.
7. [x] **New app icon.** Redrawn as a bridge at dusk (indigo-to-coral sky, low sun,
       solid span, current Mac mini).
8. [ ] **Announce.** Reddit post once the release is live.

## Check by hand before publishing

The automated tests and builds pass, but none of these has been seen on screen yet.

### Menu bar and app

- [x] **Menu-bar icon** (checked 2026-11-25). Readable on a light and a dark menu bar and with a tinted
      wallpaper. Plain template when no clients are installed; otherwise the colour
      image with **green** dots for connected or ready clients, yellow for needs a look
      and red for can't serve. The bridge follows the bar's text colour, including
      after a light/dark switch.
- [ ] **Animation cost.** One tool call animates for about a second, then the app goes
      back to 0% CPU in Activity Monitor.
- [x] **Right-click menu** (checked 2026-11-25). Still appears on the icon, including on a notched
      built-in display and an external display. The status item is found by its
      window level and height (60pt or less), which hasn't been tried on those
      setups.
- [ ] **Sessions.** Claude Desktop shows as one client with "2 sessions"; Restart
      Bridge clears the count without leaving ghost sessions.
- [ ] **App icon.** Looks right in Finder › Applications, the Dock (while Settings is
      open) and About, in light, dark, tinted and clear appearances.
- [ ] **About and version.** About shows the final version, build and date;
      `macbridge --version` prints `macbridge 1.9.0 (<date>)`.

### Delete confirmation

Skipped in the 2026-11-25 pass; still to do. Try it on a throwaway reminder, never
real data:

- [ ] It floats above the frontmost app without taking the keyboard.
- [ ] Escape cancels and Return does nothing.
- [ ] Tab moves between the buttons.
- [ ] The countdown ticks down.
- [ ] A second delete waits behind the first and gets its own deadline.
- [ ] Other tool calls keep working while the prompt is up.
- [ ] Quitting the client while the prompt is up closes it (once the hangup fix is in).

### Settings window (toolbar tabs)

Open it from the panel, the right-click menu, ⌘, and by opening MacBridge from Finder.

- [ ] Safety, General and Diagnostics show as icons in the toolbar, and the window
      is titled after the selected tab.
- [ ] Each tab lays out cleanly at 460×400, help text sits under each label, and
      Diagnostics scrolls.
- [ ] The window opens centred on the screen the mouse is on, clear of the Dock.
- [ ] Closing it removes the Dock icon again.

### Launch splash

Quit MacBridge and open it from Finder.

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
- [ ] **Decide:** it also shows at login when "Open MacBridge at login" is on (login
      items don't carry the client marker). Skip it there, or keep it?

### Prompts, resources and richer writes (new since the 1.9.0 build)

- [ ] **Prompts.** `/mcp__macbridge__daily-agenda`, `…plan-my-week` and
      `…review-overdue` show in Claude Code and work before the app is running.
- [ ] **Resources.** `@`-mentioning `macbridge://agenda/today` in Claude Code attaches
      it. A new client connecting doesn't trigger the Reminders permission prompt.
- [ ] **Repeats in Apple's apps.** Create "every Mon/Wed", "2nd Tuesday" and "last
      weekday of the month" on a test calendar and a test list. Calendar.app and
      Reminders.app show the same rule MacBridge describes.
- [ ] **Alerts and time zones.** An event with three alerts shows all three in
      Calendar.app. An event in `Europe/London` shows the right local time, and
      Calendar.app's time zone support shows the zone.
- [ ] **Claude Desktop too.** Prompts and resources in Claude Desktop, if it lists
      them. Note what it doesn't support.

## Feature backlog: Calendar and Reminders tools

Researched 2026-11-21: the tools compared against what EventKit allows, what other
Apple Calendar/Reminders MCP servers offer, and the MCP features beyond tools. No
EventKit APIs were added in macOS 26 or 27, so everything below works from macOS 14.

Done: prompts, resources, richer repeats and alerts (see "Where things stand").

### Ranked by value for effort

| # | Addition | Effort | Notes |
|---|---|---|---|
| 1 | **Completed reminders by date** ("what did I finish this week?") | Low | `predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)`. Today `include_completed` has no date window. Pairs well with a `weekly-review` prompt. |
| 2 | **Conflict check** (`calendar_check_conflicts` for a proposed time) | Low | Reuses the free-time logic. che-ical-mcp has it. |
| 3 | **Create, rename and delete calendars** | Low | `EKCalendar(for:eventStore:)`, `saveCalendar`, `removeCalendar`. Reminder lists already have this; calendars don't. Delete goes through the confirmation prompt. |
| 4 | **One-click Connect for Cursor, Windsurf and VS Code** ([#2](../../issues/2)) | Medium | Reuses `ClientSetup.detect` and `ClientConfigWriter`. Each editor has its own file, and some allow comments (JSONC), which the writer must not break. Widens who can use MacBridge more than any tool does. |
| 5 | **Reminder start date and location reminders** ("remind me when I get home") | Medium | `startDateComponents`; `EKAlarm.structuredLocation` + `proximity`. A place name has to be turned into coordinates (MapKit geocoding); check what permission or entitlement that needs. |
| 6 | **Batch operations** (create, move or complete many at once, with per-item results) | Medium | Fewer round trips for "move all of Friday to Monday". Batch deletes need one confirmation listing everything. |
| 7 | **Undo for destructive tools** (snapshot before delete) | Medium | A safety net only che-ical-mcp offers. EventKit can't restore an id, so undo recreates the item with a new id. |
| 8 | **Change notifications** from `EKEventStoreChanged` | Medium | Lets clients refresh resources. Coarse signal (no diff). Better done after the 2026-07-28 spec move, which replaces subscriptions. |

Suggested 1.10 scope: #1, #2, #3 (all low effort) plus #4.

### Not possible through EventKit

- **Inviting attendees.** `attendees` is read-only and there's no public way to add
  people; invites need Calendar.app or CalDAV.
- **Travel time.** Private to Calendar.app.
- **Reminder tags, subtasks, sections and flags.** Not public. Other servers fake
  tags and subtasks in the notes field, which doesn't show up in Reminders.app as the
  real feature, so it isn't worth copying.

Sources: [EventKit](https://developer.apple.com/documentation/eventkit),
[FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events),
[PsychQuant/che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp),
[MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
[swift-sdk PR #314](https://github.com/modelcontextprotocol/swift-sdk/pull/314).

## To start thinking about

Decisions that shape the next few releases, though none is urgent this week.

- **The Swift MCP SDK is stalled.** As of 2026-11-25, swift-sdk's latest release is
  still 0.12.1 (2026-05-07). PR #314 (spec 2026-07-28) is open and unmerged, last
  touched 2026-11-22. Elicitation, long-running tasks and `subscriptions/listen` all
  wait on it. Options: keep waiting; review or test the PR upstream to help it land;
  or pin to the PR's branch in a separate branch here and try it out. Recommended:
  test the PR against MacBridge's test suite and leave a review, which costs little
  and tells us early what will break.
- **Swift 6 language mode.** Every target is still `.swiftLanguageMode(.v5)` and
  `SWIFT_VERSION` 5.0. This needs its own release with the reviewer agent on every
  file. Doing it before the SDK move means fewer concurrency changes landing at once.
  Pair it with moving `BridgeServer` off one thread per connection.
- **Distribution and discovery.** Once a release is actually published: a Homebrew
  cask (`brew install --cask macbridge`) is the usual way Mac developers install
  tools like this. The MCP registry and a Claude Desktop extension (`.mcpb`) are
  worth revisiting, though an app that must be installed and granted permissions
  fits a bundled extension poorly.
- **Release routine.** Nothing has been published so far. Decide how often to cut
  releases (for example, whenever a backlog item ships), so the README's version
  history matches what people can download.
- **Move the checkout out of iCloud.** It keeps causing the duplicate-file problem
  (see Housekeeping); moving the folder fixes it for good.

## Deferred work

| Item | Why it waited | When to pick it up |
|---|---|---|
| **Swift 6 language mode / approachable concurrency** | Moving to the stricter checks touches most files; too much for a polish release. | Its own release (see "To start thinking about"). |
| **MCP spec 2026-07-28** | swift-sdk 0.12.1 (the latest) doesn't support it; Claude Desktop negotiates 2025-11-25. | When swift-sdk 0.13 or later ships (PR #314). |
| **Confirm through the client (elicitation)** rather than MacBridge's own popup | Needs the 2026-07-28 SDK, and Claude Desktop doesn't support it reliably yet. | Once the main clients support it; keep the popup as the fallback. |
| **Claude Desktop extension (.mcpb) / MCP registry listing** | Optional. A bundled extension fits poorly with an app that has to be installed and granted permissions. | After the first published release (see Distribution). |
| **Per-connection threads** | Each connection holds a thread while connected. Measured 2026-11-21: 320 concurrent connections ran fine (325 threads, 71 MB, no fd leak), and silent connections are now closed after 10 s. Fine for real use. | With the Swift 6 move. |

## Performance (measured 2026-11-21)

Load-tested against the installed app, Release build, on this Mac:

| Scenario | Result |
|---|---|
| Idle, 60 s | 0.0% CPU, 1 wakeup, 22 MB, 6 threads |
| One tool call | ~1 s of light CPU, then 0% (was ~44% for 11 s) |
| One call every 3 s (a busy chat) | 5.6% average (was ~44%) |
| 1 client × 50 calls | 29 calls/s, p50 34 ms, p95 55 ms |
| 8 clients × 100 calls | 93 calls/s, p50 ~60 ms, p95 ~165 ms, ~70% CPU, 85 MB, no errors |
| 60 clients connected at once | no errors, 71 threads |
| 320 raw connections | all accepted, files back to baseline after close |
| 100 silent connections | all closed after 10 s |

Memory settles around 85 MB once EventKit has loaded, with no growth across runs. Sustained
load CPU is EventKit's own query work; nothing real uses 90 calls a second.

## Housekeeping

- **iCloud duplicates.** The repo lives in iCloud-synced `~/Documents`, and iCloud
  keeps adding "Name 2.swift" copies that break `swift build` with duplicate
  declarations. It happened twice during the 1.9.0 work, with 20 files in total (none
  present on 2026-11-25). Moving the checkout to a folder iCloud doesn't sync (e.g.
  `~/Developer`) stops it. Until then, list them with:

  ```sh
  find . -path ./.build -prune -o -name '* [0-9].*' -print
  ```

  Compare each one to the committed file and move it out. Never commit them.

- **Dependabot alerts.** The 40 alerts from the deleted Python lockfiles (`uv.lock`,
  `archive_python/uv.lock`) were dismissed as "not used" on 2026-11-25. New ones would
  be real: the Swift packages are the only dependencies now.
