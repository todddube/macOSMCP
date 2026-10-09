//
//  SocketEndpoint.swift
//  MacBridgeKit · MacBridge
//
//  POSIX plumbing for the Unix-domain socket.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Darwin
import Foundation

/// Shared POSIX plumbing for the Unix-domain socket used between shim and app.
///
/// A socket rather than an XPC service because the shim is spawned by arbitrary
/// third-party MCP clients, not by the app — it is not an XPC client of ours in
/// any launchd sense. A socket in Application Support is also debuggable with
/// `nc`, which matters for a transport that sits between two processes we ship.
enum SocketEndpoint {

    /// Socket failures, worded for the user since they surface in the CLI and menu bar.
    enum SocketError: Error, LocalizedError {
        case pathTooLong(String)
        case syscall(String, errno: Int32)
        case closed
        case alreadyRunning(String)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path):
                return "Socket path is too long for sockaddr_un (104 bytes): \(path)"
            case .syscall(let name, let code):
                return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
            case .closed:
                return "The connection was closed."
            case .alreadyRunning(let path):
                return "Another copy of MacBridge is already listening on \(path). "
                    + "Quit the running one from its menu-bar icon before starting this one."
            }
        }
    }

    /// Build a `sockaddr_un` for `path`, validating the length up front.
    ///
    /// `sun_path` is a fixed 104-byte buffer; overrunning it silently truncates
    /// the path and connects to the wrong place, so this is checked rather than
    /// trusted.
    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }

        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            bytes.withUnsafeBufferPointer { source in
                raw.update(from: source.baseAddress!, count: bytes.count)
            }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// A new stream socket with SIGPIPE suppressed. The caller owns and closes the fd.
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno: errno) }

        // Without SO_NOSIGPIPE, writing to a socket whose peer has gone raises
        // SIGPIPE and kills the process outright — which for the app would mean a
        // client quitting takes the menu bar down with it.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Write every byte, looping over short writes.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { throw SocketError.closed }
                if errno == EINTR { continue }
                if errno == EPIPE || errno == ECONNRESET { throw SocketError.closed }
                throw SocketError.syscall("write", errno: errno)
            }
        }
    }

    /// One blocking read. Returns nil at end of stream.
    static func read(_ fd: Int32, into buffer: inout [UInt8]) throws -> Data? {
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            if errno == ECONNRESET || errno == EPIPE { return nil }
            throw SocketError.syscall("read", errno: errno)
        }
    }

    /// True when something is already accepting connections on `path`.
    ///
    /// Used before removing a socket file: a second copy of the app — a fresh build
    /// launched while the installed one is running — would otherwise steal the path,
    /// leaving the first instance listening on an orphaned inode, never receiving
    /// another client, and still reporting "Listening".
    static func isLive(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let fd = try? makeSocket() else { return false }
        defer { close(fd) }

        guard var addr = try? address(for: path) else { return false }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// The pid on the other end of a connected socket.
    ///
    /// This is the identity that can actually be trusted, unlike the self-reported
    /// name in the handshake, and is what tells two clients apart even when they
    /// claim the same name.
    static func peerPID(_ fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }
}
