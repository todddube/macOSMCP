//
//  ClientConfigWriterTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Pins the rules for merging MacBridge into a client's own config file.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// The config belongs to the client, so the merge must add MacBridge and change
/// nothing else, and must refuse rather than overwrite anything it can't read.
@Suite("Client config writer")
struct ClientConfigWriterTests {

    private let shim = "/Applications/MacBridge.app/Contents/MacOS/macbridge"

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func macbridgeEntry(_ data: Data) throws -> [String: Any]? {
        let servers = try object(data)["mcpServers"] as? [String: Any]
        return servers?[ClientConfigWriter.serverKey] as? [String: Any]
    }

    @Test("A missing file becomes a config with just MacBridge")
    func createsFromNothing() throws {
        let data = try ClientConfigWriter.merged(into: nil, shimPath: shim, path: "x")
        let entry = try #require(try macbridgeEntry(data))
        #expect(entry["command"] as? String == shim)
        #expect(entry["args"] as? [String] == ["mcp"])
    }

    @Test("Other servers and settings survive the merge")
    func keepsEverythingElse() throws {
        let existing = Data("""
            {"theme": "dark", "mcpServers": {"other": {"command": "/usr/bin/other"}}}
            """.utf8)
        let data = try ClientConfigWriter.merged(into: existing, shimPath: shim, path: "x")
        let root = try object(data)
        #expect(root["theme"] as? String == "dark")
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "/usr/bin/other")
        #expect(try macbridgeEntry(data)?["command"] as? String == shim)
    }

    @Test("A stale MacBridge entry is repointed at this copy")
    func repointsStaleEntry() throws {
        let existing = Data("""
            {"mcpServers": {"macbridge": {"command": "/old/build/macbridge", "args": ["mcp"]}}}
            """.utf8)
        let data = try ClientConfigWriter.merged(into: existing, shimPath: shim, path: "x")
        #expect(try macbridgeEntry(data)?["command"] as? String == shim)
    }

    @Test("Another entry running MacBridge is folded in, not left as a duplicate")
    func foldsDuplicates() throws {
        let existing = Data("""
            {"mcpServers": {"Calendar": {"command": "/old/MacBridge.app/Contents/MacOS/macbridge"},
                            "other": {"command": "/usr/bin/other"}}}
            """.utf8)
        let data = try ClientConfigWriter.merged(into: existing, shimPath: shim, path: "x")
        let servers = try #require(try object(data)["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["macbridge", "other"])
    }

    @Test("Keys the user added to the entry survive a repair")
    func keepsUserKeys() throws {
        let existing = Data("""
            {"mcpServers": {"macbridge": {"command": "/old/macbridge", "env": {"A": "1"}}}}
            """.utf8)
        let data = try ClientConfigWriter.merged(into: existing, shimPath: shim, path: "x")
        let entry = try #require(try macbridgeEntry(data))
        #expect((entry["env"] as? [String: String]) == ["A": "1"])
        #expect(entry["command"] as? String == shim)
    }

    @Test("An empty file is treated as a new config")
    func emptyFileIsNew() throws {
        let data = try ClientConfigWriter.merged(into: Data(" \n".utf8), shimPath: shim, path: "x")
        #expect(try macbridgeEntry(data) != nil)
    }

    @Test("Unreadable JSON is refused, not overwritten")
    func refusesBadJSON() {
        #expect(throws: ClientConfigWriter.WriteError.unreadable(path: "cfg")) {
            try ClientConfigWriter.merged(into: Data("{not json".utf8), shimPath: shim, path: "cfg")
        }
    }

    @Test("A non-object mcpServers is refused")
    func refusesOddServers() {
        #expect(throws: ClientConfigWriter.WriteError.unexpectedServers(path: "cfg")) {
            try ClientConfigWriter.merged(into: Data(#"{"mcpServers": []}"#.utf8), shimPath: shim, path: "cfg")
        }
    }

    @Test("A symlinked config keeps its link; the target is written")
    func followsSymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientConfigWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("claude_desktop_config.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ClientConfigWriter.install(shimPath: shim, configAt: link)
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try macbridgeEntry(Data(contentsOf: target))?["command"] as? String == shim)
    }

    @Test("Install backs up the original once and writes the merge")
    func installBacksUpOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientConfigWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = dir.appendingPathComponent("claude_desktop_config.json")
        let original = Data(#"{"mcpServers": {}}"#.utf8)
        try original.write(to: config)

        let backup = try #require(try ClientConfigWriter.install(shimPath: shim, configAt: config))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try macbridgeEntry(Data(contentsOf: config))?["command"] as? String == shim)

        // A second install must not replace the user's original with an edited copy.
        try ClientConfigWriter.install(shimPath: "/elsewhere/macbridge", configAt: config)
        #expect(try Data(contentsOf: backup) == original)
    }
}
