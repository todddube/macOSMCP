//
//  LineFramerTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Newline framing of the bridge's byte stream.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// A socket read returns whatever arrived; the framer makes whole lines of it.
@Suite("Line framing")
struct LineFramerTests {

    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("A complete line comes back without its newline")
    func singleLine() throws {
        var framer = LineFramer()
        #expect(strings(try framer.append(Data("hello\n".utf8))) == ["hello"])
    }

    @Test("One chunk can finish several lines")
    func several() throws {
        var framer = LineFramer()
        #expect(strings(try framer.append(Data("a\nb\nc\n".utf8))) == ["a", "b", "c"])
    }

    @Test("A line split across chunks is returned once it completes")
    func split() throws {
        var framer = LineFramer()
        #expect(try framer.append(Data("hel".utf8)).isEmpty)
        #expect(try framer.append(Data("lo".utf8)).isEmpty)
        #expect(strings(try framer.append(Data("\nnext".utf8))) == ["hello"])
        #expect(strings(try framer.append(Data("\n".utf8))) == ["next"])
    }

    @Test("A multibyte character split between chunks survives")
    func multibyte() throws {
        var framer = LineFramer()
        let bytes = Array("café\n".utf8)  // é is two bytes
        let cut = bytes.count - 2
        #expect(try framer.append(Data(bytes[..<cut])).isEmpty)
        #expect(strings(try framer.append(Data(bytes[cut...]))) == ["café"])
    }

    @Test("Carriage returns are trimmed and blank lines skipped")
    func blanksAndCRLF() throws {
        var framer = LineFramer()
        #expect(strings(try framer.append(Data("a\r\n\n\r\nb\n".utf8))) == ["a", "b"])
    }

    @Test("A stream with no newline past the limit throws and is discarded")
    func tooLong() throws {
        var framer = LineFramer(maximumLineLength: 8)
        #expect(try framer.append(Data("12345678".utf8)).isEmpty, "at the limit is still allowed")
        #expect(throws: LineFramer.FramingError.self) {
            _ = try framer.append(Data("9".utf8))
        }
        // The oversized bytes are gone, so the stream can carry on.
        #expect(strings(try framer.append(Data("ok\n".utf8))) == ["ok"])
    }

    @Test("A line that ends in a newline is fine at the limit")
    func longButTerminated() throws {
        var framer = LineFramer(maximumLineLength: 8)
        #expect(strings(try framer.append(Data("abcdefgh\n".utf8))) == ["abcdefgh"])
    }
}
