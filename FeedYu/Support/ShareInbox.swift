import Foundation

/// Hand-off channel between the share extension and the main app: the
/// extension drops shared Google Maps links here (App Group UserDefaults);
/// the app drains them into shared-list configs when it becomes active.
/// Compiled into BOTH the app and the FeedYuShare extension targets.
enum ShareInbox {
    static let appGroupID = "group.com.yuyu.FeedYu"
    private static let pendingKey = "pendingSharedListURLs"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static func append(_ urlString: String) {
        guard let defaults else { return }
        var pending = defaults.stringArray(forKey: pendingKey) ?? []
        guard !pending.contains(urlString) else { return }
        pending.append(urlString)
        defaults.set(pending, forKey: pendingKey)
    }

    /// Returns all pending links and clears the inbox.
    static func drain() -> [String] {
        guard let defaults else { return [] }
        let pending = defaults.stringArray(forKey: pendingKey) ?? []
        if !pending.isEmpty { defaults.removeObject(forKey: pendingKey) }
        return pending
    }

    /// First http(s) URL inside a shared text blob (Google Maps shares
    /// "Check out my list! https://maps.app.goo.gl/…").
    static func firstHTTPURL(in text: String) -> String? {
        guard let match = text.firstMatch(of: #/https?://[^\s"'<>]+/#) else { return nil }
        return String(match.0)
    }
}
