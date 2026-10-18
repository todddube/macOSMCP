//
//  UpdateCheckTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Version comparison and release parsing for Check for Updates.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// No network: the GitHub response is fed in directly.
@Suite("Update check")
struct UpdateCheckTests {

    @Test("Versions compare part by part, not as text")
    func comparison() {
        #expect(UpdateCheck.isNewer("1.10.0", than: "1.9.0"))
        #expect(UpdateCheck.isNewer("2.0", than: "1.99.99"))
        #expect(!UpdateCheck.isNewer("1.9", than: "1.9.0"))
        #expect(!UpdateCheck.isNewer("1.8.0", than: "1.9.0"))
        #expect(!UpdateCheck.isNewer("1.9.0-beta", than: "1.9.0"))
    }

    @Test("A release tag's leading v is dropped")
    func tag() {
        #expect(UpdateCheck.version(fromTag: "v1.9.0") == "1.9.0")
        #expect(UpdateCheck.version(fromTag: "1.9.0") == "1.9.0")
    }

    @Test("A newer release is offered with its page; an older or equal one isn't")
    func parsing() throws {
        let body = Data(#"{"tag_name":"v1.9.0","html_url":"https://github.com/todddube/macOSMCP/releases/tag/v1.9.0","name":"x"}"#.utf8)
        #expect(try UpdateCheck.result(fromReleaseJSON: body, current: "1.8.0") == .available(
            version: "1.9.0",
            page: URL(string: "https://github.com/todddube/macOSMCP/releases/tag/v1.9.0")!
        ))
        #expect(try UpdateCheck.result(fromReleaseJSON: body, current: "1.9.0") == .upToDate(latest: "1.9.0"))
    }
}
