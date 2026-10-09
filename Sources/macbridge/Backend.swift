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

    func callTool(_ name: String, arguments: [String: Value]?) async throws -> Value {
        try await registry.call(name, arguments: arguments)
    }

    var describe: String { "direct (EventKit in this process)" }
}

/// Forwards to MacBridge.app over the Unix socket. The default.
struct BridgeBackend: ToolBackend {
    let client: BridgeClient

    func listTools() async throws -> [Tool] {
        try await client.listTools()
    }

    func callTool(_ name: String, arguments: [String: Value]?) async throws -> Value {
        try await client.call(name, arguments: arguments)
    }

    var describe: String { "bridged to MacBridge.app" }
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
