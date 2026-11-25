//
//  BridgeRoundTripTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The app's socket server and the shim's client, end to end over a real socket.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// Uses only `list`, `ping` and calls the test's authorizer refuses, none of which
/// touch EventKit, so nothing prompts.
///
/// Each test gets its own folder: the server sweeps stale sockets from the folder
/// it listens in, and must not go near anyone else's.
@Suite("Bridge round trip", .serialized)
struct BridgeRoundTripTests {

    private func withSocketFolder(_ body: (URL) async throws -> Void) async throws {
        // Short: sockaddr_un holds 104 bytes of path.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder.appendingPathComponent("b.sock"))
    }

    @Test("A client connects, lists the tools and pings")
    func connectAndList() async throws {
        try await withSocketFolder { socket in
            let server = BridgeServer(registry: ToolRegistry(), socketURL: socket)
            try server.start()
            defer { server.stop() }

            let client = try await BridgeClient.connect(
                clientName: "test", socketURL: socket, launchIfNeeded: false
            )
            #expect(await client.welcome?.appVersion == MacBridge.version)
            #expect(try await client.listTools().count == ToolRegistry.definitions().count)
            #expect(await client.ping())
            await client.disconnect()
        }
    }

    /// A raw connection to `socket` that sends nothing, as a stuck or hostile peer would.
    private func rawConnection(to socket: URL) throws -> Int32 {
        let fd = try SocketEndpoint.makeSocket()
        var addr = try SocketEndpoint.address(for: socket.path)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0)
        return fd
    }

    @Test("A connection that never sends a handshake is closed, and the server keeps serving")
    func silentConnectionTimesOut() async throws {
        try await withSocketFolder { socket in
            let server = BridgeServer(registry: ToolRegistry(), socketURL: socket, handshakeTimeout: 0.3)
            try server.start()
            defer { server.stop() }

            let silent = try rawConnection(to: socket)
            defer { close(silent) }
            // The server's close reaches us as end-of-file, well before this read's own 5 s timeout.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(silent, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let started = Date()
            var byte: UInt8 = 0
            #expect(Darwin.read(silent, &byte, 1) == 0)
            #expect(Date().timeIntervalSince(started) < 3)

            // A real client connecting afterwards, and idling past the timeout, is unaffected.
            let client = try await BridgeClient.connect(clientName: "test", socketURL: socket, launchIfNeeded: false)
            try await Task.sleep(for: .milliseconds(600))
            #expect(await client.ping())
            await client.disconnect()
        }
    }

    @Test("Stopping ends open connections, and the client reconnects to the next server")
    func restartDropsConnections() async throws {
        try await withSocketFolder { socket in
            let disconnects = Counter()
            let first = BridgeServer(registry: ToolRegistry(), socketURL: socket, observe: { event in
                if case .disconnected = event { disconnects.increment() }
            })
            try first.start()

            let client = try await BridgeClient.connect(
                clientName: "test", socketURL: socket, launchIfNeeded: false
            )
            #expect(await client.ping())

            first.stop()
            #expect(!FileManager.default.fileExists(atPath: socket.path), "stop removes the socket")

            // The open connection must end with the server, not linger on its own
            // thread: that was what kept a wedged connection alive across Restart.
            let deadline = Date().addingTimeInterval(2)
            while disconnects.value == 0 && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(disconnects.value == 1, "stop should end the open connection")

            let second = BridgeServer(registry: ToolRegistry(), socketURL: socket)
            try second.start()
            defer { second.stop() }

            // The old connection was shut down, so this ping fails its write and
            // takes the reconnect path to the new server.
            #expect(await client.ping(), "the client should reach the restarted server")
            await client.disconnect()
        }
    }

    @Test("A client hanging up mid-call cancels the call's wait for the user")
    func hangupCancelsPendingCall() async throws {
        try await withSocketFolder { socket in
            let cancelled = Counter()
            let disconnects = Counter()
            // Stands in for the confirmation prompt: waits until cancelled, or 30 s.
            let server = BridgeServer(
                registry: ToolRegistry(),
                socketURL: socket,
                authorize: { _, _ in
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { cancelled.increment() }
                    return "declined"
                },
                observe: { event in
                    if case .disconnected = event { disconnects.increment() }
                }
            )
            try server.start()
            defer { server.stop() }

            let fd = try rawConnection(to: socket)
            try SocketEndpoint.writeAll(fd, try BridgeCodec.line(BridgeHello(clientName: "test")))
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = try SocketEndpoint.read(fd, into: &buffer)  // the welcome
            let call = BridgeRequest(id: 1, op: .call, name: "reminders_delete_list", arguments: [:])
            try SocketEndpoint.writeAll(fd, try BridgeCodec.line(call))
            try await Task.sleep(for: .milliseconds(200))
            close(fd)

            let deadline = Date().addingTimeInterval(5)
            while (cancelled.value == 0 || disconnects.value == 0) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(cancelled.value == 1, "the pending call should be cancelled when its client hangs up")
            #expect(disconnects.value == 1, "the hangup should be reported as a disconnect")
        }
    }

    @Test("A pending call doesn't mistake a live, quiet client for a hangup")
    func quietClientIsNotAHangup() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]) }
        #expect(!BridgeServer.peerHasHungUp(pair[0]))
        // A request sent meanwhile is data, not a hangup, and stays unread.
        _ = "x".withCString { Darwin.write(pair[1], $0, 1) }
        #expect(!BridgeServer.peerHasHungUp(pair[0]))
        close(pair[1])
        #expect(BridgeServer.peerHasHungUp(pair[0]))
    }

    @Test("The socket folder is private to the user after start")
    func folderIsPrivate() async throws {
        try await withSocketFolder { socket in
            let folder = socket.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

            let server = BridgeServer(registry: ToolRegistry(), socketURL: socket)
            try server.start()
            defer { server.stop() }

            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }
}

/// A thread-safe count, for observer callbacks that arrive on server queues.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}
