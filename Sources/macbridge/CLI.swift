//
//  CLI.swift
//  macbridge · MacBridge
//
//  The command-line face: mcp, doctor and tools.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP
import MacBridgeKit

// The command-line face of MacBridge.
//
// Shared by two entry points: App/main.swift (inside MacBridge.app, which runs the
// menu-bar app when launched with no subcommand) and Sources/macbridge/main.swift
// (the package executable, for terminal use and CI).
//
// `macbridge mcp` is what MCP clients run. By default it is a thin shim: it
// connects to MacBridge.app over a Unix socket, launching the app if it is not
// yet running, and forwards tool calls to it. The app owns EventKit, so TCC is
// granted once to the app rather than to whatever spawned this process, and the
// user can see every call from the menu bar, and will be able to gate it once
// per-client consent lands.
//
// `macbridge mcp --direct` runs EventKit in this process with no app required,
// which is how the tools are exercised in tests.

/// Nothing may reach stdout except MCP protocol frames, or the client's parser
/// desynchronises and the connection dies with no useful error.
func log(_ message: String, isError: Bool = false) {
    // stderr is what the AI client captures into its own MCP log, which is the first
    // place anyone looks; BridgeLog adds os_log and the persistent file.
    FileHandle.standardError.write(Data(("macbridge: " + message + "\n").utf8))
    if isError {
        BridgeLog.error(message, category: .cli)
    } else {
        BridgeLog.info(message, category: .cli)
    }
}

/// Print `--help`, including the license and credits footer, to stdout.
func printUsage() {
    print("""
        macbridge \(MacBridge.version) — bridge AI clients to macOS Calendar & Reminders

        USAGE
          macbridge mcp                Serve MCP over stdio, via MacBridge.app (what clients run)
          macbridge mcp --direct       Serve MCP over stdio with EventKit in this process
          macbridge mcp --client NAME  Label this connection as NAME in the app's menu
          macbridge doctor             Report permissions, bridge status and tool inventory
          macbridge doctor --request   Same, but prompt for any access not yet decided
          macbridge tools [--schemas]  List the tools this server exposes
          macbridge --help             Show this message

        CLIENT SETUP
          Claude Code:     claude mcp add macbridge -- /Applications/MacBridge.app/Contents/MacOS/macbridge mcp
          Claude Desktop:  add to claude_desktop_config.json:
            { "mcpServers": { "macbridge": {
                "command": "/Applications/MacBridge.app/Contents/MacOS/macbridge", "args": ["mcp"] } } }

        ABOUT
          \(Credits.copyright). Free and open source under the \(Credits.license).
          \(Credits.repositoryURL.absoluteString)
          Built with \(Credits.components.map(\.name).joined(separator: ", ")).
          Third-party licenses: THIRD_PARTY_NOTICES.md, in the repository and the app's Resources.
        """)
}

// MARK: - doctor

/// `macbridge doctor`: permissions, the bridge socket, client setup and tool
/// counts. With `requestAccess`, prompts for any undecided grant.
func runDoctor(requestAccess: Bool) async {
    print("MacBridge \(MacBridge.version)")

    print("\nPermissions")
    // A fresh store per domain: requesting access mutates the store's state, and
    // doctor should not leave a half-authorised store behind.
    for domain in EventKitDomain.allCases {
        let store = EKEventStore()
        var status = EventKitAuthorization.status(for: domain)

        if requestAccess, status == .notDetermined {
            try? await EventKitAuthorization.ensureAccess(to: domain, store: store)
            status = EventKitAuthorization.status(for: domain)
        }

        let mark = EventKitAuthorization.hasFullAccess(status) ? "ok  " : "--  "
        let label = domain.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)
        print("  \(mark)\(label) \(EventKitAuthorization.statusDescription(status))")

        if status == .notDetermined && !requestAccess {
            print("      run `macbridge doctor --request` to prompt for access")
        }
        if status == .denied || status == .restricted {
            print("      System Settings → Privacy & Security → \(domain.displayName)")
        }
    }
    if requestAccess {
        print("\n  Note: these grants belong to whichever process asked. Once MacBridge.app")
        print("  is installed, grant them to the app instead — that is the supported path.")
    }

    print("\nBridge")
    if let socketURL = try? BridgeProtocol.socketURL() {
        let exists = FileManager.default.fileExists(atPath: socketURL.path)
        print("  socket   \(socketURL.path)")
        print("  status   \(exists ? "present" : "not listening — the app is not running")")
        if let bundle = AppLauncher.containingAppBundleForDiagnostics() {
            print("  app      \(bundle.path)")
        } else {
            print("  app      this binary is not inside a MacBridge.app bundle")
            print("           `macbridge mcp` will need --direct until it is")
        }
    }

    print("\nClient setup")
    let shimPath = AppLauncher.containingAppBundleForDiagnostics()
        .map { $0.appendingPathComponent("Contents/MacOS/macbridge").path }
        ?? CommandLine.arguments[0]

    for client in ClientSetup.detect(shimPath: shimPath) {
        let mark: String
        let detail: String
        switch client.status {
        case .ready:
            mark = "ok  "
            detail = "configured for this app"
        case .pointsElsewhere(let command):
            mark = "--  "
            detail = "points at \(command)"
        case .notConfigured:
            mark = "--  "
            detail = "not set up — \(client.configPath)"
        case .notInstalled:
            mark = "    "
            detail = "not installed"
        }
        print("  \(mark)\(client.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)")
    }
    if ClientSetup.detect(shimPath: shimPath).allSatisfy({ !$0.isReady }) {
        print("")
        print("  No client is pointed at MacBridge, so nothing can use it yet. Add it with:")
        print("    claude mcp add macbridge -- \(shimPath) mcp")
    }

    let definitions = ToolRegistry.definitions()
    print("\nTools")
    for domain in EventKitDomain.allCases {
        print("  \(definitions.filter { $0.name.hasPrefix(domain.toolPrefix) }.count) \(domain.rawValue)")
    }
    print("  \(definitions.count) total, \(ToolRegistry.destructiveToolNames.count) destructive")
}

// MARK: - tools

/// `macbridge tools`: the tool list with read/write/destructive flags, or the full
/// definitions as JSON with `showSchemas`.
func runTools(showSchemas: Bool) {
    let definitions = ToolRegistry.definitions()

    if showSchemas {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(definitions), let text = String(data: data, encoding: .utf8) else {
            log("could not encode tool definitions")
            exit(1)
        }
        print(text)
        return
    }

    let destructive = ToolRegistry.destructiveToolNames
    for tool in definitions {
        let flag = destructive.contains(tool.name)
            ? "[destructive]"
            : (tool.annotations.readOnlyHint == true ? "[read-only]" : "[write]")
        print("\(tool.name)  \(flag)")
    }
    print("\n\(definitions.count) tools")
}

// MARK: - mcp

/// Serve MCP over stdio until the client disconnects, answering from `backend`.
func runMCPServer(backend: ToolBackend) async throws {
    let server = Server(
        name: MacBridge.serverName,
        version: MacBridge.version,
        instructions: MacBridge.instructions,
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: try await backend.listTools())
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            let result = try await backend.callTool(params.name, arguments: params.arguments)
            return CallTool.Result(
                content: [.text(text: JSONText.encode(result), annotations: nil, _meta: nil)],
                structuredContent: Value?.some(result)
            )
        } catch {
            // Tool failures come back as an error *result*, not a protocol error:
            // the model should read what went wrong and correct itself, which a
            // JSON-RPC error would deny it.
            let message = (error as? MacBridgeError)?.errorDescription
                ?? (error as? BridgeClient.ClientError)?.errorDescription
                ?? error.localizedDescription
            log("\(params.name) failed: \(message)", isError: true)
            return CallTool.Result(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    log("serving over stdio — \(backend.describe)")
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
}

/// The in-process backend for `--direct`, otherwise a connection to MacBridge.app,
/// launching it if needed. Throws when the app can't be reached.
func makeBackend(arguments: [String]) async throws -> ToolBackend {
    if arguments.contains("--direct") {
        return DirectBackend(registry: ToolRegistry())
    }

    let clientName = ClientDetection.detect(arguments: arguments)
    let socketURL = try BridgeProtocol.socketURL()

    do {
        let client = try await BridgeClient.connect(
            clientName: clientName,
            clientVersion: nil,
            socketURL: socketURL
        )
        let toolCount = await client.welcome?.toolCount ?? 0
        log("connected to MacBridge.app as '\(clientName)' — \(toolCount) tools")
        return BridgeBackend(client: client)
    } catch {
        let detail = (error as? BridgeClient.ClientError)?.errorDescription ?? error.localizedDescription
        log("could not reach MacBridge.app: \(detail)", isError: true)
        throw error
    }
}

// MARK: - Entry point

/// Subcommands the CLI answers to. Anything else — in particular an empty
/// argument list, which is how LaunchServices starts an app — is not ours, and
/// tells the single binary to run the GUI instead.
enum CLI {

    static let subcommands: Set<String> = ["mcp", "doctor", "tools", "--help", "-h", "help"]

    /// True when this process was invoked as a command-line tool rather than
    /// double-clicked or launched by an MCP client's `open`.
    static func isCommandLineInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return subcommands.contains(first)
    }

    /// Run a subcommand. Returns normally so callers can exit as they see fit.
    static func run(_ arguments: [String]) async {
        switch arguments.first {
        case "mcp":
            do {
                try await runMCPServer(backend: try await makeBackend(arguments: arguments))
            } catch {
                let detail = (error as? BridgeClient.ClientError)?.errorDescription ?? error.localizedDescription
                log(detail)
                log("hint: `macbridge mcp --direct` serves the tools without the app")
                exit(1)
            }

        case "doctor":
            await runDoctor(requestAccess: arguments.contains("--request"))

        case "tools":
            runTools(showSchemas: arguments.contains("--schemas"))

        case "--help", "-h", "help":
            printUsage()

        case nil:
            printUsage()
            exit(1)

        case .some(let unknown):
            log("unknown command '\(unknown)'")
            printUsage()
            exit(1)
        }
    }
}
