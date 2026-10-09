//
//  main.swift
//  macbridge · MacBridge
//
//  Entry point for the package executable. The app bundle uses App/main.swift.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

// Entry point for the `macbridge` package executable — terminal and CI use.
//
// Inside MacBridge.app the entry point is App/main.swift instead, which runs the
// menu-bar app when no subcommand is given. This file is excluded from that
// target; see project.yml.

await CLI.run(Array(CommandLine.arguments.dropFirst()))
