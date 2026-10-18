//
//  UpdateCheck.swift
//  MacBridgeKit · MacBridge
//
//  Asks GitHub for the newest published release and compares it with this one.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Asks GitHub for the newest published release and compares it with this one.
///
/// Only ever run when the user asks (Check for Updates…), never on a timer: the
/// app otherwise makes no network requests at all, and that is worth keeping.
/// The request carries nothing about the user but the app version, in the
/// User-Agent GitHub requires.
public enum UpdateCheck {

    /// What the check found.
    public enum Result: Equatable, Sendable {
        /// This copy is the newest release, or newer (a local build).
        case upToDate(latest: String)
        /// A newer release, with the page to download it from.
        case available(version: String, page: URL)
        /// Nothing has been published yet.
        case noReleases
    }

    /// The newest release that isn't a draft or prerelease, per GitHub.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/todddube/macOSMCP/releases/latest")!

    /// Check GitHub, comparing against `current`.
    public static func run(current: String = MacBridge.version, session: URLSession = .shared) async throws -> Result {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBridge/\(current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // /releases/latest answers 404 until something is published.
        if status == 404 { return .noReleases }
        guard status == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(status)."])
        }
        return try result(fromReleaseJSON: data, current: current)
    }

    /// The result for a `releases/latest` response body.
    static func result(fromReleaseJSON data: Data, current: String) throws -> Result {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latest = version(fromTag: release.tag_name)
        return isNewer(latest, than: current)
            ? .available(version: latest, page: release.html_url)
            : .upToDate(latest: latest)
    }

    /// "v1.9.0" → "1.9.0".
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// True when `candidate` is a later version than `current`, comparing numeric
    /// parts in order, with missing parts as 0 (1.9 equals 1.9.0). Anything after
    /// a hyphen is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
