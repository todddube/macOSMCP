//
//  BridgeClientGuardTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The client's duplicate-write guard, timeout and redacted failures, against a stub server.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Darwin
import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// A scripted stand-in for the app: it accepts connections and runs a closure for
/// each, so a test can drop a connection at an exact point.
private final class StubServer: @unchecked Sendable {
    /// One accepted connection.
    final class Connection: @unchecked Sendable {
        let fd: Int32
        private var framer = LineFramer()
        private var queued: [Data] = []

        init(fd: Int32) { self.fd = fd }

        /// The next line, or nil at end of stream.
        func readLine() -> Data? {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if !queued.isEmpty { return queued.removeFirst() }
                guard let chunk = try? SocketEndpoint.read(fd, into: &buffer),
                      let lines = try? framer.append(chunk)
                else { return nil }
                queued.append(contentsOf: lines)
            }
        }

        func send<T: Encodable>(_ message: T) {
            if let line = try? BridgeCodec.line(message) { try? SocketEndpoint.writeAll(fd, line) }
        }

        /// Answer the handshake the way the app does.
        func welcome() {
            _ = readLine()
            send(BridgeWelcome(appVersion: MacBridge.version, toolCount: 0))
        }

        /// Read the next request.
        func readRequest() -> BridgeRequest? {
            readLine().flatMap { try? BridgeCodec.decode(BridgeRequest.self, from: $0) }
        }

        /// Block until the peer hangs up.
        func waitForHangup() {
            while readLine() != nil {}
        }

        func close() { Darwin.close(fd) }
    }

    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var connections = 0
    private var seen: [(connection: Int, request: BridgeRequest)] = []
    private let script: @Sendable (Int, Connection, StubServer) -> Void

    init(path: String, script: @escaping @Sendable (Int, Connection, StubServer) -> Void) throws {
        self.script = script
        listenFD = try SocketEndpoint.makeSocket()
        var addr = try SocketEndpoint.address(for: path)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 8) == 0 else {
            throw SocketEndpoint.SocketError.syscall("bind/listen", errno: errno)
        }
        DispatchQueue.global().async { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            var pollFD = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 50)
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            guard ready > 0 else { continue }

            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            let index = connections
            connections += 1
            lock.unlock()
            let connection = Connection(fd: fd)
            DispatchQueue.global().async { [self] in
                script(index, connection, self)
                connection.close()
            }
        }
    }

    /// Record a request a script read, so a test can count what reached the app.
    func record(_ request: BridgeRequest, on connection: Int) {
        lock.lock(); defer { lock.unlock() }
        seen.append((connection, request))
    }

    var requests: [(connection: Int, request: BridgeRequest)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}

/// The write tool used below, and a read-only one.
private let writeTool = "calendar_create_event"
private let readTool = "calendar_search_events"

@Suite("Bridge client guard", .serialized)
struct BridgeClientGuardTests {

    private func withStub(
        script: @escaping @Sendable (Int, StubServer.Connection, StubServer) -> Void,
        _ body: (URL, StubServer) async throws -> Void
    ) async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let socket = folder.appendingPathComponent("s.sock")
        let server = try StubServer(path: socket.path, script: script)
        defer { server.stop() }
        try await body(socket, server)
    }

    private func connect(_ socket: URL, replyTimeout: TimeInterval = 5) async throws -> BridgeClient {
        try await BridgeClient.connect(
            clientName: "test", socketURL: socket, launchIfNeeded: false, replyTimeout: replyTimeout
        )
    }

    /// Answer a call with success.
    private static func answer(_ request: BridgeRequest, on connection: StubServer.Connection) {
        connection.send(BridgeResponse(id: request.id, ok: true, result: .string("done")))
    }

    // MARK: isSafeToRepeat

    @Test("Only reads, lists and pings are safe to repeat")
    func safeToRepeat() {
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .list)))
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .ping)))
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: readTool)))
        #expect(!BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: writeTool)))
        #expect(!BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: "no_such_tool")))
        #expect(!BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call)))
    }

    // MARK: After the send

    @Test("A write tool whose connection drops after it was sent is never repeated")
    func outcomeUnknown() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            if let request = connection.readRequest() {
                server.record(request, on: index)
                // Hang up without answering: the app may or may not have acted.
            }
        }) { socket, server in
            let client = try await connect(socket)
            do {
                _ = try await client.call(writeTool, arguments: [:])
                Issue.record("expected outcomeUnknown")
            } catch BridgeClient.ClientError.outcomeUnknown(let tool) {
                #expect(tool == writeTool)
            }
            #expect(server.requests.count == 1, "the request must not be sent a second time")
            await client.disconnect()
        }
    }

    @Test("A read-only tool whose connection drops after it was sent is retried")
    func readIsRetried() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            guard let request = connection.readRequest() else { return }
            server.record(request, on: index)
            if index > 0 { Self.answer(request, on: connection); connection.waitForHangup() }
        }) { socket, server in
            let client = try await connect(socket)
            let result = try await client.call(readTool, arguments: [:])
            #expect(result == .string("done"))
            #expect(server.requests.map(\.connection) == [0, 1])
            await client.disconnect()
        }
    }

    // MARK: Before the send

    @Test("A write tool is retried when the connection was already gone before it was sent")
    func writeRetriedBeforeSend() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            if index == 0 { return }  // Hang up straight after the handshake.
            guard let request = connection.readRequest() else { return }
            server.record(request, on: index)
            Self.answer(request, on: connection)
            connection.waitForHangup()
        }) { socket, server in
            let client = try await connect(socket)
            // Let the hang-up land, so the write fails before any byte is sent.
            try await Task.sleep(nanoseconds: 300_000_000)

            let result = try await client.call(writeTool, arguments: [:])
            #expect(result == .string("done"))
            #expect(server.requests.count == 1, "it reached the app exactly once")
            #expect(server.requests.first?.connection == 1)
            await client.disconnect()
        }
    }

    // MARK: Timeout and abandon

    @Test("An unanswered write tool times out, is abandoned and is not repeated")
    func timeoutWrite() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            if let request = connection.readRequest() { server.record(request, on: index) }
            connection.waitForHangup()  // Never answer; ends when the client abandons.
        }) { socket, server in
            let client = try await connect(socket, replyTimeout: 0.4)
            do {
                _ = try await client.call(writeTool, arguments: [:])
                Issue.record("expected noReply")
            } catch BridgeClient.ClientError.noReply(let tool, _, let changesData) {
                #expect(tool == writeTool)
                #expect(changesData, "the message must warn that it may still complete")
            }
            #expect(server.requests.count == 1)
            await client.disconnect()
        }
    }

    @Test("An unanswered read-only tool times out without the may-complete warning")
    func timeoutRead() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            if let request = connection.readRequest() { server.record(request, on: index) }
            connection.waitForHangup()
        }) { socket, server in
            let client = try await connect(socket, replyTimeout: 0.4)
            do {
                _ = try await client.call(readTool, arguments: [:])
                Issue.record("expected noReply")
            } catch BridgeClient.ClientError.noReply(_, _, let changesData) {
                #expect(!changesData)
            }
            #expect(server.requests.count == 1, "a timeout is not a dropped connection, so no retry")
            await client.disconnect()
        }
    }

    @Test("After an abandon the next request starts on a clean connection")
    func cleanAfterAbandon() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            guard let request = connection.readRequest() else { return }
            server.record(request, on: index)
            if index == 0 {
                connection.waitForHangup()  // Silent, then dropped by the client.
            } else {
                Self.answer(request, on: connection)
                connection.waitForHangup()
            }
        }) { socket, _ in
            let client = try await connect(socket, replyTimeout: 0.4)
            do {
                _ = try await client.call(readTool, arguments: [:])
                Issue.record("expected noReply")
            } catch BridgeClient.ClientError.noReply {}

            #expect(try await client.call(readTool, arguments: [:]) == .string("done"))
            await client.disconnect()
        }
    }

    @Test("An error that is not retried closes the connection, so the next call starts clean")
    func unretriedErrorDisconnects() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            guard let request = connection.readRequest() else { return }
            server.record(request, on: index)
            if index == 0 {
                // An unreadable reply: a decode error, which is not retried.
                try? SocketEndpoint.writeAll(connection.fd, Data("not json\n".utf8))
                connection.waitForHangup()
            } else {
                Self.answer(request, on: connection)
                connection.waitForHangup()
            }
        }) { socket, server in
            let client = try await connect(socket)
            do {
                _ = try await client.call(readTool, arguments: [:])
                Issue.record("expected a decode error")
            } catch {}

            // The first connection was hung up on (the script's waitForHangup ended
            // and the second request arrives on a new one).
            #expect(try await client.call(readTool, arguments: [:]) == .string("done"))
            #expect(server.requests.map(\.connection) == [0, 1])
            await client.disconnect()
        }
    }

    @Test("Cancelling a waiting call returns promptly instead of waiting out the timeout")
    func cancellation() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            if let request = connection.readRequest() { server.record(request, on: index) }
            connection.waitForHangup()
        }) { socket, _ in
            let client = try await connect(socket, replyTimeout: 30)
            let started = Date()
            let task = Task { try await client.call(readTool, arguments: [:]) }
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            _ = await task.result
            #expect(Date().timeIntervalSince(started) < 10)
            await client.disconnect()
        }
    }

    @Test("Concurrent requests are answered in turn on one connection")
    func serialised() async throws {
        try await withStub(script: { index, connection, server in
            connection.welcome()
            while let request = connection.readRequest() {
                server.record(request, on: index)
                try? await_(0.05)
                Self.answer(request, on: connection)
            }
        }) { socket, server in
            let client = try await connect(socket)
            try await withThrowingTaskGroup(of: Value.self) { group in
                for _ in 0..<5 { group.addTask { try await client.call(readTool, arguments: [:]) } }
                for try await value in group { #expect(value == .string("done")) }
            }
            #expect(server.requests.count == 5)
            #expect(Set(server.requests.map(\.connection)) == [0])
            await client.disconnect()
        }
    }

    // MARK: Redacted failures

    @Test("A failure carries the app's redacted log text, not the model's message")
    func redactedLogText() async throws {
        try await withStub(script: { _, connection, _ in
            connection.welcome()
            while let request = connection.readRequest() {
                connection.send(BridgeResponse.failure(
                    id: request.id,
                    "No calendar event matching 'Chemo appointment' was found.",
                    logError: "No calendar event matching the given name or id."
                ))
            }
        }) { socket, _ in
            let client = try await connect(socket)
            do {
                _ = try await client.call(readTool, arguments: [:])
                Issue.record("expected toolFailed")
            } catch let error as BridgeClient.ClientError {
                #expect(error.errorDescription?.contains("Chemo") == true, "the model still sees it")
                #expect(error.logDescription.contains("Chemo") == false)
                #expect(error.logDescription == "No calendar event matching the given name or id.")
            }
            await client.disconnect()
        }
    }

    @Test("With no redacted text, only the fact of failure is logged")
    func noLogText() {
        let error = BridgeClient.ClientError.toolFailed("Calendar 'Therapy' is read-only.")
        #expect(!error.logDescription.contains("Therapy"))
        #expect(error.errorDescription?.contains("Therapy") == true)
    }

    @Test("A response from an older app, with no logError, still decodes")
    func backwardCompatibleDecoding() throws {
        let old = Data(#"{"id":4,"ok":false,"error":"boom"}"#.utf8)
        let response = try BridgeCodec.decode(BridgeResponse.self, from: old)
        #expect(response.error == "boom")
        #expect(response.logError == nil)
    }

    @Test("The real server sends a redacted log string for a failed call")
    func serverFillsLogError() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("b.sock")

        let server = BridgeServer(registry: ToolRegistry(), socketURL: socket)
        try server.start()
        defer { server.stop() }

        let client = try await connect(socket)
        do {
            _ = try await client.call("no_such_tool", arguments: nil)
            Issue.record("expected toolFailed")
        } catch BridgeClient.ClientError.toolFailed(_, let logMessage) {
            #expect(logMessage == MacBridgeError.unknownTool("no_such_tool").logDescription)
        }
        await client.disconnect()
    }
}

/// Blocking sleep for the stub's scripts, which run on plain dispatch threads.
private func await_(_ seconds: TimeInterval) throws {
    Thread.sleep(forTimeInterval: seconds)
}
