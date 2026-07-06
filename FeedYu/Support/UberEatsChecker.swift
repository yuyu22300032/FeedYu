import Foundation
import CoreLocation

/// Best-effort "is this restaurant on Uber Eats?" check: fetch the Uber Eats
/// search page for the restaurant's name (with a location cookie so results
/// are local) and look for a matching /store/ link.
///
/// Three outcomes by design:
/// - available: a store link matched — we also capture the exact store URL
///   so the order button deep-links straight to the store.
/// - notFound: the page showed real results but none matched → the engine
///   drops the candidate and rolls another.
/// - unknown: blocked / offline / unparseable → treated as available-enough
///   (the button falls back to a search universal link) so the tab still
///   works when Uber's bot wall says no. ubereats.com 403s obvious CLI
///   clients; a device URLSession with a Safari UA may or may not pass —
///   never assume it does.
@MainActor
final class UberEatsChecker: ObservableObject {
    static let shared = UberEatsChecker()

    enum Availability: Equatable {
        case available(URL?)
        case notFound
        case unknown
    }

    /// Session cache keyed by normalized name (availability changes rarely
    /// within a session; notFound is deliberately not persisted).
    private var cache: [String: Availability] = [:]

    func availability(for restaurant: Restaurant, near origin: CLLocation?) async -> Availability {
        if let url = restaurant.uberEatsURL { return .available(url) }
        let key = restaurant.normalizedName
        if let cached = cache[key] { return cached }
        let result = await Self.fetchAvailability(name: restaurant.name, origin: origin)
        cache[key] = result
        return result
    }

    /// Universal link fallback: opens the Uber Eats app's search when
    /// installed (iOS hands it to the app locally — the bot wall never runs),
    /// else the website in Safari.
    nonisolated static func searchURL(for name: String) -> URL {
        var components = URLComponents(string: "https://www.ubereats.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        return components.url!
    }

    // MARK: - Fetch + parse (nonisolated, fixture-testable)

    nonisolated static func fetchAvailability(name: String, origin: CLLocation?) async -> Availability {
        var request = URLRequest(url: searchURL(for: name))
        request.timeoutInterval = 15
        request.setValue(MichelinNameLocalizer.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GoogleSharedListSource.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let origin {
            // Uber Eats search is location-scoped; uev2.loc carries the point.
            let loc = """
            {"address":{"address1":"FeedYu"},"latitude":\(origin.coordinate.latitude),"longitude":\(origin.coordinate.longitude),"reference":"","referenceType":"uberLatLng","type":"uberLatLng"}
            """
            let encoded = loc.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            request.setValue("uev2.loc=\(encoded)", forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .unknown
        }
        let html = String(decoding: data.prefix(1_500_000), as: UTF8.self)
        return parseAvailability(fromHTML: html, name: name)
    }

    /// A results page reliably carries /store/<slug>/<uuid> hrefs. No store
    /// links at all → we didn't get a real results page → unknown.
    nonisolated static func parseAvailability(fromHTML html: String, name: String) -> Availability {
        let pattern = #"/store/([^/"?\\]+)/([A-Za-z0-9_-]{20,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .unknown }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !matches.isEmpty else { return .unknown }

        let target = Restaurant.normalize(name)
        for match in matches {
            guard let slugRange = Range(match.range(at: 1), in: html),
                  let fullRange = Range(match.range(at: 0), in: html) else { continue }
            let slug = String(html[slugRange]).removingPercentEncoding ?? String(html[slugRange])
            if namesMatch(target, Restaurant.normalize(slug)) {
                let path = String(html[fullRange]).removingPercentEncoding ?? String(html[fullRange])
                return .available(URL(string: "https://www.ubereats.com" + path))
            }
        }
        return .notFound
    }

    /// Tolerant name comparison: containment either way (slugs append
    /// city/branch qualifiers), else a long-enough common prefix (branch
    /// suffixes on OUR side, e.g. "鼎泰豐 信義店" vs slug "鼎泰豐-taipei-101").
    /// CJK prefixes count at 3+ chars (3 ideographs are highly specific);
    /// Latin needs 6+ ("pizzahut" vs "pizzamania" must not match).
    nonisolated static func namesMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.contains(b) || b.contains(a) { return true }
        var prefixLength = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            prefixLength += 1
        }
        guard prefixLength > 0 else { return false }
        let prefix = a.prefix(prefixLength)
        let hasCJK = prefix.unicodeScalars.contains { $0.value >= 0x2E80 }
        return prefixLength >= (hasCJK ? 3 : 6)
    }
}
