//
//  JSONText.swift
//  MacBridgeKit · MacBridge
//
//  Renders a result as JSON text, for clients that only read `content`.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// Renders a result `Value` as JSON text.
///
/// Tool results are returned twice over: as `structuredContent` for clients that
/// validate it, and as this text block for the many that only read `content`.
public enum JSONText {

    /// Keys are sorted so output is stable across calls. Never throws: an
    /// unencodable value becomes a JSON error object, since the call has already run.
    public static func encode(_ value: Value, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"result could not be encoded as JSON"}"#
        }
        return text
    }
}
