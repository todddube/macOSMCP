# MacBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-6-orange.svg)

**v1.8.0** — a free, open-source macOS **menu-bar app and MCP server** that gives Claude Code and Claude Desktop read
and write access to your **Calendar** and **Reminders**, through EventKit, entirely on your Mac.

Swift package + Xcode app. No Python, no Node, and no network use except **Check for Updates…**,
when you click it. Requires macOS 13+. Free to use, modify and share under the
[MIT License](LICENSE). To build it yourself, see [BUILDING.md](BUILDING.md).

```
  Claude Code ───stdio──┐
  Claude Desktop ─stdio─┤   macbridge mcp        ← shim: no EventKit, no TCC of its own
  (any MCP client) ─────┘        │
                                 │ Unix socket, newline-delimited JSON
                                 ▼
                    MacBridge.app (menu bar)     ← the same binary, launched with no arguments
                    ├─ BridgeServer      one connection per client, kernel-verified identity
                    ├─ ToolRegistry      18 tools, name → handler table
                    ├─ ActivityLog       what the menu bar shows
                    └─ MacBridgeKit      EventKit lives here; TCC is granted once, to the app
```

## Tools

| | Calendar (8) | Reminders (10) |
|---|---|---|
| Read | `calendar_list_calendars`, `calendar_search_events`, `calendar_find_available_times` | `reminders_list_lists`, `reminders_search_reminders` |
| Write | `calendar_create_event`, `calendar_update_event`, `calendar_reschedule_event`, `calendar_open_event` | `reminders_create_reminder`, `reminders_update_reminder`, `reminders_complete_reminder`, `reminders_open_reminder`, `reminders_create_list`, `reminders_update_list` |
| Destructive | `calendar_cancel_event` | `reminders_delete_reminder`, `reminders_delete_list` |

One search tool per domain rather than several narrow ones: today's schedule, a text search,
overdue items and upcoming items are all parameters of `reminders_search_reminders` and
`calendar_search_events`. A model picks parameters more reliably than it picks between five
near-identical tools.

Dates accept `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM[:SS]`, full ISO-8601, or relative values: `today`,
`tomorrow`, `now`, `+7d`, `-3d`, `+2w`, `+1mo`, `+2h`, `+30min`. Output is always one canonical form, so a client never has
to guess. Times are in the Mac's local time zone.

`calendar_find_available_times` exists so a model proposing a meeting slot does not have to read
events and reason about the gaps itself. Events marked *free* and cancelled events do not block;
all-day events block their whole span. Birthdays, and all-day events on subscribed calendars such
as public holidays, don't block unless `include_subscribed` is set or `calendars` names them; timed
events on subscribed calendars still do. The result says what was left out.

Search results stay short: each event says how it repeats and, for an invitation, how you
replied. Pass `event_id` to `calendar_search_events` for one event in full: who is invited and
how each replied, its alerts, and whether it shows as busy. Pass `include_details` to get that
for every event. `calendar_update_event` changes alerts, availability and how an event repeats;
`reminders_update_reminder` changes how a reminder repeats.

## Install

You don't need to build anything. Requires **macOS 13 or later**.

1. **Download** `MacBridge-<version>.dmg` from the
   [latest release](https://github.com/todddube/macOSMCP/releases/latest).
2. **Open it and drag MacBridge onto Applications**, then open MacBridge from Applications. (If you
   open it from somewhere else, it offers to move itself.) A bridge icon appears in the menu bar;
   there's no Dock icon.
3. **Click the bridge icon, then Grant** next to Calendars and Reminders.
4. **Click Connect** next to Claude Desktop or Claude Code. For Claude Desktop, quit and reopen it
   afterwards.

That's it. Ask Claude something like *"what's on my calendar tomorrow?"* to try it. The dots under
the menu-bar icon turn green when a client is connected.

To remove MacBridge, click **Disconnect** next to each client in the panel, quit MacBridge from the
right-click menu, and drag it from Applications to the Trash.

### Build from source

```bash
git clone https://github.com/todddube/macOSMCP.git && cd macOSMCP
make install     # build, install to /Applications, launch
```

Needs Xcode 16.3 or later. Then **Grant** and **Connect** as above. [BUILDING.md](BUILDING.md) covers
the rest: tests, Xcode, signing so permissions survive rebuilds, and making a release.

## First run

MacBridge does nothing on its own — a client has to be told to run `macbridge mcp`. The menu-bar
panel states where you are:

```
  ● MacBridge 1.8.0                          18 tools
    Listening — 12 calls, 1 failed

  PERMISSIONS
    ✓ Calendars   granted
    ! Reminders   not yet requested          [Grant…]

  SAFETY
    ☐ Read-only
    ☑ Ask before deleting

  CLIENT SETUP                               Re-check
    ✓ Claude Code       connected to this app
    ○ Claude Desktop    not set up
        [Connect Claude Desktop]        Manual setup ▾

  CONNECTED CLIENTS                                 1
    ● Claude Code                              pid 49823

  RECENT ACTIVITY
    14:02:11  reminders_search_reminders    Claude Code
    14:01:58  calendar_search_events        Claude Code
    14:01:40  — connected —                 Claude Code

  DIAGNOSTICS
    [Open Log]  [Copy Diagnostics]  [Refresh]
    [Restart Bridge]  [Relaunch App]

    ☐ Open MacBridge at login
```

If another copy of MacBridge is the one your clients point at, a warning appears at the top with its
path — the failure that is otherwise invisible.

It reads both clients' config files and compares the command they name against this app's own
binary — so a config left over from a `DerivedData` build shows as **wrong path** rather than
looking fine and failing later. `macbridge doctor` prints the same information.

**Connect** does the setup for you. For Claude Desktop it adds MacBridge to
`claude_desktop_config.json`, keeping everything else in the file and its permissions. It saves the
original beside it as `claude_desktop_config.json.macbridge-backup` the first time, and the file as it
was just before each later change as `claude_desktop_config.json.macbridge-previous`. A file that is
already correct isn't touched. For Claude Code it runs
`claude mcp add --scope user`. **Manual setup** still copies the command or the JSON, for anyone
who would rather make the change themselves.

**Safety** controls what every connected client may do. **Read-only** refuses all changes, and
**Ask before deleting** (on by default) shows an alert before any event, reminder or list is
deleted, and before a repeating event's repeat is changed, which removes the occurrences that no
longer fit. Nobody answering within a minute counts as Don't Allow.

## Logs and diagnostics

| Source | Where | Contains |
|---|---|---|
| **The app** | `~/Library/Logs/MacBridge/macbridge.log` | connects, disconnects, every tool call and failure. Capped at 512 KB, one generation kept. |
| The app, live | `log stream --predicate 'subsystem == "com.thedubes.macbridge"'` | the same via the unified log, with categories `bridge`, `tools`, `permissions`, `app`, `cli` |
| Claude Desktop | `~/Library/Logs/Claude/mcp-server-macbridge.log` | the shim's stderr plus full JSON-RPC traffic |
| Claude Code | `~/Library/Caches/claude-cli-nodejs/<project>/mcp-logs-macbridge/` | the same, per project |

The panel has **Open Log** and **Copy Diagnostics** — the latter puts version, bundle path, socket,
permissions, client setup, connection counts and the last 30 log lines on the clipboard in one
block.

**Restart Bridge** rebinds the socket without quitting; connected clients reconnect on their next
call, so it is safe to use mid-conversation. **Relaunch App** restarts the process, which is what
picks up a permission change that EventKit will not show to already-running stores.

## Two copies, two sockets

Each `.app` listens on its own socket, named from a digest of its bundle path:

```
~/Library/Application Support/MacBridge/bridge-ab550ba7.sock   ← /Applications/MacBridge.app
~/Library/Application Support/MacBridge/bridge-8e71cfd3.sock   ← an Xcode DerivedData build
```

This is not tidiness. A DerivedData build and the copy in `/Applications` are, to macOS, **different
apps with different TCC identities**. When they shared one socket, whichever started first served
every client — so requests could land on a copy that had no Calendar or Reminders permission and
fail with "not yet requested", while the copy you had granted sat idle. Restarting appeared to fix
it because it shuffled which copy held the socket.

A shim derives the same socket name as the app in its own bundle, so it can only ever reach its own
copy, and the handshake also carries the bundle path as a second check. The panel warns when your
clients are configured for a different copy than the one running.

## Connect a client

**Claude Code**

```bash
claude mcp add --scope user macbridge -- /Applications/MacBridge.app/Contents/MacOS/macbridge mcp
```

**Claude Desktop** — in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{ "mcpServers": { "macbridge": {
    "command": "/Applications/MacBridge.app/Contents/MacOS/macbridge", "args": ["mcp"] } } }
```

Or click **Connect** in the menu-bar panel, which does this for you. This repo's `.mcp.json` already points at
that path, so Claude Code picks it up when you open the project here.

You do not need to start the app first: if a client spawns the shim while the app is closed, the
shim launches it and waits for the socket.

## One binary, two faces

`MacBridge.app/Contents/MacOS/macbridge` is **both** the menu-bar app and the CLI that MCP clients
spawn. Launched by LaunchServices there are no arguments, so the SwiftUI app runs; invoked as
`macbridge mcp` it connects to the running app over the socket and never touches AppKit or EventKit.

It has to be one binary rather than an app plus an embedded tool: macOS filesystems are
case-insensitive by default, so `Contents/MacOS/MacBridge` and `Contents/MacOS/macbridge` are the
same path, and copying the second destroys the first.

The socket protocol is deliberately **not** MCP. The shim already speaks MCP to the client, so the
app only has to answer *what tools exist* and *run this one*. That keeps the app a tool server —
the thing that owns TCC, the activity log and eventually consent — and keeps MCP version churn on
the shim side. Both ship in the same bundle, so they always update together.

## Command line

The app's binary is also a command-line tool:

```bash
M=/Applications/MacBridge.app/Contents/MacOS/macbridge
$M doctor             # permissions, bridge status, client setup, tool inventory
$M doctor --request   # the same, asking macOS for any permission not yet decided
$M tools              # list the tools
$M mcp                # what clients run: MCP over stdio, through the app
$M mcp --direct       # MCP with EventKit in this process, no app needed
$M --version
```

`mcp --direct` is a fallback for anyone who doesn't want the menu-bar app. It follows Read-only,
refuses deletes while Ask before deleting is on (it has nowhere to ask), and asks macOS for
permission itself. If that request can't show a prompt, the call gives up after a minute and says
to run `doctor --request` once.

`doctor` run from Terminal reports **Terminal's** permissions, not the app's: macOS attributes a
command-line tool's access to the app that launched it. The menu-bar panel shows what the app holds.

## Not yet done

- **Per-client consent.** Read-only and Ask before deleting apply to every client alike. Allowing or
  blocking one client, or limiting clients to some calendars and lists, isn't built yet.
- **First notarized release.** `make release` and `make publish` are ready, but haven't run yet: they
  need the Developer ID certificate and notary credentials set up.
- **Automatic updates.** **Check for Updates…** (right-click menu, or About) says whether a newer
  release is out and opens its page; installing it is still a download. MacBridge never checks on
  its own.
- **Connect for Cursor, Windsurf and VS Code.** One-click setup covers Claude Code and Claude
  Desktop; other clients take the command from **Manual setup**
  ([#2](https://github.com/todddube/macOSMCP/issues/2)).
- **Inviting people.** Attendees can be read but not added: EventKit has no way to send
  invitations.

## Feedback

Found a bug or have an idea? [Open an issue](https://github.com/todddube/macOSMCP/issues/new/choose).
The app links there too, from the menu-bar icon's right-click menu (**Report an Issue…** and
**Request a Feature…**) and from **About MacBridge**.

## Acknowledgements

MacBridge builds on these open-source packages, compiled into the binary:

| Package | Author | License |
|---|---|---|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Model Context Protocol project | MIT / Apache-2.0 |
| [EventSource](https://github.com/mattt/eventsource) | Mattt | MIT |
| [SwiftLog](https://github.com/apple/swift-log) | Apple Inc. | Apache-2.0 |
| [Swift System](https://github.com/apple/swift-system) | Apple Inc. | Apache-2.0 |

Their full license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also ships
inside the app. **About MacBridge** lists these credits, and its **Third-Party Licenses** button
opens that file. `macbridge --help` shows them too. Builds use
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT), which is a build tool only and is not
shipped in the app.

MacBridge is an independent project. It is not affiliated with or endorsed by Apple or Anthropic.
Claude, Claude Code and Claude Desktop are trademarks of Anthropic, PBC. Mac, macOS, Calendar and
Reminders are trademarks of Apple Inc.

## License

Copyright © 2026 Todd Dube. Released under the [MIT License](LICENSE): free to use, copy, modify
and distribute, with no warranty. Every source file carries the copyright notice in its header.

## Version history

**1.8.0** — Open-source release, one-click setup, and safer edits.
Released under the MIT License, with a copyright notice in every source file. Added
`THIRD_PARTY_NOTICES.md` with the full license text of every package compiled into the binary,
and bundled it and `LICENSE` into the app. The About window now shows the license, credits for
each package with links, and a **Third-Party Licenses** button. The right-click menu and the
About window link to GitHub issue forms for bug reports and feature requests. `macbridge --help` ends with the
same credits.

A download for people who won't build from source: `make release` produces a signed, notarized and
stapled DMG, and `make publish` uploads it as a draft GitHub release. The panel's **Connect** button
sets up Claude Desktop (merging its config file, with a backup) or Claude Code (`claude mcp add
--scope user`) in one click. The Claude Code command the app suggested used to lack
`--scope user`, so it registered MacBridge for one folder only. A copy launched from Downloads or
the disk image offers to move itself to Applications. The README starts with a four-step install.

The menu-bar bridge is now drawn live, with coloured cars, and the status dots say more by how
they move: green breathes while connected and flashes quickly while traffic is crossing, and stays
steady while a client is closed or not yet set up. Yellow or red flashes brightly with a glow only
for a real problem with Claude Code or Claude Desktop. The template menu-bar image assets are gone.

Removed the Apple Events entitlement and usage string, which were held in reserve for Mail and
Messages support that is no longer planned. MacBridge now asks for Calendar and Reminders access and
nothing else. Removed a calendar filter that matched "Scheduled Reminders" by its English title.
EventKit never returns that virtual calendar, so the filter did nothing, and it would have failed
on a non-English Mac anyway.

An **Open MacBridge at login** checkbox at the bottom of the panel registers the app as a login
item (`SMAppService`), so the bridge is ready after a restart. It reads its state back from macOS,
so turning it off in System Settings → Login Items unticks it too, and it's offered only for a copy
in Applications. The Xcode project is now checked in, with ad-hoc signing by default, so a fresh
clone builds in Xcode with no xcodegen and no certificate; `make signing` writes the local override.

Fixed **Grant** appearing to do nothing. After the prompt is allowed, EventKit in the running app
could keep reporting "not yet requested" though macOS had recorded the grant, so the panel kept its
Grant button and tool calls failed until a relaunch. The panel now trusts the request's own answer,
and each tool call asks again on its own store while EventKit still lags. The panel also re-reads
permissions each time it opens. `make signing` warns when the signing
identity changes, since macOS then asks for Calendar and Reminders again.

Edits to a repeating event now reach the occurrence you meant. Every occurrence shares one id, so
"cancel next Tuesday's standup" used to act on the series' first occurrence instead. Search now
returns an `occurrence_date` with each occurrence, the update, reschedule and cancel tools take it,
and a new `span: all_events` changes the whole series. A write to a repeating event without one is
refused rather than guessed. An occurrence moved on its own can still be found afterwards.

A write is no longer sent twice when the connection drops mid-call: if the app may already have
saved it, the model is told to check before retrying, instead of the shim resending it and making a
duplicate. Misspelt argument names are refused with a suggestion (`due_date` → `due`) instead of
being ignored, which had created undated reminders that reported success. Dates accept the shapes
models actually write (`T14:00`, `2026-10-18 9:00`, fractional seconds) and `+2h`, `+30min` and
`+1mo`; `+1m` is refused as ambiguous. A timed `start_date` in a calendar search is kept rather
than rounded to midnight, free-time search no longer offers slots that have already passed, and
output follows the Mac's time zone after travel. Moving a reminder's due date replaces only the
alarm at the old time, keeping location alarms and extra alerts.

**Connect** no longer loosens a private config file's permissions, keeps flags you added after
`mcp` (such as `--direct`), leaves alone other MacBridge entries you set up with flags of their
own, skips the write when the file is already correct, and saves the file as it was before each
change as `.macbridge-previous`. Event and reminder titles no longer go into the log file or the
unified log, failures are logged without the values involved, the log is readable by you only, and
**Copy Diagnostics** blanks titles left in logs by older versions. **Grant** no longer leaves a Dock
icon when pressed for both permissions at once, the panel stops claiming access after a
`tccutil reset`, a permission managed by your organization says so instead of offering Grant, and
write-only Calendar access can be upgraded from the panel. A not-found error now points at the tool
that finds the thing that's missing, a URL that isn't one is refused instead of dropped, switching
an event between all-day and timed no longer leaves odd times, and the default search window is
seven days, not eight. `macbridge --version` prints the version; an unknown `--flag` is an error
rather than a second copy of the app.

A **Safety** section in the panel. **Read-only** lets clients read your calendars and reminders but
refuses every change, telling the model why. **Ask before deleting**, on by default, holds a delete
or cancel until you allow it, in an alert that names the client and exactly what would go — the
event and which occurrences, the reminder, or the list and how many reminders are on it. Don't
Allow is the default button, and the alert declines by itself after a minute so a client is never
left waiting. `macbridge mcp --direct` follows Read-only too and, with no app to ask, refuses
deletes while Ask before deleting is on.

**Disconnect** next to a connected client removes MacBridge from its settings, the reverse of
Connect. `macbridge mcp` now answers the client at once and connects to the app in the background,
so a cold start (launching MacBridge first) no longer delays the client's startup, and an app that
can't be reached is reported on the first tool call instead of the server failing outright.
**Restart Bridge** now really ends open connections; before, a stuck one survived it. A call the
app doesn't answer within two minutes reports that plainly rather than as `errno 35`, and a shim
talking to an older running copy of the app says so in the client's log. The app refuses bridge
connections from other users and keeps its socket folder private on every start. A failed call in
**Recent Activity** shows why, with the whole message on hover.

Events in more detail. Search results say how an event repeats and how you replied to an
invitation; `event_id` returns one event in full, with attendees and their replies, alerts and
availability. Event updates can change alerts, availability (busy, free, tentative or away) and
how the event repeats, from one occurrence on or for the whole series; reminder updates can
change how a reminder repeats. A repeat change that would remove occurrences asks first, like a
delete, and changing a repeat keeps its days, so a Monday, Wednesday and Friday meeting stays one.
A requested alert no longer comes with Calendar's default alert as well, a repeat that ends on a
date now includes that date, and a repeating reminder without a due date is refused with the
reason rather than failing to save. Free-time search ignores birthdays and all-day events on
subscribed calendars, so a public holiday no longer blocks the whole day.

**Check for Updates…**, in the right-click menu and the About window, asks GitHub for the newest
release and offers its page; nothing is checked unless you ask. A permission request that macOS
never answers, as when `macbridge mcp --direct` can't show its prompt, now gives up after a minute
with a message saying what to do, instead of leaving the client waiting forever. VoiceOver reads
the panel's section titles as headings and its status dots and failed calls in words, not by
colour alone. CI builds and tests every push on GitHub, the MCP Swift SDK is pinned to 0.12.x so an
update can't change its API unannounced, and [BUILDING.md](BUILDING.md) collects everything
needed to build, test and release MacBridge yourself.

**0.7.0** — About window, right-click menu, client status dots, and traffic in the menu bar.
Two dots under the bridge glyph show Claude Code (left) and Claude Desktop (right):
green means connected and working, yellow means something needs a look (set up but not
connected, not set up, one permission missing, or the last call failed), and red means
calls can't succeed (the bridge is down, no permissions, or the config points at
another copy). The dots pulse slowly unless Reduce Motion is on. Hover over them, or
open the panel, to see the reason.

Right-click (or Control-click) the icon for a menu with each client's status, About,
diagnostics, restart and quit. The About window covers what MacBridge is for, the
author, and links to the GitHub profile and this repository. Tool calls now animate as
traffic across the bridge in the menu bar and the panel, and the separate activity
window from 0.6.0 is gone.

**0.6.0** — Calendar permissions, and an activity window.
Calendar access could never be granted: clicking Grant did nothing, with no prompt, no
error and nothing in the logs. `tccd` gave the reason — under the hardened runtime,
`kTCCServiceCalendar` requires the `com.apple.security.personal-information.calendars`
entitlement, which had been omitted on the incorrect assumption that it was sandbox-only.
Without it TCC sets `promptPolicy = 0`, meaning it will never prompt. Reminders was
unaffected only because it had been granted before the hardened runtime was enabled.

Recent Activity moved out of the menu-bar panel into a floating window that dismisses on
focus loss, with filters for failures and connections. Calls now carry a result summary
and a duration, writes and destructive calls are marked, and repeats collapse. Debug
builds use their own bundle identifier, so DerivedData copies can no longer collide with
the installed app in Launch Services or TCC.

**0.5.0** — Icons.
An app icon (Mac mini beneath a suspension bridge, full colour) and a matching menu-bar template
glyph with a broken-span alert variant, both generated by `Tools/generate-icons.swift`. Replaces the
SF Symbol in the menu bar and the generic placeholder in Finder.

**0.4.0** — Signing, entitlements, and fixes found by reading the logs.
Deleted the archived Python implementation. Added a file header to every Swift source.
`App/MacBridge.entitlements` had been generated empty by xcodegen and shipped that way, so the app
carried no entitlements at all. Declared them in `project.yml` (sandbox off, Apple Events on), added
`NSAppleEventsUsageDescription` — without which macOS denies the request with no prompt — stripped
`get-task-allow` from Release builds, and added `make notarize` with its prerequisites checked up
front. Deleted the archived `uv.lock`, the sole source of a dozen Dependabot alerts, and began
tracking `Package.resolved` so the dependency graph covers the Swift packages the app actually links.

The Claude Desktop log then showed `Server disconnected` after every install: `make stop`'s `pkill`
pattern was unanchored, so it matched `…/macbridge mcp` and killed every connected client's shim, not
just the app. Anchored it. Also made the reconnect wait properly for the app to relaunch instead of
making one attempt after 750ms, swept stale socket files that a killed instance leaves behind
(including the orphaned pre-per-bundle `bridge.sock`), and fixed client identification: the server
can only see the socket's peer — which is our own shim — so the shim now reports the client's
executable, and versioned interpreters like `python3.13` are walked past rather than reported as the
client.

**0.3.0** — Diagnosis and recovery.
Two copies of the app shared one socket path, and because a DerivedData build and `/Applications`
have different TCC identities, whichever grabbed the socket first served every client — including
when it held no permissions. Sockets are now derived per bundle. Added logging to
`~/Library/Logs/MacBridge/` and `os_log`, Restart Bridge and Relaunch App, Open Log and Copy
Diagnostics, shim reconnection so a restart no longer strands clients, a warning when the running
copy is not the configured one, process-tree client naming, and signing via a generated
`Signing.xcconfig` so permission grants survive rebuilds.

**0.2.0** — The app.
Menu-bar app owning EventKit and the bridge, with the CLI reduced to a shim. One binary serves as
both, because a case-insensitive filesystem cannot hold `MacBridge` and `macbridge` in the same
directory. Added the Xcode project generated from `project.yml`, a native test target for ⌘U, and
client-setup detection.

**0.1.0** — The tools.
18 MCP tools over Calendar and Reminders through EventKit, replacing a Python `fastmcp` server whose
Reminders support was read-only. Consolidated five narrow read tools per domain into one
parameterised search.
