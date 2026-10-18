//
//  Backend.swift
//  macbridge · MacBridge
//
//  Where the CLI gets its tools: the app over the bridge, or in-process.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import MacBridgeKit

/// Where the CLI gets its tools from.
///
/// Two implementations, because the same `macbridge mcp` command serves two
/// situations: normally it is a shim in front of MacBridge.app, but `--direct`
/// runs everything in this process, which is how the tools are tested without a
/// GUI and how someone who does not want the menu-bar app can still use them.
protocol ToolBackend: Sendable {
    /// The inventory to answer `tools/list` with.
    func listTools() async throws -> [Tool]
    /// Run one tool. Throws with a message the model should read when it fails.
    func callTool(_ name: String, arguments: [String: Value]?) async throws -> Value
    /// A few words naming the backend, for the startup log line.
    var describe: String { get }
}

/// EventKit in this process. No app, no socket, and TCC prompts attach to the CLI.
struct DirectBackend: ToolBackend {
    let registry: ToolRegistry

    func listTools() async throws -> [Tool] {
        ToolRegistry.definitions()
    }

    /// Applies the app's ``AccessPolicy`` too, read fresh on every call, so turning
    /// on Read-only in the panel also covers a client running without the app.
    /// There is nowhere to show a confirmation here, so a call that needs one is
    /// refused with a message saying how to proceed.
    func callTool(_ name: String, arguments: [String: Value]?) async throws -> Value {
        switch AccessPolicy.load().decision(for: name) {
        case .allow:
            return try await registry.call(name, arguments: arguments)
        case .refuse(let message):
            throw BridgeClient.ClientError.refused(message)
        case .confirm:
            throw BridgeClient.ClientError.refused(AccessPolicy.cannotConfirm(name))
        }
    }

    var describe: String { "direct (EventKit in this process)" }
}

/// Forwards to MacBridge.app over the Unix socket, the default, connecting on
/// first need rather than before the MCP server starts.
///
/// Connecting first meant a cold start (launching the app, then waiting for its
/// socket, up to 20 seconds) ran before `initialize` was answered, and an app that
/// couldn't be reached killed the server, which a client shows only as "failed".
/// Now the client is answered at once, the connection is made in the background,
/// and a failure to reach the app is a tool error the model can read and relay.
struct BridgeBackend: ToolBackend {
    let bridge: LazyBridge

    /// The app's own list once connected; until then this binary's, which is the
    /// same inventory unless an older copy of the app is still running.
    func listTools() async throws -> [Tool] {
        if let client = await bridge.connectedClient, let tools = try? await client.listTools() {
            return tools
        }
        return ToolRegistry.definitions()
    }

    func callTool(_ name: String, arguments: [String: Value]?) async throws -> Value {
        try await bridge.client().call(name, arguments: arguments)
    }

    var describe: String { "bridged to MacBridge.app" }
}

/// One connection to the app, made by whichever caller needs it first.
actor LazyBridge {
    private let clientName: String
    private let socketURL: URL
    private var connected: BridgeClient?
    private var connecting: Task<BridgeClient, Error>?

    init(clientName: String, socketURL: URL) {
        self.clientName = clientName
        self.socketURL = socketURL
    }

    /// The client if a connection has already been made; never connects.
    var connectedClient: BridgeClient? { connected }

    /// The connected client, connecting (and launching the app) if need be.
    /// Concurrent callers share one attempt; a failed attempt is retried by the
    /// next call rather than remembered.
    func client() async throws -> BridgeClient {
        if let connected { return connected }
        if let connecting { return try await connecting.value }

        let task = Task { [clientName, socketURL] in
            try await BridgeClient.connect(clientName: clientName, clientVersion: nil, socketURL: socketURL)
        }
        connecting = task
        defer { connecting = nil }
        do {
            let client = try await task.value
            connected = client
            await report(client)
            return client
        } catch {
            let detail = (error as? BridgeClient.ClientError)?.errorDescription ?? error.localizedDescription
            log("could not reach MacBridge.app: \(detail)", isError: true)
            throw error
        }
    }

    /// Log the connection, and warn when the app answering isn't this version:
    /// an old copy left running after an update serves old tools and old fixes.
    private func report(_ client: BridgeClient) async {
        let welcome = await client.welcome
        log("connected to MacBridge.app as '\(clientName)' — \(welcome?.toolCount ?? 0) tools")
        if let appVersion = welcome?.appVersion, appVersion != MacBridge.version {
            log(
                "MacBridge.app \(appVersion) is running, but this macbridge is \(MacBridge.version). "
                    + "Quit MacBridge from its menu-bar icon and open it again to use the new version.",
                isError: true
            )
        }
    }
}

/// Best-effort name for the AI client that spawned us.
///
/// Always overridable with `--client`; the detection itself lives in
/// `ClientNaming` so the rule can be tested without spawning processes.
enum ClientDetection {

    /// The `--client` value if given, otherwise a name inferred from the process tree.
    static func detect(arguments: [String]) -> String {
        if let index = arguments.firstIndex(of: "--client"), arguments.count > index + 1 {
            return arguments[index + 1]
        }
        return ClientNaming.detectClientName()
    }
}
