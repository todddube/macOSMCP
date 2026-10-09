//
//  BridgeIdentityTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Per-bundle socket derivation, and naming a client from its process tree.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// The socket-naming rule that stops two copies of MacBridge fighting.
///
/// This is the regression test for the bug that made calls fail for no visible
/// reason: an Xcode DerivedData build and the copy in /Applications shared one
/// socket path, so whichever grabbed it first served every client — including when
/// it was the copy with no Calendar or Reminders permission.
@Suite("Bridge identity")
struct BridgeIdentityTests {

    let installed = "/Applications/MacBridge.app"
    let derived = "/Users/someone/Library/Developer/Xcode/DerivedData/MacBridge-abc/Build/Products/Debug/MacBridge.app"

    @Test("Different bundles get different sockets")
    func differentBundlesDiffer() {
        #expect(BridgeProtocol.socketSlug(for: installed) != BridgeProtocol.socketSlug(for: derived))
    }

    @Test("The same bundle always gets the same socket")
    func stableForOneBundle() {
        #expect(BridgeProtocol.socketSlug(for: installed) == BridgeProtocol.socketSlug(for: installed))
    }

    @Test("Case and trailing-slash differences do not create a second socket")
    func normalised() {
        // macOS filesystems are case-insensitive, so these are the same bundle and
        // must not end up listening in two places.
        #expect(
            BridgeProtocol.socketSlug(for: "/Applications/MacBridge.app")
                == BridgeProtocol.socketSlug(for: "/Applications/macbridge.app")
        )
        #expect(
            BridgeProtocol.socketSlug(for: "/Applications/MacBridge.app")
                == BridgeProtocol.socketSlug(for: "/Applications/MacBridge.app/")
        )
    }

    @Test("The slug is short and filesystem-safe")
    func slugShape() {
        let slug = BridgeProtocol.socketSlug(for: derived)
        #expect(slug.count == 8)
        #expect(slug.allSatisfy { $0.isHexDigit })
    }

    @Test("The socket path stays within the sockaddr_un limit")
    func pathLengthIsSafe() throws {
        // sun_path is 104 bytes; overrunning it truncates silently and connects to
        // the wrong place.
        let url = try BridgeProtocol.socketURL(forBundleAt: derived)
        #expect(url.path.utf8.count < 104, "socket path too long: \(url.path)")
        #expect(url.lastPathComponent.hasPrefix("bridge-"))
        #expect(url.pathExtension == "sock")
    }
}

/// Naming the client from the process tree.
@Suite("Client naming")
struct ClientNamingTests {

    @Test("Claude Desktop is found through its disclaimer helper")
    func throughDisclaimer() {
        // The real chain, and the bug this fixes: reading only the immediate parent
        // labelled every Claude Desktop connection "disclaimer".
        let chain = [
            "/Applications/Claude.app/Contents/Helpers/disclaimer",
            "/Applications/Claude.app/Contents/MacOS/Claude",
        ]
        #expect(ClientNaming.friendlyName(forChain: chain) == "Claude Desktop")
    }

    @Test("Claude Code is recognised directly")
    func claudeCode() {
        #expect(ClientNaming.friendlyName(forChain: ["/opt/homebrew/bin/claude"]) == "Claude Code")
    }

    @Test("A helper inside an unknown app is named after the app")
    func unknownAppByBundle() {
        let chain = ["/Applications/Mystery.app/Contents/Helpers/spawner"]
        #expect(ClientNaming.friendlyName(forChain: chain) == "Mystery")
    }

    @Test("Shell and runtime wrappers are skipped in favour of the real client")
    func skipsWrappers() {
        let chain = ["/bin/zsh", "/usr/local/bin/node", "/Applications/Cursor.app/Contents/MacOS/Cursor"]
        #expect(ClientNaming.friendlyName(forChain: chain) == "Cursor")
    }

    @Test("Versioned interpreters are treated as wrappers", arguments: [
        "python3.13", "python3", "python", "node-18", "ruby2.7", "zsh",
    ])
    func versionedWrappers(name: String) {
        // A shim spawned by python3.13 reported the interpreter as the client, because
        // only the unversioned "python3" was in the passthrough set.
        #expect(ClientNaming.isPassthrough(name), "'\(name)' should be walked past")
    }

    @Test("A real client name is not mistaken for a wrapper", arguments: [
        "claude", "cursor", "code", "codex", "warp",
    ])
    func realClientsAreNotWrappers(name: String) {
        #expect(!ClientNaming.isPassthrough(name))
    }

    @Test("A versioned interpreter in the chain is skipped for the real client")
    func skipsVersionedInterpreter() {
        let chain = [
            "/Users/someone/.pyenv/versions/3.13.12/bin/python3.13",
            "/bin/bash",
            "/opt/homebrew/bin/claude",
        ]
        #expect(ClientNaming.friendlyName(forChain: chain) == "Claude Code")
    }

    @Test("An entirely unrecognised chain does not claim to know")
    func unknown() {
        #expect(ClientNaming.friendlyName(forChain: ["/bin/zsh", "/sbin/launchd"]) == "Unknown client")
        #expect(ClientNaming.friendlyName(forChain: []) == "Unknown client")
    }

    @Test("The enclosing app is found from a nested helper path")
    func enclosingApp() {
        #expect(
            ClientNaming.enclosingAppName(of: "/Applications/Claude.app/Contents/Helpers/disclaimer")
                == "Claude"
        )
        #expect(ClientNaming.enclosingAppName(of: "/usr/bin/env") == nil)
    }

    @Test("Walking the live process tree yields this test runner's ancestry")
    func liveChain() {
        // Not asserting specific names — just that the walk terminates and returns
        // real paths rather than looping or coming back empty.
        let chain = ClientNaming.ancestorExecutables()
        #expect(chain.count <= 6)
        #expect(chain.allSatisfy { $0.hasPrefix("/") })
    }
}
