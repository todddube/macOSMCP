//
//  Credits.swift
//  MacBridgeKit · MacBridge
//
//  Authorship, license and third-party credits, shown by the About window and the CLI.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Who made MacBridge, how it is licensed, and the open-source work it builds on.
///
/// One list, read by both the About window and `macbridge --help`, so the credits a
/// user sees can't drift between the two. `THIRD_PARTY_NOTICES.md` carries the full
/// license texts; keep its table in step with ``components`` when a dependency changes.
public enum Credits {

    /// The copyright holder, as written in `LICENSE`.
    public static let author = "Todd Dube"

    /// The year MacBridge was first published.
    public static let copyrightYear = 2026

    /// The license MacBridge itself is released under.
    public static let license = "MIT License"

    /// The one-line notice for the About window and the CLI.
    public static var copyright: String { "Copyright © \(copyrightYear) \(author)" }

    // The force-unwraps below are on string literals, never on input, so they can't fail.

    /// The author's GitHub profile.
    public static let authorURL = URL(string: "https://github.com/todddube")!
    /// The public source repository.
    public static let repositoryURL = URL(string: "https://github.com/todddube/macOSMCP")!
    /// `LICENSE` on the repository's main branch.
    public static let licenseURL = URL(string: "https://github.com/todddube/macOSMCP/blob/main/LICENSE")!

    /// An open-source component compiled into the MacBridge binary.
    public struct Component: Sendable, Identifiable {
        public let name: String
        public let author: String
        /// Short license name for display, using SPDX identifiers where one fits.
        public let license: String
        public let url: URL

        public var id: String { name }
    }

    /// Every third-party package linked into the binary, in the order they are credited.
    ///
    /// Only what is linked: swift-nio, swift-atomics and swift-collections appear in
    /// `Package.resolved` only because the SDK's conformance-test executables use them;
    /// the `MCP` library MacBridge links does not.
    public static let components: [Component] = [
        Component(name: "MCP Swift SDK", author: "Model Context Protocol project",
                  license: "MIT / Apache-2.0",
                  url: URL(string: "https://github.com/modelcontextprotocol/swift-sdk")!),
        Component(name: "EventSource", author: "Mattt", license: "MIT",
                  url: URL(string: "https://github.com/mattt/eventsource")!),
        Component(name: "SwiftLog", author: "Apple Inc.", license: "Apache-2.0",
                  url: URL(string: "https://github.com/apple/swift-log")!),
        Component(name: "Swift System", author: "Apple Inc.", license: "Apache-2.0",
                  url: URL(string: "https://github.com/apple/swift-system")!),
    ]
}
