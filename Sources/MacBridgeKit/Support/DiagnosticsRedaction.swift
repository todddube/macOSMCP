//
//  DiagnosticsRedaction.swift
//  MacBridgeKit · MacBridge
//
//  Blanks quoted text in log lines before they go into a public bug report.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Removes quoted spans from log lines, which is where event and reminder titles
/// ended up in older versions.
public enum DiagnosticsRedaction {

    /// `line` with the text inside curly, straight double and straight single quotes
    /// replaced by an ellipsis, keeping the quote marks.
    ///
    /// A straight quote only opens a span after a non-word character and only closes
    /// one before a non-word character or the end, so apostrophes inside words
    /// ("don't", "Bob's") and paths are left alone, and one inside a quoted title
    /// ('Bob's party') does not end it early.
    public static func redactQuotedText(_ line: String) -> String {
        var result = line
        for (pattern, template) in patterns {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }

    private static let patterns: [(pattern: String, template: String)] = [
        ("\u{201C}[^\u{201D}]*\u{201D}", "\u{201C}…\u{201D}"),
        ("(?<![\\p{L}\\p{N}])\"[^\"\\n]*\"(?![\\p{L}\\p{N}])", "\"…\""),
        // Lazy, so the first quote that ends a word closes the span; a quote between
        // letters inside the title ("'Bob's party'") is an apostrophe, not a closer.
        ("(?<![\\p{L}\\p{N}])'[^\\n]*?'(?![\\p{L}\\p{N}])", "'…'"),
    ]
}
