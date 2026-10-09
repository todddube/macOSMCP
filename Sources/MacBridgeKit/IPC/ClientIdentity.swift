//
//  ClientIdentity.swift
//  MacBridgeKit · MacBridge
//
//  Who is on the other end of a bridge connection.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Who is on the other end of a bridge connection.
///
/// `name` is self-reported by the shim, for display and for keying consent;
/// `pid` and `executablePath` come from the kernel and are what a security
/// decision should rest on.
public struct ClientIdentity: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let version: String?
    public let pid: Int32
    public let executablePath: String?
    public let connectedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        version: String? = nil,
        pid: Int32,
        executablePath: String? = nil,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.pid = pid
        self.executablePath = executablePath
        self.connectedAt = connectedAt
    }

    /// A short label for the menu bar.
    public var displayName: String {
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    /// Best-effort path of the connected process, from its pid.
    public static func executablePath(forPID pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

// proc_pidpath lives in libproc.h, which has no Swift overlay.
@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ size: UInt32) -> Int32
