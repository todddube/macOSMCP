//
//  BridgeClient.swift
//  MacBridgeKit · MacBridge
//
//  The shim's side of the bridge: connects to the app, forwards calls, reconnects.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Darwin
import Foundation
import MCP

/// The shim's side of the bridge: connects to MacBridge.app and forwards calls.
///
/// An actor so requests serialise. The protocol pairs one response to one request
/// on a single connection, and serialising here is simpler and cheaper than
/// multiplexing by id for a client that is driving one conversation at a time.
public actor BridgeClient {

    private var fd: Int32 = -1
    private var framer = LineFramer()
    /// Lines already framed but not yet consumed. A single socket read can finish
    /// several messages; without this queue the extras were extracted from the
    /// framer and then dropped on the floor.
    private var queued: [Data] = []
    private var nextID = 0
    private let io = DispatchQueue(label: "com.thedubes.macbridge.client.io")

    /// The app's handshake reply from the current connection; nil until connected.
    public private(set) var welcome: BridgeWelcome?

    /// Kept so the connection can be rebuilt without the caller's help.
    private var reconnect: (clientName: String, clientVersion: String?, socketURL: URL)?

    /// Failures the CLI reports, each with a message written for the user or model.
    public enum ClientError: Error, LocalizedError {
        case appUnavailable(String)
        case refused(String)
        case protocolFailure(String)
        case toolFailed(String)
        case wrongBundle(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .appUnavailable(let detail): return detail
            case .refused(let detail): return detail
            case .protocolFailure(let detail): return "Bridge protocol failure: \(detail)"
            case .toolFailed(let detail): return detail
            case .wrongBundle(let expected, let actual):
                return """
                    This macbridge belongs to \(expected), but \(actual) answered on the bridge. \
                    Two copies of MacBridge are running — quit the one at \(actual) from its \
                    menu-bar icon, then retry.
                    """
            }
        }
    }

    private init() {}

    // MARK: Connecting

    /// Connect to the app, launching it first if it is not already listening.
    ///
    /// A cold start is the normal case: an MCP client spawns the shim whenever it
    /// feels like it, long before anyone has opened the menu-bar app. Rather than
    /// fail and make the user go launch it, the shim starts the app it lives
    /// inside and waits for the socket to appear.
    public static func connect(
        clientName: String,
        clientVersion: String? = nil,
        socketURL: URL,
        launchIfNeeded: Bool = true,
        timeout: TimeInterval = 20
    ) async throws -> BridgeClient {
        let client = BridgeClient()

        await client.rememberReconnect(clientName: clientName, clientVersion: clientVersion, socketURL: socketURL)

        if await client.tryConnect(to: socketURL) {
            try await client.handshake(clientName: clientName, clientVersion: clientVersion)
            return client
        }

        guard launchIfNeeded else {
            throw ClientError.appUnavailable(
                "MacBridge is not running and no socket was found at \(socketURL.path)."
            )
        }

        try AppLauncher.launchContainingApp()

        // Poll rather than watch the filesystem: the socket appearing is not the
        // same as it accepting, and a connect attempt tests both at once.
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 100_000_000  // 100ms, doubling to 1s
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 1_000_000_000)
            if await client.tryConnect(to: socketURL) {
                try await client.handshake(clientName: clientName, clientVersion: clientVersion)
                return client
            }
        }

        throw ClientError.appUnavailable(
            """
            MacBridge did not start listening within \(Int(timeout))s. Open MacBridge from \
            /Applications and check the menu-bar icon, then retry.
            """
        )
    }

    private func tryConnect(to socketURL: URL) -> Bool {
        guard let socket = try? SocketEndpoint.makeSocket() else { return false }
        guard var addr = try? SocketEndpoint.address(for: socketURL.path) else {
            close(socket)
            return false
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(socket)
            return false
        }

        // A hung app would otherwise hang the AI client indefinitely. Generous,
        // because an EventKit query across many calendars is legitimately slow.
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        fd = socket
        return true
    }

    private func handshake(clientName: String, clientVersion: String?) throws {
        let hello = BridgeHello(
            clientName: clientName,
            clientVersion: clientVersion,
            // Nearest ancestor that is not a wrapper: the client itself.
            clientExecutable: ClientNaming.clientExecutable()
        )
        try SocketEndpoint.writeAll(fd, try BridgeCodec.line(hello))

        guard let line = try readLine() else {
            throw ClientError.protocolFailure("the app closed the connection during the handshake")
        }
        let welcome = try BridgeCodec.decode(BridgeWelcome.self, from: line)
        if let refusal = welcome.refusal {
            throw ClientError.refused(refusal)
        }

        // Belt and braces alongside the per-bundle socket name: if some other copy
        // of MacBridge is somehow on this socket, say so rather than silently using
        // an app with different permissions than the user granted.
        if let ours = BridgeProtocol.owningBundlePath(),
           let theirs = welcome.bundlePath,
           (ours as NSString).standardizingPath.caseInsensitiveCompare(
               (theirs as NSString).standardizingPath) != .orderedSame {
            throw ClientError.wrongBundle(expected: ours, actual: theirs)
        }

        self.welcome = welcome
    }

    private func rememberReconnect(clientName: String, clientVersion: String?, socketURL: URL) {
        reconnect = (clientName, clientVersion, socketURL)
    }

    /// Close the socket. Once a connection has succeeded, the next request reconnects.
    public func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    // MARK: Requests

    /// The app's tool inventory, for answering `tools/list`.
    public func listTools() async throws -> [Tool] {
        let response = try await request(BridgeRequest(id: nextRequestID(), op: .list))
        guard response.ok, let tools = response.tools else {
            throw ClientError.protocolFailure(response.error ?? "the app returned no tool list")
        }
        return tools
    }

    /// Run a tool. A tool-level failure throws `toolFailed` with the message the
    /// model should see; transport problems throw `protocolFailure`.
    public func call(_ name: String, arguments: [String: Value]?) async throws -> Value {
        let response = try await request(
            BridgeRequest(id: nextRequestID(), op: .call, name: name, arguments: arguments)
        )
        if response.ok {
            return response.result ?? .null
        }
        throw ClientError.toolFailed(response.error ?? "the tool failed with no message")
    }

    /// Whether the app answers at all. Never throws: any failure is just `false`.
    public func ping() async -> Bool {
        guard let response = try? await request(BridgeRequest(id: nextRequestID(), op: .ping))
        else { return false }
        return response.ok
    }

    private func nextRequestID() -> Int {
        nextID += 1
        return nextID
    }

    /// Send a request, rebuilding the connection once if it has gone away.
    ///
    /// Without this, restarting the app — including from the menu bar's Restart
    /// Bridge button — left every connected shim permanently broken until the AI
    /// client itself restarted the MCP server, which users experience as "it just
    /// stopped working".
    private func request(_ request: BridgeRequest) async throws -> BridgeResponse {
        do {
            return try sendAndReceive(request)
        } catch {
            guard shouldRetry(after: error), let reconnect else { throw error }

            disconnect()
            framer = LineFramer()
            queued.removeAll()

            // Wait properly for the app to come back, rather than making one attempt
            // after a fixed delay: launching takes a second or three, and a single
            // 750ms try surfaced "The connection was closed." to the model instead of
            // recovering.
            guard try await reestablish(to: reconnect.socketURL) else { throw error }
            try handshake(clientName: reconnect.clientName, clientVersion: reconnect.clientVersion)
            return try sendAndReceive(request)
        }
    }

    /// Reconnect, launching the app if it is not listening, with the same patience
    /// as a cold start.
    private func reestablish(to socketURL: URL, timeout: TimeInterval = 15) async throws -> Bool {
        if tryConnect(to: socketURL) { return true }

        try? AppLauncher.launchContainingApp()

        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 150_000_000  // 150ms, doubling to 1s
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 1_000_000_000)
            if tryConnect(to: socketURL) { return true }
        }
        return false
    }

    /// Retry only a dropped connection — never a refusal or a bundle mismatch, which
    /// reconnecting cannot fix and which the user needs to see.
    private func shouldRetry(after error: Error) -> Bool {
        if let error = error as? ClientError {
            switch error {
            case .protocolFailure: return true
            case .refused, .wrongBundle, .appUnavailable, .toolFailed: return false
            }
        }
        if let error = error as? SocketEndpoint.SocketError {
            switch error {
            case .closed: return true
            case .syscall, .pathTooLong, .alreadyRunning: return false
            }
        }
        return false
    }

    private func sendAndReceive(_ request: BridgeRequest) throws -> BridgeResponse {
        guard fd >= 0 else { throw ClientError.protocolFailure("not connected") }
        try SocketEndpoint.writeAll(fd, try BridgeCodec.line(request))

        // Responses arrive in order on this connection, but skip any whose id does
        // not match rather than assuming — a mismatch means a bug worth not
        // compounding by returning the wrong result.
        while let line = try readLine() {
            let response = try BridgeCodec.decode(BridgeResponse.self, from: line)
            if response.id == request.id || response.id == 0 { return response }
        }
        throw ClientError.protocolFailure("the app closed the connection before replying")
    }

    private func readLine() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if !queued.isEmpty { return queued.removeFirst() }

            guard let chunk = try SocketEndpoint.read(fd, into: &buffer) else { return nil }
            queued.append(contentsOf: try framer.append(chunk))
        }
    }
}

/// Finds and launches the app bundle the running executable lives inside.
public enum AppLauncher {

    /// The containing `.app`, for `macbridge doctor` to report.
    public static func containingAppBundleForDiagnostics() -> URL? {
        containingAppBundle()
    }

    /// `/Applications/MacBridge.app/Contents/MacOS/macbridge` → the `.app`.
    static func containingAppBundle(
        of executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    ) -> URL? {
        // Contents/MacOS/<exe> — three levels up from the binary.
        let candidate = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // MacBridge.app
        return candidate.pathExtension == "app" ? candidate : nil
    }

    /// Launch the containing app in the background.
    ///
    /// `open -g` so starting a conversation never steals focus from what the user
    /// is doing, and `/usr/bin/open` rather than `NSWorkspace` to keep MacBridgeKit
    /// free of AppKit.
    static func launchContainingApp() throws {
        guard let bundle = containingAppBundle() else {
            throw BridgeClient.ClientError.appUnavailable(
                """
                MacBridge is not running, and this macbridge binary is not inside a MacBridge.app \
                bundle, so it cannot start it. Either point your client at the copy inside \
                /Applications/MacBridge.app/Contents/MacOS/macbridge, or run `macbridge mcp --direct` \
                to serve the tools from this process without the app.
                """
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BridgeClient.ClientError.appUnavailable(
                "Could not launch \(bundle.lastPathComponent): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
    }
}
