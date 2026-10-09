//
//  ClientConfigWriter.swift
//  MacBridgeKit · MacBridge
//
//  Adds MacBridge to an MCP client's JSON config file, keeping everything else in it.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Writes the `macbridge` entry into an MCP client config such as Claude Desktop's
/// `claude_desktop_config.json`, so connecting a client is one click rather than
/// hand-editing JSON.
///
/// The file belongs to the client and may hold other servers and settings, so the
/// merge only touches MacBridge's own entries: `mcpServers.macbridge`, plus any other
/// entry whose command runs a `macbridge` binary, which would otherwise launch a
/// stale copy alongside. A file that isn't a JSON object is refused rather than
/// overwritten, and the original is copied aside before the first change.
public enum ClientConfigWriter {

    /// The key MacBridge is registered under in `mcpServers`.
    public static let serverKey = "macbridge"

    /// Why a config could not be updated, worded for the panel.
    public enum WriteError: Error, LocalizedError, Equatable {
        /// The existing file isn't a JSON object, so merging into it could lose data.
        case unreadable(path: String)
        /// `mcpServers` exists but isn't an object.
        case unexpectedServers(path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return "\(path) isn't valid JSON, so it was left untouched. Fix or remove it, then try again."
            case .unexpectedServers(let path):
                return "\(path) has an \"mcpServers\" entry MacBridge doesn't understand, so it was left untouched."
            }
        }
    }

    /// The config with MacBridge added or repointed at `shimPath`.
    ///
    /// Pure, so the merge rules are testable without touching a real client's file.
    ///
    /// - Parameters:
    ///   - existing: The file's current contents, or nil when there is no file yet.
    ///   - shimPath: The `macbridge` binary inside the installed app.
    ///   - path: Used only to word errors.
    /// - Throws: ``WriteError`` when the existing contents can't be merged safely.
    public static func merged(into existing: Data?, shimPath: String, path: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw WriteError.unreadable(path: path)
            }
            root = object
        }

        var servers: [String: Any] = [:]
        if let current = root["mcpServers"] {
            guard let object = current as? [String: Any] else {
                throw WriteError.unexpectedServers(path: path)
            }
            servers = object
        }
        // Keep anything the user added to our entry (an `env`, say); only the launch
        // command is ours to set. Other entries running some copy of MacBridge are
        // folded into this one, so Fix Connection can't leave a duplicate behind.
        var entry = servers[serverKey] as? [String: Any] ?? [:]
        for name in macbridgeEntryNames(in: servers) where name != serverKey {
            servers.removeValue(forKey: name)
        }
        entry["command"] = shimPath
        entry["args"] = ["mcp"]
        servers[serverKey] = entry
        root["mcpServers"] = servers

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// The names of the entries in an `mcpServers` object that run some copy of
    /// MacBridge, so a repair can remove every one of them.
    public static func macbridgeEntryNames(in servers: [String: Any]) -> [String] {
        servers.compactMap { name, value in
            guard let command = (value as? [String: Any])?["command"] as? String,
                  ClientSetup.isMacBridgeCommand(command)
            else { return nil }
            return name
        }.sorted()
    }

    /// The MacBridge entry names in a config file's top-level `mcpServers`, or none
    /// when the file is missing or unreadable.
    public static func macbridgeEntryNames(inConfigAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [] }
        return macbridgeEntryNames(in: servers)
    }

    /// Add MacBridge to the config at `url`, creating the file if needed.
    ///
    /// The original is copied to `<name>.macbridge-backup` beside it first, once:
    /// an existing backup is kept, so repeated connects never replace the user's
    /// own original with a file MacBridge already edited.
    ///
    /// A symlinked config is followed and its target written, so a dotfiles setup
    /// keeps its link rather than having it replaced by a plain file.
    ///
    /// - Returns: The backup's location, or nil when there was no file to back up.
    @discardableResult
    public static func install(shimPath: String, configAt link: URL) throws -> URL? {
        let url = link.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let existing = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let updated = try merged(into: existing, shimPath: shimPath, path: url.path)

        var backup: URL?
        if existing != nil {
            let candidate = url.appendingPathExtension("macbridge-backup")
            if !fileManager.fileExists(atPath: candidate.path) {
                try fileManager.copyItem(at: url, to: candidate)
            }
            backup = candidate
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
        }

        try updated.write(to: url, options: .atomic)
        return backup
    }
}
