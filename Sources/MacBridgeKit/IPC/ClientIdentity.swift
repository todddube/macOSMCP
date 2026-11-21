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
/// Everything here is established by the app, not taken on trust from the peer.
/// `pid` is the socket peer's pid from the kernel. When the peer is the `macbridge`
/// shim, `executablePath` and `name` come from walking the shim's ancestors to the
/// AI client; when it is any other process, that process is itself the client. The
/// peer's self-reported name is never used as `name`: with nothing derivable the name
/// is "Unknown client", and the report is kept as ``claimedName`` whenever it differs
/// from the derived name. Anything that shows or keys on a name (the confirmation
/// prompt, a consent store) should use `name` together with `executablePath`, and
/// mention `claimedName` when set. Code-signature checks of the peer are not made.
public struct ClientIdentity: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    /// The name the peer reported about itself when it differs from ``name``; nil when they agree.
    public let claimedName: String?
    public let version: String?
    public let pid: Int32
    public let executablePath: String?
    public let connectedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        claimedName: String? = nil,
        version: String? = nil,
        pid: Int32,
        executablePath: String? = nil,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.claimedName = claimedName
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
