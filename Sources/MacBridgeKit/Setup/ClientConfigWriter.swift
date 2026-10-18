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
/// The file belongs to the client and may hold other servers, settings and API keys,
/// so the merge only touches MacBridge's own entries: `mcpServers.macbridge`, plus
/// any other entry that runs a `macbridge` binary as plain `macbridge mcp`, which
/// would otherwise launch a stale copy alongside. A file that isn't a JSON object is
/// refused rather than overwritten, a file already correct is not rewritten, its
/// permissions are kept, and copies are made before each change.
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
        // Keep anything the user added to our entry (an `env`, or a flag after `mcp`
        // such as `--direct`); only the binary and the `mcp` subcommand are ours to
        // set. Other entries running a stale copy of MacBridge are folded into this
        // one, so Fix Connection can't leave a duplicate behind — but one with flags
        // of its own was set up on purpose (a `--direct` or development entry) and
        // is left alone.
        var entry = servers[serverKey] as? [String: Any] ?? [:]
        for name in macbridgeEntryNames(in: servers)
        where name != serverKey && isPlainEntry(servers[name]) {
            servers.removeValue(forKey: name)
        }
        let currentArgs = entry["args"] as? [String] ?? []
        let extraFlags = currentArgs.first == "mcp" ? Array(currentArgs.dropFirst()) : []
        entry["command"] = shimPath
        entry["args"] = ["mcp"] + extraFlags
        servers[serverKey] = entry
        root["mcpServers"] = servers

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// An entry that runs MacBridge as nothing more than `macbridge mcp`: a copy of
    /// what Connect writes, possibly pointing at an old build.
    private static func isPlainEntry(_ value: Any?) -> Bool {
        guard let entry = value as? [String: Any] else { return false }
        let args = entry["args"] as? [String] ?? []
        return args.isEmpty || args == ["mcp"]
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

    /// For a client configured through its own CLI, such as `claude mcp add`, which
    /// can't edit an entry in place: the entries to remove before adding MacBridge
    /// again, and the flags to add it with. The same rules as ``merged(into:shimPath:path:)``
    /// — our entry's flags after `mcp` are kept, plain stale copies are removed, and
    /// other entries with flags of their own are left alone.
    public static func reAddPlan(forConfigAt url: URL) -> (remove: [String], flags: [String]) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return ([], []) }

        // `add` refuses a name that exists, so ours goes whatever it runs.
        var remove = macbridgeEntryNames(in: servers).filter { $0 != serverKey && isPlainEntry(servers[$0]) }
        var flags: [String] = []
        if let ours = servers[serverKey] {
            remove.insert(serverKey, at: 0)
            let args = (ours as? [String: Any])?["args"] as? [String] ?? []
            if args.first == "mcp" { flags = Array(args.dropFirst()) }
        }
        return (remove, flags)
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
    /// Two copies are kept beside the file:
    /// - `<name>.macbridge-backup`, the original from before MacBridge first edited
    ///   it, written once and never replaced;
    /// - `<name>.macbridge-previous`, the file as it was just before this edit, so
    ///   months of the user's own changes since the first backup aren't lost to a
    ///   bad merge.
    ///
    /// Nothing is written when the file already says what the merge would, which
    /// spares it a reformat. The rewrite is atomic, which replaces the file, so its
    /// permissions are restored afterwards; a new file is created readable by the
    /// user only, since client configs often hold API keys in `env`.
    ///
    /// A symlinked config is followed and its target written, so a dotfiles setup
    /// keeps its link rather than having it replaced by a plain file.
    ///
    /// - Returns: The original's backup, or nil when there was no file to back up.
    @discardableResult
    public static func install(shimPath: String, configAt link: URL) throws -> URL? {
        let url = link.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let existing = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let updated = try merged(into: existing, shimPath: shimPath, path: url.path)

        guard let existing else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            // Created private, rather than written and then tightened, so there is no
            // moment at which it is readable by others.
            guard fileManager.createFile(atPath: url.path, contents: updated,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return nil
        }

        let backup = url.appendingPathExtension("macbridge-backup")
        if sameJSON(existing, updated) {
            return fileManager.fileExists(atPath: backup.path) ? backup : nil
        }

        let permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: url, to: backup)
        }
        let previous = url.appendingPathExtension("macbridge-previous")
        try existing.write(to: previous, options: .atomic)

        try updated.write(to: url, options: .atomic)
        if let permissions {
            // The copies hold the same API keys as the file, so they get its mode too.
            for copy in [url, previous, backup] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: copy.path)
            }
        }
        return backup
    }

    /// Whether two configs hold the same JSON, whatever their formatting.
    private static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
              let right = try? JSONSerialization.jsonObject(with: b) as? NSDictionary
        else { return false }
        return left.isEqual(right)
    }
}
