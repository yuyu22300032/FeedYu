import Foundation
import CoreLocation

/// Lazily fills a suggested restaurant's cover photo + description by
/// scraping a page the app already links to: the Michelin guide page when
/// there is one (rich description + photo), else the Google Maps place page
/// (photo + a thin "rating · price · category" line). Best-effort by design:
/// a failed fetch is negatively cached for the session and the card simply
/// shows no photo. Results persist into the store (fill-only).
@MainActor
final class PlaceInfoFetcher: ObservableObject {
    static let shared = PlaceInfoFetcher()

    struct PlaceInfo: Equatable {
        var summary: String?
        var imageURL: URL?
    }

    private var attemptedIDs: Set<UUID> = []
    private var inFlightIDs: Set<UUID> = []
    /// Negative cache for cid resolution, keyed by the search name used —
    /// when the localizer later fills a local-market name (魚庄 vs "Uosho"),
    /// the place earns one fresh attempt with the better query.
    private var attemptedCidSearchNames: [UUID: String] = [:]

    /// A *definitive* no-match also persists in the store and isn't retried
    /// for this long (each retry is a 1–2 MB search page). Places do gain
    /// Google listings and coordinates get fixed — cooldown, not verdict.
    static let noMatchCooldownSeconds: TimeInterval = 30 * 24 * 3600

    nonisolated static func isInNoMatchCooldown(_ restaurant: Restaurant, searchName: String,
                                                now: Date = Date()) -> Bool {
        guard restaurant.mapsNoMatchName == searchName,
              let at = restaurant.mapsNoMatchAt else { return false }
        return now.timeIntervalSince(at) < noMatchCooldownSeconds
    }

    /// Cid-resolution transport — injectable for tests (the etaProvider /
    /// runJS seam, third instance): the caching policy in `resolvedMapsURL`
    /// below (transient vs definitive, cooldown persistence, fresh-name
    /// retries) is pinned by PlaceInfoFetcherPolicyTests. Production runs
    /// the real coordinate-anchored search.
    static var resolveCid: (String, CLLocationCoordinate2D, Bool) async -> GooglePlaceResolver.Resolution = {
        await GooglePlaceResolver.resolveCid(name: $0, coordinate: $1, allowsExpensiveNetwork: $2)
    }

    /// The stored exact place link, or one resolved (and persisted) right
    /// now. Stored *search* URLs (Takeout list CSVs export those) don't
    /// count — they get upgraded to a cid like URL-less places do.
    /// Gated separately from the summary/image fetch: Michelin places ship
    /// with a CSV summary and get their photo on the first card display, so
    /// hiding resolution behind the info guard gave it one shot, ever — a
    /// single failed attempt left the place on search-URL opens for good.
    /// One resolution attempt per place per session per search name.
    /// `allowsExpensiveNetwork: false` = speculative warm-up etiquette:
    /// skip the 1–2 MB fetch on cellular / Low Data Mode (counts as a
    /// transient failure, so an explicit tap still resolves there).
    func resolvedMapsURL(for restaurant: Restaurant, store: RestaurantStore,
                         allowsExpensiveNetwork: Bool = true) async -> URL? {
        if let stored = restaurant.googleMapsURL, GoogleMapsOpener.isExactPlaceURL(stored) {
            return stored
        }
        let searchName = restaurant.googleSearchName
        guard let coordinate = restaurant.coordinate,
              attemptedCidSearchNames[restaurant.id] != searchName,
              !Self.isInNoMatchCooldown(restaurant, searchName: searchName) else { return nil }
        attemptedCidSearchNames[restaurant.id] = searchName
        // Local-market name first (matches Google's own listing), then the
        // dataset romanization — the pin-proximity match rejects impostors.
        let first = await Self.resolveCid(searchName, coordinate, allowsExpensiveNetwork)
        var cid: String?
        var transient = first == .unavailable
        if case .resolved(let value) = first { cid = value }
        if cid == nil, searchName != restaurant.name {
            let second = await Self.resolveCid(restaurant.name, coordinate, allowsExpensiveNetwork)
            if case .resolved(let value) = second { cid = value }
            transient = transient || second == .unavailable
        }
        guard let cid, let resolved = URL(string: "https://maps.google.com/?cid=\(cid)") else {
            if transient || Task.isCancelled {
                // Only a data-bearing "nothing near our pin" verdict is
                // worth caching. Shell pages / network errors / cancelled
                // fetches (view disappeared mid-warm-up) must not burn the
                // attempt — the card warm-up fails, then the user's tap
                // deserves a real retry.
                attemptedCidSearchNames.removeValue(forKey: restaurant.id)
            } else {
                // Definitive no-match: persist with a cooldown so future
                // sessions don't re-spend the search until it expires (or
                // the localizer changes the search name).
                store.setMapsNoMatch(id: restaurant.id, searchName: searchName)
            }
            return nil
        }
        store.setGoogleMapsURL(id: restaurant.id, url: resolved)
        return resolved
    }

    /// URL for a user tap: the exact place page when a cid is stored or
    /// resolves within `timeout`, else the search fallback. A resolution
    /// that outlives the timeout keeps running and persists its result, so
    /// the next tap opens the exact page.
    func mapsURL(for restaurant: Restaurant, store: RestaurantStore,
                 timeout: TimeInterval = 2.5) async -> URL {
        if let stored = restaurant.googleMapsURL, GoogleMapsOpener.isExactPlaceURL(stored) {
            return stored
        }
        let resolution = Task { await self.resolvedMapsURL(for: restaurant, store: store) }
        let resolved = await withTaskGroup(of: URL?.self) { group in
            group.addTask { await resolution.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }  // detached `resolution` is unaffected
            return await group.next() ?? nil
        }
        return resolved ?? GoogleMapsOpener.url(for: restaurant)
    }

    /// Returns the effective info for a restaurant, fetching it at most once
    /// per session when the store doesn't have it yet.
    func info(for restaurant: Restaurant, store: RestaurantStore) async -> PlaceInfo {
        // Resolve the exact place id first (own gate, see above) — it
        // upgrades slow search-URL opens to instant ?cid= links AND gives
        // the og: fetch below a real place page to read. A stored search
        // URL still serves the og: fetch when resolution comes up empty.
        // Card display is speculative, so Wi-Fi/unmetered only — on
        // cellular the user's tap (full network access) resolves instead.
        let mapsURL = await resolvedMapsURL(for: restaurant, store: store,
                                            allowsExpensiveNetwork: false) ?? restaurant.googleMapsURL

        let existing = PlaceInfo(summary: restaurant.summary, imageURL: restaurant.imageURL)
        guard existing.summary == nil || existing.imageURL == nil else { return existing }
        guard !attemptedIDs.contains(restaurant.id), !inFlightIDs.contains(restaurant.id) else { return existing }
        inFlightIDs.insert(restaurant.id)
        defer {
            inFlightIDs.remove(restaurant.id)
            attemptedIDs.insert(restaurant.id)
        }

        var fetched = PlaceInfo()
        if let michelinURL = restaurant.michelinURL {
            fetched = await Self.fetchInfo(from: MichelinDataSource.localizedGuideURL(michelinURL),
                                           userAgent: MichelinNameLocalizer.mobileUserAgent)
        }
        if fetched.summary == nil, fetched.imageURL == nil, let mapsURL {
            fetched = await Self.fetchInfo(from: mapsURL,
                                           userAgent: GoogleSharedListSource.desktopUserAgent)
        }
        let merged = PlaceInfo(summary: existing.summary ?? fetched.summary,
                               imageURL: existing.imageURL ?? fetched.imageURL)
        store.setPlaceInfo(id: restaurant.id, summary: merged.summary, imageURL: merged.imageURL)
        return merged
    }

    // MARK: - Fetch + parse (nonisolated, fixture-testable)

    nonisolated static func fetchInfo(from url: URL, userAgent: String) async -> PlaceInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GoogleSharedListSource.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false else {
            return PlaceInfo()
        }
        let html = String(decoding: data.prefix(600_000), as: UTF8.self)
        return parseInfo(fromHTML: html)
    }

    /// Tolerant scan of the page head's social-preview metadata — both
    /// Michelin and Google keep these populated even though the page bodies
    /// are JS-rendered.
    nonisolated static func parseInfo(fromHTML html: String) -> PlaceInfo {
        var info = PlaceInfo()
        if let image = metaContent(in: html, keys: ["og:image", "twitter:image"]),
           let url = URL(string: image), url.scheme?.hasPrefix("http") == true,
           !isGenericImage(url) {
            info.imageURL = url
        }
        // Prefer the longest candidate: Michelin's real description usually
        // sits in og:description; the plain meta description is boilerplate.
        let candidates = ["og:description", "twitter:description", "description"]
            .compactMap { metaContent(in: html, keys: [$0]) }
            .filter { !isBoilerplateSummary($0) }
        if let best = candidates.max(by: { $0.count < $1.count }), !best.isEmpty {
            info.summary = String(best.prefix(500))
        }
        return info
    }

    /// Google's generic marketing line ("Find local businesses, view maps
    /// and get driving directions in Google Maps.") is served as the
    /// description for place pages it won't describe — worse than nothing.
    /// The line is LOCALIZED (Accept-Language follows the device), so match
    /// the variants of every language the app ships; each fragment is
    /// distinctive enough not to appear in a real restaurant description.
    nonisolated static func isBoilerplateSummary(_ text: String) -> Bool {
        text.hasPrefix("Find local businesses, view maps")       // en
            || text.contains("尋找本地商家")                        // zh-Hant
            || text.contains("查找本地商家")                        // zh-Hans
            || text.contains("地元のお店やスポットを検索")            // ja (guessed variant)
            || text.contains("乗換案内、路線図、ドライブルート")       // ja (observed live 2026-07-09)
    }

    /// Google serves stock artwork as og:image for places with no photos —
    /// a map tile or the generic geocode pin card. Treat those as "no image"
    /// so the app's own placeholder shows instead.
    nonisolated static func isGenericImage(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return s.contains("staticmap") || s.contains("default_geocode") || s.contains("/tactile/")
    }

    /// `<meta property|name="key" content="…">`, tolerating either attribute
    /// order and single or double quotes.
    nonisolated private static func metaContent(in html: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                "<meta[^>]+(?:property|name|itemprop)=[\"']\(escaped)[\"'][^>]*?content=[\"']([^\"']+)[\"']",
                "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*?(?:property|name|itemprop)=[\"']\(escaped)[\"']",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html) else { continue }
                let decoded = decodeEntities(String(html[range]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    nonisolated static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
