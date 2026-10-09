//
//  BridgeServer.swift
//  MacBridgeKit · MacBridge
//
//  Listens on the Unix socket and serves tool calls to connected shims.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Darwin
import Foundation
import MCP

/// Listens on the Unix socket and serves tool calls to connected shims.
///
/// Lives in the app, which is what keeps TCC, the activity log and eventually
/// consent in one place the user can see, rather than in whichever CLI process a
/// client happened to spawn.
public final class BridgeServer: @unchecked Sendable {

    /// Asked to approve each call before it runs, returning a refusal message or
    /// nil to allow. Currently always allows; this is the seam the planned consent
    /// store and confirmation sheets plug into, so the server itself never has to
    /// learn about clients.
    public typealias Authorizer = @Sendable (BridgeRequest, ClientIdentity) async -> String?

    /// Called on connect, disconnect and each completed call, for the menu bar.
    public typealias Observer = @Sendable (Event) -> Void

    /// What the server reports to its ``Observer``.
    public enum Event: Sendable {
        case connected(ClientIdentity)
        case disconnected(ClientIdentity)
        case call(
            ClientIdentity,
            tool: String,
            ok: Bool,
            detail: String?,
            /// A few words on what the call did, for the activity list.
            summary: String? = nil,
            duration: TimeInterval = 0
        )
        /// One connection went wrong. The server is still listening.
        case connectionError(String)
        /// The listener itself died. The server is no longer usable.
        case serverError(String)
    }

    private let registry: ToolRegistry
    private let socketURL: URL
    private let authorize: Authorizer
    private let observe: Observer

    private let acceptQueue = DispatchQueue(label: "com.thedubes.macbridge.accept")
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var clients: [UUID: ClientIdentity] = [:]

    /// Configures the server without touching the socket; call ``start()`` to listen.
    /// Omitting `authorize` allows every call.
    public init(
        registry: ToolRegistry,
        socketURL: URL,
        authorize: Authorizer? = nil,
        observe: Observer? = nil
    ) {
        self.registry = registry
        self.socketURL = socketURL
        self.authorize = authorize ?? { _, _ in nil }
        self.observe = observe ?? { _ in }
    }

    /// Clients currently attached, for display.
    public var connectedClients: [ClientIdentity] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clients.values.sorted { $0.connectedAt < $1.connectedAt }
    }

    // MARK: Lifecycle

    /// Bind and listen on the socket, then accept clients on a background queue.
    ///
    /// - Throws: `SocketError.alreadyRunning` when another instance is listening on
    ///   the path, or a `syscall` error if the socket can't be created or bound.
    public func start() throws {
        let path = socketURL.path

        // A socket file left behind by a crash would make bind fail with EADDRINUSE
        // forever, so a stale one is removed — but only after checking that nothing
        // is actually accepting on it. Removing a live socket would let a second
        // instance steal the path while the first kept listening on an orphaned
        // inode, receiving nothing and still reporting itself healthy.
        if SocketEndpoint.isLive(path: path) {
            throw SocketEndpoint.SocketError.alreadyRunning(path)
        }
        try? FileManager.default.removeItem(at: socketURL)

        // Also sweep sockets other instances left behind — a killed or crashed copy
        // never runs its own cleanup, and the pre-per-bundle "bridge.sock" has no
        // owner at all now, so nothing else would ever remove them.
        sweepStaleSockets(besides: socketURL)

        let fd = try SocketEndpoint.makeSocket()
        var addr = try SocketEndpoint.address(for: path)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketEndpoint.SocketError.syscall("bind", errno: errno)
        }

        // Only this user may connect. The socket carries full access to the user's
        // calendar and reminders, so the permission bits are part of the security
        // story, not housekeeping.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        guard Darwin.listen(fd, 16) == 0 else {
            close(fd)
            throw SocketEndpoint.SocketError.syscall("listen", errno: errno)
        }

        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()

        BridgeLog.info("listening on \(path)", category: .bridge)
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    /// Remove socket files in our directory that nothing is listening on.
    private func sweepStaleSockets(besides current: URL) {
        let directory = current.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.pathExtension == "sock" && entry != current {
            guard !SocketEndpoint.isLive(path: entry.path) else { continue }
            try? FileManager.default.removeItem(at: entry)
            BridgeLog.info("removed stale socket \(entry.lastPathComponent)", category: .bridge)
        }
    }

    /// Stop accepting, forget connected clients and remove the socket file.
    public func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        clients.removeAll()
        stateLock.unlock()

        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: socketURL)
        BridgeLog.info("stopped listening", category: .bridge)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    // MARK: Accept

    private func acceptLoop(_ listenFD: Int32) {
        while isRunning {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                // A closed listening socket is the normal shutdown path, not a fault.
                if isRunning {
                    observe(.serverError("accept failed: \(String(cString: strerror(errno)))"))
                }
                return
            }

            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // One queue per connection: reads block, and a slow client must not
            // stall the others or the accept loop.
            DispatchQueue(label: "com.thedubes.macbridge.conn.\(fd)").async { [weak self] in
                self?.serve(fd)
            }
        }
    }

    // MARK: Per-connection

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var identity: ClientIdentity?

        do {
            while let chunk = try SocketEndpoint.read(fd, into: &buffer) {
                for line in try framer.append(chunk) {
                    if identity == nil {
                        identity = try handleHandshake(line, fd: fd)
                        continue
                    }
                    guard let identity else { continue }
                    try handleRequest(line, fd: fd, identity: identity)
                }
            }
        } catch {
            if let identity {
                observe(.call(identity, tool: "(connection)", ok: false, detail: error.localizedDescription))
            } else {
                // A malformed handshake or a stale shim is one bad connection, not a
                // dead listener — reporting it as a server error left the menu bar
                // permanently showing a failure it could never recover from.
                BridgeLog.warning("connection failed: \(error.localizedDescription)", category: .bridge)
                observe(.connectionError(error.localizedDescription))
            }
        }

        if let identity {
            stateLock.lock()
            clients.removeValue(forKey: identity.id)
            stateLock.unlock()
            BridgeLog.info("client disconnected: \(identity.displayName)", category: .bridge)
            observe(.disconnected(identity))
        }
    }

    private func handleHandshake(_ line: Data, fd: Int32) throws -> ClientIdentity {
        let hello = try BridgeCodec.decode(BridgeHello.self, from: line)

        // Trust the kernel over the handshake for the pid.
        let pid = SocketEndpoint.peerPID(fd) ?? hello.pid
        // Prefer the client executable the shim resolved; the peer path is only ever
        // our own shim and is useless for identifying who is calling.
        let identity = ClientIdentity(
            name: hello.clientName,
            version: hello.clientVersion,
            pid: pid,
            executablePath: hello.clientExecutable ?? ClientIdentity.executablePath(forPID: pid)
        )

        var refusal: String?
        if hello.protocolVersion != BridgeProtocol.version {
            refusal = """
                Bridge protocol mismatch: the client speaks v\(hello.protocolVersion), \
                this app speaks v\(BridgeProtocol.version). A stale macbridge process is \
                probably still running — quit and reopen the AI client.
                """
        }

        let welcome = BridgeWelcome(
            appVersion: MacBridge.version,
            toolCount: ToolRegistry.definitions().count,
            bundlePath: BridgeProtocol.owningBundlePath(),
            refusal: refusal
        )
        try SocketEndpoint.writeAll(fd, try BridgeCodec.line(welcome))

        if let refusal {
            BridgeLog.warning("refused \(hello.clientName): \(refusal)", category: .bridge)
            throw SocketEndpoint.SocketError.closed
        }

        stateLock.lock()
        clients[identity.id] = identity
        stateLock.unlock()

        BridgeLog.info(
            "client connected: \(identity.displayName) pid \(identity.pid) "
                + "(\(identity.executablePath ?? "unknown path"))",
            category: .bridge
        )
        observe(.connected(identity))

        return identity
    }

    private func handleRequest(_ line: Data, fd: Int32, identity: ClientIdentity) throws {
        let request: BridgeRequest
        do {
            request = try BridgeCodec.decode(BridgeRequest.self, from: line)
        } catch {
            // Malformed input gets a reply rather than a dropped connection, so the
            // shim can surface something the model can read.
            let response = BridgeResponse.failure(id: 0, "Unreadable bridge request: \(error.localizedDescription)")
            try SocketEndpoint.writeAll(fd, try BridgeCodec.line(response))
            return
        }

        // Bridge the blocking read loop into async work, then write the reply here.
        let semaphore = DispatchSemaphore(value: 0)
        var response = BridgeResponse.failure(id: request.id, "No response produced.")

        Task { [registry, authorize, observe] in
            defer { semaphore.signal() }

            switch request.op {
            case .ping:
                response = BridgeResponse(id: request.id, ok: true)

            case .list:
                response = BridgeResponse(id: request.id, ok: true, tools: ToolRegistry.definitions())

            case .call:
                guard let name = request.name else {
                    response = .failure(id: request.id, "A call request carried no tool name.")
                    return
                }
                if let refusal = await authorize(request, identity) {
                    response = .failure(id: request.id, refusal)
                    observe(.call(identity, tool: name, ok: false, detail: "denied"))
                    return
                }
                let started = Date()
                do {
                    let value = try await registry.call(name, arguments: request.arguments)
                    let elapsed = Date().timeIntervalSince(started)
                    response = BridgeResponse(id: request.id, ok: true, result: value)

                    let summary = ActivitySummary.summarize(value)
                    let timing = ActivitySummary.describe(duration: elapsed).map { " in \($0)" } ?? ""
                    BridgeLog.info(
                        "\(name) ok — \(identity.displayName)"
                            + (summary.map { " — \($0)" } ?? "") + timing,
                        category: .tools
                    )
                    observe(.call(identity, tool: name, ok: true, detail: nil,
                                  summary: summary, duration: elapsed))
                } catch {
                    let elapsed = Date().timeIntervalSince(started)
                    let message = (error as? MacBridgeError)?.errorDescription ?? error.localizedDescription
                    response = .failure(id: request.id, message)
                    BridgeLog.error("\(name) failed — \(identity.displayName): \(message)", category: .tools)
                    observe(.call(identity, tool: name, ok: false, detail: message,
                                  summary: nil, duration: elapsed))
                }
            }
        }

        semaphore.wait()
        try SocketEndpoint.writeAll(fd, try BridgeCodec.line(response))
    }
}
