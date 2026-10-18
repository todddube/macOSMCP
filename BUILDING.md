# Building MacBridge

Everything you need to build, test, change and release MacBridge yourself. If you only want to
use it, [download a release](README.md#install) instead; nothing here is needed for that.

- [What you need](#what-you-need)
- [Quick start](#quick-start)
- [Two build systems](#two-build-systems)
- [Make targets](#make-targets)
- [Tests](#tests)
- [Working in Xcode](#working-in-xcode)
- [The project file is generated](#the-project-file-is-generated)
- [Signing and permissions across rebuilds](#signing-and-permissions-across-rebuilds)
- [Dependencies](#dependencies)
- [Continuous integration](#continuous-integration)
- [Icons](#icons)
- [Making a release](#making-a-release)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)

## What you need

| | Needed for | Notes |
|---|---|---|
| **macOS 13 or later** | everything | The app's minimum too. |
| **Xcode 16.3 or later** | the app, the tests | Command Line Tools alone aren't enough: swift-testing and `xcodebuild` ship only with Xcode. The MCP Swift SDK needs Swift 6.1, which arrived in Xcode 16.3. CI builds on macOS 15 with its default Xcode. A beta Xcode works; a release one is preferred when both are installed. |
| An Apple Development certificate | permissions that survive rebuilds | Optional. Free with an Apple ID in Xcode → Settings → Accounts. Without one the app is signed ad-hoc and you grant Calendar and Reminders again after each install. See [Signing](#signing-and-permissions-across-rebuilds). |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | editing `project.yml` | Optional: `brew install xcodegen`. The generated Xcode project is checked in. |
| A Developer ID certificate and notary credentials | a release for other Macs | Paid Apple Developer Program. See [Making a release](#making-a-release). |

No Python, Node or other runtime. The one package dependency, the
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), is fetched on first build.

## Quick start

```bash
git clone https://github.com/todddube/macOSMCP.git
cd macOSMCP
make install      # test-free Release build, installed to /Applications and launched
make test         # the unit tests; no permissions needed, touches no data
```

Then click the bridge icon in the menu bar, **Grant** Calendar and Reminders, and **Connect** a
client. Or, in Xcode: open `MacBridge.xcodeproj`, pick the **MacBridge** scheme and press **⌘B**.

`make install` says which signature it used. *"signed ad-hoc"* means no certificate was found:
everything works, but macOS forgets the Calendar and Reminders grants on every install.

## Two build systems

On purpose, each for what it does well:

| | Builds | Used by |
|---|---|---|
| **SwiftPM** (`Package.swift`) | MacBridgeKit, the `macbridge` CLI, the tests | `make build`, `make test`, `make verify`, CI |
| **Xcode** (`MacBridge.xcodeproj`, from `project.yml`) | `MacBridge.app`: bundle, Info.plist, entitlements, signing | `make app`, `make install`, ⌘B |

SwiftPM can't make an app bundle or sign one; Xcode is slow and awkward from a terminal. All the
logic lives in MacBridgeKit, which both build, so they can't drift apart. MacBridgeKit never
imports AppKit or SwiftUI, which keeps it testable from the terminal.

The app and the CLI are **one binary**, `MacBridge.app/Contents/MacOS/macbridge`. With no
arguments it runs the menu-bar app; `macbridge mcp`, `doctor` and the rest are the CLI. See
[One binary, two faces](README.md#one-binary-two-faces) for why.

Builds go to `/private/tmp/macbridge-build` (SwiftPM) and `/private/tmp/macbridge-dd` (Xcode), not
`.build/`. A clone under an iCloud-synced folder such as `~/Documents` gets `com.apple.FinderInfo`
stamped on its build output, and codesign then refuses the bundle. Override with
`make build SCRATCH=…` and `make app DERIVED=…` if you'd rather.

## Make targets

```bash
make help       # every target, and which Xcode was found
make build      # SwiftPM: MacBridgeKit + the macbridge CLI
make test       # unit tests; no permissions, no user data
make verify     # the live tests too: real writes on a scratch list, deleted afterwards
make app        # build MacBridge.app (Release; CONFIG=Debug for a debug build)
make install    # build, install to /Applications, launch
make run        # launch the installed app
make stop       # quit it (leaves connected clients' shims alone)
make project    # regenerate MacBridge.xcodeproj from project.yml
make signing    # re-detect the signing certificate
make icons      # redraw the app icon
make doctor     # permissions, bridge status, client setup, tool inventory
make tools      # list the tools
make release    # signed, notarized, stapled DMG (needs a Developer ID)
make publish    # upload that DMG as a draft GitHub release (needs gh)
make clean      # remove the build directories
```

## Tests

```bash
make test       # about 160 tests in swift-testing
make verify     # the same plus the live suites
```

`make test` needs no permissions and touches no data: EventKit objects are built in memory, and
the bridge tests use a private socket in a temporary folder.

`make verify` sets `MACBRIDGE_LIVE=1`, which turns on the live suites. They create a scratch
Reminders list, exercise every write against it and delete it again, and do the same with a
scratch event. Each domain is checked separately. A domain that isn't granted *skips* rather than
fails, so a terminal without Calendar access still runs the Reminders suite.

Those permissions belong to **the terminal**, not to the app. macOS attributes a CLI's Calendar and
Reminders access to the app that launched it, so `make verify` and `macbridge doctor` run from
Terminal report Terminal's access. The menu-bar panel shows what the app itself holds.

A few rules the suites enforce, so a change that breaks them fails a test, not a user:

- Every advertised tool has a handler, and every handler is advertised.
- The version in `MacBridge.swift` matches `MARKETING_VERSION` in `project.yml`.
- The MCP SDK pin in `Package.swift` matches the one in `project.yml`.
- Every argument name a tool accepts is in its schema, or in a short, tested list of aliases.

## Working in Xcode

```bash
open MacBridge.xcodeproj          # or: make project && open MacBridge.xcodeproj
```

| | |
|---|---|
| **⌘B** | builds `MacBridge.app`, app and CLI in one binary |
| **⌘R** | runs it; it appears in the menu bar, not the Dock (`LSUIElement`) |
| **⌘U** | runs the tests in the `MacBridgeTests` bundle |

⌘B and ⌘R run a post-action that installs the build to `/Applications`, so the copy your clients
point at is always current. It doesn't launch that copy: Xcode runs the debug build under the
debugger, and the installed one starts when a client next needs it. Each bundle listens on its own
socket, so both can run at once (see [Two copies, two sockets](README.md#two-copies-two-sockets)).
Debug builds also use their own bundle identifier, `com.thedubes.macbridge.debug`.

Don't point a client at a DerivedData path. macOS ties permission grants to the app's location,
the path changes on a clean build, and Xcode may delete it.

`MacBridgeTests` is compiled from the same `Tests/MacBridgeKitTests` sources as `swift test`: one
set of tests, two runners. To run the live suites from Xcode, tick `MACBRIDGE_LIVE` in **Product →
Scheme → Edit Scheme → Test → Arguments → Environment Variables**; it is there, unticked.

To work on just the kit, the CLI and the tests, open `Package.swift` instead.

## The project file is generated

`project.yml` is the source of truth for targets, build settings, the Info.plist and the
entitlements. `make project` turns it into `MacBridge.xcodeproj`, `App/Info.plist` and
`App/MacBridge.entitlements`, and all three are checked in so a fresh clone builds without
xcodegen.

Editing any of them by hand does nothing lasting: the next `make project` overwrites it. Change
`project.yml`, run `make project`, and commit the regenerated files with it. CI warns when the
committed project doesn't match what `project.yml` generates.

Adding a source file under `App/` or `Tests/` also needs `make project`, so the Xcode targets pick it
up. SwiftPM finds new files by itself.

xcodegen sometimes reorders a dictionary in `MacBridge.xcodeproj/xcshareddata/xcschemes/MacBridge.xcscheme`
without changing anything. Discard that with `git checkout` rather than committing it.

## Signing and permissions across rebuilds

macOS ties a Calendar or Reminders grant to the app's **code signature** and its **location**. So
keep the app at `/Applications/MacBridge.app`, which `make install` always does, and sign it with a
certificate if you rebuild often.

The checked-in `Config/Signing.xcconfig` signs **ad-hoc**, so a fresh clone builds with no
certificate or Apple account. `make signing`, which `make app` and `make project` run first, looks
for a certificate and writes the gitignored, machine-local `Config/Signing.local.xcconfig`, which
overrides the default:

| Certificate found | Result |
|---|---|
| Developer ID Application (preferred), or Apple Development | The signature's identity is *bundle ID + certificate*. **Grants survive rebuilds.** |
| None | Ad-hoc. The identity is the build's own hash, which changes every build, so **macOS revokes Calendar and Reminders on each install** and you grant them again from the panel. |

`make signing` warns when the certificate changes, since macOS then asks for both permissions once
more.

The certificate is referenced by its SHA-1 hash rather than its name. Xcode's manual signing
resolves the name `"Apple Development"` to a *Mac* Development certificate, and fails with
*"No Account for Team …"* when no Xcode account matches the team, even with the certificate and key
in the keychain. The hash sidesteps that.

Verified, not assumed: rebuilding with a certificate changes the code hash but not the
requirement macOS matches grants against.

```
cdhash changed:      YES
requirement changed: no      ← what macOS matches grants against
designated => identifier "com.thedubes.macbridge" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

The entitlements, and why:

| Setting | Value | Why |
|---|---|---|
| `com.apple.security.personal-information.calendars` / `.reminders` | true | Required under the hardened runtime. Without them macOS never shows a permission prompt, and says nothing. |
| Hardened runtime | on | Required for notarization. |
| App Sandbox | off | The bridge socket lives at a fixed Application Support path, so a shim started by any client can find it. |
| `get-task-allow` | stripped in Release | Xcode adds it when signing for development; notarization rejects it. |
| Usage strings | Calendars, Reminders | Without one, macOS denies access without prompting. |

## Dependencies

| Package | Pin | Where |
|---|---|---|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | `0.12.x` | `Package.swift` (`.upToNextMinor`) and `project.yml` (`minorVersion`) |

The SDK's own dependencies (EventSource, SwiftLog, Swift System, and others) come with it. Exact
versions of everything are locked in `Package.resolved`, which is committed.

The SDK is pre-1.0, where a minor release may change its API, so it is pinned to one minor version
rather than taking any `0.x`. To move to a newer one:

1. Change the version in **both** `Package.swift` and `project.yml`; a test fails if they differ.
2. `swift package update`, then `make project`.
3. `make test` and `make verify`, then try a real client.
4. Update the version and license texts in `THIRD_PARTY_NOTICES.md`, and the credits in
   `Sources/MacBridgeKit/Support/Credits.swift` if the package list changed.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request, on a GitHub macOS 15
runner with no secrets:

1. `make build` and `make test`.
2. Regenerates the Xcode project and warns if it differs from the committed one.
3. `make app`, signed ad-hoc, then checks that the built binary prints its version and lists 18
   tools.

`make verify` doesn't run in CI: a runner can't grant Calendar or Reminders access. Run it locally
before a release.

## Icons

The artwork is code, not checked-in images. `Tools/generate-icons.swift` draws the app icon with
CoreGraphics into `App/Assets.xcassets`; edit it and run `make icons`. `BridgeRenderer` in
`App/BridgeTraffic.swift` draws the menu-bar icon live, including the traffic animation.

- **App icon:** a Mac mini under a suspension bridge: the machine on one side, the assistant on
  the other, MacBridge as the span. At 16px it reduces to a blue tile, a pale slab and a bright
  arc; the hangers, port and power light appear from 128px up.
- **Menu bar:** the same span in the menu bar's text colour, with calls crossing as coloured cars.
  A break in the deck means missing permissions or a stopped bridge. The two dots underneath are
  Claude Code (left) and Claude Desktop (right). Under Reduce Motion nothing animates.

Drawn in code so the art can be reviewed in a diff and regenerated, with nothing to install.

## Making a release

A release for other Macs needs the paid Apple Developer Program and a *Developer ID Application*
certificate; an Apple Development certificate can't stand in for it.

1. Xcode → Settings → Accounts → sign in, select the team → **Manage Certificates → +** →
   Developer ID Application. Needs the Account Holder or Admin role.
2. Store notary credentials once:
   `xcrun notarytool store-credentials macbridge-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`
3. Bump the version in `Sources/MacBridgeKit/MacBridge.swift` and in `project.yml`
   (`MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` by one), then `make project`. Add a paragraph
   to the README's version history.
4. `make release`: runs the tests, builds with the Developer ID certificate, packs
   `MacBridge-<version>.dmg` with an Applications shortcut, signs it, notarizes it, staples the
   ticket and checks it the way Gatekeeper will. It checks the certificate and the credentials
   first and says which is missing.
5. `make publish`: uploads the DMG and its SHA-256 as a **draft** GitHub release tagged
   `v<version>`, so you can review the notes before publishing it. Once published, **Check for
   Updates…** in the app offers it to everyone on an older version.

Moving from an Apple Development to a Developer ID signature changes the app's identity, so grant
Calendar and Reminders once more after the first such install.

## Project layout

```
project.yml              Xcode project spec: targets, build settings, Info.plist, entitlements
MacBridge.xcodeproj/     generated from project.yml; checked in
Config/Signing.xcconfig  ad-hoc signing default; includes the local Signing.local.xcconfig
Package.swift            SwiftPM: the kit, the CLI, the tests
Makefile                 every build, test and release step
App/                     the menu-bar app (Xcode target only)
  main.swift             entry point: app or CLI, decided by the arguments
  MacBridgeApp.swift     the MenuBarExtra scene and app delegate
  AppModel.swift         bridge lifecycle, permissions, access policy, client setup
  MenuContent.swift      the panel: status, permissions, safety, clients, activity
  ConfirmationPrompt.swift  the alert before a delete or a repeat change
  ActivityLog.swift      recent calls, in memory only
  StatusItemController.swift  right-click menu and client status dots
  BridgeTraffic.swift    the live bridge drawing and traffic animation
  AboutWindow.swift      About: author, license, third-party credits
  UpdatePrompt.swift     Check for Updates…
  InstallLocation.swift  offers to move a downloaded copy into /Applications
  LaunchAtLogin.swift    "Open MacBridge at login", via SMAppService
Sources/
  MacBridgeKit/          all the logic; no AppKit or SwiftUI
    Calendar/            CalendarService (actor), free-time search, repeat rules, mapping
    Reminders/           RemindersService (actor), mapping
    EventKit/            permissions, calendar and list lookup
    IPC/                 the bridge: protocol, framing, socket server and client
    Policy/              Read-only and Ask before deleting
    Setup/               client config detection, Connect and Disconnect, client naming
    Tools/               tool definitions, JSON schemas, ToolRegistry
    Support/             dates, arguments, errors, logging, credits, update check
  macbridge/             the CLI: mcp, doctor, tools, and the direct and bridged backends
Tests/MacBridgeKitTests/ swift-testing suites, including the opt-in live ones
Tools/generate-icons.swift  draws the app icon
.github/                 CI workflow and issue forms
LICENSE                  MIT, bundled into the app
THIRD_PARTY_NOTICES.md   credits and full license texts, bundled into the app
```

Both services are actors because `EKEventStore` is neither thread-safe nor `Sendable`. No EventKit
object leaves them: everything is turned into a plain `Value` first. That is the whole
thread-safety argument, and why the code builds in Swift 5 language mode rather than fighting
strict concurrency checks over EventKit's unannotated types.

`ToolRegistry` maps names to handlers in a table rather than a `switch`, so the advertised tools and
the callable ones can be compared directly. A tool advertised but never wired up fails a test
instead of failing the first time a model calls it.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Xcode is required for tests` | Only Command Line Tools are installed. Install Xcode; the Makefile finds it in `/Applications`. |
| codesign: *"resource fork, Finder information, or similar detritus not allowed"* | Build output landed in an iCloud-synced folder. Leave `SCRATCH` and `DERIVED` at their `/private/tmp` defaults. |
| Calendar and Reminders need granting after every install | Signed ad-hoc. Add an Apple Development certificate in Xcode, then `make install`. |
| The panel says granted, but tool calls fail with "not yet requested" | Clients reach a different copy of the app. The panel warns about this; `macbridge doctor` shows which copy each client points at. Use **Connect** to fix the path. |
| `macbridge mcp --direct` reports that macOS asked for permission and had no answer | The direct mode's own permission prompt couldn't appear. Run `macbridge doctor --request` in Terminal once and answer it there, or use the app (`macbridge mcp`). |
| `MacBridge 2.xcodeproj` appeared | Xcode had the project open while it was regenerated. Delete the copy; it's gitignored. |
| A newly added file isn't in the Xcode build | Run `make project`. |
