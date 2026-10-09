# MacBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-6-orange.svg)

**v0.7.0** — a free, open-source macOS **menu-bar app and MCP server** that gives Claude Code and Claude Desktop read
and write access to your **Calendar** and **Reminders**, through EventKit, entirely on your Mac.

Swift package + Xcode app. No Python, no Node, no network. Requires macOS 13+.
Free to use, modify and share under the [MIT License](LICENSE).

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

Dates accept `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, full ISO-8601, or relative values — `today`,
`tomorrow`, `now`, `+7d`, `-3d`, `+2w`. Output is always one canonical form, so a client never has
to guess. Times are in the Mac's local time zone.

`calendar_find_available_times` exists so a model proposing a meeting slot does not have to read
events and reason about the gaps itself. Events marked *free* and cancelled events do not block;
all-day events block their whole span.

## Install

Requires **macOS 13+**, **Xcode 16+** (for the app bundle and the tests), and
[xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.

```bash
make install     # build Release, install to /Applications, launch
```

Then click the menu-bar icon and **Grant** Calendar and Reminders access.

TCC ties a permission grant to the app's identity *and* its location, so keep the app at
`/Applications/MacBridge.app` — `make install` always puts it there.

`make install` signs with whatever certificate it finds and tells you which you got. With an Apple
Development or Developer ID certificate the grant **persists across rebuilds**; with no certificate
it falls back to ad-hoc and you re-grant after every install. See
[Permissions and rebuilds](#permissions-and-rebuilds).

## First run

MacBridge does nothing on its own — a client has to be told to run `macbridge mcp`. The menu-bar
panel states where you are:

```
  ● MacBridge 0.4.0                          18 tools
    Listening — 12 calls, 1 failed

  PERMISSIONS
    ✓ Calendars   granted
    ! Reminders   not yet requested          [Grant…]

  CLIENT SETUP                               Re-check
    ✓ Claude Code       connected to this app
    ○ Claude Desktop    not set up
        Add this to its config, then restart it:
        [Copy JSON]  [Reveal config]

  CONNECTED CLIENTS                                 1
    ● Claude Code                              pid 49823

  RECENT ACTIVITY                                Clear
    14:02:11  reminders_search_reminders    Claude Code
    14:01:58  calendar_search_events        Claude Code
    14:01:40  — connected —                 Claude Code

  DIAGNOSTICS
    [Open Log]  [Copy Diagnostics]  [Refresh]
    [Restart Bridge]  [Relaunch App]
```

If another copy of MacBridge is the one your clients point at, a warning appears at the top with its
path — the failure that is otherwise invisible.

It reads both clients' config files and compares the command they name against this app's own
binary — so a config left over from a `DerivedData` build shows as **wrong path** rather than
looking fine and failing later. `macbridge doctor` prints the same information.

If the `claude` CLI is not found, the panel offers the JSON route instead of showing you a command
that will not run.

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

### Permissions and rebuilds

TCC keys a permission grant to the app's **code signature**, so how the app is signed decides
whether grants survive a rebuild.

`make project` runs `make signing`, which looks for a signing identity and writes a gitignored,
machine-local `Signing.xcconfig`:

| Identity found | Effect |
|---|---|
| Developer ID or Apple Development | Designated requirement is *bundle ID + certificate*. **Grants persist across rebuilds.** |
| None | Ad-hoc. The signature's own hash is its identity, and it changes every build, so **macOS revokes Calendar and Reminders on each install** and you re-grant from the panel. |

`make install` reports which of the two you got.

The certificate is referenced by SHA-1 hash rather than name, deliberately: Xcode's manual signing
resolves the name `"Apple Development"` to a *Mac* Development certificate and fails with
*"No Account for Team …"* when no Xcode account matches the team — even though the certificate and
its private key are right there in the keychain. The hash is used directly and sidesteps that.

Verified rather than assumed — rebuilding and reinstalling changes the code hash but not the
requirement:

```
cdhash changed:      YES
requirement changed: no      ← what TCC matches
designated => identifier "com.thedubes.macbridge" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

Note that the in-tool permission request cannot reliably raise a prompt from a menu-bar-only app.
Use the **Grant…** buttons in the panel, which ask from a real user action.

### Icons

The artwork is **code**, not checked-in binaries. `Tools/generate-icons.swift` draws the app icon
with CoreGraphics into `App/Assets.xcassets` (re-run with `make icons` after editing it), and
`BridgeRenderer` in `App/BridgeTraffic.swift` draws the menu-bar icon live.

- **App icon** — a Mac mini under a suspension bridge: the machine on one side, the assistant on
  the other, MacBridge as the span. Composed to survive 16px, where it reduces to a blue tile, a
  pale slab and a bright arc; the hangers, port and power LED appear only at 128px and up.
- **Menu bar** — the same span in colour: orange towers and cables over a road that follows the
  menu bar's light or dark text colour. Calls drive across it as coloured cars. A break in the
  deck shows missing permissions or a stopped bridge without opening the panel. Two dots underneath
  show Claude Code (left) and Claude Desktop (right). Green breathes slowly while idle and flashes
  quickly while traffic flows. Yellow (needs a look) and red (calls can't succeed) flash brightly
  with a glow. Under Reduce Motion the dots hold still.

Generated rather than drawn in a design tool so the art is reviewable in a diff, reproducible, and
tweakable without leaving the repo — the machine has no SVG converter and this needs none.

### Signing, entitlements and distribution

| Setting | Value | Why |
|---|---|---|
| `com.apple.security.personal-information.calendars` / `.reminders` | true | **Required under the hardened runtime.** Without them TCC sets `promptPolicy = 0` and silently refuses to ever show a permission prompt. |
| Hardened runtime | on | Required for notarization. |
| Sandbox | **off** | EventKit would survive a sandbox, but the bridge socket lives at a fixed Application Support path rather than in a container, so a shim spawned by any client can find it. |
| `get-task-allow` | stripped in Release | Xcode injects it when signing with a development identity; notarization rejects it. |
| Usage strings | Calendars, Reminders | TCC will not prompt at all without one — a missing string denies silently. |

Entitlements are **generated** from `project.yml` into `App/MacBridge.entitlements`, the same as
Info.plist. Editing that file by hand does nothing; `make project` overwrites it. (It shipped as an
empty `<dict/>` for several commits precisely because the properties were not declared here.)

**To distribute to another Mac** you need a *Developer ID Application* certificate, which an Apple
Development certificate cannot substitute for:

1. Xcode → Settings → Accounts → sign in, select the team → **Manage Certificates → +** →
   Developer ID Application. Needs the Account Holder or Admin role.
2. `xcrun notarytool store-credentials macbridge-notary --apple-id <id> --team-id <TEAMID>
   --password <app-specific-password>`
3. `make signing` picks the new certificate up automatically — it prefers Developer ID over Apple
   Development — then `make notarize` builds, submits, staples and verifies with `spctl`.

`make notarize` checks both prerequisites up front and tells you which is missing rather than
failing somewhere inside `notarytool`.

## Connect a client

**Claude Code**

```bash
claude mcp add macbridge -- /Applications/MacBridge.app/Contents/MacOS/macbridge mcp
```

**Claude Desktop** — in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{ "mcpServers": { "macbridge": {
    "command": "/Applications/MacBridge.app/Contents/MacOS/macbridge", "args": ["mcp"] } } }
```

The menu-bar panel copies either form to the clipboard. This repo's `.mcp.json` already points at
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

## Commands

```bash
make help       # every target
make build      # SwiftPM: MacBridgeKit + the macbridge CLI
make test       # 79 tests, 11 suites; needs no permissions, touches no user data
make app        # build MacBridge.app
make install    # build Release, install to /Applications, launch
make project    # regenerate MacBridge.xcodeproj from project.yml
make signing    # re-detect the signing identity
make icons      # redraw the app and menu-bar icons
make doctor     # permissions, bridge status, tool inventory
make tools      # list the tools
make verify     # live write round-trip on a disposable list, then deletes it
make notarize   # notarize and staple for distribution (needs a Developer ID)
make clean      # remove build directories
```

`make verify` runs the live suites, which create a scratch Reminders list, exercise every write
path against it and delete it again. They need real permission, and each domain is gated
independently — if Calendar is not granted, the Calendar suite *skips* rather than fails.
`make test` leaves them off entirely.

`macbridge mcp --direct` skips the app and runs EventKit in the CLI process: a fallback for anyone
who does not want the menu-bar app.

Note that `macbridge doctor` run from a terminal reports **the terminal's** permissions, not the
app's, because macOS attributes a CLI process's TCC to its responsible parent. The menu-bar panel
is the accurate view of what the app itself holds.

## Layout

```
project.yml              Xcode project spec — targets, build settings, Info.plist
Package.swift            SwiftPM: the kit, the CLI, the tests
App/                     the menu-bar app (Xcode target only)
  main.swift             entry point: GUI or CLI, decided by the arguments
  MacBridgeApp.swift     MenuBarExtra scene and app delegate
  AppModel.swift         bridge lifecycle, permissions, clipboard helpers
  MenuContent.swift      the panel: status, permissions, clients, activity
  ActivityLog.swift      bounded in-memory log, never written to disk
  StatusItemController.swift  right-click menu and client status dots
  BridgeTraffic.swift    traffic animation on the bridge glyph
  AboutWindow.swift      About window: author, license, third-party credits
Sources/
  MacBridgeKit/          all logic; no AppKit, so it stays terminal-testable
    Calendar/            CalendarService (actor), FreeBusy, Recurrence, mapping
    Reminders/           RemindersService (actor), mapping
    EventKit/            authorization, calendar and list resolution
    IPC/                 bridge protocol, framing, socket server and client
    Setup/               client config detection and process-tree client naming
    Tools/               tool definitions, JSON schemas, ToolRegistry
    Support/             dates, argument coercion, errors, logging, credits
  macbridge/             CLI subcommands, shared by both entry points
Tools/
  generate-icons.swift   draws the icons into App/Assets.xcassets
Tests/MacBridgeKitTests/ swift-testing suites, including the opt-in live ones
LICENSE                  MIT, bundled into the app
THIRD_PARTY_NOTICES.md   credits and full license texts, bundled into the app
```

Both services are actors because `EKEventStore` is neither thread-safe nor `Sendable`. No EventKit
object escapes them — everything is mapped to a `Value` before returning — which is the whole
safety argument.

`ToolRegistry` holds a name → handler table rather than a switch, so the advertised inventory and
the routable set can be compared directly. A tool that is advertised but never wired up fails a
test instead of failing the first time a model calls it.

## Building

`MacBridge.xcodeproj` is **generated** from `project.yml` by `make project`, and is gitignored — a
`.pbxproj` reviews badly and merges worse. `project.yml` is the source of truth for targets, build
settings *and* the Info.plist, so **`App/Info.plist` is generated too**; editing it by hand
accomplishes nothing. `Signing.xcconfig` is generated as well, and is machine-local because a
certificate hash is not portable.

### Working in Xcode

⌘B and ⌘R run a post-action that installs the build to `/Applications`, so the copy your clients are
configured for is always current. It deliberately does **not** launch it — Xcode launches the debug
build with the debugger attached, and a shim auto-launches the installed copy when a client next
connects. Because each bundle has its own socket, both can run at once without interfering.

Do not point a client at a DerivedData path: TCC grants attach to it, the hash changes on every
clean build, and Xcode may delete the directory.

```bash
make project && open MacBridge.xcodeproj
```

Two targets, and the usual shortcuts all work:

| | |
|---|---|
| **⌘B** | builds `MacBridge.app` — app and CLI in one binary |
| **⌘R** | runs it; it appears in the menu bar, not the Dock (`LSUIElement`) |
| **⌘U** | runs all 79 tests in the `MacBridgeTests` bundle, listed in the Test navigator |

`MacBridgeTests` is a native Xcode test bundle compiled from the same
`Tests/MacBridgeKitTests` sources that `swift test` uses — one set of tests, two runners, so a
failure in Xcode is a failure in CI.

The live suites are off by default. To run them from Xcode, tick `MACBRIDGE_LIVE` in
**Product → Scheme → Edit Scheme → Test → Arguments → Environment Variables**; it is pre-added and
unchecked. From the terminal, `make verify` does the same thing.

To work on just the kit, the CLI and the tests without the app, open `Package.swift` directly.

Builds go to `/private/tmp`, not `.build/`. This checkout sits under an iCloud-synced
`~/Documents`, which stamps `com.apple.FinderInfo` on build output; codesign then rejects the
bundle with *"resource fork, Finder information, or similar detritus not allowed"*. Override with
`make build SCRATCH=...` if your clone is somewhere unsynced.

Tests need Xcode's toolchain rather than Command Line Tools: swift-testing's macro plugin and
`Testing.framework` ship only with Xcode. The Makefile finds it automatically, preferring a release
Xcode over a beta.

## Not yet done

- **Per-client consent.** `BridgeServer` already takes an `Authorizer` that currently allows
  everything, and the identity handed to it carries a kernel-verified pid rather than the
  self-reported name. The remaining work is a persisted store, the allow/deny UI on each client
  row, and a confirmation sheet for the three destructive tools.
- **Writing client configs** from the app, instead of copying them to the clipboard.
- **Notarization.** `make notarize` is written and checks its prerequisites, but has not been run:
  it needs a Developer ID Application certificate, which an Apple Development certificate cannot
  substitute for.

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

**Unreleased** — Open-source release preparation.
Released under the MIT License, with a copyright notice in every source file. Added
`THIRD_PARTY_NOTICES.md` with the full license text of every package compiled into the binary,
and bundled it and `LICENSE` into the app. The About window now shows the license, credits for
each package with links, and a **Third-Party Licenses** button. The right-click menu and the
About window link to GitHub issue forms for bug reports and feature requests. `macbridge --help` ends with the
same credits.

The menu-bar bridge is now drawn in colour, and the status dots say more by how they move: green
breathes while idle and flashes quickly while traffic is crossing, and yellow or red flashes
brightly with a glow when Claude Code or Claude Desktop has a problem. The template menu-bar image
assets are gone, since the icon is drawn live.

Removed the Apple Events entitlement and usage string, which were held in reserve for Mail and
Messages support that is no longer planned. MacBridge now asks for Calendar and Reminders access and
nothing else. Removed a calendar filter that matched "Scheduled Reminders" by its English title.
EventKit never returns that virtual calendar, so the filter did nothing, and it would have failed
on a non-English Mac anyway.


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
