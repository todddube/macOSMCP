//
//  main.swift
//  MacBridge (app) · MacBridge
//
//  Entry point: menu-bar app or CLI, decided by the arguments.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import Foundation

// One binary, two faces.
//
// MacBridge.app/Contents/MacOS/macbridge is BOTH the menu-bar app and the CLI an
// MCP client spawns. Launched by LaunchServices there are no arguments, so the
// SwiftUI app runs; invoked as `macbridge mcp` it runs the shim and never touches
// AppKit.
//
// They have to be one binary rather than two files in Contents/MacOS: macOS
// filesystems are case-insensitive by default, so an app executable named
// "MacBridge" and a tool named "macbridge" are the same path, and whichever is
// copied second silently destroys the first.

let arguments = Array(CommandLine.arguments.dropFirst())

if CLI.isCommandLineInvocation(arguments) {
    await CLI.run(arguments)
    exit(0)
} else {
    MacBridgeApp.main()
}
