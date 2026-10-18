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

/// Uses only `list` and `ping`, which never touch EventKit, so nothing prompts.
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
