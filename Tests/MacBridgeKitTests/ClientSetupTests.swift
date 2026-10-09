//
//  ClientSetupTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Whether a client's config actually points at this copy of the app.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// The rule that decides whether a client is actually pointed at *this* app.
///
/// Worth testing because the failure it guards against is silent: a config naming
/// a `macbridge` binary that no longer exists looks configured, and only breaks
/// when the user next tries to use it.
@Suite("Client setup detection")
struct ClientSetupTests {

    let shim = "/Applications/MacBridge.app/Contents/MacOS/macbridge"

    @Test("An exact match on our own path is ready")
    func exactMatch() {
        #expect(ClientSetup.status(forCommands: [shim], shimPath: shim) == .ready)
    }

    @Test("Ready wins even when other servers are configured too")
    func mixedWithOtherServers() {
        let commands = ["/usr/bin/npx", "/opt/homebrew/bin/some-other-server", shim]
        #expect(ClientSetup.status(forCommands: commands, shimPath: shim) == .ready)
    }

    @Test("A macbridge binary at another path is flagged, not accepted")
    func staleBuildPath() {
        // The realistic case: a config written while testing a DerivedData build.
        let stale = "/private/tmp/macbridge-dd/Build/Products/Debug/MacBridge.app/Contents/MacOS/macbridge"
        #expect(ClientSetup.status(forCommands: [stale], shimPath: shim) == .pointsElsewhere(stale))
    }

    @Test("Unrelated servers do not count as configured")
    func unrelatedServers() {
        let commands = ["/usr/bin/npx", "/Applications/SomethingElse.app/Contents/MacOS/somethingelse"]
        #expect(ClientSetup.status(forCommands: commands, shimPath: shim) == .notConfigured)
    }

    @Test("A server whose name merely contains 'macbridge' is not mistaken for ours")
    func similarNameIsNotOurs() {
        // Only the last path component is compared, so this must not match.
        #expect(
            ClientSetup.status(forCommands: ["/usr/local/bin/macbridge-proxy"], shimPath: shim)
                == .notConfigured
        )
    }

    @Test("Matching the binary name is case-insensitive")
    func caseInsensitiveName() {
        // macOS filesystems are case-insensitive, so a config may spell it either way
        // and still refer to the same file.
        let other = "/Users/someone/build/MacBridge.app/Contents/MacOS/MacBridge"
        #expect(ClientSetup.status(forCommands: [other], shimPath: shim) == .pointsElsewhere(other))
    }

    @Test("No servers at all is not configured")
    func empty() {
        #expect(ClientSetup.status(forCommands: [], shimPath: shim) == .notConfigured)
    }

    @Test("Detection returns both Claude clients, whatever their state")
    func detectCoversBothClients() {
        let found = ClientSetup.detect(shimPath: shim)
        #expect(found.count == 2)
        #expect(found.map(\.id).sorted() == ["claude-code", "claude-desktop"])
        #expect(found.allSatisfy { !$0.configPath.isEmpty })
    }
}
