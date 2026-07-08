import Foundation
import CoreLocation

/// Resolves a place's Google Maps cid (the id behind fast, exact
/// `maps.google.com/?cid=` links) from a coordinate-anchored search page.
/// Used for places the list scraper imported without an id — opening them
/// through a search URL works but is slow (the Maps app runs a live
/// search); a resolved cid makes every later open instant.
///
/// Wire format: the search page HTML embeds each result's feature id as
/// `!1s0x<tile>:0x<id>` with its pin at `!3d<lat>!4d<lng>` nearby. The cid
/// is the DECIMAL value of the id half (this is Google's documented
/// "ludocid"). Proximity to our saved coordinates picks the right result —
/// same principle as the Uber Eats matcher, names lie but pins don't.
enum GooglePlaceResolver {
    /// Accept a result only when its pin is this close to our place.
    /// Looser than the Uber Eats matcher's 100 m: that one matches by name
    /// across a city-wide feed, while this search is already anchored at
    /// the place's own coordinates and nearest-pin-wins — the extra 50 m
    /// mostly forgives coarse Michelin/Takeout geocoding.
    static let matchRadiusMeters: CLLocationDistance = 150

    /// Why a resolution attempt produced no cid matters for caching:
    /// `.noMatch` (data-bearing page, but nothing near our pin — or an
    /// ambiguous tie) won't change on retry; `.unavailable` (network error
    /// or Google's data-less JS shell page, which it serves depending on
    /// client fingerprint/mood) is transient and worth retrying — e.g. the
    /// tap that follows a failed card-display warm-up.
    enum Resolution: Equatable {
        case resolved(String)
        case noMatch
        case unavailable
    }

    static func resolveCid(name: String, coordinate: CLLocationCoordinate2D) async -> Resolution {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let anchor = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        guard let url = URL(string: "https://www.google.com/maps/search/\(encoded)/@\(anchor),17z") else {
            return .noMatch
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // google.com/maps serves the data-bearing page to desktop UAs.
        request.setValue(GoogleSharedListSource.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GoogleSharedListSource.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false else {
            return .unavailable
        }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        return resolution(fromHTML: html, near: coordinate)
    }

    /// Pure classification of a fetched search page (testable).
    static func resolution(fromHTML html: String, near coordinate: CLLocationCoordinate2D) -> Resolution {
        if let cid = extractCid(fromHTML: html, near: coordinate) {
            return .resolved(cid)
        }
        // No feature-id tokens anywhere = the JS shell page (or a format
        // change) — the query never really ran, so don't cache the failure.
        let carriesData = html.firstMatch(of: #/0x[0-9a-fA-F]{6,}:0x[0-9a-fA-F]{1,16}/#) != nil
        return carriesData ? .noMatch : .unavailable
    }

    /// Two *different* places nearly equally close = our saved coordinates
    /// can't tell them apart (food courts, twin branches next door) — refuse
    /// rather than guess (see the guard in `extractCid`).
    static let ambiguityMarginMeters: CLLocationDistance = 40

    /// Feature ids with a pin within `matchRadiusMeters` of `coordinate`;
    /// nearest wins. Tolerant scan — no assumptions about page structure
    /// beyond the `!1s…` / `!3d…!4d…` tokens appearing per result.
    static func extractCid(fromHTML html: String, near coordinate: CLLocationCoordinate2D) -> String? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Nearest pin per distinct cid — the same place usually appears
        // several times in the page and must not trip the ambiguity guard.
        var nearestByCid: [String: CLLocationDistance] = [:]

        for match in html.matches(of: #/0x[0-9a-fA-F]{6,}:0x([0-9a-fA-F]{1,16})/#) {
            // The pin belonging to this feature id sits in the same result
            // blob — scan a window after the id for !3d<lat>!4d<lng>.
            let windowEnd = html.index(match.range.upperBound, offsetBy: 400, limitedBy: html.endIndex) ?? html.endIndex
            let window = html[match.range.upperBound..<windowEnd]
            guard let pin = window.firstMatch(of: #/!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)/#),
                  let latitude = Double(pin.1), let longitude = Double(pin.2),
                  abs(latitude) <= 90, abs(longitude) <= 180 else { continue }
            let distance = target.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            guard distance <= matchRadiusMeters else { continue }
            guard let value = UInt64(String(match.1), radix: 16), value != 0 else { continue }
            let cid = String(value)
            nearestByCid[cid] = min(distance, nearestByCid[cid] ?? .infinity)
        }

        let ranked = nearestByCid.sorted { $0.value < $1.value }
        guard let winner = ranked.first else { return nil }
        // Ambiguity guard: a runner-up almost as close means a coin flip.
        // Returning nil keeps the tap on the visible search page, where the
        // user picks — a wrong cid would be persisted and silently open the
        // wrong restaurant on every future tap. Possible future upgrade:
        // disambiguate by scoring result names (UberEatsChecker.similarity)
        // instead of refusing — needs a name scanner for the search-page
        // blob, and names lie (romanization/translation), so pins must stay
        // the primary signal. See DEVELOPMENT.md backlog.
        if ranked.count > 1, ranked[1].value - winner.value < ambiguityMarginMeters {
            return nil
        }
        return winner.key
    }
}
