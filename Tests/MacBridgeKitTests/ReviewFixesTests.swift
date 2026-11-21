//
//  ReviewFixesTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Date arguments, free-time range cap, update-page validation and client identity.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import Testing

@testable import MacBridgeKit

@Suite("Date arguments that can be cleared")
struct ClearableDateTests {

    @Test("Absent is nil; null and an empty string both clear")
    func absentAndClear() throws {
        #expect(try Arguments([:]).clearableDate("due") == nil)

        let nullCleared = try Arguments(["due": .null]).clearableDate("due")
        #expect(nullCleared != nil && nullCleared! == nil)

        let emptyCleared = try Arguments(["due": .string("")]).clearableDate("due")
        #expect(emptyCleared != nil && emptyCleared! == nil)
    }

    @Test("A date string sets")
    func sets() throws {
        let result = try Arguments(["due": .string("2026-10-01T14:00:00")]).clearableDate("due")
        #expect(result != nil && result! != nil && result!!.hasTime)
    }

    @Test("A number, a boolean or a blank string throws instead of clearing")
    func rejectsNonStrings() {
        let values: [Value] = [.int(1_767_225_600), .double(1.5), .bool(true), .string("   "), .array([])]
        for value in values {
            #expect(throws: MacBridgeError.self) {
                _ = try Arguments(["due": value]).clearableDate("due")
            }
        }
    }

    @Test("The error says what to send instead")
    func message() {
        do {
            _ = try Arguments(["due": .int(5)]).clearableDate("due")
            Issue.record("expected a throw")
        } catch let error as MacBridgeError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("due") && text.contains("date string") && text.contains("clear"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("optionalDate no longer ignores a non-string value")
    func optionalDateRejects() throws {
        #expect(throws: MacBridgeError.self) {
            _ = try Arguments(["start_date": .int(3)]).optionalDate("start_date")
        }
        #expect(try Arguments(["start_date": .null]).optionalDate("start_date") == nil)
    }
}

@Suite("Free-time range cap")
struct FreeBusyCapTests {

    @Test("A far-off end is pulled back to the cap")
    func capped() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let far = start.addingTimeInterval(86_400 * 999_999)
        let result = FreeBusy.cappedEnd(from: start, to: far, maxDays: 365 * 4)
        #expect(result.narrowed)
        #expect(result.end == Calendar.current.date(byAdding: .day, value: 365 * 4, to: start))
        // And the window count stays bounded.
        let windows = FreeBusy.dailyWindows(in: DateInterval(start: start, end: result.end), startHour: 9, endHour: 17)
        #expect(windows.count <= 365 * 4 + 1)
    }

    @Test("A range within the cap is left alone")
    func untouched() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400 * 30)
        let result = FreeBusy.cappedEnd(from: start, to: end, maxDays: 365 * 4)
        #expect(!result.narrowed)
        #expect(result.end == end)
    }
}

@Suite("Update check validation")
struct UpdateCheckValidationTests {

    @Test("Only https github.com pages under this repository are trusted")
    func trustedPages() {
        func trusted(_ s: String) -> Bool { UpdateCheck.isTrustedReleasePage(URL(string: s)!) }
        #expect(trusted("https://github.com/todddube/macOSMCP/releases/tag/v1.9.0"))
        #expect(!trusted("http://github.com/todddube/macOSMCP/releases/tag/v1.9.0"))
        #expect(!trusted("https://evil.example/todddube/macOSMCP/releases/tag/v1.9.0"))
        #expect(!trusted("https://github.com.evil.example/todddube/macOSMCP/releases"))
        #expect(!trusted("https://github.com/someoneelse/macOSMCP/releases/tag/v1.9.0"))
        #expect(!trusted("https://github.com/todddube/macOSMCP-fork/releases"))
        #expect(!trusted("https://user@github.com/todddube/macOSMCP/releases"))
        #expect(!trusted("file:///todddube/macOSMCP/"))
    }

    @Test("A release pointing elsewhere is rejected")
    func untrustedRelease() {
        let body = Data(#"{"tag_name":"v9.9.9","html_url":"https://evil.example/download"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try UpdateCheck.result(fromReleaseJSON: body, current: "1.0.0")
        }
    }

    @Test("A +build suffix doesn't make a version compare as zero")
    func buildMetadata() {
        #expect(UpdateCheck.isNewer("1.10.0+5", than: "1.9.0"))
        #expect(!UpdateCheck.isNewer("1.9.0+7", than: "1.9.0"))
        #expect(!UpdateCheck.isNewer("1.9.0", than: "1.9.0+7"))
        #expect(UpdateCheck.isNewer("2.0.0-rc1+3", than: "1.9.9"))
    }
}

@Suite("Client identity from the process tree")
struct ClientIdentifyTests {

    private let claudeChain = [
        "/Applications/Claude.app/Contents/Helpers/disclaimer",
        "/Applications/Claude.app/Contents/MacOS/Claude",
    ]

    private let shim = "/Applications/MacBridge.app/Contents/MacOS/macbridge"

    @Test("The derived name and executable win over a different claim")
    func derivedWins() {
        let id = ClientNaming.identify(
            claimedName: "Trusted Admin Tool", peerExecutable: shim, ancestors: claudeChain)
        #expect(id.name == "Claude Desktop")
        #expect(id.executable == "/Applications/Claude.app/Contents/MacOS/Claude")
        #expect(id.disagreeingClaim == "Trusted Admin Tool")
    }

    @Test("An agreeing claim leaves nothing to report")
    func agrees() {
        let id = ClientNaming.identify(claimedName: "claude desktop", peerExecutable: shim, ancestors: claudeChain)
        #expect(id.name == "Claude Desktop")
        #expect(id.disagreeingClaim == nil)
    }

    @Test("With nothing derivable the name is Unknown client and the claim is only reported")
    func claimIsNeverTheName() {
        let none = ClientNaming.identify(claimedName: "My Client", peerExecutable: shim, ancestors: [])
        #expect(none.name == "Unknown client")
        #expect(none.disagreeingClaim == "My Client")
        let wrappers = ClientNaming.identify(claimedName: "My Client", peerExecutable: shim, ancestors: ["/bin/zsh"])
        #expect(wrappers.name == "Unknown client")
        #expect(wrappers.disagreeingClaim == "My Client")
        let empty = ClientNaming.identify(claimedName: "", peerExecutable: shim, ancestors: [])
        #expect(empty.name == "Unknown client")
        #expect(empty.disagreeingClaim == nil)
    }

    @Test("A peer that is not the shim is the client itself, whatever it claims or whose child it is")
    func directPeer() {
        // A same-user process connecting straight to the socket, with ancestors that
        // would otherwise name a trusted client.
        let direct = ClientNaming.identify(
            claimedName: "Claude Desktop", peerExecutable: "/tmp/evil/tool", ancestors: claudeChain)
        #expect(direct.name == "tool")
        #expect(direct.executable == "/tmp/evil/tool")
        #expect(direct.disagreeingClaim == "Claude Desktop")

        // Orphaned (ppid 1, no ancestors) and claiming a name: still not trusted.
        let orphan = ClientNaming.identify(
            claimedName: "Claude Desktop", peerExecutable: "/usr/bin/python3", ancestors: [])
        #expect(orphan.name == "Unknown client")
        #expect(orphan.disagreeingClaim == "Claude Desktop")

        let unreadable = ClientNaming.identify(claimedName: "X", peerExecutable: nil, ancestors: [])
        #expect(unreadable.name == "Unknown client")
        #expect(unreadable.disagreeingClaim == "X")
    }

    @Test("The shim is recognised by its executable name, in a bundle or a dev build")
    func shimDetection() {
        #expect(ClientNaming.isShim(executablePath: shim))
        #expect(ClientNaming.isShim(executablePath: "/Users/x/src/.build/debug/macbridge"))
        #expect(ClientNaming.isShim(executablePath: "/Applications/MacBridge.app/Contents/MacOS/MacBridge"))
        #expect(!ClientNaming.isShim(executablePath: "/usr/bin/python3"))
        #expect(!ClientNaming.isShim(executablePath: "/tmp/macbridge-helper"))
        #expect(!ClientNaming.isShim(executablePath: nil))
    }
}
