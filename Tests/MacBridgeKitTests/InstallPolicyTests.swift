//
//  InstallPolicyTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Pins when the app offers to move itself, and what it may move to the Trash.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Testing

@testable import MacBridgeKit

/// Getting this wrong either nags users who installed correctly or trashes a copy
/// that wasn't safe to trash, so each path case is pinned.
@Suite("Install policy")
struct InstallPolicyTests {

    private let home = "/Users/someone"
    private let id = "com.thedubes.macbridge"

    private func offers(_ path: String, resolved: String? = nil, id: String? = nil,
                        suppressed: Bool = false) -> Bool {
        InstallPolicy.shouldOfferMove(
            bundlePath: path, resolvedPath: resolved ?? path, homeDirectory: home,
            bundleIdentifier: id ?? self.id, suppressed: suppressed
        )
    }

    @Test("Offers the move from Downloads, a disk image or a translocated path")
    func offersOutsideApplications() {
        #expect(offers("/Users/someone/Downloads/MacBridge.app"))
        #expect(offers("/Volumes/MacBridge 0.7.0/MacBridge.app"))
        #expect(offers("/private/var/folders/xy/T/AppTranslocation/ABC/d/MacBridge.app"))
    }

    @Test("Leaves an installed copy alone")
    func quietWhenInstalled() {
        #expect(!offers("/Applications/MacBridge.app"))
        #expect(!offers("/Users/someone/Applications/MacBridge.app"))
    }

    @Test("A /Applications symlink to a copy elsewhere counts as installed")
    func symlinkCountsAsInstalled() {
        #expect(!offers("/Applications/MacBridge.app", resolved: "/Users/someone/dev/MacBridge.app"))
    }

    @Test("Debug builds and a suppressed prompt never ask")
    func debugAndSuppressed() {
        #expect(!offers("/tmp/DerivedData/MacBridge.app", id: "com.thedubes.macbridge.debug"))
        #expect(!offers("/Users/someone/Downloads/MacBridge.app", suppressed: true))
    }

    @Test("Only a plain copy outside /Applications may be trashed")
    func trashRules() {
        let dest = "/Applications/MacBridge.app"
        #expect(InstallPolicy.mayTrashSource(at: "/Users/someone/Downloads/MacBridge.app", destination: dest))
        #expect(!InstallPolicy.mayTrashSource(at: "/Volumes/MacBridge/MacBridge.app", destination: dest))
        #expect(!InstallPolicy.mayTrashSource(
            at: "/private/var/folders/xy/T/AppTranslocation/ABC/d/MacBridge.app", destination: dest))
        #expect(!InstallPolicy.mayTrashSource(at: dest, destination: dest))
    }
}
