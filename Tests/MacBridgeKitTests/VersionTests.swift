//
//  VersionTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Keeps the code's version string in step with the app bundle's.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// The version is written twice: `MacBridge.version`, which the CLI and the MCP
/// handshake report, and `MARKETING_VERSION` in project.yml, which becomes the
/// bundle's `CFBundleShortVersionString`. Bumping one and forgetting the other
/// would have About and `macbridge --version` disagree, so the build catches it.
@Suite("Version")
struct VersionTests {

    @Test func codeVersionMatchesProjectYML() throws {
        let projectYML = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacBridgeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectYML, encoding: .utf8)

        let line = try #require(
            text.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") },
            "project.yml has no MARKETING_VERSION"
        )
        let declared = line
            .split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))

        #expect(declared == MacBridge.version)
    }

    /// The MCP SDK is pinned twice too: Package.swift for SwiftPM, project.yml for
    /// the Xcode build of the app. Different pins would build the CLI and the app
    /// against different SDKs.
    @Test func sdkPinMatchesBetweenPackageAndProject() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        let packagePin = try #require(
            package.firstMatch(of: #/swift-sdk\.git", \.upToNextMinor\(from: "([0-9.]+)"\)/#)?.1,
            "Package.swift should pin swift-sdk with .upToNextMinor(from:)"
        )
        let projectPin = try #require(
            project.firstMatch(of: #/minorVersion: ([0-9.]+)/#)?.1,
            "project.yml should pin swift-sdk with minorVersion"
        )
        #expect(packagePin == projectPin)
    }
}
