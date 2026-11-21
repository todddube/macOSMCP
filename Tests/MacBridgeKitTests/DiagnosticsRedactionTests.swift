//
//  DiagnosticsRedactionTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Quoted titles are blanked from diagnostics, apostrophes and paths are not.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Testing

@testable import MacBridgeKit

@Suite("Diagnostics redaction")
struct DiagnosticsRedactionTests {

    @Test("Curly, straight double and straight single quoted spans are blanked")
    func quotedSpans() {
        #expect(DiagnosticsRedaction.redactQuotedText("created \u{201C}Buy milk\u{201D}")
                == "created \u{201C}…\u{201D}")
        #expect(DiagnosticsRedaction.redactQuotedText("deleted \"Dentist\" today") == "deleted \"…\" today")
        #expect(DiagnosticsRedaction.redactQuotedText("'Team sync' repeats weekly") == "'…' repeats weekly")
    }

    @Test("Apostrophes in words and paths are left alone")
    func apostrophesAndPaths() {
        let line = "client didn't answer for Bob's list at /Users/me/Library/App Support/x.log"
        #expect(DiagnosticsRedaction.redactQuotedText(line) == line)
    }

    @Test("An apostrophe before a quoted title does not swallow it")
    func mixed() {
        #expect(DiagnosticsRedaction.redactQuotedText("didn't find 'Lunch' on Bob's list")
                == "didn't find '…' on Bob's list")
    }

    @Test("A single-quoted title containing an apostrophe is blanked whole")
    func apostropheInsideTitle() {
        #expect(DiagnosticsRedaction.redactQuotedText("created 'Bob's party' today") == "created '…' today")
        #expect(DiagnosticsRedaction.redactQuotedText("deleted 'Bob's party'") == "deleted '…'")
        #expect(DiagnosticsRedaction.redactQuotedText("'Don't forget' and 'Lunch'") == "'…' and '…'")
        #expect(DiagnosticsRedaction.redactQuotedText("'Bob's party' isn't Bob's list")
                == "'…' isn't Bob's list")
    }
}
