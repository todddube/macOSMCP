// swift-tools-version: 6.0
import PackageDescription

// MacBridge — Swift menu-bar app bridging AI clients to macOS Calendar & Reminders.
// Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//
// MacBridgeKit holds all the logic and is terminal-testable. The `macbridge`
// executable is the CLI; inside MacBridge.app the same binary is also the menu-bar
// app, built by the Xcode project generated from project.yml.
//
// Tests need Xcode's toolchain (swift-testing's macro plugin and
// Testing.framework ship only with Xcode); `make test` points DEVELOPER_DIR at it.
//
// Swift 5 language mode: EventKit is an Objective-C framework with no Sendable
// annotations, so strict concurrency checking fights every EKEventStore call for
// no safety gain — non-Sendable EventKit objects never escape the services here.

let package = Package(
    name: "MacBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacBridgeKit", targets: ["MacBridgeKit"]),
        .executable(name: "macbridge", targets: ["macbridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "MacBridgeKit",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "macbridge",
            dependencies: [
                "MacBridgeKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Embed the Info.plist so TCC has a usage description to show. A bare
            // SwiftPM executable has no bundle, and macOS denies Calendar and
            // Reminders access outright — with no prompt — when none is found.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/macbridge/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MacBridgeKitTests",
            dependencies: [
                "MacBridgeKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
