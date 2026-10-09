# MacBridge Swift Standards (project)

These rules apply on top of the global baseline in `~/.claude/swift-standards.md`.
Where the two disagree, this file wins. The `swift-code-reviewer` agent keeps the
"Platform baseline" current.

Last verified: 2026-10-05

## Platform baseline

| Item | Value | Where it is set |
|---|---|---|
| Toolchain | Apple Swift 6.4 (Xcode) | `xcrun swift --version` |
| Tools version | 6.0 | `Package.swift` line 1 |
| Language mode | Swift 5 (deliberate) | `swiftLanguageMode(.v5)` in `Package.swift`, `project.yml` |
| Deployment target | macOS 13 | `Package.swift` `platforms` |
| Tests | swift-testing only | `Tests/`; `make test` (needs Xcode) |
| UI | SwiftUI `MenuBarExtra` + AppKit | `App/` |
| Dependencies | `modelcontextprotocol/swift-sdk` (`MCP`) only | `Package.swift` |
| License | MIT, © 2026 Todd Dube | `LICENSE`, `THIRD_PARTY_NOTICES.md`, `Credits.swift` |

**Deliberate decisions. Do not flag these:**
- **Swift 5 language mode.** EventKit has no Sendable annotations, and non-Sendable
  EventKit objects never leave the services.
- `unsafeFlags` in `Package.swift`. It embeds the Info.plist so TCC shows a prompt.
- The Xcode project is generated from `project.yml`, and icons are drawn by
  `Tools/generate-icons.swift`.

## Header target labels

Project name: `MacBridge`.

| Path | Line 3 of header |
|---|---|
| `Sources/MacBridgeKit/**` | `MacBridgeKit · MacBridge` |
| `Sources/macbridge/**` | `macbridge · MacBridge` |
| `App/**` | `MacBridge (app) · MacBridge` |
| `Tests/MacBridgeKitTests/**` | `MacBridgeKitTests · MacBridge` |
| `Tools/**` | `Tools · MacBridge` |

Every header also ends with the copyright line, after the summary (MacBridge is
public under MIT, so each file carries its notice):

```swift
//
//  FileName.swift
//  MacBridgeKit · MacBridge
//
//  One-line role of the file, ending with a period.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//
```

Keep the year as the year of first publication; don't bump it per edit.

## Project rules

- `MacBridgeKit` must not import AppKit or SwiftUI. It is terminal-testable
  (`Reveal.swift` shows how to open URLs without linking AppKit).
- **EventKit:** check authorization before every store access. Use the macOS 14+
  full-access APIs behind `#available`, with a macOS 13 fallback. Commit saves, and
  choose `.thisEvent` vs `.futureEvents` on purpose.
- **TCC:** a new protected resource needs its usage key in both
  `Sources/macbridge/Info.plist` and the app plist defined in `project.yml`.
- Errors that reach MCP clients go through `MacBridgeError`, with a message a model can act on.
- **Credits:** adding, removing or swapping a package dependency means updating
  `Credits.components` and `THIRD_PARTY_NOTICES.md` (table and full license text) together.
- Logging goes through `BridgeLog`. Never log calendar/reminder contents at default level.
- Tests that touch real Calendar/Reminders data belong in `LiveRoundTripTests` behind
  `MACBRIDGE_LIVE`.
- Don't run `make install`, `make run`, `make notarize` or `make verify` during review.

## Project references

- EventKit: https://developer.apple.com/documentation/eventkit
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- MCP Swift SDK: https://github.com/modelcontextprotocol/swift-sdk

Changes:
- 2026-10-09 — MIT copyright line in every header; credits rule for dependencies.
- 2026-10-05 — Initial project standards; general rules moved to the global file.
