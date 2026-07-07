import Foundation

/// Suggestions open in Google Maps so the user confirms open hours and live
/// traffic there (deliberate decision — the app has no Places API key).
enum GoogleMapsOpener {
    /// Whether a stored URL opens the exact place page directly. `?cid=` /
    /// `?ftid=` links (scraper, Takeout GeoJSON) and `/maps/place/` paths
    /// do; Takeout list CSVs often export `/maps/search/` URLs, which run a
    /// live search first — those are worth upgrading to a resolved cid.
    static func isExactPlaceURL(_ url: URL) -> Bool {
        if url.path.contains("/maps/place/") { return true }
        let query = url.query ?? ""
        return query.contains("cid=") || query.contains("ftid=")
    }

    static func url(for restaurant: Restaurant) -> URL {
        // Prefer the stored per-place URL (?cid= from the scraper/Takeout) —
        // opens the exact place page.
        if let stored = restaurant.googleMapsURL {
            return stored
        }

        // No cid but coordinates: a name search anchored at the place's own
        // map position. Universal link → opens the Google Maps app on the
        // place card. (An unanchored `comgooglemaps://?q=name` search used
        // to fail with "place not found" for names Google couldn't resolve
        // globally.)
        if let coordinate = restaurant.coordinate {
            let name = restaurant.googleSearchName
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
            let anchor = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
            if let url = URL(string: "https://www.google.com/maps/search/\(encoded)/@\(anchor),17z") {
                return url
            }
        }

        // Last resort (no coordinates): plain text search.
        let query = [restaurant.googleSearchName, restaurant.address ?? ""]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://www.google.com/maps/search/")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query),
        ]
        return components.url!
    }
}
