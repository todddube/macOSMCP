//
//  ClientNaming.swift
//  MacBridgeKit · MacBridge
//
//  Works out which AI client is connected, from the process tree.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Darwin
import Foundation

/// Works out which AI client is on the other end of a shim.
///
/// MCP only tells a server the client's name at `initialize`, which happens *after*
/// the bridge handshake needs it, so the process tree is what is available at the
/// right moment.
///
/// It has to be a tree walk, not just the parent: Claude Desktop spawns MCP servers
/// through `Claude.app/Contents/Helpers/disclaimer`, so reading only the immediate
/// parent labelled every Claude Desktop connection `disclaimer` in the menu bar.
public enum ClientNaming {

    /// Process names that are wrappers rather than the client itself, so the walk
    /// keeps going past them.
    static let passthroughNames: Set<String> = [
        "disclaimer", "node", "bun", "deno", "npx", "sh", "zsh", "bash", "login",
        "env", "python", "uv", "uvx", "launchd", "xargs", "sudo", "ruby", "perl",
        "tmux", "screen", "make", "open", "timeout", "gtimeout", "nice", "stdbuf",
        "script", "time",
    ]

    /// App bundle name → display name.
    ///
    /// Checked *before* executable names, because the two collide: the Claude Code
    /// CLI binary is named `claude`, and so is the executable inside `Claude.app`.
    /// Matching the executable first labelled Claude Desktop as "Claude Code".
    static let knownApps: [String: String] = [
        "claude": "Claude Desktop",
        "cursor": "Cursor",
        "visual studio code": "VS Code",
        "code": "VS Code",
        "windsurf": "Windsurf",
        "zed": "Zed",
        "warp": "Warp",
        "raycast": "Raycast",
        "lm studio": "LM Studio",
        "msty studio": "Msty Studio",
        "chatwise": "ChatWise",
    ]

    /// Executable name → display name, for clients that are plain binaries.
    static let knownExecutables: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "goose": "goose",
        "cursor": "Cursor",
        "code": "VS Code",
        "zed": "Zed",
    ]

    /// True when a process name is a wrapper to be walked past.
    ///
    /// Not an exact set lookup: interpreters carry version suffixes — `python3.13`,
    /// `ruby2.7`, `node-18` — and matching literally meant a shim spawned by
    /// `python3.13` reported the interpreter as the client.
    static func isPassthrough(_ name: String) -> Bool {
        if passthroughNames.contains(name) { return true }
        return passthroughNames.contains { base in
            guard name.hasPrefix(base) else { return false }
            let suffix = name.dropFirst(base.count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        }
    }

    /// Pick a display name from a chain of ancestor executable paths, nearest first.
    ///
    /// Pure, so the rule is testable without spawning processes.
    public static func friendlyName(forChain chain: [String]) -> String {
        var fallback: String?

        for path in chain {
            let base = (path as NSString).lastPathComponent
            let key = base.lowercased()

            // The enclosing .app wins over the executable name — see knownApps.
            if let appName = enclosingAppName(of: path) {
                if let known = knownApps[appName.lowercased()] { return known }
                if fallback == nil { fallback = appName }
            }

            if let known = knownExecutables[key] { return known }

            if fallback == nil, !isPassthrough(key) { fallback = base }
        }
        return fallback ?? "Unknown client"
    }

    /// `/Applications/Claude.app/Contents/Helpers/disclaimer` → `Claude`.
    static func enclosingAppName(of path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        // Walk up a bounded number of levels looking for a .app wrapper.
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                return url.deletingPathExtension().lastPathComponent
            }
            if url.path == "/" { break }
        }
        return nil
    }

    // MARK: Live process tree

    /// Executable paths of this process's ancestors, nearest first.
    public static func ancestorExecutables(
        startingAt pid: pid_t = getppid(),
        maximumDepth: Int = 6
    ) -> [String] {
        var chain: [String] = []
        var current = pid

        for _ in 0..<maximumDepth {
            guard current > 1 else { break }
            if let path = ClientIdentity.executablePath(forPID: current) {
                chain.append(path)
            }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return chain
    }

    /// The parent of `pid`, via sysctl — there is no Swift overlay for this.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The client's own executable path, skipping shell and helper wrappers.
    ///
    /// Reported to the app so its log and menu name the real client rather than the
    /// shim, which is all the server can observe on its own.
    public static func clientExecutable() -> String? {
        let chain = ancestorExecutables()
        return chain.first { path in
            !isPassthrough((path as NSString).lastPathComponent.lowercased())
        } ?? chain.first
    }

    /// The name to report for the client that spawned this process.
    public static func detectClientName() -> String {
        friendlyName(forChain: ancestorExecutables())
    }
}
