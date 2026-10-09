//
//  LineFramer.swift
//  MacBridgeKit · MacBridge
//
//  Splits a byte stream into newline-delimited messages.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// A socket read returns whatever happened to arrive: half a message, three
/// messages, or a message split mid-multibyte-character. Everything upstream of
/// this type assumes whole lines, so this is where that assumption is made true.
///
/// Pure and synchronous, which is what makes the framing directly testable —
/// exactly the class of bug that is miserable to diagnose through a live socket.
public struct LineFramer {

    private var buffer = Data()

    /// Guards against a peer that never sends a newline. Without a cap, a
    /// malformed or hostile stream would grow this buffer until the process dies.
    public let maximumLineLength: Int

    public init(maximumLineLength: Int = 8 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Why the stream was abandoned; the connection is closed rather than resynced.
    public enum FramingError: Error, LocalizedError {
        case lineTooLong(Int)

        public var errorDescription: String? {
            switch self {
            case .lineTooLong(let limit):
                return "A single message exceeded \(limit) bytes with no newline; closing the connection."
            }
        }
    }

    /// Append freshly read bytes and return every complete line they finished.
    ///
    /// Empty lines are skipped rather than returned, so a stray blank line or
    /// `\r\n` padding cannot be mistaken for a message.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)

        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let trimmed = Self.trimmingCarriageReturn(Data(buffer[buffer.startIndex..<newlineIndex]))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }

        if buffer.count > maximumLineLength {
            buffer.removeAll()
            throw FramingError.lineTooLong(maximumLineLength)
        }
        return lines
    }

    /// Any trailing bytes not yet terminated by a newline.
    public var pending: Data { buffer }

    private static func trimmingCarriageReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}
