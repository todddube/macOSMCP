//
//  BridgeProtocol.swift
//  MacBridgeKit · MacBridge
//
//  The wire protocol between shim and app, and the per-bundle socket path.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import CryptoKit
import Foundation
import MCP

/// The wire protocol between the `macbridge mcp` shim and MacBridge.app.
///
/// Deliberately *not* MCP. The shim already links the MCP SDK and speaks the
/// protocol to the client, so the app only needs to answer two questions: what
/// tools exist, and please run this one. That keeps the app a tool server — the
/// thing that owns TCC, consent and the activity log — and keeps MCP version
/// churn on the shim side. Both ship in the same bundle, so they update together.
///
/// Messages are newline-delimited JSON, one object per line, same framing as MCP
/// over stdio.
public enum BridgeProtocol {
    /// Bumped only for incompatible changes. The shim and app are always shipped
    /// together, so a mismatch means a stale process is still running — worth
    /// reporting clearly rather than failing to parse something subtle.
    public static let version = 1

    /// Where this copy of MacBridge listens.
    ///
    /// The socket name includes a digest of the owning `.app` path, so two copies of
    /// MacBridge never compete for one socket. That collision was not hypothetical:
    /// an Xcode DerivedData build and the copy in /Applications have *different TCC
    /// identities*, and whichever grabbed the shared socket first served every
    /// client — so requests routed to a copy with no Calendar or Reminders
    /// permission and failed, while the copy the user had granted sat idle.
    ///
    /// A shim inside a bundle derives the same name as the app in that bundle, so it
    /// can only ever reach its own copy.
    ///
    /// Not in a sandbox container: the app is not sandboxed, so a shim spawned by
    /// any client can find the socket at this plain Application Support path. The
    /// result also has to stay well under the 104-byte `sockaddr_un` limit, which is
    /// why the digest is truncated rather than the path embedded.
    public static func socketURL(forBundleAt bundlePath: String? = nil) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("MacBridge", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let owner = bundlePath ?? owningBundlePath() ?? canonicalBundlePath
        return directory.appendingPathComponent("bridge-\(socketSlug(for: owner)).sock")
    }

    /// Where a normally installed MacBridge lives.
    ///
    /// Used by a bare CLI build that is not inside a bundle, so `swift build` shims
    /// talk to the installed app rather than to nothing.
    public static let canonicalBundlePath = "/Applications/MacBridge.app"

    /// The `.app` this process runs from, if any.
    ///
    /// Both the GUI app and the shim are the same binary inside the same bundle, so
    /// `Bundle.main` gives both of them the identical answer — which is exactly why
    /// the derived socket name matches.
    public static func owningBundlePath() -> String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    /// A short, stable, filesystem-safe digest of a bundle path.
    public static func socketSlug(for bundlePath: String) -> String {
        // Case-insensitively normalised: macOS filesystems are case-insensitive, so
        // two spellings of one path must not produce two sockets.
        let normalised = (bundlePath as NSString).standardizingPath.lowercased()
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Handshake

/// First line the shim sends, identifying which AI client it is serving.
///
/// The client name is self-reported and therefore untrusted; it labels rows in the
/// app's UI and will key the consent store. It is never used to make a security
/// decision on its own — the process identity below is what is checked.
public struct BridgeHello: Codable, Sendable {
    public var protocolVersion: Int
    public var clientName: String
    public var clientVersion: String?
    public var pid: Int32
    /// The AI client's own executable, as the shim resolved it from the process tree.
    ///
    /// Sent because the server can only see the *peer* of the socket, which is the
    /// shim itself — so logs read "Claude Code (…/MacBridge.app/…/macbridge)", naming
    /// our own binary rather than the client's and telling nobody anything.
    public var clientExecutable: String?

    public init(
        clientName: String,
        clientVersion: String? = nil,
        clientExecutable: String? = nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.protocolVersion = BridgeProtocol.version
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientExecutable = clientExecutable
        self.pid = pid
    }
}

/// The app's reply, which also tells the shim how many tools to expect.
public struct BridgeWelcome: Codable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public var toolCount: Int
    /// The `.app` that answered. The shim checks this against its own bundle so a
    /// second copy of MacBridge cannot quietly serve requests meant for this one.
    public var bundlePath: String?
    /// Set when the app is refusing to serve this client, e.g. denied by consent.
    public var refusal: String?

    public init(appVersion: String, toolCount: Int, bundlePath: String? = nil, refusal: String? = nil) {
        self.protocolVersion = BridgeProtocol.version
        self.appVersion = appVersion
        self.toolCount = toolCount
        self.bundlePath = bundlePath
        self.refusal = refusal
    }
}

// MARK: - Requests and responses

/// One request from shim to app, matched to its ``BridgeResponse`` by `id`.
public struct BridgeRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        /// Return the tool inventory.
        case list
        /// Execute one tool.
        case call
        /// Liveness check, used by the shim before it gives up and relaunches.
        case ping
    }

    public var id: Int
    public var op: Operation
    /// The tool to run; set only for `.call`.
    public var name: String?
    public var arguments: [String: Value]?

    public init(id: Int, op: Operation, name: String? = nil, arguments: [String: Value]? = nil) {
        self.id = id
        self.op = op
        self.name = name
        self.arguments = arguments
    }
}

/// The app's answer to one ``BridgeRequest``, echoing its `id`.
///
/// On success `tools` is set for `.list` and `result` for `.call`; a `.ping` reply
/// carries neither. On failure only `error` is set.
public struct BridgeResponse: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var tools: [Tool]?
    public var result: Value?
    /// Present when `ok` is false. Carries the message a model should read.
    public var error: String?

    public init(id: Int, ok: Bool, tools: [Tool]? = nil, result: Value? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.tools = tools
        self.result = result
        self.error = error
    }

    /// A failed response carrying `message` for the model.
    public static func failure(id: Int, _ message: String) -> BridgeResponse {
        BridgeResponse(id: id, ok: false, error: message)
    }
}

// MARK: - Codec

/// One JSON encoder/decoder pair for the whole wire protocol.
public enum BridgeCodec {

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // No pretty-printing: a newline inside a message would break the framing.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static let decoder = JSONDecoder()

    /// Encode a message as a single line, newline included.
    public static func line<T: Encodable>(_ message: T) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    /// Decode one framed message.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
