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
/// An actor, with a gate so requests serialise even across suspension points. The
/// protocol pairs one response to one request on a single connection, and
/// serialising here is simpler and cheaper than multiplexing by id for a client
/// that is driving one conversation at a time. The blocking socket reads (up to the
/// reply timeout) run on the `io` queue behind a continuation, so they never hold
/// one of the cooperative pool's few threads.
public actor BridgeClient {

    /// The open connection; nil until connected and after ``disconnect()``.
    private var wire: Wire?
    private var nextID = 0
    private let io = DispatchQueue(label: "com.thedubes.macbridge.client.io")
    private let replyTimeout: TimeInterval

    /// Serialises requests: set while one holds the connection.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The app's handshake reply from the current connection; nil until connected.
    public private(set) var welcome: BridgeWelcome?

    /// Kept so the connection can be rebuilt without the caller's help.
    private var reconnect: (clientName: String, clientVersion: String?, socketURL: URL)?

    /// Failures the CLI reports, each with a message written for the user or model.
    public enum ClientError: Error, LocalizedError {
        case appUnavailable(String)
        case refused(String)
        case protocolFailure(String)
        /// A tool failed in the app. `logMessage` is the app's redacted form of the
        /// failure, safe to log; nil when the app sent none (an older app, or an
        /// error with no redacted form).
        case toolFailed(String, logMessage: String? = nil)
        case wrongBundle(expected: String, actual: String)
        /// The connection dropped after a write tool's request was sent, so it may
        /// or may not have run. Never retried: running it again could duplicate it.
        case outcomeUnknown(tool: String)
        /// The app took longer than the read timeout to answer.
        case noReply(tool: String, seconds: Int, changesData: Bool)

        /// What may go in a log file or the unified log. A tool failure's message can
        /// echo event and calendar titles, so only the app's redacted `logMessage` is
        /// used, or a bare statement that it failed. Everything else carries only
        /// fixed text, paths and macOS error wording.
        public var logDescription: String {
            switch self {
            case .toolFailed(_, let logMessage):
                return logMessage ?? "the tool failed (details withheld from the log)"
            default:
                return errorDescription ?? "\(self)"
            }
        }

        public var errorDescription: String? {
            switch self {
            case .appUnavailable(let detail): return detail
            case .refused(let detail): return detail
            case .protocolFailure(let detail): return "Bridge protocol failure: \(detail)"
            case .toolFailed(let detail, _): return detail
            case .wrongBundle(let expected, let actual):
                return """
                    This macbridge belongs to \(expected), but \(actual) answered on the bridge. \
                    Two copies of MacBridge are running — quit the one at \(actual) from its \
                    menu-bar icon, then retry.
                    """
            case .noReply(let tool, let seconds, let changesData):
                let advice = changesData
                    ? "It may still complete, so check with calendar_search_events or reminders_search_reminders before calling it again."
                    : "Try again; if it keeps happening, the user can use Restart Bridge in the MacBridge menu."
                return "MacBridge didn't answer \(tool) within \(seconds) seconds. \(advice)"
            case .outcomeUnknown(let tool):
                return """
                    The connection to MacBridge dropped after \(tool) was sent, so it may or may not \
                    have completed. Check with calendar_search_events or reminders_search_reminders \
                    before calling it again, or the change could be made twice.
                    """
            }
        }
    }

    private init(replyTimeout: TimeInterval) {
        self.replyTimeout = replyTimeout
    }

    /// How long a request waits for the app's reply by default.
    public static let defaultReplyTimeout: TimeInterval = 120

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
        timeout: TimeInterval = 20,
        replyTimeout: TimeInterval = BridgeClient.defaultReplyTimeout
    ) async throws -> BridgeClient {
        let client = BridgeClient(replyTimeout: replyTimeout)

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

        try await AppLauncher.launchContainingApp()

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
        // because an EventKit query across many calendars is legitimately slow, and
        // longer than the app's 90-second budget for a delete confirmation
        // (queueing included), so a refusal from that still arrives.
        let whole = replyTimeout.rounded(.down)
        var timeout = timeval(
            tv_sec: Int(whole),
            tv_usec: Int32((replyTimeout - whole) * 1_000_000)
        )
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        wire = Wire(fd: socket)
        return true
    }

    private func handshake(clientName: String, clientVersion: String?) async throws {
        guard let wire else { throw ClientError.protocolFailure("not connected") }
        let hello = BridgeHello(
            clientName: clientName,
            clientVersion: clientVersion,
            // Informational: the app works the client out for itself.
            clientExecutable: ClientNaming.clientExecutable()
        )
        let line = try await onIO(wire) { wire in
            try wire.send(try BridgeCodec.line(hello))
            return try wire.readLine()
        }
        guard let line else {
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
    ///
    /// Not public: closing a descriptor under a blocked read lets the number be
    /// reused. Callable only while no request is in flight, which is true inside
    /// ``request(_:)`` (it holds the gate) and for tests with an idle client.
    func disconnect() {
        wire?.close()
        wire = nil
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
        throw ClientError.toolFailed(
            response.error ?? "the tool failed with no message",
            logMessage: response.logError
        )
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
    ///
    /// A write tool is retried only if its request never reached the app. Once the
    /// bytes are written, a dropped connection means the app may have saved the
    /// change before dying, and repeating the call would make a second event or
    /// reminder; the caller hears ``ClientError/outcomeUnknown(tool:)`` instead.
    /// Restarting the app still recovers transparently: writing to the closed
    /// socket fails before anything is sent.
    private func request(_ request: BridgeRequest) async throws -> BridgeResponse {
        await acquire()
        defer { release() }

        var sent = false
        do {
            return try await sendAndReceive(request, sent: &sent)
        } catch let error as SocketEndpoint.SocketError where Self.isTimeout(error) {
            throw abandon(request)
        } catch {
            // A cancelled caller interrupts the read, which looks like a dropped
            // connection; retrying for someone who has gone away would only repeat
            // the work.
            if Task.isCancelled {
                disconnect()
                throw CancellationError()
            }
            guard shouldRetry(after: error), let reconnect else {
                // Not retried, so nothing else will close this connection: after a
                // partly written request or an unreadable reply the framing may be
                // out of step (a decode error, an oversized line, a read failure),
                // and the next request would read the wrong response.
                disconnect()
                throw error
            }

            disconnect()

            if sent && !Self.isSafeToRepeat(request) {
                // The next request reconnects on its own: with no socket, its send
                // fails before writing anything and takes the retry path.
                throw ClientError.outcomeUnknown(tool: request.name ?? "the tool")
            }

            // Wait properly for the app to come back, rather than making one attempt
            // after a fixed delay: launching takes a second or three, and a single
            // 750ms try surfaced "The connection was closed." to the model instead of
            // recovering.
            guard try await reestablish(to: reconnect.socketURL) else { throw error }
            do {
                try await handshake(clientName: reconnect.clientName, clientVersion: reconnect.clientVersion)
                var resent = false
                return try await sendAndReceive(request, sent: &resent)
            } catch let retryError as SocketEndpoint.SocketError where Self.isTimeout(retryError) {
                throw abandon(request)
            } catch {
                disconnect()
                throw error
            }
        }
    }

    /// Give up on a request the app didn't answer in time.
    ///
    /// The app may still be working on it and would answer into this connection
    /// later; dropping the connection means the next request starts clean instead
    /// of queueing behind the stale reply.
    private func abandon(_ request: BridgeRequest) -> ClientError {
        disconnect()
        return ClientError.noReply(
            tool: request.name ?? request.op.rawValue,
            seconds: Int(replyTimeout.rounded(.up)),
            changesData: request.name.map(ToolRegistry.changesData) ?? false
        )
    }

    /// A receive timeout: `SO_RCVTIMEO` makes `read` fail with `EAGAIN`.
    static func isTimeout(_ error: SocketEndpoint.SocketError) -> Bool {
        if case .syscall("read", let code) = error { return code == EAGAIN || code == EWOULDBLOCK }
        return false
    }

    /// Whether sending `request` a second time can't change anything: the tool
    /// list, a ping, or a read-only tool.
    static func isSafeToRepeat(_ request: BridgeRequest) -> Bool {
        switch request.op {
        case .list, .ping: return true
        case .call: return request.name.map(ToolRegistry.isReadOnly) ?? false
        }
    }

    /// Reconnect, launching the app if it is not listening, with the same patience
    /// as a cold start.
    private func reestablish(to socketURL: URL, timeout: TimeInterval = 15) async throws -> Bool {
        if tryConnect(to: socketURL) { return true }

        try? await AppLauncher.launchContainingApp()

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
            case .refused, .wrongBundle, .appUnavailable, .toolFailed, .outcomeUnknown, .noReply: return false
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

    /// - Parameter sent: set once every byte of the request has been written,
    ///   which is the point after which the app may have acted on it.
    private func sendAndReceive(_ request: BridgeRequest, sent: inout Bool) async throws -> BridgeResponse {
        guard let wire else { throw ClientError.protocolFailure("not connected") }
        let payload = try BridgeCodec.line(request)
        let requestID = request.id

        // The flag is written on the io queue; reading it after the await is safe
        // because the continuation resumes after that work has finished.
        let box = SentFlag()
        defer { sent = box.value }

        return try await onIO(wire) { wire in
            try wire.send(payload)
            box.value = true

            // Responses arrive in order on this connection, but skip any whose id
            // does not match rather than assuming: a mismatch means a bug worth not
            // compounding by returning the wrong result.
            while let line = try wire.readLine() {
                let response = try BridgeCodec.decode(BridgeResponse.self, from: line)
                if response.id == requestID || response.id == 0 { return response }
            }
            throw ClientError.protocolFailure("the app closed the connection before replying")
        }
    }

    // MARK: Blocking I/O

    /// Run blocking socket work on the `io` queue, resuming when it finishes.
    ///
    /// Cancelling the caller shuts the socket down, which ends a read that would
    /// otherwise sit out the whole reply timeout.
    private func onIO<T: Sendable>(
        _ wire: Wire,
        _ work: @escaping @Sendable (Wire) throws -> T
    ) async throws -> T {
        let queue = io
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try work(wire))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            wire.interrupt()
        }
    }

    /// Wait for the connection to be free of any other request.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hand the connection to the next waiting request, or mark it free.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Whether a request's bytes were all written; see ``BridgeClient``'s `sendAndReceive`.
private final class SentFlag: @unchecked Sendable {
    var value = false
}

/// One connection's socket and its framing state.
///
/// Used from the `io` queue only while a request holds the client's gate, so its
/// buffers are never touched by two threads. The lock guards the descriptor, which
/// ``interrupt()`` (on cancellation) and ``close()`` can race.
private final class Wire: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    private var framer = LineFramer()
    /// Lines already framed but not yet consumed. A single socket read can finish
    /// several messages; without this queue the extras were extracted from the
    /// framer and then dropped on the floor.
    private var queued: [Data] = []
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ data: Data) throws {
        try SocketEndpoint.writeAll(fd, data)
    }

    /// The next whole line, blocking until one arrives; nil at end of stream.
    func readLine() throws -> Data? {
        while true {
            if !queued.isEmpty { return queued.removeFirst() }

            guard let chunk = try SocketEndpoint.read(fd, into: &buffer) else { return nil }
            queued.append(contentsOf: try framer.append(chunk))
        }
    }

    /// Wake a blocked read or write without releasing the descriptor.
    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        if !closed { shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// Finds and launches the app bundle the running executable lives inside.
public enum AppLauncher {

    /// Set in the app's environment when a client starts it in the background, so the
    /// app can tell that launch apart from one the user made (and skip the splash).
    public static let launchedByEnvironmentKey = "MACBRIDGE_LAUNCHED_BY"
    /// The ``launchedByEnvironmentKey`` value for a launch by a client's shim.
    public static let launchedByClient = "client"

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
    /// is doing, `--env` so the app knows a client started it, and `/usr/bin/open`
    /// rather than `NSWorkspace` to keep MacBridgeKit free of AppKit.
    static func launchContainingApp() async throws {
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
        process.arguments = ["-g", "--env", "\(launchedByEnvironmentKey)=\(launchedByClient)", "-a", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Awaited through the termination handler rather than `waitUntilExit()`,
        // which would block a thread of the cooperative pool.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            throw BridgeClient.ClientError.appUnavailable(
                "Could not launch \(bundle.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }
}
