//
//  ClientSetup.swift
//  MacBridgeKit · MacBridge
//
//  Whether the Claude clients are installed and pointed at this app.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Whether the AI clients that use MacBridge are installed, and whether they have
/// actually been pointed at this app.
///
/// MacBridge does nothing on its own: a client has to be configured to spawn
/// `macbridge mcp`. That step is easy to forget and produces no error anywhere —
/// the app just sits in the menu bar with nothing connected — so the panel states
/// it plainly instead of leaving the user to guess.
public struct ClientSetup: Identifiable, Sendable {

    /// How far along a client's setup is, best first.
    public enum Status: Sendable, Equatable {
        /// Configured, and pointing at this copy of the app.
        case ready
        /// Configured, but pointing somewhere else — usually a stale build path.
        case pointsElsewhere(String)
        /// Installed, but MacBridge is not in its config.
        case notConfigured
        /// Not installed on this Mac.
        case notInstalled
    }

    public let id: String
    public let name: String
    public let status: Status
    /// The config file this was read from, for the panel to show.
    public let configPath: String

    public var isReady: Bool { status == .ready }

    // MARK: Detection

    /// Inspect both Claude clients. `shimPath` is the binary a config must name.
    public static func detect(shimPath: String) -> [ClientSetup] {
        [claudeCode(shimPath: shimPath), claudeDesktop(shimPath: shimPath)]
    }

    /// Claude Code keeps its MCP servers in ~/.claude.json.
    private static func claudeCode(shimPath: String) -> ClientSetup {
        let config = home.appendingPathComponent(".claude.json")
        let installed = claudeCLIPath() != nil || FileManager.default.fileExists(atPath: config.path)

        return ClientSetup(
            id: "claude-code",
            name: "Claude Code",
            status: installed ? status(ofConfigAt: config, shimPath: shimPath) : .notInstalled,
            configPath: config.path
        )
    }

    private static func claudeDesktop(shimPath: String) -> ClientSetup {
        let config = home
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        let installed = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: config.path)

        return ClientSetup(
            id: "claude-desktop",
            name: "Claude Desktop",
            status: installed ? status(ofConfigAt: config, shimPath: shimPath) : .notInstalled,
            configPath: config.path
        )
    }

    /// Read the `mcpServers` commands out of an MCP client config file.
    private static func status(ofConfigAt url: URL, shimPath: String) -> Status {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return .notConfigured }

        let commands = servers.values.compactMap { ($0 as? [String: Any])?["command"] as? String }
        return status(forCommands: commands, shimPath: shimPath)
    }

    /// Decide the status from the commands a config declares.
    ///
    /// Split out from the file reading so the rule is directly testable. Comparing
    /// the *path* rather than just looking for a server named "macbridge" is what
    /// catches a config left over from a DerivedData build: that one would otherwise
    /// look configured and then fail when the user next tried to use it.
    public static func status(forCommands commands: [String], shimPath: String) -> Status {
        if commands.contains(shimPath) { return .ready }

        if let ours = commands.first(where: isMacBridgeCommand) {
            return .pointsElsewhere(ours)
        }
        return .notConfigured
    }

    /// Whether a configured command runs some copy of MacBridge, whatever the
    /// server entry is called: its binary is named `macbridge`.
    public static func isMacBridgeCommand(_ command: String) -> Bool {
        (command as NSString).lastPathComponent.caseInsensitiveCompare("macbridge") == .orderedSame
    }

    // MARK: Helpers

    private static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Where the `claude` CLI lives, if it is installed.
    ///
    /// A GUI app inherits almost no PATH, so `which claude` is useless here and the
    /// usual install locations are checked directly.
    public static func claudeCLIPath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
