import Foundation

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

    /// Returns the effective info for a restaurant, fetching it at most once
    /// per session when the store doesn't have it yet.
    func info(for restaurant: Restaurant, store: RestaurantStore) async -> PlaceInfo {
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
        if fetched.summary == nil, fetched.imageURL == nil, let mapsURL = restaurant.googleMapsURL {
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
        if let best = candidates.max(by: { $0.count < $1.count }), !best.isEmpty {
            info.summary = String(best.prefix(500))
        }
        return info
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
