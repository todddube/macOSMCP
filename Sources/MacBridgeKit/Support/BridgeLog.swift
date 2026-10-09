//
//  BridgeLog.swift
//  MacBridgeKit · MacBridge
//
//  Logging, to os_log and to a size-capped file.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import os

/// Logging for MacBridge.
///
/// Two destinations, because they answer different questions:
///
/// * **`os_log`** for watching live — `log stream --predicate 'subsystem ==
///   "com.thedubes.macbridge"'` — and for the free structured metadata and
///   redaction the unified log gives.
/// * **A capped file** at `~/Library/Logs/MacBridge/macbridge.log` for history,
///   because the unified log's retention is short and unpredictable, and because a
///   user reporting a problem can attach a file. The in-memory activity list in the
///   menu bar dies with the process, which left crashes and yesterday's failures
///   with no trace at all.
///
/// Everything is `nonisolated` and lock-guarded so any actor or queue can log
/// without ceremony.
public enum BridgeLog {

    /// The unified-log subsystem; filter on it with `log stream` or Console.
    public static let subsystem = "com.thedubes.macbridge"

    /// The unified-log category, also shown in brackets in the file log.
    public enum Category: String, Sendable {
        case bridge
        case tools
        case permissions
        case app
        case cli
    }

    /// Severity. The raw value is the label written to the file log.
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    // MARK: Public API

    /// Unified log only: debug lines are too chatty for the file.
    public static func debug(_ message: String, category: Category = .app) {
        emit(message, level: .debug, category: category)
    }

    public static func info(_ message: String, category: Category = .app) {
        emit(message, level: .info, category: category)
    }

    public static func warning(_ message: String, category: Category = .app) {
        emit(message, level: .warning, category: category)
    }

    public static func error(_ message: String, category: Category = .app) {
        emit(message, level: .error, category: category)
    }

    /// Where the file log lives, for the menu's "Open Log" action.
    public static var fileURL: URL {
        logDirectory.appendingPathComponent("macbridge.log")
    }

    /// `~/Library/Logs/MacBridge`, which also holds the rotated previous log.
    public static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MacBridge", isDirectory: true)
    }

    /// The most recent lines, newest last, for diagnostics reports.
    public static func recentLines(limit: Int = 50) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)).map(String.init)
    }

    // MARK: Implementation

    private static let loggers = OSAllocatedUnfairLock<[String: Logger]>(initialState: [:])
    private static let fileLock = NSLock()

    /// Rotated at 512 KB, one generation kept. Enough to cover a session or two of
    /// history without ever needing attention.
    private static let maximumFileSize = 512 * 1024

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func logger(for category: Category) -> Logger {
        loggers.withLock { cache in
            if let existing = cache[category.rawValue] { return existing }
            let created = Logger(subsystem: subsystem, category: category.rawValue)
            cache[category.rawValue] = created
            return created
        }
    }

    private static func emit(_ message: String, level: Level, category: Category) {
        let log = logger(for: category)
        switch level {
        case .debug: log.debug("\(message, privacy: .public)")
        case .info: log.info("\(message, privacy: .public)")
        case .warning: log.warning("\(message, privacy: .public)")
        case .error: log.error("\(message, privacy: .public)")
        }

        // Debug lines would dominate the file without earning their place there.
        guard level != .debug else { return }
        appendToFile("\(timestamp.string(from: Date()))  \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  [\(category.rawValue)]  \(message)")
    }

    private static func appendToFile(_ line: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

            let url = fileURL
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > maximumFileSize {
                // One generation: the previous file is replaced, not accumulated, so
                // this can never grow without bound and never needs pruning.
                let previous = logDirectory.appendingPathComponent("macbridge.previous.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }

            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // Logging must never take the app down, and there is nowhere left to
            // report a logging failure to; os_log above already has the message.
        }
    }
}
